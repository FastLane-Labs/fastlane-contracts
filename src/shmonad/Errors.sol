//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

abstract contract ShMonadErrors {
    // Holds
    error NotPolicyAgent(uint64 policyID, address caller);
    error BatchHoldAccountAmountLengthMismatch(uint256 accountsLength, uint256 amountsLength);
    error BatchReleaseAccountAmountLengthMismatch(uint256 accountsLength, uint256 amountsLength);
    // CapitalAllocator
    error ZeroAddress();

    // ValidatorRegistry
    error ValidatorAlreadyAdded();
    error ValidatorAlreadyDeactivated();
    error ValidatorDeactivationNotQueued();
    error ValidatorDeactivationQueuedIncomplete();
    error ValidatorNotFullyRemoved();
    error InvalidValidatorId(uint256 validatorId);
    error InvalidValidatorAddress(address coinbase);
    error ValidatorNotFoundInPrecompile(uint64 validatorId);
    error InsufficientAccumulatedCommission(uint256 requested, uint256 available);

    error CannotUnstakeZeroShares();
    error InsufficientBalanceForUnstake();
    error NoUnstakeRequestFound();
    error CompletionEpochNotReached(uint256 currentEpoch, uint256 completionEpoch);
    error InsufficientBalanceAtomicUnstakingPool(uint256 requestedAmount, uint256 availableAmount);
    error InsufficientReservedLiquidity(uint256 requestedAmount, uint256 availableReserved);

    // ValidatorRegistry
    error CommissionMustBeBelow100Percent();
    error PercentageMustBeBelow100Percent();
    error Create2Failed();

    // Policies
    error CommitRecipientCannotBeZeroAddress();
    error InsufficientUncommittedBalance(uint256 available, uint256 requested);
    error InsufficientUnheldCommittedBalance(uint128 committed, uint128 held, uint128 requested);
    error InsufficientFunds(uint128 committed, uint128 uncommitting, uint128 held, uint128 requested);
    error InsufficientUncommittingBalance(uint256 available, uint256 requested);
    error UncommittingPeriodIncomplete(uint256 uncommittingCompleteBlock);
    error PolicyInactive(uint64 policyID);
    error PolicyAgentAlreadyExists(uint64 policyID, address agent);
    error PolicyAgentNotFound(uint64 policyID, address agent);
    error PolicyNeedsAtLeastOneAgent(uint64 policyID);
    error TopUpPeriodDurationTooShort(uint32 requestedPeriodDuration, uint32 minPeriodDuration);
    error AgentInstantUncommittingDisallowed(uint64 policyID, address agent);
    error InvalidUncommitCompletor();
    error InsufficientUncommitApproval(uint256 approved, uint256 requested);

    // Zero-Yield Tranche
    error InsufficientZeroYieldBalance(uint256 available, uint256 requested);

    // ERC4626
    error IncorrectNativeTokenAmountSent();
    error InvalidFeeRate(uint256 feeRate);

    // Safety
    error NotWhenFrozen();
    error NotWhenClosed();

    // Initialization
    error UnauthorizedInitializer();

    // AtomicUnstakePool
    error InsufficientPoolLiquidity(uint256 requested, uint256 available);
    error TargetLiquidityCannotExceed100Percent();
    error YInterceptExceedsRay();
    error SlopeRateExceedsRay();
    error FeeCurveFullUtilizationExceedsRay();

    // StakeTracker
    error WillOverflowOnBitshift();
    error ValidatorAvailableExceedsTargetStake(uint256 availableMON, uint256 targetStakeMON);

    // Legacy Migration errors
    error LegacyStakeDetected();
    error LegacyLiabilitiesDetected();
    error LegacyAtomicStateDetected();
    error LegacyDelegationsDetected();
    error LegacyDelegationsPaginationIncomplete();
}
