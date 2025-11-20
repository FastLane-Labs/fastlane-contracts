//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

abstract contract ShMonadEvents {
    event Commit(uint64 indexed policyID, address indexed account, uint256 amount);
    event RequestUncommit(
        uint64 indexed policyID, address indexed account, uint256 amount, uint256 expectedUncommitCompleteBlock
    );
    event CompleteUncommit(uint64 indexed policyID, address indexed account, uint256 amount);
    event UncommitApprovalUpdated(
        uint64 indexed policyID, address indexed account, address indexed completor, uint96 shares
    );
    event AgentTransferFromCommitted(uint64 indexed policyID, address indexed from, address indexed to, uint256 amount);
    event AgentTransferToUncommitted(uint64 indexed policyID, address indexed from, address indexed to, uint256 amount);
    event AgentWithdrawFromCommitted(uint64 indexed policyID, address indexed from, address indexed to, uint256 amount);
    event AgentExecuteWithSponsor(
        uint64 indexed policyID,
        address indexed payor,
        address indexed agent,
        address recipient,
        uint256 msgValue,
        uint256 gasLimit,
        uint256 actualPayorCost
    );
    event SetTopUp(
        uint64 indexed policyID,
        address indexed account,
        uint128 minCommitted,
        uint128 maxTopUpPerPeriod,
        uint32 topUpPeriodDuration
    );
    event CreatePolicy(uint64 indexed policyID, address indexed creator, uint48 escrowDuration);
    event AddPolicyAgent(uint64 indexed policyID, address indexed agent);
    event RemovePolicyAgent(uint64 indexed policyID, address indexed agent);
    event DisablePolicy(uint64 indexed policyID);
    event BoostYield(
        address indexed sender,
        address indexed yieldOriginator,
        uint256 indexed validatorId,
        uint256 amount,
        bool sharesBurned
    );

    // Capital Allocator events
    event RequestUnstake(address indexed owner, uint256 shares, uint256 amountMon, uint256 completionEpoch);
    event CompleteUnstake(address indexed owner, uint256 amountMon);
    event NewEpoch(uint256 epochNumber, uint256 requestedUnstakeAmount, uint256 redeemedUnstakeAmount);
    event ValidatorAdded(uint256 validatorId, address coinbase);
    event ValidatorRegisteredByAuth(uint64 indexed validatorId, address indexed authAddress);
    event ValidatorNotFoundInActiveSet(
        uint64 validatorId, address coinbase, uint64 internalEpoch, uint256 detectionIndex
    );
    event ValidatorMarkedInactive(uint64 validatorId, address coinbase, uint64 internalEpoch);
    event ValidatorDeactivated(uint256 validatorId);
    event ValidatorRemoved(uint256 validatorId);
    event ValidatorWeightsUpdated(uint256[] validators, uint16[] targetWeights, uint256 totalWeight);
    event ValidatorStakeAdded(uint256 indexed validatorId, uint256 amount);
    event ValidatorUnstakeRequested(
        uint64 indexed withdrawEpoch, uint64 indexed validatorId, uint8 withdrawId, uint256 amount
    );
    event ValidatorUnstakeCompleted(uint256 indexed validatorId, uint256 amount, uint256 withdrawId);
    event ManualUnstakeRedemption(uint256 redeemedAmount);
    event ManualUnstakeInitiation(uint256 amountRequested, uint256 amountUnstaked);
    event StakeFromPoolLiquidity(uint256 amountRequested, uint256 amountStaked, uint256 poolLiquidityRemaining);
    event LowValidatorStakeDeltaOnDecrease(
        address coinbase,
        uint64 validatorId,
        uint64 globalEpoch,
        uint128 targetStakeAmount,
        uint128 netAmount,
        bool inActiveSetCurrent,
        bool inActiveSetLast
    );
    event LowValidatorStakeDeltaOnIncrease(
        address coinbase,
        uint64 validatorId,
        uint64 globalEpoch,
        uint128 targetStakeAmount,
        uint128 netAmount,
        bool inActiveSetCurrent,
        bool inActiveSetLast
    );
    event LowValidatorStakeDeltaNetZero(
        address coinbase,
        uint64 validatorId,
        uint64 globalEpoch,
        uint128 targetStakeAmount,
        uint128 netAmount,
        bool inActiveSetCurrent,
        bool inActiveSetLast
    );
    event InsufficientLocalBalance(
        uint256 expectedAmount, uint256 actualAmount, uint256 balance, uint256 totalSupply, uint256 actionIndex
    );
    event InsufficientActiveDelegatedBalance(
        address coinbase,
        uint64 validatorId,
        uint64 globalEpoch,
        uint256 expectedWithdrawAmount,
        uint256 actualWithdrawAmount
    );
    event WithdrawSettlementDelayed(
        address coinbase,
        uint64 validatorId,
        uint64 globalEpoch,
        uint256 expectedWithdrawAmount,
        uint256 availableWithdrawAmount,
        uint8 withdrawalId
    );
    event QueuesOffsetViaNet(
        uint256 offsetAmount,
        uint256 globalUnstakableAmount,
        uint256 queueForUnstake,
        uint256 globalStakableAmount,
        uint256 queueToStake
    );
    event ReservesIncreasedBySurplusDeposits(uint256 netToReserves);
    event ReservesIncreasedByExcessQueueCapacity(uint256 netToReserves);
    event UnstakingQueueExceedsUnstakableAmount(uint256 queueForUnstake, uint256 unstakableAmount);
    event StakeUnassignableNoGlobalRevenue(uint256 queueToStake);
    event StakingQueueExceedsStakableAmount(uint256 queueToStake, uint256 stakableAmount);
    event UnregisteredValidatorRevenue(uint64 epoch, uint256 rewardsSentToValidator, uint256 revenueToShMonad);
    event CrankSkippedOnValidatorIdZero(address coinbase);

    event UnexpectedNoValidators(uint64 epoch, uint256 queueToStakeRolled, uint256 queueForUnstakeRolled);
    event UnexpectedGoodwill(uint64 epoch, uint256 goodwillAmount);
    event UnexpectedSurplusOnUnstakeSettle(uint256 expectedAmount, uint256 actualAmount, uint256 actionIndex);
    event UnexpectedDeficitOnUnstakeSettle(uint256 expectedAmount, uint256 actualAmount, uint256 actionIndex);
    event UnexpectedFailureInitiateStake(
        address coinbase, uint64 valId, uint128 nextTargetStakeAmount, uint128 netAmount
    );
    event UnexpectedFailureInitiateUnstake(
        address coinbase, uint64 valId, uint128 nextTargetStakeAmount, uint128 netAmount
    );
    event UnexpectedValidatorRewardsPayError(
        address coinbase, uint64 valId, uint128 validatorRewardsPayable, uint256 addressThisBalance, uint256 actionIndex
    );
    event UnexpectedYieldSettlementError(
        address coinbase, uint64 valId, uint128 amountRewarded, uint256 addressThisBalance, uint256 actionIndex
    );
    event UnexpectedStakeSettlementError(address coinbase, uint64 valId, uint128 amountReceived, uint256 actionIndex);
    event UnexpectedPendingStakeExceedsExpectedActive(
        uint64 valId, uint64 shMonEpoch, uint256 pendingStake, uint256 expectedTotalStake
    );
    event UnexpectedPendingStakeExpectedIsNotActual(
        uint64 valId, uint64 shMonEpoch, uint256 pendingExpected, uint256 pendingActual
    );
    event UnexpectedActiveStakeExpectedIsNotActual(
        uint64 valId, uint64 shMonEpoch, uint256 activeExpected, uint256 activeActual
    );
    event UnexpectedTotalStakeExpectedIsNotActual(
        uint64 valId,
        uint64 shMonEpoch,
        uint256 totalExpected,
        uint256 totalActual,
        uint256 withdrawalsExpected,
        uint256 withdrawalsActual,
        uint256 depositsExpected,
        uint256 depositsActual
    );
    event UnexpectedStakeWithdrawalsExpectedIsNotActual(
        uint64 valId, uint64 shMonEpoch, uint256 withdrawalsExpected, uint256 withdrawalsActual
    );
    event UnexpectedAtomicSettlementUnavailableAssets(
        uint64 shMonEpoch,
        uint256 netUnavailable,
        uint256 stakeIn,
        uint256 unstakeOut,
        uint256 queueToStake,
        uint256 queueForUnstake,
        uint256 distributedAmount,
        uint256 oldAllocatedAmount,
        uint256 newAllocatedAmount
    );

    // DirectDelegation events
    event Delegate(uint256 indexed validatorId, address indexed account, uint256 assets, uint256 vShares);
    event Undelegate(
        uint256 indexed validatorId, address indexed account, uint256 vShares, uint256 assets, uint256 shares
    );

    event SendValidatorRewards(address sender, uint64 valId, uint256 validatorPayout, uint256 feeTaken);

    // AtomicUnstakePool events
    event PoolTargetLiquidityPercentageSet(uint256 oldPercentage, uint256 newPercentage);
    event PoolLiquidityUpdated(uint256 currentLiquidity, uint256 targetLiquidity);
    event UnstakeFeeEnabledSet(bool enabled);
    event FeeCurveUpdated(
        uint256 oldSlopeRateRay, uint256 oldYInterceptRay, uint256 newSlopeRateRay, uint256 newYInterceptRay
    );

    // ValidatorRegistry events
    event AdminCommissionClaimedAsShares(address indexed recipient, uint256 assets, uint256 shares);

    // Zero-Yield Tranche events
    event DepositToZeroYieldTranche(address indexed sender, address indexed receiver, uint256 assets);
    event ZeroYieldBalanceConvertedToShares(address indexed from, address indexed to, uint256 assets, uint256 shares);
}
