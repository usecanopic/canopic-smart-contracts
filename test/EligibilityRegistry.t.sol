// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.t.sol";
import {EligibilityRegistry} from "../src/eligibility/EligibilityRegistry.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {Roles} from "../src/libraries/Types.sol";

/// @notice Covers the EligibilityRegistry queries that front-ends rely on: role flags per account, kept in step with
///         whatever the attestation provider currently says.
contract EligibilityRegistryTest is Fixture {
    function test_rolesOfReportsEachRole() public view {
        (bool t, bool l, bool m) = eligibility.rolesOf(trader);
        assertTrue(t);
        assertFalse(l);
        assertFalse(m);

        (t, l, m) = eligibility.rolesOf(maker);
        assertFalse(t);
        assertFalse(l);
        assertTrue(m);

        (t, l, m) = eligibility.rolesOf(outsider);
        assertFalse(t || l || m);
    }

    function test_rolesOfFollowsRevocation() public {
        vm.prank(issuer);
        attestations.revoke(lp1, Roles.LP);
        (, bool l,) = eligibility.rolesOf(lp1);
        assertFalse(l);
    }

    function test_rolesOfNeedsAnAdapter() public {
        EligibilityRegistry bare = new EligibilityRegistry(ISettingsTimelock(address(new TimelockWithoutProvider())));
        vm.expectRevert(EligibilityRegistry.AdapterNotSet.selector);
        bare.rolesOf(trader);
    }

    function test_isEligibleManyChecksEachAccount() public view {
        address[] memory accounts = new address[](3);
        accounts[0] = lp1;
        accounts[1] = trader;
        accounts[2] = lp2;

        bool[] memory ok = eligibility.isEligibleMany(accounts, Roles.LP);
        assertEq(ok.length, 3);
        assertTrue(ok[0]);
        assertFalse(ok[1]);
        assertTrue(ok[2]);
    }
}

contract TimelockWithoutProvider {
    function eligibilityAdapter() external pure returns (address) {
        return address(0);
    }
}
