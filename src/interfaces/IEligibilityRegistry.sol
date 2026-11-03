// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAttestationProvider
/// @notice Pluggable source the registry consults for eligibility; possible backends are EAS, ONCHAINID and
///         Chainlink ACE.
interface IAttestationProvider {
    function isEligible(address account, bytes32 role) external view returns (bool);
    function attestationOf(address account, bytes32 role) external view returns (bytes32 uid, uint64 expiry);
}

/// @title IEligibilityRegistry
/// @notice Consulted on every swap, deposit, RFQ settlement and vault share transfer. Withdrawals deliberately skip
///         it, because holding shares is in itself the right to redeem them and needs no further approval.
interface IEligibilityRegistry {
    error NotEligible(address account, bytes32 role);

    function isEligible(address account, bytes32 role) external view returns (bool);
    function requireRole(address account, bytes32 role) external view;
    function attestationOf(address account, bytes32 role) external view returns (bytes32 uid, uint64 expiry);
}
