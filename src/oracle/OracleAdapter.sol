// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";
import {
    AggregatorV3Interface,
    IERC8056,
    IOracleHaltFlag,
    ISessionStatusSource,
    IStreamReader
} from "../interfaces/ThirdParty.sol";
import {Types} from "../libraries/Types.sol";

/// @title OracleAdapter
/// @notice Puts Chainlink Data Feeds (and Data Streams, where enabled) behind the protocol's guard rails:
///         it works out the current trading session, applies a staleness limit per session, enforces a move
///         cap, honours corporate-action pauses raised elsewhere and holds a grace period once the sequencer
///         recovers. No other contract reads feeds directly; each venue price is built from the mid served here.
/// @dev Every price states how many base units of the quote token buy a single whole listed token. Chainlink
///      equity feeds already include the ERC-8056 multiplier, so the value reported here is purely informational.
contract OracleAdapter is IOracleAdapter {
    using SafeCast for uint256;

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint8 feedDecimals;
        uint8 quoteDecimals;
        uint8 tokenDecimals;
        uint32 stalenessRegular;
        uint32 stalenessExtended;
        uint32 stalenessClosed;
        uint16 moveCapBps;
        /// @dev Maximum age at which a saved checkpoint still counts as the reference for the move cap.
        uint32 moveCapWindow;
        uint16 streamDivergenceBps;
        address marketStatusSource;
        address pauseSource;
        address multiplierSource;
        address streamAdapter;
        bool configured;
    }

    struct Checkpoint {
        uint128 lastPrice;
        uint40 lastAt;
        bool paused;
    }

    /// @notice Fallback trading hours (each value counts UTC seconds into the day), read only for tokens lacking a market-status source.
    struct Schedule {
        uint32 regularOpen;
        uint32 regularClose;
        uint32 extendedOpen;
        uint32 extendedClose;
    }

    uint8 internal constant CL_STATUS_PRE_MARKET = 1;
    uint8 internal constant CL_STATUS_REGULAR = 2;
    uint8 internal constant CL_STATUS_POST_MARKET = 3;
    uint8 internal constant CL_STATUS_OVERNIGHT = 4;

    ISettingsTimelock public immutable params;
    AggregatorV3Interface public sequencerFeed;
    Schedule public schedule;

    mapping(address => FeedConfig) internal _feeds;
    mapping(address => Checkpoint) internal _checkpoints;

    event FeedConfigured(address indexed token, address feed, uint8 feedDecimals, uint8 quoteDecimals);
    event SequencerFeedSet(address feed);
    event ScheduleSet(uint32 regularOpen, uint32 regularClose, uint32 extendedOpen, uint32 extendedClose);
    event MarketPausedEvent(address indexed token, uint256 lastPrice, uint256 newPrice);
    event MarketResumed(address indexed token);
    event Checkpointed(address indexed token, uint256 price);

    error NotGovernance();
    error ZeroAddress();
    error InvalidFeedConfig();
    error InvalidSchedule();
    error MarketHalted(address token);
    error StreamNotConfigured(address token);
    error StreamDivergence(uint256 feedPrice, uint256 streamPrice);
    error StreamReportStale(uint256 observedAt);

    modifier onlyGovernance() {
        if (msg.sender != params.owner()) revert NotGovernance();
        _;
    }

    constructor(ISettingsTimelock params_) {
        // Governance ownership and the sequencer grace value both come from SettingsTimelock, so wiring in
        // the zero address would produce a contract nobody could manage.
        if (address(params_) == address(0)) revert ZeroAddress();
        params = params_;
        // Starts out on US stock market hours in UTC (standard time): the regular session runs 14:30 to 21:00 and the extended one from 09:00 until 01:00 the morning after.
        Schedule memory s = Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 25 hours
        });
        _validateSchedule(s);
        schedule = s;
    }

    // ---------------------------------------------------------------------
    // Admin configuration (governance only)
    // ---------------------------------------------------------------------

    function configureFeed(
        address token,
        address quoteToken,
        AggregatorV3Interface feed,
        uint32 stalenessRegular,
        uint32 stalenessExtended,
        uint32 stalenessClosed,
        uint16 moveCapBps,
        uint32 moveCapWindow,
        uint16 streamDivergenceBps,
        address marketStatusSource,
        address pauseSource,
        address multiplierSource,
        address streamAdapter
    ) external onlyGovernance {
        // Reject settings that would neuter their own safeguard. With a zero staleness limit every round
        // counts as stale and the market never reopens; a move cap enabled without a window could only
        // reference a checkpoint written in the current block; and zero stream tolerance rejects all reports.
        if (stalenessRegular == 0 || stalenessExtended == 0 || stalenessClosed == 0) revert InvalidFeedConfig();
        if (moveCapBps != 0 && moveCapWindow == 0) revert InvalidFeedConfig();
        if (streamAdapter != address(0) && streamDivergenceBps == 0) revert InvalidFeedConfig();
        // A feed for the quote asset itself makes no sense, because it is the unit every price is quoted in.
        // Catching a zero feed here avoids discovering it later when the first quote fails.
        if (token == quoteToken || address(feed) == address(0)) revert InvalidFeedConfig();
        uint8 fd = feed.decimals();
        uint8 qd = IERC20Metadata(quoteToken).decimals();
        uint8 td = IERC20Metadata(token).decimals();
        _feeds[token] = FeedConfig({
            feed: feed,
            feedDecimals: fd,
            quoteDecimals: qd,
            tokenDecimals: td,
            stalenessRegular: stalenessRegular,
            stalenessExtended: stalenessExtended,
            stalenessClosed: stalenessClosed,
            moveCapBps: moveCapBps,
            moveCapWindow: moveCapWindow,
            streamDivergenceBps: streamDivergenceBps,
            marketStatusSource: marketStatusSource,
            pauseSource: pauseSource,
            multiplierSource: multiplierSource,
            streamAdapter: streamAdapter,
            configured: true
        });
        emit FeedConfigured(token, address(feed), fd, qd);
    }

    /// @notice Configures which feed reports L2 sequencer uptime. Use address(0) to switch off the sequencer gate entirely.
    function setSequencerFeed(AggregatorV3Interface feed) external onlyGovernance {
        // An uptime feed only ever answers 0 (up) or 1 (down). If a price feed were plugged in by mistake its
        // answer would be some other value, `_sequencerGrace` would read that as downtime, and every market would halt at once.
        if (address(feed) != address(0)) {
            (, int256 answer,,,) = feed.latestRoundData();
            if (answer != 0 && answer != 1) revert InvalidFeedConfig();
        }
        sequencerFeed = feed;
        emit SequencerFeedSet(address(feed));
    }

    function setSchedule(Schedule calldata s) external onlyGovernance {
        _validateSchedule(s);
        schedule = s;
        emit ScheduleSet(s.regularOpen, s.regularClose, s.extendedOpen, s.extendedClose);
    }

    /// @notice Clears the checkpoint for `token`, removing any pause set by hand or by the move cap. A resume is
    ///         governance's acceptance of today's price; retaining the reference from before the pause would just
    ///         trip the cap again on the same jump that has now been approved.
    function resume(address token) external onlyGovernance {
        _requireConfigured(token);
        delete _checkpoints[token];
        emit MarketResumed(token);
    }

    /// @dev Pausing a token with no feed would emit an event that looks like a real halt while protecting nothing,
    ///      which is how a mistyped address in an incident goes unnoticed. Both calls therefore insist on a feed.
    function pause(address token) external onlyGovernance {
        _requireConfigured(token);
        // Nothing to do if the market is paused already; bailing out keeps a second pause event out of the logs.
        if (_checkpoints[token].paused) return;
        _checkpoints[token].paused = true;
        emit MarketPausedEvent(token, _checkpoints[token].lastPrice, 0);
    }

    // ---------------------------------------------------------------------
    // Quote views and refresh
    // ---------------------------------------------------------------------

    function quote(address token) public view override returns (Quote memory q) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);

        (, int256 answer,, uint256 updatedAt,) = c.feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert PriceInvalid(token);

        q.price = _scale(uint256(answer), c.feedDecimals, c.quoteDecimals);
        // When a feed carries more decimals than the quote token, scaling down may truncate a tiny answer to
        // zero. Later code divides by the mid, so a zero here is treated as an invalid price.
        if (q.price == 0) revert PriceInvalid(token);
        q.updatedAt = uint64(updatedAt);
        q.session = _session(c);
        q.stale = block.timestamp - updatedAt > _stalenessBound(c, q.session);
        // Any round over the move cap shows up as paused immediately, before a checkpoint is ever written, which
        // means previews, vault fills and RFQ settlement reject it starting from the block it first appears in.
        q.paused = _checkpoints[token].paused || _sourcePaused(c) || _beyondMoveCap(c, _checkpoints[token], q.price);
        q.multiplier = _multiplier(c);
        q.sequencerGrace = _sequencerGrace();
    }

    /// @inheritdoc IOracleAdapter
    /// @dev Anyone may call this. A trade that trips the cap reverts and undoes its own writes, which means
    ///      trades on their own can never make a pause stick. Monitors use this function to persist the pause;
    ///      once written it outlasts the move-cap window and remains until governance invokes `resume`.
    ///      Checkpoints are only updated from prices that are tradeable. The checkpoint serves as the benchmark
    ///      for the next print, so saving a stale round, an externally paused price or a price from inside the
    ///      sequencer grace period would backfire: after a corporate action or an outage, the first good price
    ///      would breach the cap only because of the very gap it is supposed to close, leaving the market stuck
    ///      until governance performs a resume that ought to be unnecessary.
    function refresh(address token) external override returns (Quote memory q) {
        q = quote(token);
        FeedConfig storage c = _feeds[token];
        Checkpoint storage cp = _checkpoints[token];
        if (_beyondMoveCap(c, cp, q.price)) {
            if (!cp.paused) {
                cp.paused = true;
                emit MarketPausedEvent(token, cp.lastPrice, q.price);
            }
            return q;
        }
        if (q.paused || q.stale || q.sequencerGrace) return q;
        cp.lastPrice = q.price.toUint128();
        cp.lastAt = uint40(block.timestamp);
        emit Checkpointed(token, q.price);
    }

    /// @inheritdoc IOracleAdapter
    function verifyStreamReport(address token, bytes calldata report) external override returns (uint256 price) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);
        if (c.streamAdapter == address(0)) revert StreamNotConfigured(token);
        // Stream prices are validated against the feed mid. While the market is halted that mid cannot be
        // trusted, so no report is accepted until trading resumes.
        Quote memory q = quote(token);
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted(token);
        (uint256 raw, uint256 observedAt) = IStreamReader(c.streamAdapter).verify(token, report);
        // A genuine signature only proves the price was true when observed. Without an age limit an old report
        // could be replayed for as long as the market stayed within the divergence tolerance.
        if (observedAt > block.timestamp || block.timestamp - observedAt > _stalenessBound(c, q.session)) {
            revert StreamReportStale(observedAt);
        }
        price = _scale(raw, c.feedDecimals, c.quoteDecimals);
        uint256 diff = price > q.price ? price - q.price : q.price - price;
        if (diff * Types.BPS / q.price > c.streamDivergenceBps) revert StreamDivergence(q.price, price);
    }

    /// @notice Returns true if `token` is configured and its feed gives a valid price that is neither paused nor
    ///         stale, with the sequencer grace period already over. Errors produce false instead of reverting, so keepers
    ///         and dashboards can poll every market without decoding revert payloads.
    function isLive(address token) external view returns (bool) {
        try this.quote(token) returns (Quote memory q) {
            return !(q.paused || q.stale || q.sequencerGrace);
        } catch {
            return false;
        }
    }

    function tokenDecimals(address token) external view override returns (uint8) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);
        return c.tokenDecimals;
    }

    function feedConfig(address token) external view returns (FeedConfig memory) {
        return _feeds[token];
    }

    function checkpoint(address token) external view returns (Checkpoint memory) {
        return _checkpoints[token];
    }

    function hasStream(address token) external view override returns (bool) {
        return _feeds[token].streamAdapter != address(0);
    }

    // ---------------------------------------------------------------------
    // Internal logic
    // ---------------------------------------------------------------------

    /// @dev Every value is an offset in seconds from 00:00 UTC. The regular session has to be non-empty and sit within
    ///      the extended session, which is allowed to run past midnight provided it closes before reopening.
    ///      `_scheduledSession` cannot classify times correctly for a schedule that breaks these constraints,
    ///      such as one with a zero-length regular session or no closed period during the day.
    function _validateSchedule(Schedule memory s) internal pure {
        if (s.regularOpen >= s.regularClose || s.regularClose > 1 days) revert InvalidSchedule();
        if (s.extendedOpen > s.regularOpen || s.extendedClose < s.regularClose) revert InvalidSchedule();
        if (s.extendedClose >= 1 days + s.extendedOpen) revert InvalidSchedule();
    }

    function _requireConfigured(address token) internal view {
        if (!_feeds[token].configured) revert FeedNotConfigured(token);
    }

    function _scale(uint256 answer, uint8 fromDec, uint8 toDec) internal pure returns (uint256) {
        if (toDec >= fromDec) return answer * (10 ** (toDec - fromDec));
        return answer / (10 ** (fromDec - toDec));
    }

    function _session(FeedConfig storage c) internal view returns (Types.Session) {
        if (c.marketStatusSource != address(0)) {
            uint8 s = ISessionStatusSource(c.marketStatusSource).marketStatus();
            if (s == CL_STATUS_REGULAR) return Types.Session.Regular;
            if (s == CL_STATUS_PRE_MARKET || s == CL_STATUS_POST_MARKET || s == CL_STATUS_OVERNIGHT) {
                return Types.Session.Extended;
            }
            // Closed, and also unknown or unrecognised codes: when the status is in doubt the market gets the
            // widest spread and the smallest clip, never the regular session's terms.
            return Types.Session.Closed;
        }
        return _scheduledSession();
    }

    /// @dev Fallback driven purely by the clock, with Saturday and Sunday closed. Holidays are not modelled,
    ///      which is why production deployments should configure a market-status source.
    function _scheduledSession() internal view returns (Types.Session) {
        uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7; // 0 means Sunday (1 Jan 1970 was a Thursday)
        uint256 secondOfDay = block.timestamp % 1 days;
        Schedule memory s = schedule;
        // If extendedClose runs beyond 24h, the early morning hours are the tail of yesterday's extended session.
        bool inWrappedTail = s.extendedClose > 1 days && secondOfDay < s.extendedClose - 1 days;
        if (inWrappedTail) {
            uint256 prevDay = (dayOfWeek + 6) % 7;
            return (prevDay == 0 || prevDay == 6) ? Types.Session.Closed : Types.Session.Extended;
        }
        if (dayOfWeek == 0 || dayOfWeek == 6) return Types.Session.Closed;
        if (secondOfDay >= s.regularOpen && secondOfDay < s.regularClose) return Types.Session.Regular;
        if (secondOfDay >= s.extendedOpen && secondOfDay < (s.extendedClose > 1 days ? 1 days : s.extendedClose)) {
            return Types.Session.Extended;
        }
        return Types.Session.Closed;
    }

    /// @dev The goal is to catch one bad round, so the comparison only uses a recent checkpoint. Only `refresh`
    ///      writes checkpoints, and an illiquid market can go several days without one, by which point normal
    ///      price drift is indistinguishable from a spike. After the window lapses the cap is not applied, and
    ///      the following `refresh` sets a new reference.
    function _beyondMoveCap(FeedConfig storage c, Checkpoint storage cp, uint256 price) internal view returns (bool) {
        if (cp.lastPrice == 0 || c.moveCapBps == 0 || block.timestamp - cp.lastAt > c.moveCapWindow) return false;
        uint256 last = cp.lastPrice;
        uint256 diff = price > last ? price - last : last - price;
        return diff * Types.BPS / last > c.moveCapBps;
    }

    function _stalenessBound(FeedConfig storage c, Types.Session s) internal view returns (uint256) {
        if (s == Types.Session.Regular) return c.stalenessRegular;
        if (s == Types.Session.Extended) return c.stalenessExtended;
        return c.stalenessClosed;
    }

    /// @dev A configured source that cannot answer counts as paused. The flag exists to stop trading through a
    ///      corporate action, and a source that broke or was upgraded mid-event says nothing about whether one is
    ///      underway. Withdrawals never read the oracle, so failing closed here leaves LP exits untouched.
    function _sourcePaused(FeedConfig storage c) internal view returns (bool) {
        if (c.pauseSource == address(0)) return false;
        try IOracleHaltFlag(c.pauseSource).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return true;
        }
    }

    function _multiplier(FeedConfig storage c) internal view returns (uint256) {
        if (c.multiplierSource == address(0)) return Types.WAD;
        try IERC8056(c.multiplierSource).uiMultiplier() returns (uint256 m) {
            return m == 0 ? Types.WAD : m;
        } catch {
            return Types.WAD;
        }
    }

    /// @dev Looks at the uptime feed Chainlink publishes for the L2 sequencer: answer 0 means up, 1 means down, and startedAt is the
    ///      time of the last status flip. Markets keep moving while users cannot transact during an outage, so
    ///      after recovery trading waits out the configured grace period instead of restarting on a stale mid.
    function _sequencerGrace() internal view returns (bool) {
        if (address(sequencerFeed) == address(0)) return false;
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        if (answer != 0) return true; // feed says the sequencer is down: count it as grace and halt trading
        // A zero startedAt indicates the round was never initialised. Without this guard the subtraction below
        // would see uptime dating back to 1970 and incorrectly reopen trading.
        if (startedAt == 0) return true;
        // A status flip dated after the current block cannot be trusted, and subtracting it would panic and take
        // `quote` down with an arithmetic error. Holding the market in grace reports the same halt cleanly.
        if (startedAt > block.timestamp) return true;
        uint256 grace = params.riskParams().sequencerGrace;
        return block.timestamp - startedAt < grace;
    }
}
