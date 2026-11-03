// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISettingsTimelock} from "../interfaces/ISettingsTimelock.sol";
import {Types} from "../libraries/Types.sol";

/// @title SettingsTimelock
/// @notice Single home for all tunable protocol settings. Every update waits out a delay and emits an event
///         recording what changed.
/// @dev Typical lifecycle: `schedule` a batch, wait for `delay` to pass, then call `execute`. All setters use
///      `onlySelf`, which after bootstrap admits only calls the contract makes to itself from inside `execute`.
///      Until then the owner can hit setters directly; calling `finishBootstrap()` is irreversible and forces
///      every later change through the delay. The guardian can do exactly one thing: stop swaps. This contract
///      never custodies or moves funds, and it has no means of preventing withdrawals from a vault.
contract SettingsTimelock is ISettingsTimelock {
    // ---------------------------------------------------------------------
    // Owner, timelock delay and the operation queue
    // ---------------------------------------------------------------------

    /// @notice Minimum permitted delay. `finishBootstrap` requires the delay to meet it, and from then on the
    ///         delay can never drop beneath it.
    uint256 public constant MIN_DELAY = 1 hours;
    /// @notice Maximum permitted delay, applied in every phase. Waiting longer adds no safety and would merely
    ///         lock settings for years; since changing the delay also goes through the queue, a mistyped value
    ///         would be impossible to fix.
    uint256 public constant MAX_DELAY = 30 days;

    address public override owner;
    address public override guardian;
    address public pendingOwner;
    uint256 public delay;
    bool public bootstrapped;

    struct Operation {
        uint64 eta;
        bool executed;
        bool cancelled;
        bytes32 rationale;
    }

    mapping(bytes32 => Operation) public operations;

    // ---------------------------------------------------------------------
    // Persisted settings
    // ---------------------------------------------------------------------

    mapping(uint8 => TierConfig) internal _tiers;
    mapping(address => MarketConfig) internal _markets;
    mapping(address => bool) public override attestationIssuer;
    address public override eligibilityAdapter;
    bool public override swapsPaused;

    RegimeParams internal _regimeParams;
    RiskParams internal _riskParams;
    FeeParams internal _feeParams;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event OperationScheduled(bytes32 indexed id, uint64 eta, bytes32 rationale, bytes[] calls);
    event OperationExecuted(bytes32 indexed id);
    event OperationCancelled(bytes32 indexed id);
    event ParamChanged(bytes32 indexed key, bytes32 indexed subject, bytes value);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event GuardianChanged(address indexed guardian);
    event DelayChanged(uint256 delay);
    event BootstrapFinished();
    event EmergencyPause(bool swapsPaused, address indexed by);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotGuardian();
    error NotSelf();
    error NotPendingOwner();
    error AlreadyBootstrapped();
    error OperationExists();
    error OperationNotReady();
    error OperationNotFound();
    error CallFailed(uint256 index, bytes reason);
    error InvalidBps();
    error InvalidTier();
    error InvalidCap();
    error DelayTooShort();
    error DelayTooLong();
    error InvalidGrace();
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Caller checks
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev While bootstrapping, both the owner and the contract are let through; once bootstrap ends, only
    ///      calls the contract issues to itself during `execute` succeed.
    modifier onlySelf() {
        if (bootstrapped) {
            if (msg.sender != address(this)) revert NotSelf();
        } else {
            if (msg.sender != owner && msg.sender != address(this)) revert NotOwner();
        }
        _;
    }

    constructor(address owner_, address guardian_, uint256 delay_) {
        // A zero guardian is allowed (no one holds the pause key), but a zero owner would leave governance with no one at the helm.
        if (owner_ == address(0)) revert ZeroAddress();
        if (delay_ > MAX_DELAY) revert DelayTooLong();
        owner = owner_;
        guardian = guardian_;
        delay = delay_;
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianChanged(guardian_);
        emit DelayChanged(delay_);
    }

    // ---------------------------------------------------------------------
    // Scheduling, execution and cancellation
    // ---------------------------------------------------------------------

    function operationId(bytes[] calldata calls, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(calls, salt));
    }

    /// @notice True if batch `id` can be executed at this moment, meaning it was queued, is neither cancelled nor
    ///         done, and its eta has passed. Lets keepers check readiness without dry-running `execute` for a revert.
    function operationReady(bytes32 id) external view returns (bool) {
        Operation storage op = operations[id];
        return op.eta != 0 && !op.cancelled && !op.executed && block.timestamp >= op.eta;
    }

    /// @notice Queues a set of setter calls for later execution. Pass the hash of the public write-up that
    ///         justifies the change as `rationale`.
    function schedule(bytes[] calldata calls, bytes32 salt, bytes32 rationale) external onlyOwner returns (bytes32 id) {
        id = operationId(calls, salt);
        // Only a pending or executed batch occupies its id. Cancelled batches free it up, so the same salt can
        // be reused to queue them a second time.
        if (operations[id].eta != 0 && !operations[id].cancelled) revert OperationExists();
        uint64 eta = uint64(block.timestamp + delay);
        operations[id] = Operation({eta: eta, executed: false, cancelled: false, rationale: rationale});
        emit OperationScheduled(id, eta, rationale, calls);
    }

    /// @notice Runs a queued batch after its eta. The batch is atomic: if any single call fails, none take effect.
    function execute(bytes[] calldata calls, bytes32 salt) external onlyOwner {
        bytes32 id = operationId(calls, salt);
        Operation storage op = operations[id];
        if (op.eta == 0 || op.cancelled || op.executed) revert OperationNotFound();
        if (block.timestamp < op.eta) revert OperationNotReady();
        op.executed = true;
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory reason) = address(this).call(calls[i]);
            if (!ok) revert CallFailed(i, reason);
        }
        emit OperationExecuted(id);
    }

    function cancel(bytes32 id) external onlyOwner {
        Operation storage op = operations[id];
        if (op.eta == 0 || op.executed || op.cancelled) revert OperationNotFound();
        op.cancelled = true;
        emit OperationCancelled(id);
    }

    /// @notice Ends bootstrap so that every setter must go through the delay from now on. This cannot be undone.
    function finishBootstrap() external onlyOwner {
        if (bootstrapped) revert AlreadyBootstrapped();
        // `setDelay` does not apply its minimum before bootstrap ends, hence the repeat check. Committing to a
        // very short delay would allow later reductions to land before anyone watching had time to respond.
        if (delay < MIN_DELAY) revert DelayTooShort();
        bootstrapped = true;
        emit BootstrapFinished();
    }

    // ---------------------------------------------------------------------
    // Ownership transfer, guardian and delay
    // ---------------------------------------------------------------------

    function transferOwnership(address to) external onlyOwner {
        // `cancelOwnershipTransfer` is the way to clear a pending handover, so receiving the zero address or
        // the current owner here can only be a mistake.
        if (to == address(0)) revert ZeroAddress();
        if (to == owner) revert NotPendingOwner();
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    /// @notice Withdraws an ownership offer that is still unaccepted, for example one sent to an incorrect address.
    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert NotPendingOwner();
        pendingOwner = address(0);
        emit OwnershipTransferStarted(owner, address(0));
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setGuardian(address guardian_) external onlySelf {
        guardian = guardian_;
        emit GuardianChanged(guardian_);
    }

    function setDelay(uint256 delay_) external onlySelf {
        if (bootstrapped && delay_ < MIN_DELAY) revert DelayTooShort();
        if (delay_ > MAX_DELAY) revert DelayTooLong();
        delay = delay_;
        emit DelayChanged(delay_);
    }

    // ---------------------------------------------------------------------
    // Emergency stop. It freezes swaps alone, leaving deposits, withdrawals and RFQ cancellations available.
    // The guardian may engage the stop, but lifting it is an owner-only action.
    // ---------------------------------------------------------------------

    function setPaused(bool swaps) external {
        if (msg.sender != guardian && msg.sender != owner && msg.sender != address(this)) revert NotGuardian();
        // Restarting is deliberately out of the guardian's reach: it may halt trading at once, but a compromised
        // guardian key cannot lift a pause while an incident is still unfolding.
        if (!swaps && msg.sender == guardian) revert NotOwner();
        swapsPaused = swaps;
        emit EmergencyPause(swaps, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Timelocked parameter setters
    // ---------------------------------------------------------------------

    function setTierConfig(uint8 tier, TierConfig calldata cfg) external onlySelf {
        if (tier == 0) revert InvalidTier();
        // No bound is wider than the oracle band, so base half spread and max skew together must fit within it.
        // The inventory band must leave room either side of the target ratio, and no value can pass 100%.
        if (
            cfg.oracleBandBps > Types.BPS || cfg.inventoryBandBps > Types.TARGET_RATIO_BPS
                || (cfg.enabled && cfg.inventoryBandBps == 0)
                || uint256(cfg.baseHalfSpreadBps) + cfg.maxSkewBps > cfg.oracleBandBps
        ) revert InvalidBps();
        // A zero clip on a live tier rejects all fills, which would quietly disable every market in that tier.
        if (cfg.enabled && cfg.maxClip == 0) revert InvalidCap();
        _tiers[tier] = cfg;
        emit ParamChanged("tier", bytes32(uint256(tier)), abi.encode(cfg));
    }

    function setMarketConfig(address token, MarketConfig calldata cfg) external onlySelf {
        if (cfg.enabled && !_tiers[cfg.tier].enabled) revert InvalidTier();
        // The logic mirrors the tier check: zero daily volume stops all fills and zero TVL stops all deposits.
        // To wind a market down, set `enabled` to false instead of setting its caps to zero.
        if (cfg.enabled && (cfg.dailyVolumeCap == 0 || cfg.tvlCap == 0)) revert InvalidCap();
        _markets[token] = cfg;
        emit ParamChanged("market", bytes32(uint256(uint160(token))), abi.encode(cfg));
    }

    function setRegimeParams(RegimeParams calldata p) external onlySelf {
        // Extended and closed sessions can only make spreads wider and clips smaller, never tighter or larger.
        if (
            p.extendedSpreadMulBps < Types.BPS || p.closedSpreadMulBps < p.extendedSpreadMulBps
                || p.extendedClipMulBps > Types.BPS || p.closedClipMulBps > p.extendedClipMulBps
        ) revert InvalidBps();
        _regimeParams = p;
        emit ParamChanged("regimeParams", bytes32(0), abi.encode(p));
    }

    /// @notice Largest allowed sequencer grace period. A wait past one day stops protecting against an outdated
    ///         mid and simply keeps a working market closed.
    uint256 public constant MAX_SEQUENCER_GRACE = 1 days;

    function setRiskParams(RiskParams calldata p) external onlySelf {
        // A zero grace would allow trades in the very block the sequencer comes back, at a mid that aged while
        // it was down. Avoiding exactly that situation is why the grace period exists.
        if (p.sequencerGrace == 0 || p.sequencerGrace > MAX_SEQUENCER_GRACE) revert InvalidGrace();
        _riskParams = p;
        emit ParamChanged("riskParams", bytes32(0), abi.encode(p));
    }

    function setFeeParams(FeeParams calldata p) external onlySelf {
        if (p.swapFeeBps > Types.BPS || p.rfqFeeBps > Types.BPS || p.spreadShareBps > Types.BPS) revert InvalidBps();
        _feeParams = p;
        emit ParamChanged("feeParams", bytes32(0), abi.encode(p));
    }

    function setAttestationIssuer(address issuer, bool ok) external onlySelf {
        attestationIssuer[issuer] = ok;
        emit ParamChanged("attestationIssuer", bytes32(uint256(uint160(issuer))), abi.encode(ok));
    }

    function setEligibilityAdapter(address adapter) external onlySelf {
        // Without an adapter every registry lookup reverts, which would freeze both swaps and deposits.
        // Stopping the venue belongs to the guardian, not to a typo in an address.
        if (adapter == address(0)) revert ZeroAddress();
        eligibilityAdapter = adapter;
        emit ParamChanged("eligibilityAdapter", bytes32(uint256(uint160(adapter))), "");
    }

    // ---------------------------------------------------------------------
    // Getters
    // ---------------------------------------------------------------------

    function tierConfig(uint8 tier) external view override returns (TierConfig memory) {
        return _tiers[tier];
    }

    function marketConfig(address token) external view override returns (MarketConfig memory) {
        return _markets[token];
    }

    function regimeParams() external view override returns (RegimeParams memory) {
        return _regimeParams;
    }

    function riskParams() external view override returns (RiskParams memory) {
        return _riskParams;
    }

    function feeParams() external view override returns (FeeParams memory) {
        return _feeParams;
    }
}
