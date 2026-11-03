// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ISettingsTimelock
/// @notice Read access to all of the protocol's configurable parameters.
interface ISettingsTimelock {
    /// @notice Pricing settings that apply to all markets within a tier. Each spread figure covers one side only, as
    ///         a bps distance from the oracle mid, and the oracle band is an absolute bound on every fill.
    struct TierConfig {
        uint16 baseHalfSpreadBps;
        uint16 maxSkewBps;
        /// @dev Tolerance, in bps of value, around the 50/50 split before the vault counts as out of balance.
        uint16 inventoryBandBps;
        /// @dev Maximum gap allowed between the guarded mid and any fill, on either the vault or the RFQ route.
        uint16 oracleBandBps;
        /// @dev Per-trade size limit for the vault in the regular session, denominated in quote-token notional.
        uint128 maxClip;
        bool enabled;
    }

    struct MarketConfig {
        uint8 tier;
        /// @dev Daily ceiling (UTC) on traded quote-token notional while the guarded launch phase lasts.
        uint128 dailyVolumeCap;
        /// @dev TVL limit (quote-token units) that holds for as long as the guarded launch phase runs.
        uint128 tvlCap;
        bool enabled;
    }

    /// @notice Multipliers that vary by session, given in bps of the base value (10_000 equals x1.0).
    struct RegimeParams {
        uint16 extendedSpreadMulBps;
        uint16 closedSpreadMulBps;
        uint16 extendedClipMulBps;
        uint16 closedClipMulBps;
    }

    struct RiskParams {
        /// @dev Waiting period after the sequencer recovers before trading may resume.
        uint32 sequencerGrace;
    }

    struct FeeParams {
        /// @dev Applied to each vault fill and shown as its own line on the ticket.
        uint16 swapFeeBps;
        /// @dev Applied to each RFQ fill and taken out of the trade's quote-token leg.
        uint16 rfqFeeBps;
        /// @dev Portion of the vault's spread earnings that goes to the protocol.
        uint16 spreadShareBps;
    }

    function owner() external view returns (address);
    function guardian() external view returns (address);

    function tierConfig(uint8 tier) external view returns (TierConfig memory);
    function marketConfig(address token) external view returns (MarketConfig memory);
    function regimeParams() external view returns (RegimeParams memory);
    function riskParams() external view returns (RiskParams memory);
    function feeParams() external view returns (FeeParams memory);
    function attestationIssuer(address issuer) external view returns (bool);
    function eligibilityAdapter() external view returns (address);
    function swapsPaused() external view returns (bool);
}
