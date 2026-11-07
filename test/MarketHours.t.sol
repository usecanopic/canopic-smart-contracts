// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.t.sol";
import {OracleVault} from "../src/venue/OracleVault.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {SwapRouter} from "../src/venue/SwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/ThirdParty.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockStreamReader} from "../src/mocks/Mocks.sol";

/// @notice Covers session regimes and halts: beyond regular hours spreads widen and the largest allowed clip
///         shrinks, and any oracle fault halts the market rather than allowing a faulty price to trade.
contract RevertingHaltFlag {
    function oraclePaused() external pure returns (bool) {
        revert("source offline");
    }
}

contract MarketHoursTest is Fixture {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
    }

    function test_closedSessionWidensSpreadAndShrinksClip() public {
        (uint256 regularOut,) = nvdaVault.quoteSwap(true, 10_000e6);

        nvda.setMarketStatus(5); // in Chainlink's status codes, 5 means the market is closed
        (uint256 closedOut, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);

        assertEq(uint8(b.session), uint8(Types.Session.Closed));
        assertEq(b.halfSpreadBps, 30); // the 10 bps base half-spread multiplied by three while closed
        assertLt(closedOut, regularOut);

        // The closed-session clip is half the regular one: 26,000 fits under the 50,000 regular cap
        // but goes over the 25,000 cap that applies while closed.
        vm.expectRevert(abi.encodeWithSelector(OracleVault.ClipExceeded.selector, 26_000e6, 25_000e6));
        nvdaVault.quoteSwap(true, 26_000e6);
    }

    function test_extendedSessionMultiplier() public {
        nvda.setMarketStatus(2);
        (, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);
        assertEq(uint8(b.session), uint8(Types.Session.Extended));
        assertEq(b.halfSpreadBps, 15); // extended hours apply a 1.5x factor to the 10 bps base half-spread
    }

    function test_staleFeedHaltsTrading() public {
        vm.warp(block.timestamp + 2 hours); // the regular-session staleness limit is 1 hour
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Quoting picks up again as soon as a new round lands, with no privileged action required.
        nvdaFeed.set(int256(NVDA_PRICE_8));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_corporateActionPausesAndResumes() public {
        nvda.setOraclePaused(true);
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        nvda.setOraclePaused(false);
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_moveCapPausesMarketPendingReview() public {
        _swap(address(usdg), address(nvda), 1_000e6); // the first checkpoint is written by this trade

        // With a 25% cap in place, a 30% jump halts the market immediately. Because the vault preview reverts,
        // the router has no vault quote to send the order to, and makers have no reference to settle against.
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));
        assertFalse(oracle.checkpoint(address(nvda)).paused);

        // State changes from a reverted fill are discarded, so the pause only sticks once refresh is called.
        vm.expectEmit(true, false, false, true);
        emit OracleAdapter.MarketPausedEvent(address(nvda), NVDA_MID, NVDA_MID * 130 / 100);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertTrue(oracle.checkpoint(address(nvda)).paused);

        // A stored pause persists past the end of the move-cap window. Otherwise the questionable price would
        // silently become the new reference an hour on and be traded with nobody reviewing it.
        vm.warp(block.timestamp + 2 hours);
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Only governance can clear the pause, and it states its rationale publicly. resume() erases the stored
        // checkpoint, which lets the reviewed price trade without tripping the cap again straight away.
        vm.prank(gov);
        oracle.resume(address(nvda));
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
    }

    function test_moveCapRebaselinesAfterTheWindow() public {
        _swap(address(usdg), address(nvda), 1_000e6);

        // The cap compares moves only against a checkpoint that falls within the window. After the window lapses,
        // a print of any size is treated as normal drift over a quiet stretch and is adopted as the new reference.
        vm.warp(block.timestamp + 2 hours);
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
        assertEq(oracle.checkpoint(address(nvda)).lastPrice, NVDA_MID * 130 / 100);
    }

    function test_sequencerOutageAndGrace() public {
        sequencer.setWithTimestamps(1, block.timestamp, block.timestamp); // uptime feed signals the sequencer is down
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Quotes keep reverting after the sequencer recovers, because the one-hour grace period is still running.
        sequencer.setWithTimestamps(0, block.timestamp, block.timestamp);
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        vm.warp(block.timestamp + 61 minutes);
        nvdaFeed.set(int256(NVDA_PRICE_8));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_uninitializedSequencerRoundHaltsTrading() public {
        // Chainlink returns startedAt = 0 before the uptime round is initialised. Treating that as "up since 1970"
        // would let the grace-period subtraction pass trades, so it has to count as an outage instead.
        sequencer.setWithTimestamps(0, 0, block.timestamp);
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
    }

    function test_scheduleRefusesImpossibleSessions() public {
        // Were the regular close set before the regular open, the entire day would fall into extended or closed hours.
        OracleAdapter.Schedule memory s = OracleAdapter.Schedule({
            regularOpen: 21 hours, regularClose: 14 hours + 30 minutes, extendedOpen: 9 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleAdapter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // The regular window has to sit entirely within the extended window.
        s = OracleAdapter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 15 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleAdapter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // Extended hours that reach the next day's extended open would leave no closed period at all.
        s = OracleAdapter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 33 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleAdapter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // The live schedule, whose extended session runs past midnight, is still accepted.
        s = OracleAdapter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        oracle.setSchedule(s);
        (,,, uint32 extendedClose) = oracle.schedule();
        assertEq(extendedClose, 25 hours);
    }

    function test_feedConfigRefusesSelfDisablingGuards() public {
        // With the staleness limit at zero, every round would count as stale and the market could never trade.
        vm.prank(gov);
        vm.expectRevert(OracleAdapter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            0,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );

        // A window of zero length would restrict the move cap to comparing prints within one block.
        vm.prank(gov);
        vm.expectRevert(OracleAdapter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            0,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );

        // Setting the divergence limit to zero would cause every stream report submitted for verification to fail.
        vm.prank(gov);
        vm.expectRevert(OracleAdapter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            0,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0xDEAD)
        );
    }

    function test_streamReportVerifiesOnlyAgainstALiveMid() public {
        MockStreamReader stream = new MockStreamReader();
        vm.prank(gov);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(stream)
        );

        // A report near enough to the feed is accepted and returned scaled to quote-token units.
        stream.set(NVDA_PRICE_8);
        assertEq(oracle.verifyStreamReport(address(nvda), ""), NVDA_MID);

        // The 2% limit rejects a report that is 3% away.
        stream.set(NVDA_PRICE_8 * 103 / 100);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StreamDivergence.selector, NVDA_MID, NVDA_MID * 103 / 100));
        oracle.verifyStreamReport(address(nvda), "");

        // Divergence is measured from the feed mid, which is precisely the value that is untrustworthy while
        // halted, so verification continues to revert until the pause is lifted.
        stream.set(NVDA_PRICE_8);
        vm.prank(gov);
        oracle.pause(address(nvda));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.MarketHalted.selector, address(nvda)));
        oracle.verifyStreamReport(address(nvda), "");
    }

    function test_multiplierReportedNotDoubleApplied() public view {
        // The ERC-8056 multiplier is already baked into Chainlink equity prices, so OracleAdapter exposes it as an
        // informational field only and does not adjust the price with it.
        assertEq(oracle.quote(address(nvda)).multiplier, 1e18);
        assertEq(oracle.quote(address(nvda)).price, NVDA_MID);
    }

    function test_refreshOnlyCheckpointsPrintsTheMarketCouldTradeOn() public {
        _swap(address(usdg), address(nvda), 1_000e6);
        uint256 baselineAt = oracle.checkpoint(address(nvda)).lastAt;

        // A stale round cannot be traded on, so it must never become the baseline that the next print is
        // compared with.
        vm.warp(block.timestamp + 2 hours);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertEq(oracle.checkpoint(address(nvda)).lastAt, baselineAt);

        // Likewise, a new round observed while the source is paused is skipped. This matters for corporate actions:
        // the source pauses with the pre-split price still on the feed, someone calls refresh, and shortly after,
        // still within the move-cap window, the post-split price is published. Anchoring on that paused refresh
        // would fire the cap, halting trading until governance steps in to resume. Anchoring on the last real fill
        // instead places the print outside the window, and it is adopted as the new baseline without fuss.
        nvdaFeed.set(int256(NVDA_PRICE_8));
        nvda.setOraclePaused(true);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertEq(oracle.checkpoint(address(nvda)).lastAt, baselineAt);

        vm.warp(block.timestamp + 10 minutes);
        nvdaFeed.set(int256(NVDA_PRICE_8 / 10)); // a 10-for-1 split
        nvda.setOraclePaused(false);
        assertFalse(oracle.quote(address(nvda)).paused);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertEq(oracle.checkpoint(address(nvda)).lastPrice, NVDA_MID / 10);
        assertFalse(oracle.checkpoint(address(nvda)).paused);
    }

    function test_priceThatScalesToZeroIsInvalid() public {
        // When an 8-decimal answer is below one quote unit, the mid rounds down to zero. Three consumers (the vault
        // ask, the RFQ band, the stream divergence check) use the mid as a divisor, so such a price is turned away
        // at entry rather than causing a divide-by-zero panic later on.
        nvdaFeed.set(99); // worth 0.00000099 USD, under the smallest unit a 6-decimal quote token can hold
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.PriceInvalid.selector, address(nvda)));
        oracle.quote(address(nvda));
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.PriceInvalid.selector, address(nvda)));
        nvdaVault.quoteSwap(true, 1_000e6);

        // Once the answer reaches one quote unit or more, quotes are available again.
        nvdaFeed.set(100);
        assertEq(oracle.quote(address(nvda)).price, 1);
    }

    function test_deploymentRefusesAZeroController() public {
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        new OracleAdapter(ISettingsTimelock(address(0)));
    }

    function test_repeatPauseLeavesOneRecord() public {
        vm.startPrank(gov);
        oracle.pause(address(nvda));
        vm.recordLogs();
        oracle.pause(address(nvda));
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(oracle.quote(address(nvda)).paused);
    }

    function test_isLiveMirrorsTheHaltConditions() public {
        assertTrue(oracle.isLive(address(nvda)));
        // A token lacking a configured feed yields false rather than a revert.
        assertFalse(oracle.isLive(address(usdg)));

        nvda.setOraclePaused(true);
        assertFalse(oracle.isLive(address(nvda)));
        nvda.setOraclePaused(false);
        assertTrue(oracle.isLive(address(nvda)));

        vm.warp(block.timestamp + 2 hours); // past the 1-hour regular-hours staleness limit
        assertFalse(oracle.isLive(address(nvda)));
    }

    function test_sequencerFeedMustBeAnUptimeFeed() public {
        vm.startPrank(gov);
        // Uptime feeds answer only 0 or 1, while a normal price feed answers with a price.
        vm.expectRevert(OracleAdapter.InvalidFeedConfig.selector);
        oracle.setSequencerFeed(AggregatorV3Interface(address(nvdaFeed)));

        // Clearing the feed is still allowed, as is setting it to a real uptime feed.
        oracle.setSequencerFeed(AggregatorV3Interface(address(0)));
        oracle.setSequencerFeed(AggregatorV3Interface(address(sequencer)));
        vm.stopPrank();
        assertEq(address(oracle.sequencerFeed()), address(sequencer));
    }

    function test_feedConfigRefusesTheQuoteAssetAndAMissingFeed() public {
        vm.startPrank(gov);
        vm.expectRevert(OracleAdapter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(usdg),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        vm.expectRevert(OracleAdapter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(0)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        vm.stopPrank();
    }

    function test_unreadablePauseSourceHaltsTheMarket() public {
        uint256 lpShares = nvdaVault.balanceOf(lp1);

        address broken = address(new RevertingHaltFlag());
        vm.prank(gov);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            broken,
            address(nvda),
            address(0)
        );

        assertTrue(oracle.quote(address(nvda)).paused);
        assertFalse(oracle.isLive(address(nvda)));
        vm.expectRevert(OracleVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Exits never read the oracle, so a broken source cannot trap an LP.
        vm.prank(lp1);
        (uint256 quoteOut,) = nvdaVault.withdraw(lpShares, lp1);
        assertGt(quoteOut, 0);
    }
}
