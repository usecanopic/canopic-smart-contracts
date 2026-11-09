// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.t.sol";
import {Roles} from "../src/libraries/Types.sol";
import {SettingsTimelock} from "../src/settings/SettingsTimelock.sol";
import {ISettingsTimelock} from "../src/interfaces/ISettingsTimelock.sol";
import {VaultFactory} from "../src/venue/VaultFactory.sol";
import {SwapRouter} from "../src/venue/SwapRouter.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {AttestationBook} from "../src/eligibility/AttestationBook.sol";
import {MockERC20, MockStockToken} from "../src/mocks/Mocks.sol";

/// @notice Checks how settings changes are governed: after bootstrap the timelock is the sole route to every
///         setter, the guardian's power is limited to pausing, and values the pricing maths could not handle
///         get rejected.
contract SettingsTimelockTest is Fixture {
    function _feeCall(uint16 swapFee) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            SettingsTimelock.setFeeParams,
            (ISettingsTimelock.FeeParams({swapFeeBps: swapFee, rfqFeeBps: 2, spreadShareBps: 1000}))
        );
    }

    function test_bootstrapLocksSettersToTheTimelock() public {
        vm.prank(gov);
        params.finishBootstrap();

        // From here on, calling a setter directly reverts no matter who the caller is, even the owner.
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.NotSelf.selector);
        params.setFeeParams(ISettingsTimelock.FeeParams({swapFeeBps: 5, rfqFeeBps: 2, spreadShareBps: 1000}));

        // The only remaining route is the timelock: schedule the batch, let the delay elapse, then execute it.
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), keccak256("rationale: fee retune per Q3 execution data"));

        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.OperationNotReady.selector);
        params.execute(calls, bytes32("salt"));

        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        params.execute(calls, bytes32("salt"));
        assertEq(params.feeParams().swapFeeBps, 5);
    }

    function test_scheduledOperationCanBeCancelled() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.prank(gov);
        params.cancel(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.OperationNotFound.selector);
        params.execute(calls, bytes32("salt"));

        // A second cancel reverts, because the contract treats a cancelled operation as nonexistent.
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.OperationNotFound.selector);
        params.cancel(id);
    }

    function test_cancelledOperationCanBeRescheduled() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.prank(gov);
        params.cancel(id);

        // Rescheduling the same batch with the same salt starts a new delay instead of clashing with the spent id.
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        params.execute(calls, bytes32("salt"));
        assertEq(params.feeParams().swapFeeBps, 5);
    }

    function test_guardianCanPauseAndNothingElse() public {
        vm.prank(guardian);
        params.setPaused(true);
        assertTrue(params.swapsPaused());

        vm.prank(guardian);
        vm.expectRevert(SettingsTimelock.NotOwner.selector);
        params.setFeeParams(ISettingsTimelock.FeeParams({swapFeeBps: 0, rfqFeeBps: 0, spreadShareBps: 0}));

        vm.prank(outsider);
        vm.expectRevert(SettingsTimelock.NotGuardian.selector);
        params.setPaused(true);
    }

    function test_tierValidationRefusesUnpriceableConfigs() public {
        // If base spread and maximum skew together exceed the oracle band, no quote is possible, so the setter reverts.
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.InvalidBps.selector);
        params.setTierConfig(
            4,
            ISettingsTimelock.TierConfig({
                baseHalfSpreadBps: 60,
                maxSkewBps: 30,
                inventoryBandBps: 2000,
                oracleBandBps: 75,
                maxClip: 1_000e6,
                enabled: true
            })
        );

        // Enabling a tier with a zero inventory band is rejected, since its first fill would cause a zero divisor
        // when computing skew.
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.InvalidBps.selector);
        params.setTierConfig(
            4,
            ISettingsTimelock.TierConfig({
                baseHalfSpreadBps: 10,
                maxSkewBps: 15,
                inventoryBandBps: 0,
                oracleBandBps: 75,
                maxClip: 1_000e6,
                enabled: true
            })
        );
    }

    function test_capsRefuseSelfDisablingConfigs() public {
        // A tier with a zero clip, or a market with no daily volume or TVL headroom, would be enabled only on paper,
        // with every deposit or trade reverting for going over its limit. Rejecting these values early prevents
        // launching a market that is unable to trade.
        ISettingsTimelock.TierConfig memory tier = params.tierConfig(1);
        tier.maxClip = 0;
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.InvalidCap.selector);
        params.setTierConfig(1, tier);

        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.InvalidCap.selector);
        params.setMarketConfig(
            address(nvda), ISettingsTimelock.MarketConfig({tier: 1, dailyVolumeCap: 0, tvlCap: 1e6, enabled: true})
        );
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.InvalidCap.selector);
        params.setMarketConfig(
            address(nvda), ISettingsTimelock.MarketConfig({tier: 1, dailyVolumeCap: 1e6, tvlCap: 0, enabled: true})
        );

        // Retiring a market is done through the enabled flag rather than zero caps, so a disabled market may hold
        // any caps.
        vm.prank(gov);
        params.setMarketConfig(
            address(nvda), ISettingsTimelock.MarketConfig({tier: 1, dailyVolumeCap: 0, tvlCap: 0, enabled: false})
        );
        assertFalse(params.marketConfig(address(nvda)).enabled);
    }

    function test_bootstrapRequiresTheMinimumDelay() public {
        // A short delay is permitted during bootstrap for testing, but bootstrap cannot be finished while it is set.
        vm.prank(gov);
        params.setDelay(30 minutes);
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.DelayTooShort.selector);
        params.finishBootstrap();

        uint256 floor = params.MIN_DELAY();
        vm.prank(gov);
        params.setDelay(floor);
        vm.prank(gov);
        params.finishBootstrap();
        assertTrue(params.bootstrapped());

        // After bootstrap, delay changes routed through the timelock are held to that same floor.
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(SettingsTimelock.setDelay, (30 minutes));
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettingsTimelock.CallFailed.selector, 0, abi.encodeWithSelector(SettingsTimelock.DelayTooShort.selector)
            )
        );
        params.execute(calls, bytes32("salt"));
    }

    function test_regimeValidationKeepsMultipliersHonest() public {
        // Regime multipliers can only widen spreads and shrink clips; the opposite direction is rejected.
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.InvalidBps.selector);
        params.setRegimeParams(
            ISettingsTimelock.RegimeParams({
                extendedSpreadMulBps: 9_000,
                closedSpreadMulBps: 30_000,
                extendedClipMulBps: 7_500,
                closedClipMulBps: 5_000
            })
        );
    }

    function test_marketRequiresEnabledTier() public {
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.InvalidTier.selector);
        params.setMarketConfig(
            address(0xBEEF), ISettingsTimelock.MarketConfig({tier: 9, dailyVolumeCap: 1e6, tvlCap: 1e6, enabled: true})
        );
    }

    function test_deploymentRefusesZeroAddresses() public {
        // With address zero as owner, nobody could ever govern SettingsTimelock.
        vm.expectRevert(SettingsTimelock.ZeroAddress.selector);
        new SettingsTimelock(address(0), guardian, 1 days);

        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(params, eligibility, oracle, address(0), address(usdg));

        // The router is a one-time setting, so allowing zero would leave the factory permanently unusable.
        vm.prank(gov);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setRouter(address(0));
    }

    function test_marketOpensOnlyOnceFullyWired() public {
        MockStockToken fresh = new MockStockToken("Tesla Stock Token", "TSLAx");

        // Reverts since no parameters exist for the market yet.
        vm.prank(gov);
        vm.expectRevert(VaultFactory.MarketNotConfigured.selector);
        factory.createMarket(address(fresh));

        // Setting the market parameters still falls short as long as no oracle feed is configured.
        vm.prank(gov);
        params.setMarketConfig(
            address(fresh),
            ISettingsTimelock.MarketConfig({tier: 1, dailyVolumeCap: 1_000e6, tvlCap: 1_000e6, enabled: true})
        );
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.FeedNotConfigured.selector, address(fresh)));
        factory.createMarket(address(fresh));
    }

    function test_revokeRequiresAnAttestation() public {
        // Revoking a mistyped account should revert clearly instead of emitting an event with a zero uid for no record.
        vm.prank(issuer);
        vm.expectRevert(AttestationBook.NotAttested.selector);
        attestations.revoke(outsider, Roles.TRADER);

        // Revoking an existing record succeeds.
        vm.prank(issuer);
        attestations.revoke(trader, Roles.TRADER);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_ownershipHandoverIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(gov);
        params.transferOwnership(next);
        assertEq(params.owner(), gov); // ownership changes hands only after the nominee accepts
        vm.prank(next);
        params.acceptOwnership();
        assertEq(params.owner(), next);
    }

    function test_delayIsCappedSoATypoCannotLockGovernanceOut() public {
        // Delays beyond the maximum add no safety and would only lock SettingsTimelock up for years.
        vm.expectRevert(SettingsTimelock.DelayTooLong.selector);
        new SettingsTimelock(gov, guardian, 31 days);

        uint256 ceiling = params.MAX_DELAY();
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.DelayTooLong.selector);
        params.setDelay(ceiling + 1);
        vm.prank(gov);
        params.setDelay(ceiling);
        assertEq(params.delay(), ceiling);

        // The timelock route applies the same ceiling. Without it, a typo could not be undone, because the fix
        // would also have to sit through the excessive delay before it could run.
        vm.prank(gov);
        params.setDelay(1 days);
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(SettingsTimelock.setDelay, (ceiling + 1));
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettingsTimelock.CallFailed.selector, 0, abi.encodeWithSelector(SettingsTimelock.DelayTooLong.selector)
            )
        );
        params.execute(calls, bytes32("salt"));
    }

    function test_eligibilityAdapterCannotBeCleared() public {
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.ZeroAddress.selector);
        params.setEligibilityAdapter(address(0));
        assertEq(params.eligibilityAdapter(), address(attestations));
    }

    function test_routerMustBeBoundToTheFactory() public {
        VaultFactory fresh = new VaultFactory(params, eligibility, oracle, address(fees), address(usdg));

        // The fixture's router is bound to the fixture's own factory, so this freshly deployed factory refuses it.
        vm.prank(gov);
        vm.expectRevert(VaultFactory.RouterMismatch.selector);
        fresh.setRouter(address(router));

        SwapRouter bound = new SwapRouter(params, eligibility, fresh, rfq);
        vm.prank(gov);
        fresh.setRouter(address(bound));
        assertEq(fresh.router(), address(bound));
    }

    function test_operationReadyFollowsTheLifecycle() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("ready"), bytes32(0));
        assertFalse(params.operationReady(id));

        (uint64 eta,,,) = params.operations(id);
        vm.warp(eta);
        assertTrue(params.operationReady(id));

        vm.prank(gov);
        params.execute(calls, bytes32("ready"));
        assertFalse(params.operationReady(id));
        assertFalse(params.operationReady(bytes32("unknown")));
    }

    function test_sequencerGraceMustBeMeaningful() public {
        vm.startPrank(gov);
        vm.expectRevert(SettingsTimelock.InvalidGrace.selector);
        params.setRiskParams(ISettingsTimelock.RiskParams({sequencerGrace: 0}));
        vm.expectRevert(SettingsTimelock.InvalidGrace.selector);
        params.setRiskParams(ISettingsTimelock.RiskParams({sequencerGrace: 1 days + 1}));

        params.setRiskParams(ISettingsTimelock.RiskParams({sequencerGrace: 1 days}));
        vm.stopPrank();
        assertEq(params.riskParams().sequencerGrace, 1 days);
    }

    function test_pendingHandoverCanBeCancelled() public {
        address wrong = makeAddr("wrong");
        vm.prank(gov);
        params.transferOwnership(wrong);

        vm.prank(gov);
        params.cancelOwnershipTransfer();
        assertEq(params.pendingOwner(), address(0));

        vm.prank(wrong);
        vm.expectRevert(SettingsTimelock.NotPendingOwner.selector);
        params.acceptOwnership();

        // Once no transfer is pending, cancelling again has no target and reverts.
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.NotPendingOwner.selector);
        params.cancelOwnershipTransfer();
    }

    function test_handoverRefusesZeroAndSelf() public {
        vm.startPrank(gov);
        vm.expectRevert(SettingsTimelock.ZeroAddress.selector);
        params.transferOwnership(address(0));
        vm.expectRevert(SettingsTimelock.NotPendingOwner.selector);
        params.transferOwnership(gov);
        vm.stopPrank();
    }

    function test_ownerHoldingTheGuardianKeyCanLiftAPause() public {
        SettingsTimelock shared = new SettingsTimelock(gov, gov, 1 days);
        vm.startPrank(gov);
        shared.setPaused(true);
        shared.setPaused(false);
        vm.stopPrank();
        assertFalse(shared.swapsPaused());
    }

    function test_separateGuardianStillCannotLiftAPause() public {
        vm.prank(guardian);
        params.setPaused(true);

        vm.prank(guardian);
        vm.expectRevert(SettingsTimelock.NotOwner.selector);
        params.setPaused(false);

        vm.prank(gov);
        params.setPaused(false);
        assertFalse(params.swapsPaused());
    }

    function test_queuedOperationLapsesAfterTheGracePeriod() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("late"), bytes32(0));

        (uint64 eta,,,) = params.operations(id);
        uint256 lastCall = uint256(eta) + params.GRACE_PERIOD();
        vm.warp(lastCall);
        assertTrue(params.operationReady(id));

        vm.warp(lastCall + 1);
        assertFalse(params.operationReady(id));
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.OperationExpired.selector);
        params.execute(calls, bytes32("late"));

        // A lapsed batch frees its id, so the same change can be queued again from the start.
        vm.prank(gov);
        assertEq(params.schedule(calls, bytes32("late"), bytes32(0)), id);
        assertFalse(params.operationReady(id));
    }

    function test_operationExecutesOnTheLastDayOfItsGracePeriod() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("edge"), bytes32(0));

        (uint64 eta,,,) = params.operations(id);
        vm.warp(uint256(eta) + params.GRACE_PERIOD());
        vm.prank(gov);
        params.execute(calls, bytes32("edge"));
        assertEq(params.feeParams().swapFeeBps, 5);

        // An executed batch never lapses, which keeps it from being queued and replayed later.
        vm.warp(block.timestamp + 365 days);
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.OperationExists.selector);
        params.schedule(calls, bytes32("edge"), bytes32(0));
    }

    function test_feesAreCappedAtOnePercent() public {
        vm.startPrank(gov);
        params.setFeeParams(ISettingsTimelock.FeeParams({swapFeeBps: 100, rfqFeeBps: 100, spreadShareBps: 10_000}));

        vm.expectRevert(SettingsTimelock.FeeTooHigh.selector);
        params.setFeeParams(ISettingsTimelock.FeeParams({swapFeeBps: 101, rfqFeeBps: 2, spreadShareBps: 1000}));

        vm.expectRevert(SettingsTimelock.FeeTooHigh.selector);
        params.setFeeParams(ISettingsTimelock.FeeParams({swapFeeBps: 2, rfqFeeBps: 101, spreadShareBps: 1000}));

        vm.expectRevert(SettingsTimelock.InvalidBps.selector);
        params.setFeeParams(ISettingsTimelock.FeeParams({swapFeeBps: 2, rfqFeeBps: 2, spreadShareBps: 10_001}));
        vm.stopPrank();
    }

    function test_factoryRefusesAQuoteTokenAboveEighteenDecimals() public {
        MockERC20 wide = new MockERC20("Wide Dollar", "WIDE", 24);
        vm.expectRevert(VaultFactory.QuoteDecimalsUnsupported.selector);
        new VaultFactory(params, eligibility, oracle, address(fees), address(wide));

        MockERC20 eighteen = new MockERC20("Plain Dollar", "PLAIN", 18);
        new VaultFactory(params, eligibility, oracle, address(fees), address(eighteen));
    }

    function test_zeroAddressCannotBeApprovedAsIssuer() public {
        vm.startPrank(gov);
        vm.expectRevert(SettingsTimelock.ZeroAddress.selector);
        params.setAttestationIssuer(address(0), true);

        // Clearing it stays allowed, so the call is harmless when tidying up.
        params.setAttestationIssuer(address(0), false);
        vm.stopPrank();
        assertFalse(params.attestationIssuer(address(0)));
    }

    function test_emptyBatchCannotBeScheduled() public {
        vm.prank(gov);
        vm.expectRevert(SettingsTimelock.EmptyOperation.selector);
        params.schedule(new bytes[](0), bytes32("nothing"), bytes32(0));
    }

    function test_repeatEmergencyPauseLeavesOneRecord() public {
        vm.prank(guardian);
        params.setPaused(true);

        vm.recordLogs();
        vm.prank(gov);
        params.setPaused(true);
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(params.swapsPaused());

        // The guardian's restriction still applies even when the call would change nothing.
        vm.prank(gov);
        params.setPaused(false);
        vm.prank(guardian);
        vm.expectRevert(SettingsTimelock.NotOwner.selector);
        params.setPaused(false);
    }
}
