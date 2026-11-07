// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.t.sol";
import {AttestationBook} from "../src/eligibility/AttestationBook.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {Roles} from "../src/libraries/Types.sol";

/// @notice Standalone checks for AttestationBook covering who is allowed to issue, the life of a record up to its
///         expiry, the effect of issuer whitelist edits on existing records, and the inputs it rejects.
contract AttestationBookTest is Fixture {
    function test_deploymentRefusesAZeroController() public {
        // Issuer lookups all route via SettingsTimelock; without one, no account could issue or receive an attestation.
        vm.expectRevert(AttestationBook.ZeroAddress.selector);
        new AttestationBook(ISettingsTimelock(address(0)));
    }

    function test_attestRefusesTheZeroAccount() public {
        // Nobody controls address zero, so a record written for it would only clutter the event history.
        vm.prank(issuer);
        vm.expectRevert(AttestationBook.ZeroAddress.selector);
        attestations.attest(address(0), Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
    }

    function test_onlyWhitelistedIssuersMayAttest() public {
        vm.prank(outsider);
        vm.expectRevert(AttestationBook.NotIssuer.selector);
        attestations.attest(outsider, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
    }

    function test_expiryMustBeInTheFuture() public {
        vm.prank(issuer);
        vm.expectRevert(AttestationBook.BadExpiry.selector);
        attestations.attest(outsider, Roles.TRADER, "LT", 2, uint64(block.timestamp));
    }

    function test_renewalOverwritesThePreviousRecord() public {
        (bytes32 uidBefore, uint64 expiryBefore) = attestations.attestationOf(trader, Roles.TRADER);
        vm.prank(issuer);
        bytes32 uid = attestations.attest(trader, Roles.TRADER, "LT", 2, expiryBefore + 30 days);

        (bytes32 uidAfter, uint64 expiryAfter) = attestations.attestationOf(trader, Roles.TRADER);
        assertEq(uidAfter, uid);
        assertTrue(uid != uidBefore);
        assertEq(expiryAfter, expiryBefore + 30 days);
        assertTrue(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_eligibilityEndsAtExpiry() public {
        (, uint64 expiry) = attestations.attestationOf(trader, Roles.TRADER);
        vm.warp(expiry - 1);
        assertTrue(eligibility.isEligible(trader, Roles.TRADER));
        vm.warp(expiry);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));

        // The account loses eligibility once expired, but its attestation can still be read from storage.
        (bytes32 uid,) = attestations.attestationOf(trader, Roles.TRADER);
        assertTrue(uid != bytes32(0));
    }

    function test_delistingAnIssuerVoidsEverythingItIssued() public {
        vm.prank(gov);
        params.setAttestationIssuer(issuer, false);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));
        assertFalse(eligibility.isEligible(lp1, Roles.LP));
        assertFalse(eligibility.isEligible(maker, Roles.MAKER));

        // Whitelisting the issuer again brings those accounts back, as the records were disowned, not deleted.
        vm.prank(gov);
        params.setAttestationIssuer(issuer, true);
        assertTrue(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_anyIssuerMayRevokeAnotherIssuersRecord() public {
        address second = makeAddr("secondIssuer");
        vm.prank(gov);
        params.setAttestationIssuer(second, true);

        // If one issuer is compromised, a different one can revoke its records at once, with no governance vote.
        vm.prank(second);
        attestations.revoke(trader, Roles.TRADER);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));

        // Issuing a new attestation restores the account's eligibility.
        vm.prank(issuer);
        attestations.attest(trader, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
        assertTrue(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_batchAttestsEveryAccount() public {
        address[] memory accounts = new address[](3);
        accounts[0] = makeAddr("a");
        accounts[1] = makeAddr("b");
        accounts[2] = makeAddr("c");

        vm.prank(issuer);
        bytes32[] memory uids =
            attestations.attestBatch(accounts, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));

        assertEq(uids.length, 3);
        for (uint256 i = 0; i < accounts.length; i++) {
            (bytes32 uid,) = attestations.attestationOf(accounts[i], Roles.TRADER);
            assertEq(uid, uids[i]);
            assertTrue(eligibility.isEligible(accounts[i], Roles.TRADER));
        }
        assertTrue(uids[0] != uids[1] && uids[1] != uids[2]);
    }

    function test_batchIsAllOrNothing() public {
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("a");
        accounts[1] = address(0);

        vm.prank(issuer);
        vm.expectRevert(AttestationBook.ZeroAddress.selector);
        attestations.attestBatch(accounts, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
        assertFalse(eligibility.isEligible(accounts[0], Roles.TRADER));

        vm.prank(outsider);
        vm.expectRevert(AttestationBook.NotIssuer.selector);
        attestations.attestBatch(accounts, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
    }

    function test_revokeBatchEndsEveryAttestation() public {
        address[] memory accounts = new address[](2);
        accounts[0] = lp1;
        accounts[1] = lp2;

        vm.prank(issuer);
        attestations.revokeBatch(accounts, Roles.LP);
        assertFalse(eligibility.isEligible(lp1, Roles.LP));
        assertFalse(eligibility.isEligible(lp2, Roles.LP));
    }

    function test_revokeBatchIsAllOrNothing() public {
        address[] memory accounts = new address[](2);
        accounts[0] = lp1;
        accounts[1] = outsider; // never attested

        vm.prank(issuer);
        vm.expectRevert(AttestationBook.NotAttested.selector);
        attestations.revokeBatch(accounts, Roles.LP);
        assertTrue(eligibility.isEligible(lp1, Roles.LP));

        vm.prank(outsider);
        vm.expectRevert(AttestationBook.NotIssuer.selector);
        attestations.revokeBatch(accounts, Roles.LP);
    }

    function test_attestRefusesUnknownRoles() public {
        vm.prank(issuer);
        vm.expectRevert(AttestationBook.UnknownRole.selector);
        attestations.attest(outsider, keccak256("canopic.role.TRADERS"), "LT", 2, uint64(block.timestamp + 1 days));

        vm.prank(issuer);
        attestations.attest(outsider, Roles.RELAYER, "LT", 2, uint64(block.timestamp + 1 days));
        assertTrue(eligibility.isEligible(outsider, Roles.RELAYER));
    }

    function test_revokingTwiceEmitsNothingNew() public {
        vm.startPrank(issuer);
        attestations.revoke(trader, Roles.TRADER);

        vm.recordLogs();
        attestations.revoke(trader, Roles.TRADER);
        assertEq(vm.getRecordedLogs().length, 0);

        // A batch overlapping an earlier revocation still goes through for everyone else.
        attestations.attest(lp1, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
        address[] memory accounts = new address[](2);
        accounts[0] = trader;
        accounts[1] = lp1;
        attestations.revokeBatch(accounts, Roles.TRADER);
        vm.stopPrank();
        assertFalse(eligibility.isEligible(lp1, Roles.TRADER));
    }
}
