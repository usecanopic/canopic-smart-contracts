// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";
import {IEligibilityRegistry} from "../interfaces/IEligibilityRegistry.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {OracleVault} from "./OracleVault.sol";

interface IFactoryBound {
    function factory() external view returns (address);
}

/// @title VaultFactory
/// @notice Creates a single OracleVault for each listed token and also serves as the registry the SwapRouter
///         queries to find them. Only governance can open a market, and only after two prerequisites are met:
///         the SettingsTimelock already holds the market's configuration and the OracleAdapter has a feed for it.
contract VaultFactory {
    ISettingsTimelock public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleAdapter public immutable oracle;
    address public immutable feeTreasury;
    address public immutable quoteToken;

    /// @notice SwapRouter address, settable a single time. Vaults look it up here, so the router can ship after them.
    address public router;

    mapping(address => address) public vaultOf;
    address[] public allMarkets;

    event RouterSet(address router);
    event MarketOpened(address indexed token, address vault);

    error NotGovernance();
    error RouterAlreadySet();
    error RouterNotSet();
    error RouterMismatch();
    error MarketExists();
    error MarketNotConfigured();
    error QuoteAssetNotListable();
    error ZeroAddress();
    error QuoteDecimalsUnsupported();

    modifier onlyGovernance() {
        if (msg.sender != params.owner()) revert NotGovernance();
        _;
    }

    constructor(
        ISettingsTimelock params_,
        IEligibilityRegistry eligibility_,
        IOracleAdapter oracle_,
        address feeTreasury_,
        address quoteToken_
    ) {
        if (
            address(params_) == address(0) || address(eligibility_) == address(0) || address(oracle_) == address(0)
                || feeTreasury_ == address(0) || quoteToken_ == address(0)
        ) revert ZeroAddress();
        // Vault shares carry 18 decimals and are scaled up from the quote token's. A quote token with more decimals
        // than that would deploy fine here and then make every createMarket panic, so it is turned away now.
        if (IERC20Metadata(quoteToken_).decimals() > 18) revert QuoteDecimalsUnsupported();
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        feeTreasury = feeTreasury_;
        quoteToken = quoteToken_;
    }

    /// @notice Links the SwapRouter exactly once, irreversibly; moving to another router requires a full redeploy.
    function setRouter(address router_) external onlyGovernance {
        // The router can never be set again, so storing address(0) would leave the factory permanently unusable.
        if (router_ == address(0)) revert ZeroAddress();
        if (router != address(0)) revert RouterAlreadySet();
        // Every router resolves vaults through the factory it was constructed with. Binding a router that
        // points at a different factory would grant it swap access to these vaults while it routes against
        // another registry, and since the link is permanent, such a router is refused immediately.
        if (IFactoryBound(router_).factory() != address(this)) revert RouterMismatch();
        router = router_;
        emit RouterSet(router_);
    }

    function createMarket(address token) external onlyGovernance returns (address vault) {
        if (router == address(0)) revert RouterNotSet();
        // Routing keys off whichever leg of a trade is the quote asset. Listing the quote asset against itself
        // would produce a market that the router could never send an order to.
        if (token == quoteToken) revert QuoteAssetNotListable();
        if (vaultOf[token] != address(0)) revert MarketExists();
        // A vault lacking configuration or a feed would still deploy, but every deposit and swap would fail.
        // Insisting on both up front keeps half-working markets out of the registry.
        if (!params.marketConfig(token).enabled) revert MarketNotConfigured();
        oracle.tokenDecimals(token); // FeedNotConfigured is raised here when the token has no feed
        string memory sym = IERC20Metadata(token).symbol();
        vault = address(
            new OracleVault(
                params,
                eligibility,
                oracle,
                feeTreasury,
                quoteToken,
                token,
                string.concat("Canopic ", sym, " Vault"),
                string.concat("cv", sym)
            )
        );
        vaultOf[token] = vault;
        allMarkets.push(token);
        emit MarketOpened(token, vault);
    }

    function marketsLength() external view returns (uint256) {
        return allMarkets.length;
    }

    /// @notice Returns one page of listed tokens and their vaults, up to `count` items from position `start`.
    ///         Indexers and front ends can fetch the whole registry in chunks instead of one entry per call.
    ///         When the requested window extends past the last market it is clipped, not reverted.
    function markets(uint256 start, uint256 count)
        external
        view
        returns (address[] memory tokens, address[] memory vaults)
    {
        uint256 len = allMarkets.length;
        uint256 end = start >= len ? start : (count > len - start ? len : start + count);
        tokens = new address[](end - start);
        vaults = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            tokens[i - start] = allMarkets[i];
            vaults[i - start] = vaultOf[allMarkets[i]];
        }
    }
}
