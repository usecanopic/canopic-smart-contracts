// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IEligibilityRegistry, IAttestationProvider} from "../interfaces/IEligibilityRegistry.sol";
import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";
import {Roles} from "../libraries/Types.sol";

/// @title EligibilityRegistry
/// @notice Decides if an account is allowed to trade, supply liquidity or act as an RFQ maker. The rules live in
///         an attestation provider selected via the SettingsTimelock, which means EAS, ONCHAINID or Chainlink ACE
///         can be swapped in while the venue contracts stay untouched. Every view here is open to anyone.
contract EligibilityRegistry is IEligibilityRegistry {
    ISettingsTimelock public immutable params;

    error AdapterNotSet();
    error ZeroAddress();

    constructor(ISettingsTimelock params_) {
        if (address(params_) == address(0)) revert ZeroAddress();
        params = params_;
    }

    function adapter() public view returns (IAttestationProvider) {
        address a = params.eligibilityAdapter();
        if (a == address(0)) revert AdapterNotSet();
        return IAttestationProvider(a);
    }

    function isEligible(address account, bytes32 role) public view override returns (bool) {
        return adapter().isEligible(account, role);
    }

    function requireRole(address account, bytes32 role) external view override {
        if (!isEligible(account, role)) revert NotEligible(account, role);
    }

    /// @notice Tests `role` for each entry in `accounts` at once, built for indexers and operations tooling that
    ///         vet large sets of wallets.
    function isEligibleMany(address[] calldata accounts, bytes32 role) external view returns (bool[] memory ok) {
        IAttestationProvider a = adapter();
        ok = new bool[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            ok[i] = a.isEligible(accounts[i], role);
        }
    }

    /// @notice Fetches the trader, LP and maker status of `account` in one go, letting an interface decide what to
    ///         show after a single call rather than three separate provider lookups.
    function rolesOf(address account) external view returns (bool trader, bool lp, bool maker) {
        IAttestationProvider a = adapter();
        trader = a.isEligible(account, Roles.TRADER);
        lp = a.isEligible(account, Roles.LP);
        maker = a.isEligible(account, Roles.MAKER);
    }

    function attestationOf(address account, bytes32 role) external view override returns (bytes32 uid, uint64 expiry) {
        return adapter().attestationOf(account, role);
    }
}
