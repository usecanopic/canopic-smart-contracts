// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types} from "../libraries/Types.sol";

/// @title IOracleAdapter
/// @notice The protocol's sole price source: all prices it consumes come through here.
interface IOracleAdapter {
    struct Quote {
        /// @dev Value of a full unit of the listed token, expressed in the quote token's smallest units.
        uint256 price;
        uint64 updatedAt;
        Types.Session session;
        /// @dev Set during a halt, whether caused by the move cap, by hand, or by the source's `oraclePaused()`.
        bool paused;
        /// @dev Set when the price has aged past the staleness window configured for the active session.
        bool stale;
        /// @dev The token's ERC-8056 `uiMultiplier()` when supported, otherwise 1e18.
        uint256 multiplier;
        /// @dev Set while the post-outage sequencer grace period is still running.
        bool sequencerGrace;
    }

    error PriceInvalid(address token);
    error FeedNotConfigured(address token);

    function quote(address token) external view returns (Quote memory);
    /// @notice Advances the move-cap checkpoint, halting the market when the price moved further than the cap allows.
    function refresh(address token) external returns (Quote memory);
    function verifyStreamReport(address token, bytes calldata report) external returns (uint256 price);
    function tokenDecimals(address token) external view returns (uint8);
    /// @notice Decimals of the quote token the feed for `token` was configured to price in.
    function quoteDecimals(address token) external view returns (uint8);
    function hasStream(address token) external view returns (bool);
}
