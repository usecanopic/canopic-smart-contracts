// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Types
/// @notice Common structs, enums and constants that the rest of the protocol imports.
library Types {
    // ---------------------------------------------------------------------
    // Enums
    // ---------------------------------------------------------------------

    /// @notice Session of the underlying stock market, as the OracleAdapter reports it. Each vault derives its pricing
    ///         regime from it, quoting wider spreads and smaller clips whenever regular hours are over.
    enum Session {
        Regular,
        Extended,
        Closed
    }

    /// @notice Execution route that ended up filling an order.
    enum Venue {
        Vault,
        Rfq
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    /// @dev Desired inventory mix, a 50/50 split of vault value between the listed token and the quote asset.
    uint256 internal constant TARGET_RATIO_BPS = 5_000;

    // ---------------------------------------------------------------------
    // Payloads signed off-chain
    // ---------------------------------------------------------------------

    /// @notice Maker quote signed as EIP-712 typed data and settled through the RFQ route. Issuing or retracting one
    ///         costs nothing since it lives off-chain, and once filled it can never settle again. The quote asset
    ///         must be on exactly one side, either `tokenIn` or `tokenOut`.
    struct MakerQuote {
        address maker;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        /// @dev Only this address may fill the quote; the zero address opens it to every taker.
        address taker;
        uint40 expiry;
        uint256 nonce;
    }

    // ---------------------------------------------------------------------
    // Price breakdown
    // ---------------------------------------------------------------------

    /// @notice The pieces that make up a vault price. Every fill emits it, which keeps the on-chain record
    ///         identical, item by item, to the ticket shown to the trader.
    struct Breakdown {
        /// @dev Guarded oracle mid for a full unit of the listed token, quoted in the quote token's smallest units.
        uint256 mid;
        /// @dev Effective half-spread for this side after both the regime multiplier and the skew are applied.
        uint16 halfSpreadBps;
        /// @dev Signed inventory skew, above zero when the vault is overweight the token versus its target.
        int16 skewBps;
        /// @dev Fee rate the protocol charged on this fill.
        uint16 feeBps;
        Session session;
    }
}

/// @title Roles
/// @notice Hashed role keys; an action proceeds only once the EligibilityRegistry confirms the matching role.
library Roles {
    bytes32 internal constant TRADER = keccak256("canopic.role.TRADER");
    bytes32 internal constant LP = keccak256("canopic.role.LP");
    bytes32 internal constant MAKER = keccak256("canopic.role.MAKER");
    bytes32 internal constant RELAYER = keccak256("canopic.role.RELAYER");
}
