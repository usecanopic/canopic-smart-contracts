// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAttestationProvider} from "../interfaces/IEligibilityRegistry.sol";
import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";
import {Roles} from "../libraries/Types.sol";

/// @title AttestationBook
/// @notice Standalone attestation store that follows EAS conventions, for chains where EAS is not deployed
///         (currently the Robinhood Chain testnet). Each entry records a role, jurisdiction class, investor
///         class and expiry, and nothing that identifies a person. The SettingsTimelock approves issuers, which
///         may be KYC providers themselves or signers they run.
contract AttestationBook is IAttestationProvider {
    struct Attestation {
        bytes32 uid;
        address issuer;
        bytes2 jurisdictionClass;
        uint8 investorClass;
        uint64 issuedAt;
        uint64 expiry;
        bool revoked;
    }

    ISettingsTimelock public immutable params;
    uint256 public nonce;

    mapping(address => mapping(bytes32 => Attestation)) internal _attestations;

    event Attested(
        address indexed account,
        bytes32 indexed role,
        bytes32 uid,
        address indexed issuer,
        bytes2 jurisdictionClass,
        uint8 investorClass,
        uint64 expiry
    );
    event Revoked(address indexed account, bytes32 indexed role, bytes32 uid, address indexed issuer);

    error NotIssuer();
    error BadExpiry();
    error NotAttested();
    error UnknownRole();
    error ZeroAddress();

    modifier onlyIssuer() {
        if (!params.attestationIssuer(msg.sender)) revert NotIssuer();
        _;
    }

    constructor(ISettingsTimelock params_) {
        // The issuer allowlist lives in the timelock; a zero address here would mean no attestation could ever be written.
        if (address(params_) == address(0)) revert ZeroAddress();
        params = params_;
    }

    /// @notice Writes an attestation for `account` and `role`, replacing any earlier record in full.
    function attest(address account, bytes32 role, bytes2 jurisdictionClass, uint8 investorClass, uint64 expiry)
        external
        onlyIssuer
        returns (bytes32 uid)
    {
        return _attest(account, role, jurisdictionClass, investorClass, expiry);
    }

    /// @notice Attests `role` for a list of accounts sharing the same classes and expiry, mirroring an issuer
    ///         approving a cohort in one review pass. If any entry is invalid, nothing is written.
    function attestBatch(
        address[] calldata accounts,
        bytes32 role,
        bytes2 jurisdictionClass,
        uint8 investorClass,
        uint64 expiry
    ) external onlyIssuer returns (bytes32[] memory uids) {
        uids = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            uids[i] = _attest(accounts[i], role, jurisdictionClass, investorClass, expiry);
        }
    }

    function _attest(address account, bytes32 role, bytes2 jurisdictionClass, uint8 investorClass, uint64 expiry)
        internal
        returns (bytes32 uid)
    {
        if (expiry <= block.timestamp) revert BadExpiry();
        // Because roles are hashed, a typo produces an id that looks perfectly valid. Saving it would go through
        // yet the account would still fail every gate, so only roles the protocol really checks are allowed.
        if (role != Roles.TRADER && role != Roles.LP && role != Roles.MAKER && role != Roles.RELAYER) {
            revert UnknownRole();
        }
        // Nobody can send transactions from address zero; an attestation for it would just clutter the record.
        if (account == address(0)) revert ZeroAddress();
        uid = keccak256(abi.encodePacked(account, role, msg.sender, ++nonce, block.chainid));
        _attestations[account][role] = Attestation({
            uid: uid,
            issuer: msg.sender,
            jurisdictionClass: jurisdictionClass,
            investorClass: investorClass,
            issuedAt: uint64(block.timestamp),
            expiry: expiry,
            revoked: false
        });
        emit Attested(account, role, uid, msg.sender, jurisdictionClass, investorClass, expiry);
    }

    /// @notice Revocation is immediate. Every approved issuer has this power, which lets the rest clean up
    ///         entries written by an issuer whose keys were compromised.
    function revoke(address account, bytes32 role) external onlyIssuer {
        _revoke(account, role);
    }

    /// @notice Revokes `role` for a whole list of accounts, useful when a cohort's review is later found to be
    ///         flawed. Reverts if even one account in the list holds no attestation for the role.
    function revokeBatch(address[] calldata accounts, bytes32 role) external onlyIssuer {
        for (uint256 i = 0; i < accounts.length; i++) {
            _revoke(accounts[i], role);
        }
    }

    function _revoke(address account, bytes32 role) internal {
        Attestation storage a = _attestations[account][role];
        // Revoking a missing record would create a blank entry and emit an event with a zero uid. A mistyped
        // address from an issuer ought to fail visibly rather than muddy the log.
        if (a.uid == bytes32(0)) revert NotAttested();
        a.revoked = true;
        emit Revoked(account, role, a.uid, msg.sender);
    }

    function isEligible(address account, bytes32 role) external view override returns (bool) {
        Attestation storage a = _attestations[account][role];
        return a.uid != bytes32(0) && !a.revoked && a.expiry > block.timestamp && params.attestationIssuer(a.issuer);
    }

    function attestationOf(address account, bytes32 role) external view override returns (bytes32 uid, uint64 expiry) {
        Attestation storage a = _attestations[account][role];
        return (a.uid, a.expiry);
    }

    function attestation(address account, bytes32 role) external view returns (Attestation memory) {
        return _attestations[account][role];
    }
}
