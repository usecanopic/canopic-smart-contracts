// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./Fixture.t.sol";
import {RfqSettler} from "../src/venue/RfqSettler.sol";
import {SwapRouter} from "../src/venue/SwapRouter.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {Types, Roles} from "../src/libraries/Types.sol";

/// @notice Maker quote coverage. A quote is used only when it improves on the vault, settles atomically, and
///         is validated at fill time for expiry, nonce, signature, role and price band.
contract RfqSettlerTest is Fixture {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
    }

    function _swapWithQuote(Types.MakerQuote memory q, bytes memory sig, uint256 amountIn) internal returns (uint256) {
        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = sig;
        vm.prank(trader);
        return router.swapExactIn(p);
    }

    function test_makerWinsWhenBeatingTheVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        uint256 better = vaultOut + vaultOut / 1000; // beats the vault output by 10 bps

        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, better, 1);
        uint256 makerUsdgBefore = usdg.balanceOf(maker);

        uint256 out = _swapWithQuote(q, _sign(q), amountIn);

        assertEq(out, better);
        // Fees are taken in USDG, meaning the maker collects the trader's input minus the fee.
        uint256 fee = amountIn * 2 / 10_000;
        assertEq(usdg.balanceOf(maker), makerUsdgBefore + amountIn - fee);
        assertEq(usdg.balanceOf(address(fees)), fee);
    }

    function test_vaultWinsWhenMakerIsWorse() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut - 1, 1);

        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, _sign(q), amountIn);

        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore); // maker's token balance is unchanged
    }

    function test_sellSideFeeDeductedFromOutput() public {
        uint256 amountIn = 50e18;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(false, amountIn);
        uint256 gross = vaultOut + vaultOut / 500; // remains better than the vault even after fees
        Types.MakerQuote memory q = _makerQuote(address(nvda), address(usdg), amountIn, gross, 7);

        uint256 out = _swapWithQuote(q, _sign(q), amountIn);
        uint256 fee = gross * 2 / 10_000;
        assertEq(out, gross - fee);
        assertEq(usdg.balanceOf(address(fees)), fee);
    }

    function test_nonceCannotBeReplayed() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut + vaultOut / 1000, 42);
        bytes memory sig = _sign(q);

        _swapWithQuote(q, sig, amountIn);

        // Used and cancelled nonces look the same, so the router drops the replayed quote: the vault takes
        // the trade and the maker is never debited twice.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        (uint256 vaultOut2,) = nvdaVault.quoteSwap(true, amountIn);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut2);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // As a backstop, a direct RfqSettler call rejects the replay as well.
        vm.prank(address(router));
        vm.expectRevert(RfqSettler.NonceAlreadyUsed.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_cancelledQuoteFallsBackToVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 9);
        bytes memory sig = _sign(q);

        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 9;
        vm.prank(maker);
        rfq.cancel(nonces);

        // A trader who loses a race against a cancellation did nothing wrong, so SwapRouter quietly skips the quote.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // As a backstop, a direct RfqSettler call rejects the cancelled nonce as well.
        vm.prank(address(router));
        vm.expectRevert(RfqSettler.NonceAlreadyUsed.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_expiredQuoteFallsBackToVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 3);
        q.expiry = uint40(block.timestamp - 1);
        bytes memory sig = _sign(q);

        // A quote that expires before the transaction lands is skipped, and the vault fills the trade.
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);

        // As a backstop, a direct RfqSettler call rejects the expired quote as well.
        vm.prank(address(router));
        vm.expectRevert(RfqSettler.QuoteExpired.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_badSignatureRejected() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 4);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPk, rfq.quoteDigest(q)); // signed with the wrong key

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = abi.encodePacked(r, s, v);
        vm.prank(trader);
        vm.expectRevert(RfqSettler.BadSignature.selector);
        router.swapExactIn(p);
    }

    function test_reservedQuoteForAnotherTakerRejected() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 5);
        q.taker = outsider;

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        vm.prank(trader);
        vm.expectRevert(RfqSettler.WrongTaker.selector);
        router.swapExactIn(p);
    }

    function test_cancelRecordsOnlyRealStateChanges() public {
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 77;
        nonces[1] = 77; // same nonce repeated within the call

        vm.recordLogs();
        vm.prank(maker);
        rfq.cancel(nonces);
        vm.prank(maker);
        rfq.cancel(nonces); // then repeat the entire batch

        // Only one of the four cancellations alters storage, hence exactly one NonceCancelled event.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertTrue(rfq.nonceUsed(maker, 77));
    }

    function test_bandCutsBothWays() public {
        // With no liquidity in the SPY vault, the maker is the sole venue. Even a quote 2% better for the trader
        // must revert, because no maker signature can authorise settlement beyond the band.
        spy.mint(maker, 1_000e18);
        vm.prank(maker);
        spy.approve(address(rfq), type(uint256).max);

        uint256 amountIn = 10_000e6;
        uint256 fair = amountIn * 1e18 / SPY_MID;
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(spy), amountIn, fair * 102 / 100, 6);

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        vm.prank(trader);
        vm.expectRevert();
        router.swapExactIn(p);
    }

    function test_revokedMakerFallsBackToVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 8);
        bytes memory sig = _sign(q);

        vm.prank(issuer);
        attestations.revoke(maker, Roles.MAKER);

        // Between signing and inclusion, the maker loses its attestation. As with a cancellation, this is a
        // maker-side timing problem rather than a trader error, so the router drops the quote
        // and the vault takes the trade.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // As a backstop, a direct RfqSettler call rejects the ineligible maker as well.
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, maker, Roles.MAKER));
        rfq.settle(q, sig, trader, trader);
    }

    function test_settleOnlyThroughRouter() public {
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), 1_000e6, 1e18, 11);
        bytes memory sig = _sign(q);
        vm.prank(trader);
        vm.expectRevert(RfqSettler.NotRouter.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_retiredTierClosesTheRfqLaneToo() public {
        ISettingsTimelock.TierConfig memory tier = params.tierConfig(1);
        tier.enabled = false;
        vm.prank(gov);
        params.setTierConfig(1, tier);

        // Regression guard. Once the vault is delisted only the maker quote remains, and the disabled tier must
        // bind RFQ settlement in addition to vault swaps. Even a fair quote is expected to revert.
        uint256 amountIn = 10_000e6;
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, amountIn * 1e18 / NVDA_MID, 12);
        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        vm.prank(trader);
        vm.expectRevert(RfqSettler.MarketNotListed.selector);
        router.swapExactIn(p);

        // Cancellation keeps working after a market is retired, so makers can always withdraw open quotes.
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 12;
        vm.prank(maker);
        rfq.cancel(nonces);
        assertTrue(rfq.nonceUsed(maker, 12));
    }

    function test_cancelBelowVoidsEveryOlderQuote() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut + vaultOut / 1000, 9);
        bytes memory sig = _sign(q);

        vm.prank(maker);
        rfq.cancelBelow(10);
        assertFalse(rfq.nonceUsable(maker, 9));
        assertTrue(rfq.nonceUsable(maker, 10));

        // The invalidated quote is passed over by SwapRouter, which sends the trade to the vault.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // RfqSettler refuses it when called directly as well.
        vm.prank(address(router));
        vm.expectRevert(RfqSettler.NonceTooLow.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_cancelBelowOnlyMovesForward() public {
        vm.startPrank(maker);
        rfq.cancelBelow(50);
        vm.recordLogs();
        rfq.cancelBelow(20);
        rfq.cancelBelow(50);
        vm.stopPrank();

        assertEq(rfq.minNonce(maker), 50);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_makerCannotFillItsOwnQuote() public {
        vm.prank(issuer);
        attestations.attest(maker, Roles.TRADER, "IE", 3, uint64(block.timestamp + 1 days));
        vm.prank(maker);
        usdg.approve(address(router), type(uint256).max);

        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut + vaultOut / 1000, 1);
        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);

        vm.prank(maker);
        vm.expectRevert(RfqSettler.SelfTrade.selector);
        router.swapExactIn(p);
    }

    function test_quoteFillableTracksTheQuotesState() public {
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), 10_000e6, 56e18, 4);
        bytes memory sig = _sign(q);
        assertTrue(rfq.quoteFillable(q, sig, trader));

        // Each of these cannot be filled: a tampered signature, a self-fill by the maker, and a quote bound to a different taker.
        bytes memory bad = sig;
        bad[0] = bad[0] ^ 0x01;
        assertFalse(rfq.quoteFillable(q, bad, trader));
        assertFalse(rfq.quoteFillable(q, sig, maker));
        Types.MakerQuote memory reserved = q;
        reserved.taker = outsider;
        assertFalse(rfq.quoteFillable(reserved, _sign(reserved), trader));

        // Cancelling the nonce makes the quote permanently unusable.
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 4;
        vm.prank(maker);
        rfq.cancel(nonces);
        assertFalse(rfq.quoteFillable(q, sig, trader));
    }

    function test_quoteFillableEndsAtExpiry() public {
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), 10_000e6, 56e18, 5);
        bytes memory sig = _sign(q);
        vm.warp(q.expiry + 1);
        assertFalse(rfq.quoteFillable(q, sig, trader));
    }

    function test_quoteFillableNeedsTheQuoteAssetOnOneSide() public {
        // Stock for stock never touches the quote asset, and quote for quote touches it twice; settle refuses both.
        Types.MakerQuote memory stockOnly = _makerQuote(address(spy), address(nvda), 1e18, 3e18, 6);
        assertFalse(rfq.quoteFillable(stockOnly, _sign(stockOnly), trader));

        Types.MakerQuote memory quoteOnly = _makerQuote(address(usdg), address(usdg), 1_000e6, 1_000e6, 7);
        assertFalse(rfq.quoteFillable(quoteOnly, _sign(quoteOnly), trader));
    }

    function test_settlementRefusesFillsWhileSwapsArePaused() public {
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), 10_000e6, 56e18, 8);
        bytes memory sig = _sign(q);
        vm.prank(guardian);
        params.setPaused(true);

        // Calling as the router skips its own pause check, leaving settlement's as the only gate.
        vm.prank(address(router));
        vm.expectRevert(RfqSettler.SwapsPaused.selector);
        rfq.settle(q, sig, trader, trader);
        assertTrue(rfq.nonceUsable(maker, 8));
    }

    function test_quoteFillableIsFalseWhileSwapsArePaused() public {
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), 10_000e6, 56e18, 9);
        bytes memory sig = _sign(q);
        assertTrue(rfq.quoteFillable(q, sig, trader));

        vm.prank(guardian);
        params.setPaused(true);
        assertFalse(rfq.quoteFillable(q, sig, trader));

        vm.prank(gov);
        params.setPaused(false);
        assertTrue(rfq.quoteFillable(q, sig, trader));
    }

    function test_quoteFillableIsFalseOnceTheMarketIsRetired() public {
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), 10_000e6, 56e18, 10);
        bytes memory sig = _sign(q);
        assertTrue(rfq.quoteFillable(q, sig, trader));

        uint8 tierId = params.marketConfig(address(nvda)).tier;
        ISettingsTimelock.TierConfig memory tier = params.tierConfig(tierId);
        tier.enabled = false;
        vm.prank(gov);
        params.setTierConfig(tierId, tier);
        assertFalse(rfq.quoteFillable(q, sig, trader));
    }
}
