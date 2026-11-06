// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.t.sol";
import {OracleVault} from "../src/venue/OracleVault.sol";
import {SettingsTimelock} from "../src/settings/SettingsTimelock.sol";
import {SwapRouter} from "../src/venue/SwapRouter.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {Types, Roles} from "../src/libraries/Types.sol";

/// @notice Full-path swap coverage against the vault. Verifies pricing matches the published formula, how fees
///         split, skew, caps and bands, two-leg routes, and where eligibility checks do and do not apply.
contract SwapRouterTest is Fixture {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
        _seed(spyVault, SPY_MID);
    }

    function test_buyPricesOffTheFormula() public {
        uint256 amountIn = 10_000e6;
        uint256 out = _swap(address(usdg), address(nvda), amountIn);

        // Balanced inventory in a regular session means zero skew, a 10 bps half-spread, and 2 bps taken from the input.
        uint256 expected = _expectedBuyOut(amountIn, NVDA_MID, 10);
        assertEq(out, expected);
        assertEq(nvda.balanceOf(trader), 1_000e18 + expected);

        // LPs keep the spread minus a 10% share, which goes to ProtocolTreasury along with the explicit fee.
        uint256 fee = amountIn * 2 / 10_000;
        uint256 net = amountIn - fee;
        uint256 spread = net - expected * NVDA_MID / 1e18;
        assertEq(usdg.balanceOf(address(fees)), fee + spread * 1000 / 10_000);
    }

    function test_sellPricesOffTheFormula() public {
        uint256 amountIn = 50e18;
        uint256 out = _swap(address(nvda), address(usdg), amountIn);

        uint256 bid = NVDA_MID * (10_000 - 10) / 10_000;
        uint256 gross = amountIn * bid / 1e18;
        uint256 expected = gross - gross * 2 / 10_000;
        assertEq(out, expected);
    }

    function test_breakdownIsItemised() public view {
        (uint256 out, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);
        assertGt(out, 0);
        assertEq(b.mid, NVDA_MID);
        assertEq(b.halfSpreadBps, 10);
        assertEq(b.skewBps, 0);
        assertEq(b.feeBps, 2);
        assertEq(uint8(b.session), uint8(Types.Session.Regular));
    }

    function test_skewTightensTheRebalancingSide() public {
        // Push token inventory under its target. Relative to a balanced book, buys should then cost more and
        // sells into the vault should pay better.
        _swap(address(usdg), address(nvda), 40_000e6);
        _swap(address(usdg), address(nvda), 40_000e6);

        (, Types.Breakdown memory buySide) = nvdaVault.quoteSwap(true, 10_000e6);
        (, Types.Breakdown memory sellSide) = nvdaVault.quoteSwap(false, 50e18);
        assertLt(buySide.skewBps, 0);
        assertGt(buySide.halfSpreadBps, 10);
        assertLt(sellSide.halfSpreadBps, 10);
    }

    function test_inventoryBandMakesVaultOneSided() public {
        // Withdraw the bulk of liquidity so the vault is small enough for a single clip to reach the band limit.
        vm.startPrank(lp1);
        nvdaVault.withdraw(nvdaVault.balanceOf(lp1) * 9 / 10, lp1);
        vm.stopPrank();

        // With 100k in total (50k per side) and a 20% band, a 15k buy is allowed but another 10k crosses the limit.
        _swap(address(usdg), address(nvda), 15_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 10_000e6, 0));

        // Quotes remain available in the rebalancing direction.
        uint256 out = _swap(address(nvda), address(usdg), 10e18);
        assertGt(out, 0);
    }

    function test_sellSideBandSimulationMatchesTheFill() public {
        // Set the fee high enough to shift inventory figures, widen the band to accommodate that, and raise the
        // clip so one sell is able to reach the band limit.
        vm.startPrank(gov);
        params.setFeeParams(ISettingsTimelock.FeeParams({swapFeeBps: 1000, rfqFeeBps: 2, spreadShareBps: 1000}));
        params.setTierConfig(
            1,
            ISettingsTimelock.TierConfig({
                baseHalfSpreadBps: 10,
                maxSkewBps: 15,
                inventoryBandBps: 2000,
                oracleBandBps: 1100,
                maxClip: 1_000_000e6,
                enabled: true
            })
        );
        vm.stopPrank();
        nvda.mint(trader, 2_000e18);

        // For sells, the fee comes out of gross proceeds yet leaves the vault for ProtocolTreasury together with
        // the spread share, so vault quote holdings fall by the full gross amount. Measured like this, the
        // 500k/500k vault overshoots its 20% band by a small margin after a 208k sell. Had the simulation kept the fee inside
        // the vault, the trade would have looked within the band and been filled.
        uint256 pastTheEdge = 208_000e6 * 1e18 / NVDA_MID;
        vm.expectRevert(OracleVault.InventoryBandExceeded.selector);
        nvdaVault.quoteSwap(false, pastTheEdge);

        // When a sell clears the band check at preview time, the actual transfers also keep the vault within the band.
        uint256 insideTheEdge = 190_000e6 * 1e18 / NVDA_MID;
        _swap(address(nvda), address(usdg), insideTheEdge);
        assertLe(nvdaVault.inventoryRatioBps() - 5_000, 2_000);
    }

    function test_clipBoundsSingleSwap() public {
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 60_000e6, 0));
    }

    function test_dailyVolumeCap() public {
        vm.prank(gov);
        params.setMarketConfig(
            address(nvda),
            ISettingsTimelock.MarketConfig({tier: 1, dailyVolumeCap: 30_000e6, tvlCap: 5_000_000e6, enabled: true})
        );
        assertEq(nvdaVault.remainingDailyCap(), 30_000e6);
        _swap(address(usdg), address(nvda), 20_000e6);
        assertEq(nvdaVault.remainingDailyCap(), 10_000e6);

        // Enforcing the cap at quote time keeps preview and fill consistent: SwapRouter treats a capped vault
        // as offering no quote instead of reverting partway through the trade.
        vm.expectRevert(OracleVault.DailyCapExceeded.selector);
        nvdaVault.quoteSwap(true, 20_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 20_000e6, 0));

        // Trading exactly the reported headroom succeeds.
        assertGt(_swap(address(usdg), address(nvda), 10_000e6), 0);
        assertEq(nvdaVault.remainingDailyCap(), 0);

        // A new UTC day resets the cap. Update the feed too, so the price is not stale.
        vm.warp(block.timestamp + 1 days);
        nvdaFeed.set(int256(NVDA_PRICE_8));
        assertEq(nvdaVault.remainingDailyCap(), 30_000e6);
        assertGt(_swap(address(usdg), address(nvda), 20_000e6), 0);
    }

    function test_slippageBoundReverts() public {
        uint256 expected = _expectedBuyOut(10_000e6, NVDA_MID, 10);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.Slippage.selector, expected, expected + 1));
        router.swapExactIn(_params(address(usdg), address(nvda), 10_000e6, expected + 1));
    }

    function test_twoLegSwapThroughTheQuoteAsset() public {
        uint256 amountIn = 20e18; // NVDA in, SPY out
        uint256 out = _swap(address(nvda), address(spy), amountIn);

        // First leg: NVDA sold at the bid, less fee. Second leg: the resulting USDG buys SPY at the ask, fee taken from input.
        uint256 bid = NVDA_MID * (10_000 - 10) / 10_000;
        uint256 leg1Gross = amountIn * bid / 1e18;
        uint256 leg1Out = leg1Gross - leg1Gross * 2 / 10_000;
        uint256 expected = _expectedBuyOut(leg1Out, SPY_MID, 10);
        assertEq(out, expected);
        assertEq(spy.balanceOf(trader), 100e18 + expected);
    }

    function test_previewMatchesTheFill() public {
        // One-hop route served by the vault.
        SwapRouter.SwapParams memory p = _params(address(usdg), address(nvda), 10_000e6, 0);
        (uint256 previewed, Types.Venue venue) = router.previewExactIn(p);
        assertEq(uint8(venue), uint8(Types.Venue.Vault));
        vm.prank(trader);
        assertEq(router.swapExactIn(p), previewed);

        // Route via USDG in two hops, quoting the second on the output of the first.
        p = _params(address(nvda), address(spy), 20e18, 0);
        (previewed, venue) = router.previewExactIn(p);
        assertEq(uint8(venue), uint8(Types.Venue.Vault));
        vm.prank(trader);
        assertEq(router.swapExactIn(p), previewed);

        // When a maker beats the vault price, the preview reports the RFQ venue along with the net amount to the trader.
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut + vaultOut / 1000, 42);
        p = _params(address(usdg), address(nvda), amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        (previewed, venue) = router.previewExactIn(p);
        assertEq(uint8(venue), uint8(Types.Venue.Rfq));
        assertEq(previewed, q.amountOut);
        vm.prank(trader);
        assertEq(router.swapExactIn(p), previewed);
    }

    function test_previewRaisesTheFillsErrors() public {
        // For a halted market the preview shows zero liquidity, consistent with how a fill would behave.
        nvda.setOraclePaused(true);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.previewExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));
        nvda.setOraclePaused(false);

        // Two-hop routes surface the vault's error directly; in this case, the sell leg's clip limit.
        vm.expectRevert(abi.encodeWithSelector(OracleVault.ClipExceeded.selector, 300e18 * NVDA_MID / 1e18, 50_000e6));
        router.previewExactIn(_params(address(nvda), address(spy), 300e18, 0));

        // Preview and fill both treat a maker quote on a two-hop swap as caller error and reject it.
        SwapRouter.SwapParams memory p = _params(address(nvda), address(spy), 1e18, 0);
        p.quote = _makerQuote(address(nvda), address(spy), 1e18, 1e18, 43);
        vm.expectRevert(SwapRouter.QuoteNotApplicable.selector);
        router.previewExactIn(p);
    }

    function test_traderEligibilityEnforced() public {
        usdg.mint(outsider, 10_000e6);
        vm.startPrank(outsider);
        usdg.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, outsider, Roles.TRADER));
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));
        vm.stopPrank();
    }

    function test_recipientEligibilityEnforced() public {
        SwapRouter.SwapParams memory p = _params(address(usdg), address(nvda), 1_000e6, 0);
        p.to = outsider;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, outsider, Roles.TRADER));
        router.swapExactIn(p);
    }

    function test_guardianPauseStopsSwapsOnly() public {
        vm.prank(guardian);
        params.setPaused(true);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.SwapsPaused.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));

        // Quoting is disabled during a pause as well, so a preview cannot promise an unexecutable trade.
        vm.expectRevert(OracleVault.SwapsPaused.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Pausing is open to the guardian, unpausing is not. If the guardian key were compromised, it must not
        // restart trading during an incident, so only the owner can lift the pause.
        vm.prank(guardian);
        vm.expectRevert(SettingsTimelock.NotOwner.selector);
        params.setPaused(false);
        vm.prank(gov);
        params.setPaused(false);
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
    }

    function test_swapOnlyThroughRouter() public {
        vm.prank(trader);
        vm.expectRevert(OracleVault.NotRouter.selector);
        nvdaVault.swap(true, 1_000e6, trader);
    }

    function test_deadlineEnforced() public {
        SwapRouter.SwapParams memory p = _params(address(usdg), address(nvda), 1_000e6, 0);
        p.deadline = block.timestamp - 1;
        vm.prank(trader);
        vm.expectRevert(SwapRouter.Expired.selector);
        router.swapExactIn(p);
    }

    function test_oversizeOrdersFailForTheirOwnReason() public {
        // An amount well beyond the clip has to revert with the clip error, which pins down the order of checks.
        // If inventory were simulated before the clip test, this buy would drive the token balance below zero
        // and revert with a Panic, both for a direct vault quote and for the router's two-hop preview.
        vm.expectRevert(abi.encodeWithSelector(OracleVault.ClipExceeded.selector, 1_000_000e6, 50_000e6));
        nvdaVault.quoteSwap(true, 1_000_000e6);
        uint256 sellLeg = 6_000e18 * NVDA_MID / 1e18;
        vm.expectRevert(abi.encodeWithSelector(OracleVault.ClipExceeded.selector, sellLeg, 50_000e6));
        router.previewExactIn(_params(address(nvda), address(spy), 6_000e18, 0));

        // Within the clip but beyond what the vault holds: reduce it to 25k per side and request 30k of
        // each asset. The error states the real shortfall rather than failing inside the token transfer.
        uint256 lpShares = nvdaVault.balanceOf(lp1);
        vm.prank(lp1);
        nvdaVault.withdraw(lpShares * 95 / 100, lp1);
        uint256 tokenBal = nvda.balanceOf(address(nvdaVault));
        uint256 quoteBal = usdg.balanceOf(address(nvdaVault));

        uint256 wanted = _expectedBuyOut(30_000e6, NVDA_MID, 10);
        vm.expectRevert(abi.encodeWithSelector(OracleVault.InsufficientInventory.selector, wanted, tokenBal));
        nvdaVault.quoteSwap(true, 30_000e6);

        uint256 sellIn = 30_000e6 * 1e18 / NVDA_MID;
        uint256 gross = sellIn * (NVDA_MID * (10_000 - 10) / 10_000) / 1e18;
        uint256 owed = gross + (sellIn * NVDA_MID / 1e18 - gross) * 1000 / 10_000;
        vm.expectRevert(abi.encodeWithSelector(OracleVault.InsufficientInventory.selector, owed, quoteBal));
        nvdaVault.quoteSwap(false, sellIn);

        // In both cases SwapRouter sees no vault quote, which leaves room for a maker fill.
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 30_000e6, 0));
    }

    function test_rebalancingSideKeepsQuotingOutsideTheBand() public {
        // A price move can carry the vault beyond its band even though trades cannot. A 3x NVDA price puts the token
        // side at 75% of value against a 20% band. The price move cap stays inactive here, since nothing is checkpointed.
        nvdaFeed.set(int256(NVDA_PRICE_8 * 3));
        uint256 driftBefore = nvdaVault.inventoryRatioBps() - 5_000;
        assertGt(driftBefore, 2_000);

        // Further NVDA sells into the vault would worsen the skew, so they remain rejected.
        vm.expectRevert(OracleVault.InventoryBandExceeded.selector);
        nvdaVault.quoteSwap(false, 10e18);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(nvda), address(usdg), 10e18, 0));

        // NVDA buys bring the vault closer to target and have to be permitted despite finishing outside
        // the band. Blocking them as well would lock the market in the one direction able to repair it.
        uint256 out = _swap(address(usdg), address(nvda), 10_000e6);
        assertGt(out, 0);
        uint256 driftAfter = nvdaVault.inventoryRatioBps() - 5_000;
        assertLt(driftAfter, driftBefore);
        assertGt(driftAfter, 2_000); // imbalance persists, still outside the band
        vm.expectRevert(OracleVault.InventoryBandExceeded.selector);
        nvdaVault.quoteSwap(false, 10e18);
    }
}
