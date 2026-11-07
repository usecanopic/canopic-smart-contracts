// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal Chainlink aggregator interface, serving both price feeds and the L2 Sequencer Uptime Feed.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Corporate-action extension defined by ERC-8056, which Robinhood Stock Tokens implement.
interface IERC8056 {
    /// @return How many underlying shares back one token, as an 18-decimal figure that tracks splits and dividends.
    function uiMultiplier() external view returns (uint256);
}

/// @notice Optional indicator that a corporate action is underway. Either the token or a wrapper sitting in front of
///         its feed can provide it.
interface IOracleHaltFlag {
    function oraclePaused() external view returns (bool);
}

/// @notice Optional hook reporting whether the market is open, mirroring `marketStatus` from Chainlink Data
///         Streams v11 RWA.
interface ISessionStatusSource {
    /// @return status Chainlink status code: 0 unknown, 1 pre-market, 2 regular, 3 post-market, 4 overnight, 5 closed.
    function marketStatus() external view returns (uint8 status);
}

/// @notice On-chain verifier for Chainlink Data Streams reports that returns the embedded price.
interface IStreamReader {
    /// @param report Raw signed bytes, which must come from the stream mapped to this collateral.
    /// @return price Price expressed with the feed answer's decimals.
    /// @return observedAt Timestamp of the observation, as stored in the report.
    function verify(address collateralToken, bytes calldata report) external returns (uint256 price, uint256 observedAt);
}
