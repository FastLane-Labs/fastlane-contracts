//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { IMonadStaking } from "../interfaces/IMonadStaking.sol";
import { Vm } from "forge-std/Vm.sol";
import {
    STAKING_GAS_DELEGATE,
    STAKING_GAS_UNDELEGATE,
    STAKING_GAS_WITHDRAW,
    STAKING_GAS_CLAIM_REWARDS,
    STAKING_GAS_EXTERNAL_REWARD
} from "../Constants.sol";

/// @notice Drop-in mock of the Monad staking precompile with near-native state tracking for tests.
contract MockMonadStakingPrecompile is IMonadStaking {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Modifier to pause gas metering for mock functions.
    /// @param gasCost Intended to simulate expected gas costs of the real precompile in the future.
    ///                Currently unused as we simply pause metering to avoid OOG in heavy mock logic.
    modifier customGasCost(uint256 gasCost) {
        vm.pauseGasMetering();
        _;
        vm.resumeGasMetering();
    }

    // ================================ //
    //             Errors               //
    // ================================ //

    error InternalError();
    error MethodNotSupported();
    error InvalidInput();
    error ValidatorExists();
    error UnknownValidator();
    error UnknownDelegator();
    error WithdrawalIdExists();
    error UnknownWithdrawalId();
    error WithdrawalNotReady();
    error InsufficientStake();
    error InvalidSecpPubkey();
    error InvalidBlsPubkey();
    error InvalidSecpSignature();
    error InvalidBlsSignature();
    error SecpSignatureVerificationFailed();
    error BlsSignatureVerificationFailed();
    error NotInValidatorSet();
    error SolvencyError();
    error SnapshotInBoundary();
    error InvalidEpochChange();
    error RequiresAuthAddress();
    error CommissionTooHigh();
    error DelegationTooSmall();
    error ExternalRewardTooSmall();
    error ExternalRewardTooLarge();

    // ================================ //
    //            Constants             //
    // ================================ //

    uint256 public constant MON = 1e18;
    uint256 public constant MIN_VALIDATE_STAKE = 1_000_000 * MON;
    uint256 public constant ACTIVE_VALIDATOR_STAKE = 50_000_000 * MON;
    uint256 public constant UNIT_BIAS = 1e36;
    uint256 public constant DUST_THRESHOLD = 1e9;
    uint256 public constant MAX_EXTERNAL_REWARD = 1e24;
    uint256 public constant WITHDRAWAL_DELAY = 1;
    uint256 public constant PAGINATED_RESULTS_SIZE = 100;
    uint256 public constant MAX_COMMISSION = 1e18;
    uint256 public constant EPOCH_LENGTH = 50_000;
    uint256 public constant EPOCH_DELAY_PERIOD = 5000;
    uint64 public constant INITIAL_INTERNAL_EPOCH = 100;

    uint256 private constant VALIDATOR_FLAG_STAKE_TOO_LOW = 1 << 0;
    uint256 private constant VALIDATOR_FLAG_WITHDRAWN = 1 << 1;

    // ================================ //
    //             Structs              //
    // ================================ //

    /// @dev Bundles execution/consensus/snapshot fields so we can answer all native getters.
    struct Validator {
        bool exists;
        address authAddress;
        uint256 flags;
        uint256 executionStake; // includes active + scheduled
        uint256 activeStake;
        uint256 executionAccumulator;
        uint256 executionCommission;
        uint256 executionUnclaimedRewards;
        uint256 consensusStake;
        uint256 consensusCommission;
        uint256 snapshotStake;
        uint256 snapshotCommission;
        bytes secpPubkey;
        bytes blsPubkey;
        bool withdrawn;
    }

    /// @dev Mirrors native `Delegator` layout including pending stake buckets.
    struct DelegatorPosition {
        bool exists;
        uint256 stake;
        uint256 lastAccumulator;
        uint256 rewards;
        uint256 deltaStake;
        uint256 nextDeltaStake;
        uint64 deltaEpoch;
        uint64 nextDeltaEpoch;
    }

    /// @dev Internal version of `WithdrawalRequest` carrying the host accumulator snapshot.
    struct WithdrawalRequestInternal {
        bool exists;
        uint256 amount;
        uint256 accumulator;
        uint64 epoch;
    }

    /// @dev Tracks future accumulator references keyed by (valId, epoch).
    struct FutureAccumulator {
        uint256 accumulator;
        uint256 refCount;
    }

    /// @dev ABI payload used by the host to pass validator metadata to `addValidator`.
    struct AddValidatorPayload {
        bytes secpPubkey;
        bytes blsPubkey;
        address authAddress;
        uint256 amount;
        uint256 commission;
    }

    // ================================ //
    //             Storage              //
    // ================================ //

    uint64 private s_lastValId;
    uint64 private s_epoch; // simulated epoch counter maintained via harness call
    bool private s_inEpochDelayPeriod; // mirrors boundary window flag from the host
    bool private s_forceWithdrawalNotReady; // harness flag to simulate boundary-induced delays
    uint64 private s_stubbedProposerValId; // optional override for fork-mode tests

    mapping(uint64 => Validator) private s_validators; // valId => validator metadata
    mapping(bytes32 => uint64) private s_secpToValidator;
    mapping(bytes32 => uint64) private s_blsToValidator;
    mapping(address => uint64) private s_authToValidator;

    mapping(uint64 => mapping(address => DelegatorPosition)) private s_delegators; // valId => delegator => state
    mapping(uint64 => mapping(address => mapping(uint8 => WithdrawalRequestInternal))) private s_withdrawals;
    mapping(uint64 => mapping(uint64 => FutureAccumulator)) private s_futureAccumulators; // valId => epoch => snapshot

    // Validator set tracking
    // Valset tracking mirrors execution/consensus/snapshot arrays on the host.
    uint64[] private s_executionValset;
    uint64[] private s_consensusValset;
    uint64[] private s_snapshotValset;

    mapping(uint64 => uint256) private s_executionIndex; // index + 1
    mapping(uint64 => uint256) private s_consensusIndex; // index + 1
    mapping(uint64 => uint256) private s_snapshotIndex; // index + 1

    // Delegator pagination helpers
    mapping(uint64 => address[]) private s_validatorDelegators;
    mapping(uint64 => mapping(address => uint256)) private s_validatorDelegatorIndex; // index + 1

    mapping(address => uint64[]) private s_delegatorValidators;
    mapping(address => mapping(uint64 => uint256)) private s_delegatorValidatorIndex; // index + 1

    // ================================ //
    //        External Functions        //
    // ================================ //

    /// @notice Stubbed method for proposer ID. TODO: implement proposer selection logic in mock
    /// @custom:selector 0xfbacb0be
    function getProposerValId() external override returns (uint64 val_id) {
        uint64 stubbed = s_stubbedProposerValId;
        if (stubbed != 0) return stubbed;
        return s_authToValidator[block.coinbase];
    }

    /// @notice Mirrors native `add_validator` by decoding the host-packed payload with self-delegation.
    function addValidator(
        bytes calldata message,
        bytes calldata,
        bytes calldata
    )
        external
        payable
        override
        returns (uint64)
    {
        AddValidatorPayload memory payload = abi.decode(message, (AddValidatorPayload));
        if (msg.value != payload.amount) revert InvalidInput();
        if (payload.amount == 0) revert InvalidInput();
        if (payload.authAddress == address(0)) revert InvalidInput();
        if (payload.commission > MAX_COMMISSION) revert CommissionTooHigh();

        if (s_authToValidator[payload.authAddress] != 0) revert ValidatorExists();

        bytes32 secpHash = keccak256(payload.secpPubkey);
        if (s_secpToValidator[secpHash] != 0) revert ValidatorExists();
        bytes32 blsHash = keccak256(payload.blsPubkey);
        if (s_blsToValidator[blsHash] != 0) revert ValidatorExists();

        uint64 valId = ++s_lastValId;
        Validator storage validator = s_validators[valId];
        validator.exists = true;
        validator.authAddress = payload.authAddress;
        validator.executionStake = payload.amount;
        validator.activeStake = payload.amount;
        validator.executionCommission = payload.commission;
        validator.consensusCommission = payload.commission;
        validator.snapshotCommission = payload.commission;
        validator.consensusStake = payload.amount;
        validator.snapshotStake = payload.amount;
        validator.withdrawn = payload.amount < MIN_VALIDATE_STAKE;
        validator.secpPubkey = payload.secpPubkey;
        validator.blsPubkey = payload.blsPubkey;

        s_secpToValidator[secpHash] = valId;
        s_blsToValidator[blsHash] = valId;
        s_authToValidator[payload.authAddress] = valId;

        _addToExecutionValset(valId);

        DelegatorPosition storage selfDelegator = _ensureDelegator(valId, payload.authAddress);
        selfDelegator.stake += payload.amount;
        validator.withdrawn = _upcomingStake(selfDelegator) < MIN_VALIDATE_STAKE;
        _updateFlags(validator, valId);

        emit ValidatorCreated(valId, payload.authAddress);
        emit Delegate(valId, payload.authAddress, payload.amount, s_epoch);
        return valId;
    }

    /// @notice Enforce dust guardrails and schedule the delegation for the proper activation epoch.
    /// @custom:selector 0x84994fec
    function delegate(uint64 valId) external payable override customGasCost(STAKING_GAS_DELEGATE) returns (bool) {
        uint256 amount = msg.value;
        if (amount == 0) {
            return true;
        }
        if (amount < DUST_THRESHOLD) revert DelegationTooSmall();
        Validator storage validator = _mustGetValidator(valId);
        DelegatorPosition storage position = _ensureDelegator(valId, msg.sender);
        _syncAndActivate(valId, validator, position);

        uint64 activationEpoch = _scheduleDelegation(validator, position, valId, amount);
        validator.executionStake += amount;

        if (msg.sender == validator.authAddress) {
            validator.withdrawn = _upcomingStake(position) < MIN_VALIDATE_STAKE;
        }

        _updateFlags(validator, valId);

        emit Delegate(valId, msg.sender, amount, activationEpoch);
        return true;
    }

    /// @notice Sync rewards then stage a withdrawal request that unlocks after the delay period.
    /// @custom:selector 0x5cf41514
    function undelegate(
        uint64 valId,
        uint256 amount,
        uint8 withdrawalId
    )
        external
        override
        customGasCost(STAKING_GAS_UNDELEGATE)
        returns (bool)
    {
        Validator storage validator = _mustGetValidator(valId);
        DelegatorPosition storage position = s_delegators[valId][msg.sender];
        if (!position.exists) revert UnknownDelegator();
        _syncAndActivate(valId, validator, position); // settle + promote stake before removal

        WithdrawalRequestInternal storage request = s_withdrawals[valId][msg.sender][withdrawalId];
        if (request.exists) revert WithdrawalIdExists();

        uint64 deactivationEpoch = _nextActivationEpoch();

        if (amount == 0) {
            emit Undelegate(valId, msg.sender, withdrawalId, 0, deactivationEpoch);
            return true;
        }
        if (amount > position.stake) revert InsufficientStake();

        uint256 remaining = position.stake - amount;
        if (remaining > 0 && remaining < DUST_THRESHOLD) {
            amount = position.stake;
            remaining = 0;
        }

        position.stake = remaining;
        if (amount > validator.executionStake) revert InternalError();
        validator.executionStake -= amount;
        if (amount > validator.activeStake) revert InternalError();
        validator.activeStake -= amount;

        _incrementFutureAccumulator(valId, deactivationEpoch, validator.executionAccumulator);

        request.exists = true;
        request.amount = amount;
        request.accumulator = position.lastAccumulator;
        request.epoch = deactivationEpoch;

        if (!_hasLivePosition(position)) {
            _removeDelegatorLinks(valId, msg.sender);
        }

        if (msg.sender == validator.authAddress) {
            validator.withdrawn = _upcomingStake(position) < MIN_VALIDATE_STAKE;
        }

        _updateFlags(validator, valId);

        emit Undelegate(valId, msg.sender, withdrawalId, amount, deactivationEpoch);
        return true;
    }

    /// @notice Redelegate matured rewards, reusing the same scheduling logic as fresh stake.
    function compound(uint64 valId) external override returns (bool) {
        Validator storage validator = _mustGetValidator(valId);
        DelegatorPosition storage position = s_delegators[valId][msg.sender];
        if (!position.exists) revert UnknownDelegator();
        _syncAndActivate(valId, validator, position); // settle any pending rewards prior to compounding

        uint256 rewards = position.rewards;
        if (rewards == 0) {
            return true;
        }
        if (rewards < DUST_THRESHOLD) revert DelegationTooSmall();

        position.rewards = 0;
        emit ClaimRewards(valId, msg.sender, rewards);

        uint64 activationEpoch = _scheduleDelegation(validator, position, valId, rewards);
        validator.executionStake += rewards;

        if (msg.sender == validator.authAddress) {
            validator.withdrawn = _upcomingStake(position) < MIN_VALIDATE_STAKE;
        }

        _updateFlags(validator, valId);

        emit Delegate(valId, msg.sender, rewards, activationEpoch);
        return true;
    }

    /// @notice Honor the WITHDRAWAL_DELAY relative to block epochs before releasing funds.
    /// @custom:selector 0xaed2ee73
    function withdraw(
        uint64 valId,
        uint8 withdrawalId
    )
        external
        override
        customGasCost(STAKING_GAS_WITHDRAW)
        returns (bool)
    {
        WithdrawalRequestInternal storage request = s_withdrawals[valId][msg.sender][withdrawalId];
        if (!request.exists) revert UnknownWithdrawalId();

        uint64 earliestEpoch = request.epoch + uint64(WITHDRAWAL_DELAY);
        if (s_epoch < earliestEpoch) revert WithdrawalNotReady();
        if (s_forceWithdrawalNotReady) revert WithdrawalNotReady();

        Validator storage validator = _mustGetValidator(valId);
        DelegatorPosition storage position = s_delegators[valId][msg.sender];
        if (position.exists) {
            _syncAndActivate(valId, validator, position);
        }
        uint256 withdrawAccumulator = _decrementFutureAccumulator(valId, request.epoch);

        uint256 payout = request.amount;
        uint256 baseAccumulator = request.accumulator;
        if (withdrawAccumulator < baseAccumulator) revert InternalError();
        uint256 deltaAccumulator = withdrawAccumulator - baseAccumulator;
        if (deltaAccumulator != 0 && request.amount != 0) {
            uint256 rewards = (request.amount * deltaAccumulator) / UNIT_BIAS;
            if (rewards != 0) {
                if (validator.executionUnclaimedRewards < rewards) revert SolvencyError();
                validator.executionUnclaimedRewards -= rewards;
                payout += rewards;
            }
        }
        delete s_withdrawals[valId][msg.sender][withdrawalId];

        if (address(this).balance < payout) revert SolvencyError();
        (bool success,) = payable(msg.sender).call{ value: payout }("");
        if (!success) revert SolvencyError();

        emit Withdraw(valId, msg.sender, withdrawalId, payout, s_epoch);
        return true;
    }

    /// @notice Payout accumulated rewards while keeping the validator accounting solvent.
    /// @custom:selector 0xa76e2ca5
    function claimRewards(uint64 valId) external override customGasCost(STAKING_GAS_CLAIM_REWARDS) returns (bool) {
        Validator storage validator = _mustGetValidator(valId);
        DelegatorPosition storage position = s_delegators[valId][msg.sender];
        if (!position.exists) revert UnknownDelegator();
        _syncAndActivate(valId, validator, position);

        uint256 rewards = position.rewards;
        if (rewards == 0) {
            return true;
        }

        if (address(this).balance < rewards) revert SolvencyError();
        position.rewards = 0;

        (bool success,) = payable(msg.sender).call{ value: rewards }("");
        if (!success) revert SolvencyError();

        emit ClaimRewards(valId, msg.sender, rewards);
        return true;
    }

    /// @notice Update the commission immediately in execution view to mimic next-epoch effect.
    function changeCommission(uint64 valId, uint256 newCommission) external override returns (bool) {
        if (newCommission > MAX_COMMISSION) revert CommissionTooHigh();
        Validator storage validator = _mustGetValidator(valId);
        if (msg.sender != validator.authAddress) revert RequiresAuthAddress();

        uint256 oldCommission = validator.executionCommission;
        validator.executionCommission = newCommission;
        validator.consensusCommission = newCommission;
        validator.snapshotCommission = newCommission;

        emit CommissionChanged(valId, oldCommission, newCommission);
        return true;
    }

    /// @notice Apply direct rewards coming from msg.value within the native bounds.
    /// @custom:selector 0xe4b3303b
    function externalReward(uint64 valId)
        external
        payable
        override
        customGasCost(STAKING_GAS_EXTERNAL_REWARD)
        returns (bool)
    {
        uint256 reward = msg.value;
        if (reward < MON) revert ExternalRewardTooSmall();
        if (reward > MAX_EXTERNAL_REWARD) revert ExternalRewardTooLarge(); // native upper bound

        Validator storage validator = _mustGetValidator(valId);
        uint256 epochStake = _thisEpochStake(validator);
        if (epochStake == 0) revert NotInValidatorSet();

        _applyReward(valId, validator, reward, false, epochStake);
        return true;
    }

    /// @notice Runtime-only syscalls are not exercised in tests; mock reverts when invoked directly.
    function syscallOnEpochChange(uint64) external pure override {
        revert MethodNotSupported();
    }

    function syscallReward(address) external pure override {
        revert MethodNotSupported();
    }

    function syscallSnapshot() external pure override {
        revert MethodNotSupported();
    }

    // ================================ //
    //              Views               //
    // ================================ //

    /// @notice Return validator details mirroring the precompile tuple return shape.
    /// @custom:selector 0x2b6d639a
    function getValidator(uint64 valId)
        external
        override
        returns (
            address authAddress,
            uint64 flags,
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 commission,
            uint256 unclaimedRewards,
            uint256 consensusStake,
            uint256 consensusCommission,
            uint256 snapshotStake,
            uint256 snapshotCommission,
            bytes memory secpPubkey,
            bytes memory blsPubkey
        )
    {
        Validator storage validator = s_validators[valId];
        if (!validator.exists) revert UnknownValidator();
        authAddress = validator.authAddress;
        flags = uint64(validator.flags);
        stake = validator.executionStake;
        accRewardPerToken = validator.executionAccumulator;
        commission = validator.executionCommission;
        unclaimedRewards = validator.executionUnclaimedRewards;
        consensusStake = validator.consensusStake;
        consensusCommission = validator.consensusCommission;
        snapshotStake = validator.snapshotStake;
        snapshotCommission = validator.snapshotCommission;
        secpPubkey = validator.secpPubkey;
        blsPubkey = validator.blsPubkey;
    }

    /// @notice Surface delegator stake, reward debt, and scheduled activations.
    /// @custom:selector 0x573c1ce0
    function getDelegator(
        uint64 valId,
        address delegator
    )
        external
        override
        returns (
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 unclaimedRewards,
            uint256 deltaStake,
            uint256 nextDeltaStake,
            uint64 deltaEpoch,
            uint64 nextDeltaEpoch
        )
    {
        DelegatorPosition storage position = s_delegators[valId][delegator];
        stake = position.stake;
        accRewardPerToken = position.lastAccumulator;
        unclaimedRewards = position.rewards;
        deltaStake = position.deltaStake;
        nextDeltaStake = position.nextDeltaStake;
        deltaEpoch = position.deltaEpoch;
        nextDeltaEpoch = position.nextDeltaEpoch;
    }

    /// @notice Enumerate validator IDs delegated to by a given address.
    function getDelegations(
        address delegator,
        uint64 cursorValId
    )
        external
        override
        returns (bool done, uint64 nextValId, uint64[] memory validatorIds)
    {
        uint64[] storage list = s_delegatorValidators[delegator];
        uint256 startIndex = 0;
        if (cursorValId != 0) {
            uint256 idx = s_delegatorValidatorIndex[delegator][cursorValId];
            if (idx == 0) return (true, 0, new uint64[](0));
            startIndex = idx - 1;
            if (startIndex >= list.length) {
                return (true, 0, new uint64[](0));
            }
        }

        uint256 remaining = list.length > startIndex ? list.length - startIndex : 0;
        uint256 count = remaining < PAGINATED_RESULTS_SIZE ? remaining : PAGINATED_RESULTS_SIZE;
        validatorIds = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            validatorIds[i] = list[startIndex + i];
        }

        uint256 nextIndex = startIndex + count;
        done = nextIndex >= list.length;
        nextValId = done ? 0 : list[nextIndex];
    }

    /// @notice Enumerate delegators for a validator, mirroring native pagination semantics.
    function getDelegators(
        uint64 valId,
        address cursorDelegator
    )
        external
        override
        returns (bool done, address nextDelegator, address[] memory delegators)
    {
        address[] storage list = s_validatorDelegators[valId];
        uint256 startIndex = 0;
        if (cursorDelegator != address(0)) {
            uint256 idx = s_validatorDelegatorIndex[valId][cursorDelegator];
            if (idx == 0) return (true, address(0), new address[](0));
            startIndex = idx - 1;
            if (startIndex >= list.length) {
                return (true, address(0), new address[](0));
            }
        }

        uint256 remaining = list.length > startIndex ? list.length - startIndex : 0;
        uint256 count = remaining < PAGINATED_RESULTS_SIZE ? remaining : PAGINATED_RESULTS_SIZE;
        delegators = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            delegators[i] = list[startIndex + i];
        }

        uint256 nextIndex = startIndex + count;
        done = nextIndex >= list.length;
        nextDelegator = done ? address(0) : list[nextIndex];
    }

    /// @notice Read the stored withdrawal request triple; returns zeros if slot unused.
    /// @custom:selector 0x56fa2045
    function getWithdrawalRequest(
        uint64 valId,
        address delegator,
        uint8 withdrawalId
    )
        external
        override
        returns (uint256 withdrawalAmount, uint256 accRewardPerToken, uint64 withdrawEpoch)
    {
        WithdrawalRequestInternal storage req = s_withdrawals[valId][delegator][withdrawalId];
        if (!req.exists) return (0, 0, 0);
        withdrawalAmount = req.amount;
        accRewardPerToken = req.accumulator;
        withdrawEpoch = req.epoch;
    }

    /// @notice Page through the consensus valset with the precompile's fixed page size.
    function getConsensusValidatorSet(uint32 startIndex)
        external
        override
        returns (bool done, uint32 nextIndex, uint64[] memory validatorIds)
    {
        return _paginateValset(s_consensusValset, startIndex);
    }

    /// @notice Page through the snapshot valset with the precompile's fixed page size.
    function getSnapshotValidatorSet(uint32 startIndex)
        external
        override
        returns (bool done, uint32 nextIndex, uint64[] memory validatorIds)
    {
        return _paginateValset(s_snapshotValset, startIndex);
    }

    /// @notice Page through the execution valset with the precompile's fixed page size.
    function getExecutionValidatorSet(uint32 startIndex)
        external
        override
        returns (bool done, uint32 nextIndex, uint64[] memory validatorIds)
    {
        return _paginateValset(s_executionValset, startIndex);
    }

    /// @custom:selector 0x757991a8
    function getEpoch() external override returns (uint64 epoch, bool inEpochDelayPeriod) {
        return (uint64(s_epoch + INITIAL_INTERNAL_EPOCH), s_inEpochDelayPeriod);
    }

    // ================================ //
    //         Harness Functions        //
    // ================================ //

    /// @notice Test hook to snapshot consensus state exactly like the native syscall.
    function harnessSyscallSnapshot() external {
        for (uint256 i = 0; i < s_snapshotValset.length; i++) {
            delete s_snapshotIndex[s_snapshotValset[i]];
        }
        delete s_snapshotValset;
        for (uint256 i = 0; i < s_consensusValset.length; i++) {
            uint64 valId = s_consensusValset[i];
            s_snapshotIndex[valId] = i + 1;
            s_snapshotValset.push(valId);
            Validator storage validator = s_validators[valId];
            validator.snapshotStake = validator.consensusStake;
            validator.snapshotCommission = validator.consensusCommission;
        }
    }

    /// @notice Test hook to simulate the runtime's epoch transition side effects.
    function harnessSyscallOnEpochChange(bool inDelayPeriod) external {
        s_epoch += 1;
        s_inEpochDelayPeriod = inDelayPeriod;

        for (uint256 i = 0; i < s_executionValset.length; i++) {
            uint64 valId = s_executionValset[i];
            Validator storage validator = s_validators[valId];

            FutureAccumulator storage future = s_futureAccumulators[valId][s_epoch];
            if (future.refCount > 0) {
                future.accumulator = validator.executionAccumulator;
            }

            address[] storage delegators = s_validatorDelegators[valId];
            uint256 activatedTotal;
            for (uint256 j = 0; j < delegators.length; j++) {
                DelegatorPosition storage position = s_delegators[valId][delegators[j]];
                _syncDelegator(validator, position);
                uint256 activated = _activateScheduledStake(valId, position, s_epoch);
                if (activated > 0) {
                    activatedTotal += activated;
                }
            }

            if (activatedTotal > 0) {
                validator.activeStake += activatedTotal;
            }

            if (validator.authAddress != address(0)) {
                DelegatorPosition storage authPos = s_delegators[valId][validator.authAddress];
                validator.withdrawn = _upcomingStake(authPos) < MIN_VALIDATE_STAKE;
            }
            _updateConsensusMembership(valId);
            _updateFlags(validator, valId);
        }
    }

    /// @notice Test hook to force the next withdrawal attempt to revert as not ready.
    function harnessSetForceWithdrawalNotReady(bool enabled) external {
        s_forceWithdrawalNotReady = enabled;
    }

    /// @notice Test hook to override the stored withdrawal epoch for a pending request.
    function harnessSetWithdrawalEpoch(uint64 valId, address delegator, uint8 withdrawalId, uint64 epoch) external {
        WithdrawalRequestInternal storage request = s_withdrawals[valId][delegator][withdrawalId];
        if (!request.exists) revert UnknownWithdrawalId();
        request.epoch = epoch;
    }

    /// @notice Test hook to apply rewards as if they were injected by the runtime.
    function harnessSyscallReward(uint64 valId, uint256 reward) external payable {
        if (msg.value != reward) revert InvalidInput();
        Validator storage validator = _mustGetValidator(valId);
        uint256 epochStake = _thisEpochStake(validator);
        if (epochStake == 0) revert NotInValidatorSet();
        _applyReward(valId, validator, reward, true, epochStake);
    }

    struct ValidatorSeed {
        uint64 valId;
        address authAddress;
        uint256 consensusStake;
        uint256 consensusCommission;
        uint256 snapshotStake;
        uint256 snapshotCommission;
        uint256 executionAccumulator;
        uint256 executionUnclaimedRewards;
        bytes secpPubkey;
        bytes blsPubkey;
    }

    struct DelegatorSeed {
        uint64 valId;
        address delegator;
        uint256 stake;
        uint256 lastAccumulator;
        uint256 rewards;
        uint256 deltaStake;
        uint256 nextDeltaStake;
        uint64 deltaEpoch;
        uint64 nextDeltaEpoch;
    }

    struct WithdrawalSeed {
        uint64 valId;
        address delegator;
        uint8 withdrawalId;
        uint256 amount;
        uint256 accumulator;
        uint64 epoch;
    }

    /// @notice Test hook to override the current proposer validator ID (fork-mode convenience).
    function harnessSetProposerValId(uint64 valId) external {
        s_stubbedProposerValId = valId;
    }

    /// @notice Test hook to set the external epoch/delay flag directly (fork-mode convenience).
    /// @dev Accepts the external epoch returned by getEpoch(); internal storage subtracts INITIAL_INTERNAL_EPOCH.
    function harnessSetEpoch(uint64 epoch, bool inDelayPeriod) external {
        if (epoch < INITIAL_INTERNAL_EPOCH) revert InvalidInput();
        s_epoch = epoch - INITIAL_INTERNAL_EPOCH;
        s_inEpochDelayPeriod = inDelayPeriod;
    }

    /// @notice Bulk seed helper for validator views.
    /// @dev Seeds minimal fields used by ShMonad; derived fields/valset membership are normalized in-place.
    function harnessUpsertValidators(ValidatorSeed[] calldata seeds) external {
        for (uint256 i = 0; i < seeds.length; i++) {
            _harnessUpsertValidator(seeds[i]);
        }
    }

    function harnessUpsertDelegators(DelegatorSeed[] calldata seeds) external {
        for (uint256 i = 0; i < seeds.length; i++) {
            _harnessUpsertDelegator(seeds[i]);
        }
    }

    function harnessUpsertWithdrawals(WithdrawalSeed[] calldata seeds) external {
        for (uint256 i = 0; i < seeds.length; i++) {
            _harnessUpsertWithdrawal(seeds[i]);
        }
    }

    /// @notice Bulk-load a snapshot emitted by `script/fork/snapshot_staking_precompile.py`.
    /// @dev Snapshot format:
    ///      `abi.encode(uint64 epoch, bool inDelay, ValidatorSeed[] validators, DelegatorSeed[] delegators,
    /// WithdrawalSeed[] withdrawals)`.
    ///      This helper is intended for fork-mode test harnesses where the precompile is missing in Foundry forks.
    function harnessLoadSnapshot(bytes calldata snapshot) external {
        (
            uint64 epochExternal,
            bool inDelay,
            ValidatorSeed[] memory validators,
            DelegatorSeed[] memory delegators,
            WithdrawalSeed[] memory withdrawals
        ) = abi.decode(snapshot, (uint64, bool, ValidatorSeed[], DelegatorSeed[], WithdrawalSeed[]));

        if (epochExternal < INITIAL_INTERNAL_EPOCH) revert InvalidInput();
        s_epoch = epochExternal - INITIAL_INTERNAL_EPOCH;
        s_inEpochDelayPeriod = inDelay;

        for (uint256 i = 0; i < validators.length; i++) {
            _harnessUpsertValidator(validators[i]);
        }
        for (uint256 i = 0; i < delegators.length; i++) {
            _harnessUpsertDelegator(delegators[i]);
        }
        for (uint256 i = 0; i < withdrawals.length; i++) {
            _harnessUpsertWithdrawal(withdrawals[i]);
        }

        // Fork-mode hygiene:
        // After seeding from a live network snapshot, we want any *newly registered* validators inside tests to use
        // high-numbered IDs so they won't collide with existing chain validator IDs managed by ShMonad.
        //
        // This only affects future `registerValidator()` calls; it does not change any seeded validator IDs.
        if (s_lastValId < 9999) s_lastValId = 9999;
    }

    function _harnessUpsertValidator(ValidatorSeed memory seed) internal {
        uint64 valId = seed.valId;
        if (valId == 0) revert InvalidInput();
        if (seed.authAddress == address(0)) revert InvalidInput();

        if (valId > s_lastValId) s_lastValId = valId;

        Validator storage validator = s_validators[valId];
        if (!validator.exists) {
            validator.exists = true;
            _addToExecutionValset(valId);
        }

        validator.authAddress = seed.authAddress;
        validator.consensusStake = seed.consensusStake;
        validator.snapshotStake = seed.snapshotStake;
        validator.consensusCommission = seed.consensusCommission;
        validator.snapshotCommission = seed.snapshotCommission;

        // Execution view is used for reward math in the mock; keep it consistent enough for reads.
        validator.activeStake = seed.consensusStake;
        validator.executionStake = seed.consensusStake;
        validator.executionCommission = seed.consensusCommission;
        validator.executionAccumulator = seed.executionAccumulator;
        validator.executionUnclaimedRewards = seed.executionUnclaimedRewards;
        validator.secpPubkey = seed.secpPubkey;
        validator.blsPubkey = seed.blsPubkey;

        // Best-effort reverse lookup wiring (real chain may have duplicates; fork tests can stub proposer).
        s_authToValidator[seed.authAddress] = valId;
        if (seed.secpPubkey.length != 0) {
            bytes32 secpHash = keccak256(seed.secpPubkey);
            if (s_secpToValidator[secpHash] == 0) s_secpToValidator[secpHash] = valId;
        }
        if (seed.blsPubkey.length != 0) {
            bytes32 blsHash = keccak256(seed.blsPubkey);
            if (s_blsToValidator[blsHash] == 0) s_blsToValidator[blsHash] = valId;
        }

        // Derived flags and consensus valset membership.
        validator.withdrawn = seed.consensusStake < MIN_VALIDATE_STAKE;
        _updateConsensusMembership(valId);
        _setSnapshotMembership(valId, seed.snapshotStake != 0);
        _updateFlags(validator, valId);
    }

    function _harnessUpsertDelegator(DelegatorSeed memory seed) internal {
        if (seed.delegator == address(0)) revert InvalidInput();
        Validator storage validator = _mustGetValidator(seed.valId);

        DelegatorPosition storage position = s_delegators[seed.valId][seed.delegator];
        if (!position.exists) {
            position.exists = true;
            _addDelegatorLinks(seed.valId, seed.delegator);
        }

        position.stake = seed.stake;
        position.lastAccumulator = seed.lastAccumulator;
        position.rewards = seed.rewards;
        position.deltaStake = seed.deltaStake;
        position.nextDeltaStake = seed.nextDeltaStake;
        position.deltaEpoch = _toInternalEpochOrZero(seed.deltaEpoch);
        position.nextDeltaEpoch = _toInternalEpochOrZero(seed.nextDeltaEpoch);

        // Seed future accumulator snapshots for any scheduled stake.
        // Without this, `harnessSyscallOnEpochChange()` can underflow its refcount bookkeeping when it tries to
        // activate scheduled stake via `_decrementFutureAccumulator`.
        //
        // Note: The mock only tracks one accumulator per (valId,epoch); this is consistent with how
        // `_scheduleDelegation`
        // records the accumulator at scheduling time.
        if (position.deltaStake != 0 && position.deltaEpoch != 0) {
            _incrementFutureAccumulator(seed.valId, position.deltaEpoch, validator.executionAccumulator);
        }
        if (position.nextDeltaStake != 0 && position.nextDeltaEpoch != 0) {
            _incrementFutureAccumulator(seed.valId, position.nextDeltaEpoch, validator.executionAccumulator);
        }

        if (seed.delegator == validator.authAddress && validator.authAddress != address(0)) {
            validator.withdrawn = _upcomingStake(position) < MIN_VALIDATE_STAKE;
            _updateFlags(validator, seed.valId);
        }
    }

    function _harnessUpsertWithdrawal(WithdrawalSeed memory seed) internal {
        if (seed.delegator == address(0)) revert InvalidInput();
        _mustGetValidator(seed.valId);

        WithdrawalRequestInternal storage request = s_withdrawals[seed.valId][seed.delegator][seed.withdrawalId];
        request.exists = true;
        request.amount = seed.amount;
        request.accumulator = seed.accumulator;
        request.epoch = _toInternalEpochOrZero(seed.epoch);

        // Ensure a corresponding accumulator snapshot exists so withdraw() won't revert on refcount underflow.
        _incrementFutureAccumulator(seed.valId, request.epoch, request.accumulator);
    }

    function _toInternalEpochOrZero(uint64 externalEpoch) internal pure returns (uint64 internalEpoch) {
        if (externalEpoch == 0) return 0;
        if (externalEpoch < INITIAL_INTERNAL_EPOCH) revert InvalidInput();
        return externalEpoch - INITIAL_INTERNAL_EPOCH;
    }

    function _setSnapshotMembership(uint64 valId, bool shouldBeInSet) internal {
        uint256 idx = s_snapshotIndex[valId];
        if (shouldBeInSet) {
            if (idx == 0) {
                s_snapshotIndex[valId] = s_snapshotValset.length + 1;
                s_snapshotValset.push(valId);
            }
            return;
        }

        if (idx == 0) return;
        uint256 arrayIndex = idx - 1;
        uint256 lastIndex = s_snapshotValset.length - 1;
        if (arrayIndex != lastIndex) {
            uint64 replacement = s_snapshotValset[lastIndex];
            s_snapshotValset[arrayIndex] = replacement;
            s_snapshotIndex[replacement] = arrayIndex + 1;
        }
        s_snapshotValset.pop();
        delete s_snapshotIndex[valId];
    }

    /// @notice Convenience getter that mirrors the runtime's internal lookup.
    function harnessValidatorId(address authAddress) external view returns (uint64) {
        return s_authToValidator[authAddress];
    }

    /// @notice Test helper to mark a delegator as existing without transferring stake.
    function harnessEnsureDelegator(uint64 valId, address delegator) external {
        if (delegator == address(0)) revert InvalidInput();
        _ensureDelegator(valId, delegator);
    }

    /// @notice Lightweight validator registration helper for unit tests.
    function registerValidator(address authAddress) external returns (uint64) {
        if (authAddress == address(0)) revert InvalidInput();
        if (s_authToValidator[authAddress] != 0) revert ValidatorExists();

        uint64 valId = ++s_lastValId;
        Validator storage validator = s_validators[valId];
        validator.exists = true;
        validator.authAddress = authAddress;

        _addToExecutionValset(valId);
        validator.withdrawn = true;
        _updateFlags(validator, valId);
        _addDelegatorLinks(valId, authAddress);
        s_authToValidator[authAddress] = valId;
        return valId;
    }

    // ================================ //
    //         Internal Helpers         //
    // ================================ //

    /// @dev Revert with `UnknownValidator` if the validator ID is not registered.
    function _mustGetValidator(uint64 valId) internal view returns (Validator storage) {
        Validator storage validator = s_validators[valId];
        if (!validator.exists) revert UnknownValidator();
        return validator;
    }

    /// @dev Lazily instantiate delegator state and seed its reward debt.
    function _ensureDelegator(uint64 valId, address delegator) internal returns (DelegatorPosition storage position) {
        position = s_delegators[valId][delegator];
        if (!position.exists) {
            position.exists = true;
            position.lastAccumulator = s_validators[valId].executionAccumulator;
            _addDelegatorLinks(valId, delegator);
        }
    }

    /// @dev Mirror host lazy activation by settling rewards and promoting matured stake in-place.
    function _syncAndActivate(uint64 valId, Validator storage validator, DelegatorPosition storage position) internal {
        _syncDelegator(validator, position);
        uint256 activated = _activateScheduledStake(valId, position, s_epoch);
        if (activated != 0) {
            validator.activeStake += activated;
        }
    }

    /// @dev Maintain reverse lookups so pagination mirrors the host intrusive lists.
    function _addDelegatorLinks(uint64 valId, address delegator) internal {
        if (s_validatorDelegatorIndex[valId][delegator] == 0) {
            s_validatorDelegators[valId].push(delegator);
            s_validatorDelegatorIndex[valId][delegator] = s_validatorDelegators[valId].length; // index + 1
        }
        if (s_delegatorValidatorIndex[delegator][valId] == 0) {
            s_delegatorValidators[delegator].push(valId);
            s_delegatorValidatorIndex[delegator][valId] = s_delegatorValidators[delegator].length; // index + 1
        }
    }

    /// @dev Remove reverse lookups when the delegator exits completely.
    function _removeDelegatorLinks(uint64 valId, address delegator) internal {
        uint256 idx = s_validatorDelegatorIndex[valId][delegator];
        if (idx != 0) {
            uint256 arrayIndex = idx - 1;
            uint256 lastIndex = s_validatorDelegators[valId].length - 1;
            if (arrayIndex != lastIndex) {
                address replacement = s_validatorDelegators[valId][lastIndex];
                s_validatorDelegators[valId][arrayIndex] = replacement;
                s_validatorDelegatorIndex[valId][replacement] = arrayIndex + 1;
            }
            s_validatorDelegators[valId].pop();
            delete s_validatorDelegatorIndex[valId][delegator];
        }

        uint256 idx2 = s_delegatorValidatorIndex[delegator][valId];
        if (idx2 != 0) {
            uint256 arrayIndex2 = idx2 - 1;
            uint256 lastIndex2 = s_delegatorValidators[delegator].length - 1;
            if (arrayIndex2 != lastIndex2) {
                uint64 replacement2 = s_delegatorValidators[delegator][lastIndex2];
                s_delegatorValidators[delegator][arrayIndex2] = replacement2;
                s_delegatorValidatorIndex[delegator][replacement2] = arrayIndex2 + 1;
            }
            s_delegatorValidators[delegator].pop();
            delete s_delegatorValidatorIndex[delegator][valId];
        }
    }

    /// @dev Determine whether we still need to track this delegator in pagination structures.
    function _hasLivePosition(DelegatorPosition storage position) internal view returns (bool) {
        return position.stake != 0 || position.deltaStake != 0 || position.nextDeltaStake != 0 || position.rewards != 0;
    }

    /// @dev Total stake that will be active no later than next epoch.
    function _upcomingStake(DelegatorPosition storage position) internal view returns (uint256) {
        return position.stake + position.deltaStake + position.nextDeltaStake;
    }

    /// @dev Pull rewards owed since the last interaction into `position.rewards`.
    function _syncDelegator(Validator storage validator, DelegatorPosition storage position) internal {
        if (position.stake == 0) {
            position.lastAccumulator = validator.executionAccumulator;
            return;
        }

        uint256 accumulator = validator.executionAccumulator;
        uint256 last = position.lastAccumulator;
        if (accumulator > last) {
            uint256 delta = accumulator - last;
            uint256 pending = (position.stake * delta) / UNIT_BIAS;
            if (pending != 0) {
                if (validator.executionUnclaimedRewards < pending) revert SolvencyError();
                validator.executionUnclaimedRewards -= pending;
                position.rewards += pending;
            }
            position.lastAccumulator = accumulator;
        }
    }

    /// @dev Queue stake for activation and bump refcounts so withdrawals read the right accumulator.
    function _scheduleDelegation(
        Validator storage validator,
        DelegatorPosition storage position,
        uint64 valId,
        uint256 amount
    )
        internal
        returns (uint64 activationEpoch)
    {
        activationEpoch = _nextActivationEpoch();

        if (position.deltaStake == 0) {
            position.deltaEpoch = activationEpoch;
            position.deltaStake = amount;
            _incrementFutureAccumulator(valId, activationEpoch, validator.executionAccumulator);
        } else if (position.deltaEpoch == activationEpoch) {
            position.deltaStake += amount;
        } else {
            if (position.nextDeltaStake == 0) {
                position.nextDeltaEpoch = activationEpoch;
                position.nextDeltaStake = amount;
                _incrementFutureAccumulator(valId, activationEpoch, validator.executionAccumulator);
            } else if (position.nextDeltaEpoch == activationEpoch) {
                position.nextDeltaStake += amount;
            } else {
                revert InvalidInput();
            }
        }
    }

    /// @dev Promote scheduled stake into the active balance when its epoch arrives.
    function _activateScheduledStake(
        uint64 valId,
        DelegatorPosition storage position,
        uint64 currentEpoch
    )
        internal
        returns (uint256 activated)
    {
        if (position.deltaStake != 0 && position.deltaEpoch == currentEpoch) {
            activated += position.deltaStake;
            position.stake += position.deltaStake;
            _decrementFutureAccumulator(valId, currentEpoch);
            position.deltaStake = 0;
            position.deltaEpoch = 0;
        }

        if (position.nextDeltaStake != 0 && position.nextDeltaEpoch == currentEpoch) {
            activated += position.nextDeltaStake;
            position.stake += position.nextDeltaStake;
            _decrementFutureAccumulator(valId, currentEpoch);
            position.nextDeltaStake = 0;
            position.nextDeltaEpoch = 0;
        }
    }

    /// @dev Append validator to execution list once; subsequent calls are no-ops.
    function _addToExecutionValset(uint64 valId) internal {
        if (s_executionIndex[valId] != 0) return;
        s_executionIndex[valId] = s_executionValset.length + 1;
        s_executionValset.push(valId);
    }

    /// @dev Maintain consensus list membership as active stake crosses the activation threshold.
    function _updateConsensusMembership(uint64 valId) internal {
        Validator storage validator = s_validators[valId];
        bool shouldBeInConsensus = validator.activeStake >= ACTIVE_VALIDATOR_STAKE;
        uint256 idx = s_consensusIndex[valId];

        if (shouldBeInConsensus) {
            if (idx == 0) {
                s_consensusIndex[valId] = s_consensusValset.length + 1;
                s_consensusValset.push(valId);
            }
        } else if (idx != 0) {
            uint256 arrayIndex = idx - 1;
            uint256 lastIndex = s_consensusValset.length - 1;
            if (arrayIndex != lastIndex) {
                uint64 replacement = s_consensusValset[lastIndex];
                s_consensusValset[arrayIndex] = replacement;
                s_consensusIndex[replacement] = arrayIndex + 1;
            }
            s_consensusValset.pop();
            delete s_consensusIndex[valId];
        }

        validator.consensusStake = validator.activeStake;
    }

    /// @dev Update validator flags (stake threshold + withdrawn) and emit if anything changes.
    function _updateFlags(Validator storage validator, uint64 valId) internal {
        uint256 newFlags;
        if (validator.executionStake < ACTIVE_VALIDATOR_STAKE) {
            newFlags |= VALIDATOR_FLAG_STAKE_TOO_LOW;
        }
        if (validator.withdrawn) {
            newFlags |= VALIDATOR_FLAG_WITHDRAWN;
        }

        if (validator.flags != newFlags) {
            validator.flags = newFlags;
            emit ValidatorStatusChanged(valId, validator.authAddress, uint64(newFlags));
        }
    }

    /// @dev Calculate the next activation epoch using the simulated boundary flag.
    function _nextActivationEpoch() internal view returns (uint64) {
        uint64 base = s_epoch;
        return base + (s_inEpochDelayPeriod ? 2 : 1);
    }

    /// @dev Track the accumulator value that scheduled stake/withdrawals should reference later.
    function _incrementFutureAccumulator(uint64 valId, uint64 epoch, uint256 accumulator) internal {
        FutureAccumulator storage future = s_futureAccumulators[valId][epoch];
        if (future.refCount == 0) {
            future.accumulator = accumulator;
        }
        future.refCount += 1;
    }

    /// @dev Drop accumulator snapshots once all scheduled references for an epoch have executed.
    function _decrementFutureAccumulator(uint64 valId, uint64 epoch) internal returns (uint256) {
        FutureAccumulator storage future = s_futureAccumulators[valId][epoch];
        if (future.refCount == 0) revert InternalError();
        uint256 value = future.accumulator;
        future.refCount -= 1;
        if (future.refCount == 0) {
            future.accumulator = 0;
        }
        return value;
    }

    /// @dev Stake snapshot used for reward distribution in the current epoch.
    function _thisEpochStake(Validator storage validator) internal view returns (uint256) {
        return s_inEpochDelayPeriod ? validator.snapshotStake : validator.consensusStake;
    }

    /// @dev Split validator commission and update the per-token accumulator for delegators.
    function _applyReward(
        uint64 valId,
        Validator storage validator,
        uint256 reward,
        bool takeCommission,
        uint256 epochStake
    )
        internal
    {
        uint256 commissionCut;
        if (takeCommission && validator.executionCommission != 0 && validator.authAddress != address(0)) {
            commissionCut = (reward * validator.executionCommission) / 1e18;
            if (commissionCut != 0) {
                DelegatorPosition storage auth = _ensureDelegator(valId, validator.authAddress);
                _syncAndActivate(valId, validator, auth);
                auth.rewards += commissionCut;
            }
        }

        uint256 distributable = reward - commissionCut;
        if (distributable == 0 || epochStake == 0) {
            return;
        }

        validator.executionAccumulator += (distributable * UNIT_BIAS) / epochStake;
        validator.executionUnclaimedRewards += distributable;
    }

    /// @dev Shared valset pagination helper matching the host result shape.
    function _paginateValset(
        uint64[] storage valset,
        uint32 startIndex
    )
        internal
        view
        returns (bool done, uint32 nextIndex, uint64[] memory validatorIds)
    {
        if (startIndex >= valset.length) {
            return (true, uint32(valset.length), new uint64[](0));
        }

        uint256 remaining = valset.length - startIndex;
        uint256 count = remaining < PAGINATED_RESULTS_SIZE ? remaining : PAGINATED_RESULTS_SIZE;
        validatorIds = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            validatorIds[i] = valset[startIndex + i];
        }

        uint32 newIndex = startIndex + uint32(count);
        done = newIndex >= valset.length;
        nextIndex = done ? uint32(valset.length) : newIndex;
    }
}
