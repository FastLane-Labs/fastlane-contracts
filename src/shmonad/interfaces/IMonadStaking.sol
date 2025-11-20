//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

struct ValidatorView {
    address authAddress;
    uint64 flags;
    uint256 executionStake;
    uint256 executionAccumulator;
    uint256 executionCommission;
    uint256 executionUnclaimedRewards;
    uint256 consensusStake;
    uint256 consensusCommission;
    uint256 snapshotStake;
    uint256 snapshotCommission;
    bytes secpPubkey;
    bytes blsPubkey;
}

struct DelInfo {
    uint256 stake;
    uint256 lastAccumulator;
    uint256 rewards;
    uint256 deltaStake;
    uint256 nextDeltaStake;
    uint64 deltaEpoch;
    uint64 nextDeltaEpoch;
}

struct WithdrawalRequest {
    uint256 amount;
    uint256 accumulator;
    uint64 epoch;
}

interface IMonadStaking {
    function addValidator(
        bytes calldata payload,
        bytes calldata signedSecpMessage,
        bytes calldata signedBlsMessage
    )
        external
        payable
        returns (uint64 validatorId);

    function delegate(uint64 validatorId) external payable returns (bool success);

    function undelegate(uint64 validatorId, uint256 amount, uint8 withdrawId) external returns (bool success);

    function compound(uint64 validatorId) external returns (bool success);

    function withdraw(uint64 validatorId, uint8 withdrawId) external returns (bool success);

    function claimRewards(uint64 validatorId) external returns (bool success);

    function changeCommission(uint64 validatorId, uint256 commission) external returns (bool success);

    function externalReward(uint64 validatorId) external payable returns (bool success);

    function getValidator(uint64 validatorId)
        external
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
        );

    function getDelegator(
        uint64 validatorId,
        address delegator
    )
        external
        returns (
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 unclaimedRewards,
            uint256 deltaStake,
            uint256 nextDeltaStake,
            uint64 deltaEpoch,
            uint64 nextDeltaEpoch
        );

    function getWithdrawalRequest(
        uint64 validatorId,
        address delegator,
        uint8 withdrawId
    )
        external
        returns (uint256 withdrawalAmount, uint256 accRewardPerToken, uint64 withdrawEpoch);

    function getConsensusValidatorSet(uint32 startIndex)
        external
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds);

    function getSnapshotValidatorSet(uint32 startIndex)
        external
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds);

    function getExecutionValidatorSet(uint32 startIndex)
        external
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds);

    function getDelegations(
        address delegator,
        uint64 startValId
    )
        external
        returns (bool isDone, uint64 nextValId, uint64[] memory valIds);

    function getDelegators(
        uint64 validatorId,
        address startDelegator
    )
        external
        returns (bool isDone, address nextDelegator, address[] memory delegators);

    function getEpoch() external returns (uint64 epoch, bool inEpochDelayPeriod);

    /// @notice Returns the validator ID of the current block proposer/author for this block
    /// @dev Temporary method name used by ShMonad to avoid relying on block.coinbase; mocked in tests
    function getProposerValId() external returns (uint64 val_id);

    function syscallOnEpochChange(uint64 epoch) external;

    function syscallReward(address blockAuthor) external;

    function syscallSnapshot() external;

    // ================================ //
    //             Constants            //
    // ================================ //
    // NOTE: The precompile has these constants internally but does NOT expose them as view functions.
    // Production code uses DUST_THRESHOLD and WITHDRAWAL_DELAY from Constants.sol.
    // Test code uses all constants from MockMonadStakingPrecompile.sol:
    // - MON = 1e18
    // - MIN_VALIDATE_STAKE = 100_000 * 1e18
    // - ACTIVE_VALIDATOR_STAKE = 25_000_000 * 1e18
    // - UNIT_BIAS = 1e36
    // - DUST_THRESHOLD = 1e9 (used in production)
    // - MAX_EXTERNAL_REWARD = 1e25
    // - WITHDRAWAL_DELAY = 1 (used in production)
    // - PAGINATED_RESULTS_SIZE = 100

    event ValidatorCreated(uint64 indexed validatorId, address indexed authAddress);
    event ValidatorStatusChanged(uint64 indexed validatorId, address indexed authAddress, uint64 flags);
    event Delegate(uint64 indexed validatorId, address indexed delegator, uint256 amount, uint64 activationEpoch);
    event Undelegate(
        uint64 indexed validatorId, address indexed delegator, uint8 withdrawId, uint256 amount, uint64 activationEpoch
    );
    event Withdraw(
        uint64 indexed validatorId, address indexed delegator, uint8 withdrawId, uint256 amount, uint64 withdrawEpoch
    );
    event ClaimRewards(uint256 indexed validatorId, address indexed delegator, uint256 amount);
    event CommissionChanged(uint256 indexed validatorId, uint256 oldCommission, uint256 newCommission);
}
