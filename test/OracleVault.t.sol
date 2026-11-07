// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.t.sol";
import {OracleVault} from "../src/venue/OracleVault.sol";
import {VaultFactory} from "../src/venue/VaultFactory.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {Roles} from "../src/libraries/Types.sol";

/// @notice Liquidity provider coverage. Checks value-based share issuance, proportional two-asset redemptions,
///         and the guarantee that withdrawals keep working no matter what condition the market is in.
contract OracleVaultTest is Fixture {
    function test_depositMintsValueBasedShares() public {
        vm.prank(lp1);
        uint256 shares = nvdaVault.deposit(100_000e6, 0, 0, lp1);
        // On a fresh vault, each quote unit (6 decimals) of value becomes 1e12 share units, so shares carry 18 decimals.
        // The first depositor funds the permanently locked shares out of that.
        assertEq(shares, 100_000e6 * 1e12 - nvdaVault.LOCKED_SHARES());
        assertEq(nvdaVault.balanceOf(lp1), shares);
        assertEq(nvdaVault.totalValue(), 100_000e6);
    }

    function test_tokenDepositValuedAtMid() public {
        uint256 tokenAmount = 100_000e6 * 1e18 / NVDA_MID;
        vm.prank(lp1);
        uint256 shares = nvdaVault.deposit(0, tokenAmount, 0, lp1);
        uint256 value = tokenAmount * NVDA_MID / 1e18;
        assertEq(shares, value * 1e12 - nvdaVault.LOCKED_SHARES());
    }

    function test_secondDepositSameValuePerShare() public {
        _seed(nvdaVault, NVDA_MID);
        uint256 supplyBefore = nvdaVault.totalSupply();
        uint256 totalBefore = nvdaVault.totalValue();
        vm.prank(lp2);
        uint256 shares = nvdaVault.deposit(250_000e6, 0, 0, lp2);
        // A later depositor enters at the prevailing rate: its fraction of supply matches its fraction of vault value.
        assertApproxEqRel(shares, supplyBefore * 250_000e6 / totalBefore, 1e12);
    }

    function test_withdrawProRataInKind() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        uint256 quoteBal = usdg.balanceOf(address(nvdaVault));
        uint256 tokenBal = nvda.balanceOf(address(nvdaVault));

        uint256 supply = nvdaVault.totalSupply();
        vm.prank(lp1);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares / 2, lp1);
        assertEq(quoteOut, quoteBal * (shares / 2) / supply);
        assertEq(tokenOut, tokenBal * (shares / 2) / supply);
        assertEq(nvdaVault.balanceOf(lp1), shares - shares / 2);
    }

    function test_withdrawWorksWhileHalted() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        nvda.setOraclePaused(true); // stand-in for a corporate-action trading halt

        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
        vm.prank(lp2);
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.deposit(1_000e6, 0, 0, lp2);

        // Quotes and deposits are blocked by the halt. Withdrawing never touches a price, so it still goes through.
        vm.prank(lp1);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares, lp1);
        assertGt(quoteOut, 0);
        assertGt(tokenOut, 0);
    }

    function test_withdrawWorksWhileGuardianPaused() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        vm.prank(guardian);
        params.setPaused(true);
        vm.prank(lp1);
        (uint256 quoteOut,) = nvdaVault.withdraw(shares, lp1);
        assertGt(quoteOut, 0);
    }

    function test_depositRequiresLpRole() public {
        vm.prank(trader);
        usdg.approve(address(nvdaVault), type(uint256).max);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, trader, Roles.LP));
        nvdaVault.deposit(1_000e6, 0, 0, trader);
    }

    function test_shareTransfersGatedToLps() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        vm.prank(lp1);
        nvdaVault.transfer(lp2, shares / 4);
        assertEq(nvdaVault.balanceOf(lp2), shares / 4);

        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, outsider, Roles.LP));
        nvdaVault.transfer(outsider, 1);
    }

    function test_expiredAttestationNeverBlocksWithdraw() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        vm.prank(issuer);
        attestations.revoke(lp1, Roles.LP);
        vm.prank(lp1);
        (uint256 quoteOut,) = nvdaVault.withdraw(shares, lp1);
        assertGt(quoteOut, 0);
    }

    function test_tvlCapBoundsDeposits() public {
        vm.prank(gov);
        params.setMarketConfig(
            address(nvda),
            ISettingsTimelock.MarketConfig({tier: 1, dailyVolumeCap: 2_000_000e6, tvlCap: 100_000e6, enabled: true})
        );
        vm.prank(lp1);
        nvdaVault.deposit(90_000e6, 0, 0, lp1);
        vm.prank(lp2);
        vm.expectRevert(OracleVault.TvlCapExceeded.selector);
        nvdaVault.deposit(20_000e6, 0, 0, lp2);
    }

    function test_depositMinSharesBoundsTheMint() public {
        _seed(nvdaVault, NVDA_MID);
        uint256 expected = nvdaVault.previewDeposit(100_000e6, 0);

        // Once the preview is taken, push the mid up 1% to the LP's detriment. Fewer shares would be minted than
        // the minimum requested, and Slippage is the expected revert.
        nvdaFeed.set(int256(NVDA_PRICE_8 * 101 / 100));
        uint256 nowExpected = nvdaVault.previewDeposit(100_000e6, 0);
        assertLt(nowExpected, expected);
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(OracleVault.Slippage.selector, nowExpected, expected));
        nvdaVault.deposit(100_000e6, 0, expected, lp2);

        // With an achievable minimum, the same deposit completes as usual.
        vm.prank(lp2);
        assertEq(nvdaVault.deposit(100_000e6, 0, nowExpected, lp2), nowExpected);
    }

    function test_previewsMatchTheRealThing() public {
        // Trading once after the seed moves value per share off 1:1, which exposes any rounding difference.
        _seed(nvdaVault, NVDA_MID);
        _swap(address(usdg), address(nvda), 10_000e6);

        uint256 tokenAmount = 30_000e6 * 1e18 / NVDA_MID;
        uint256 previewedShares = nvdaVault.previewDeposit(50_000e6, tokenAmount);
        vm.prank(lp2);
        uint256 shares = nvdaVault.deposit(50_000e6, tokenAmount, 0, lp2);
        assertEq(shares, previewedShares);

        (uint256 previewedQuote, uint256 previewedToken) = nvdaVault.previewWithdraw(shares);
        vm.prank(lp2);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares, lp2);
        assertEq(quoteOut, previewedQuote);
        assertEq(tokenOut, previewedToken);
    }

    function test_previewWithdrawNeedsNoOracle() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        nvda.setOraclePaused(true); // quotes and previewDeposit now revert...
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.previewDeposit(1_000e6, 0);

        // ...but previewWithdraw needs no price, just as withdraw does not.
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.previewWithdraw(shares);
        assertGt(quoteOut, 0);
        assertGt(tokenOut, 0);
    }

    function test_disabledTierRetiresItsMarkets() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        ISettingsTimelock.TierConfig memory tier = params.tierConfig(1);
        tier.enabled = false;
        vm.prank(gov);
        params.setTierConfig(1, tier);

        // Listing depends on the tier being enabled, so switching the tier off in one governance call halts quotes and deposits...
        vm.expectRevert(OracleVault.MarketNotListed.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
        vm.prank(lp2);
        vm.expectRevert(OracleVault.MarketNotListed.selector);
        nvdaVault.deposit(1_000e6, 0, 0, lp2);

        // ...while exits stay available to LPs, the same as under every other condition.
        vm.prank(lp1);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares, lp1);
        assertGt(quoteOut, 0);
        assertGt(tokenOut, 0);
    }

    function test_quoteAssetCannotBeListed() public {
        // Because SwapRouter identifies each leg by checking for the quote asset, a USDG/USDG vault could never
        // be routed to. VaultFactory rejects it up front, ahead of any config or feed lookup.
        vm.prank(gov);
        vm.expectRevert(VaultFactory.QuoteAssetNotListable.selector);
        factory.createMarket(address(usdg));
    }

    function test_swapAccruesValuePerShare() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        uint256 valueBefore = nvdaVault.totalValue();
        _swap(address(usdg), address(nvda), 10_000e6);
        // Share supply is unchanged but total value rose by the LP portion of the spread, so each share is worth more.
        assertGt(nvdaVault.totalValue(), valueBefore - 1);
        uint256 supply = nvdaVault.totalSupply();
        assertEq(supply, shares + nvdaVault.LOCKED_SHARES());
        uint256 lpSpread = nvdaVault.totalValue() * 1e18 / supply;
        assertGt(lpSpread, valueBefore * 1e18 / supply);
    }

    function test_marketsPagesThroughTheRegistry() public view {
        (address[] memory tokens, address[] memory vaults) = factory.markets(0, 10);
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(nvda));
        assertEq(vaults[0], address(nvdaVault));
        assertEq(tokens[1], address(spy));
        assertEq(vaults[1], address(spyVault));

        (tokens, vaults) = factory.markets(1, 1);
        assertEq(tokens.length, 1);
        assertEq(vaults[0], address(spyVault));

        (tokens,) = factory.markets(5, 3);
        assertEq(tokens.length, 0);
        (tokens,) = factory.markets(0, type(uint256).max);
        assertEq(tokens.length, 2);
    }

    function test_withdrawRefusesTheZeroReceiver() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        vm.prank(lp1);
        vm.expectRevert(OracleVault.ZeroAddress.selector);
        nvdaVault.withdraw(shares, address(0));
        assertEq(nvdaVault.balanceOf(lp1), shares);
    }

    function test_remainingTvlCapTracksDeposits() public {
        assertEq(nvdaVault.remainingTvlCap(), 5_000_000e6);
        _seed(nvdaVault, NVDA_MID);
        uint256 headroom = nvdaVault.remainingTvlCap();
        assertEq(headroom, 5_000_000e6 - nvdaVault.totalValue());

        // One unit beyond the headroom hits the cap, whereas depositing exactly the headroom is accepted.
        vm.prank(lp1);
        vm.expectRevert(OracleVault.TvlCapExceeded.selector);
        nvdaVault.deposit(headroom + 1, 0, 0, lp1);
        vm.prank(lp1);
        nvdaVault.deposit(headroom, 0, 0, lp1);
        assertEq(nvdaVault.remainingTvlCap(), 0);
    }

    function test_withdrawWithMinimumsBoundsEachSide() public {
        uint256 shares = _seed(nvdaVault, NVDA_MID);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.previewWithdraw(shares / 2);

        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(OracleVault.WithdrawSlippage.selector, quoteOut, tokenOut));
        nvdaVault.withdrawWithMinimums(shares / 2, lp1, quoteOut + 1, tokenOut);

        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(OracleVault.WithdrawSlippage.selector, quoteOut, tokenOut));
        nvdaVault.withdrawWithMinimums(shares / 2, lp1, quoteOut, tokenOut + 1);

        vm.prank(lp1);
        (uint256 q, uint256 t) = nvdaVault.withdrawWithMinimums(shares / 2, lp1, quoteOut, tokenOut);
        assertEq(q, quoteOut);
        assertEq(t, tokenOut);
        assertEq(nvdaVault.balanceOf(lp1), shares - shares / 2);
    }

    function test_pricePerShareStartsAtParAndGrowsWithSpread() public {
        // Given a 6-decimal quote token, 1e12 share units are initially valued at precisely one quote unit.
        assertEq(nvdaVault.pricePerShare(), 1e6);
        _seed(nvdaVault, NVDA_MID);
        uint256 before = nvdaVault.pricePerShare();
        assertApproxEqAbs(before, 1e6, 1);

        _swap(address(usdg), address(nvda), 10_000e6);
        assertGt(nvdaVault.pricePerShare(), before);
    }

    function test_firstDepositLocksShares() public {
        vm.prank(lp1);
        nvdaVault.deposit(100_000e6, 0, 0, lp1);
        assertEq(nvdaVault.balanceOf(address(0xdEaD)), nvdaVault.LOCKED_SHARES());
        assertEq(nvdaVault.totalSupply(), 100_000e6 * 1e12);

        // Later deposits leave the locked amount alone.
        vm.prank(lp2);
        nvdaVault.deposit(100_000e6, 0, 0, lp2);
        assertEq(nvdaVault.balanceOf(address(0xdEaD)), nvdaVault.LOCKED_SHARES());
    }

    function test_firstDepositMustCoverTheLockedShares() public {
        uint256 tooSmall = nvdaVault.LOCKED_SHARES() / 1e12;
        assertEq(nvdaVault.previewDeposit(tooSmall, 0), 0);

        vm.prank(lp1);
        vm.expectRevert(OracleVault.ZeroShares.selector);
        nvdaVault.deposit(tooSmall, 0, 0, lp1);

        assertEq(nvdaVault.previewDeposit(tooSmall + 1, 0), 1e12);
        vm.prank(lp1);
        assertEq(nvdaVault.deposit(tooSmall + 1, 0, 0, lp1), 1e12);
    }

    function test_supplyCannotBeShrunkToInflateShareValue() public {
        // An attacker enters, leaves with everything it can, then donates to push up the value per share.
        vm.startPrank(lp2);
        uint256 attackerShares = nvdaVault.deposit(1e6, 0, 0, lp2);
        nvdaVault.withdraw(attackerShares, lp2);
        vm.stopPrank();
        assertEq(nvdaVault.totalSupply(), nvdaVault.LOCKED_SHARES());
        usdg.mint(address(nvdaVault), 100_000e6);

        // The locked shares keep supply large enough that the victim is not rounded away, and the attacker holds
        // nothing to profit with. The donation ends up with the locked shares, not with the attacker.
        vm.prank(lp1);
        uint256 shares = nvdaVault.deposit(200_000e6, 0, 0, lp1);
        assertGt(shares, 0);
        assertEq(nvdaVault.balanceOf(lp2), 0);
        vm.prank(lp1);
        (uint256 quoteOut,) = nvdaVault.withdraw(shares, lp1);
        assertApproxEqAbs(quoteOut, 200_000e6, 1);
    }
}
