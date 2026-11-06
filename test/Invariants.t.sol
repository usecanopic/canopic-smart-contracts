// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.t.sol";
import {OracleVault} from "../src/venue/OracleVault.sol";
import {RfqSettler} from "../src/venue/RfqSettler.sol";
import {SwapRouter} from "../src/venue/SwapRouter.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {Types, Roles} from "../src/libraries/Types.sol";

/// @notice Fuzzes the central guarantees across random trade sizes and market conditions: every fill matches
///         its preview, executes at a price within the oracle band and leaves inventory inside its band, neither
///         swaps nor deposits reduce value per share, and withdrawals always go through.
contract InvariantTest is Fixture {
    uint256 internal seedShares;

    function setUp() public override {
        super.setUp();
        seedShares = _seed(nvdaVault, NVDA_MID);
        _seed(spyVault, SPY_MID);
        // An initial trade moves value per share off 1:1, which puts the rounding paths under test.
        _swap(address(usdg), address(nvda), 10_000e6);
    }

    function testFuzz_vaultPreviewMatchesTheFill(bool buyToken, uint256 amountIn) public {
        // Covers both directions, from dust amounts up to slightly beyond the normal clip size.
        amountIn = buyToken ? bound(amountIn, 1, 60_000e6) : bound(amountIn, 1, 340e18);
        SwapRouter.SwapParams memory p = buyToken
            ? _params(address(usdg), address(nvda), amountIn, 0)
            : _params(address(nvda), address(usdg), amountIn, 0);

        uint256 previewed;
        try nvdaVault.quoteSwap(buyToken, amountIn) returns (uint256 out, Types.Breakdown memory) {
            previewed = out;
        } catch {}

        if (previewed == 0) {
            // The vault gave no usable price (a revert or zero), so SwapRouter treats it as having no quote.
            vm.prank(trader);
            vm.expectRevert(SwapRouter.NoLiquidity.selector);
            router.swapExactIn(p);
            return;
        }

        uint256 valuePerShareBefore = nvdaVault.totalValue() * 1e18 / nvdaVault.totalSupply();
        vm.prank(trader);
        uint256 filled = router.swapExactIn(p);
        assertEq(filled, previewed, "filled amount does not match the preview");

        // Once the trade settles, inventory must be inside its band and value per share must not have decreased.
        uint256 ratio = nvdaVault.inventoryRatioBps();
        uint256 drift = ratio > 5_000 ? ratio - 5_000 : 5_000 - ratio;
        assertLe(drift, 2_000, "inventory ended outside its band after the fill");
        assertGe(nvdaVault.totalValue() * 1e18 / nvdaVault.totalSupply(), valuePerShareBefore, "share value dropped");

        // From one USDG upward, rounding no longer dominates, so the implied price must fall within the oracle band.
        uint256 notional = buyToken ? amountIn : amountIn * NVDA_MID / 1e18;
        if (notional >= 1e6) {
            uint256 implied = buyToken ? amountIn * 1e18 / filled : filled * 1e18 / amountIn;
            uint256 diff = implied > NVDA_MID ? implied - NVDA_MID : NVDA_MID - implied;
            assertLe(diff * 10_000 / NVDA_MID, 75, "fill price is beyond the oracle band");
        }
    }

    function testFuzz_depositPreviewMatchesTheMint(uint256 quoteAmount, uint256 tokenAmount) public {
        quoteAmount = bound(quoteAmount, 0, 1_000_000e6);
        tokenAmount = bound(tokenAmount, 0, 5_000e18);

        if (quoteAmount == 0 && tokenAmount == 0) {
            vm.prank(lp2);
            vm.expectRevert(OracleVault.ZeroAmount.selector);
            nvdaVault.deposit(0, 0, 0, lp2);
            return;
        }

        uint256 previewed = nvdaVault.previewDeposit(quoteAmount, tokenAmount);
        if (previewed == 0) {
            // The amount is below one share, so the vault reverts instead of absorbing the funds with nothing minted.
            vm.prank(lp2);
            vm.expectRevert(OracleVault.ZeroShares.selector);
            nvdaVault.deposit(quoteAmount, tokenAmount, 0, lp2);
            return;
        }

        uint256 valuePerShareBefore = nvdaVault.totalValue() * 1e18 / nvdaVault.totalSupply();
        vm.prank(lp2);
        uint256 minted = nvdaVault.deposit(quoteAmount, tokenAmount, previewed, lp2);
        assertEq(minted, previewed, "minted shares do not match the preview");
        // Mint rounding favours the pool, which protects existing LPs from losing value.
        assertGe(nvdaVault.totalValue() * 1e18 / nvdaVault.totalSupply(), valuePerShareBefore, "LPs got diluted");
    }

    function testFuzz_withdrawalIsProRataInEveryState(uint256 shares, uint8 state) public {
        shares = bound(shares, 1, seedShares);
        state = uint8(bound(state, 0, 5));
        if (state == 1) nvda.setOraclePaused(true); // halted for a corporate action
        if (state == 2) {
            vm.prank(guardian);
            params.setPaused(true); // paused by the guardian
        }
        if (state == 3) {
            ISettingsTimelock.TierConfig memory tier = params.tierConfig(1);
            tier.enabled = false;
            vm.prank(gov);
            params.setTierConfig(1, tier); // disabling the tier delists the market
        }
        if (state == 4) vm.warp(block.timestamp + 3 hours); // oracle price has gone stale
        if (state == 5) {
            vm.prank(issuer);
            attestations.revoke(lp1, Roles.LP); // the LP's attestation is revoked
        }

        uint256 quoteBal = usdg.balanceOf(address(nvdaVault));
        uint256 tokenBal = nvda.balanceOf(address(nvdaVault));
        uint256 supply = nvdaVault.totalSupply();
        (uint256 previewedQuote, uint256 previewedToken) = nvdaVault.previewWithdraw(shares);

        vm.prank(lp1);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares, lp1);
        assertEq(quoteOut, previewedQuote);
        assertEq(tokenOut, previewedToken);
        assertEq(quoteOut, quoteBal * shares / supply);
        assertEq(tokenOut, tokenBal * shares / supply);
        assertEq(nvdaVault.balanceOf(lp1), seedShares - shares);
    }

    function testFuzz_makerFillsStayInsideTheBand(uint256 priceBps) public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        // Maker quotes range from 90% to 110% of the vault output, so a portion of the draws land past the band edge.
        uint256 amountOut = vaultOut * bound(priceBps, 9_000, 11_000) / 10_000;

        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, amountOut, 1);
        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);

        vm.prank(trader);
        try router.swapExactIn(p) returns (uint256 out) {
            // Regardless of which venue filled, the trader got at least the vault's output and a price within the band.
            assertGe(out, vaultOut, "router paid out below the vault quote");
            if (out > vaultOut) assertEq(out, amountOut, "maker filled at terms other than its quote");
            uint256 implied = amountIn * 1e18 / out;
            uint256 diff = implied > NVDA_MID ? implied - NVDA_MID : NVDA_MID - implied;
            assertLe(diff * 10_000 / NVDA_MID, 75, "fill price is beyond the oracle band");
        } catch (bytes memory reason) {
            // Reverting is allowed only when the quote beat the vault, and then the reason must be BandExceeded.
            assertGt(amountOut, vaultOut, "vault-priced fill reverted");
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 32))
            }
            assertEq(selector, RfqSettler.BandExceeded.selector, "settlement reverted for an unexpected reason");
        }
    }
}
