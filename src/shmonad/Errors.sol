//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

abstract contract ShMonadErrors {
    // --------------------------------------------- //
    //                    Holds                      //
    // --------------------------------------------- //
    /// @custom:selector 0xc9343b0a
    error NotPolicyAgent(uint64 policyID, address caller);
    /// @custom:selector 0xab2552b3
    error BatchHoldAccountAmountLengthMismatch(uint256 accountsLength, uint256 amountsLength);
    /// @custom:selector 0xac662d02
    error BatchReleaseAccountAmountLengthMismatch(uint256 accountsLength, uint256 amountsLength);
    // --------------------------------------------- //
    //              CapitalAllocator                 //
    // --------------------------------------------- //
    /// @custom:selector 0xd92e233d
    error ZeroAddress();

    // --------------------------------------------- //
    //              ValidatorRegistry                //
    // --------------------------------------------- //
    /// @custom:selector 0x0d57d92a
    error ValidatorAlreadyAdded();
    /// @custom:selector 0xfb1ba7c3
    error ValidatorAlreadyDeactivated();
    /// @custom:selector 0x786b3365
    error ValidatorDeactivationNotQueued();
    /// @custom:selector 0xf80f20c7
    error ValidatorDeactivationQueuedIncomplete();
    /// @custom:selector 0x06ba017e
    error ValidatorNotFullyRemoved();
    /// @custom:selector 0x1765091c
    error InvalidValidatorId(uint256 validatorId);
    /// @custom:selector 0x59bff387
    error InvalidValidatorAddress(address coinbase);
    /// @custom:selector 0x19708e71
    error ValidatorNotFoundInPrecompile(uint64 validatorId);
    /// @custom:selector 0xb4a306e6
    error InsufficientAccumulatedCommission(uint256 requested, uint256 available);
    /// @custom:selector 0xb4f3aa46
    error CoinbaseAlreadyDeployed(uint64 valId, address coinbase);
    /// @custom:selector 0x965a2780
    error CustomCoinbaseCantBeContract(uint64 valId);
    /// @custom:selector 0x70457d1c
    error OnlyCoinbaseAuth(uint64 valId, address caller);
    /// @custom:selector 0x7989413f
    error CannotUnstakeZeroShares();
    /// @custom:selector 0x330438b0
    error InsufficientBalanceForUnstake();
    /// @custom:selector 0x6a2c35e9
    error NoUnstakeRequestFound();
    /// @custom:selector 0xafc64529
    error CompletionEpochNotReached(uint256 currentEpoch, uint256 completionEpoch);
    /// @custom:selector 0x42f215e3
    error InsufficientBalanceAtomicUnstakingPool(uint256 requestedAmount, uint256 availableAmount);
    /// @custom:selector 0x3ab84a3e
    error InsufficientReservedLiquidity(uint256 requestedAmount, uint256 availableReserved);

    // --------------------------------------------- //
    //              ValidatorRegistry                //
    // --------------------------------------------- //
    /// @custom:selector 0x4da923a0
    error CommissionMustBeBelow100Percent();
    /// @custom:selector 0xb9b751ff
    error PercentageMustBeBelow100Percent();
    /// @custom:selector 0x04a5b3ee
    error Create2Failed();

    // --------------------------------------------- //
    //                   Policies                    //
    // --------------------------------------------- //
    /// @custom:selector 0x3662e88a
    error CommitRecipientCannotBeZeroAddress();
    /// @custom:selector 0xcfe63420
    error InsufficientUncommittedBalance(uint256 available, uint256 requested);
    /// @custom:selector 0xd081d21e
    error InsufficientUnheldCommittedBalance(uint128 committed, uint128 held, uint128 requested);
    /// @custom:selector 0x094c274a
    error InsufficientFunds(uint128 committed, uint128 uncommitting, uint128 held, uint128 requested);
    /// @custom:selector 0xe6cb18de
    error InsufficientUncommittingBalance(uint256 available, uint256 requested);
    /// @custom:selector 0xd6e4cc0a
    error UncommittingPeriodIncomplete(uint256 uncommittingCompleteBlock);
    /// @custom:selector 0x472dabaf
    error PolicyInactive(uint64 policyID);
    /// @custom:selector 0x4cf17f50
    error PolicyAgentAlreadyExists(uint64 policyID, address agent);
    /// @custom:selector 0x39a907cb
    error PolicyAgentNotFound(uint64 policyID, address agent);
    /// @custom:selector 0xadfe21f6
    error PolicyNeedsAtLeastOneAgent(uint64 policyID);
    /// @custom:selector 0xcfcc3159
    error TopUpPeriodDurationTooShort(uint32 requestedPeriodDuration, uint32 minPeriodDuration);
    /// @custom:selector 0x44fefb81
    error AgentInstantUncommittingDisallowed(uint64 policyID, address agent);
    /// @custom:selector 0x184a7846
    error InvalidUncommitCompletor();
    /// @custom:selector 0xa8571a6c
    error InsufficientUncommitApproval(uint256 approved, uint256 requested);

    // --------------------------------------------- //
    //             Zero-Yield Tranche                //
    // --------------------------------------------- //
    /// @custom:selector 0x8b8c8548
    error InsufficientZeroYieldBalance(uint256 available, uint256 requested);

    // --------------------------------------------- //
    //                   ERC4626                     //
    // --------------------------------------------- //
    /// @custom:selector 0x309a6b54
    error IncorrectNativeTokenAmountSent();
    /// @custom:selector 0xdb9a092c
    error InvalidFeeRate(uint256 feeRate);

    // --------------------------------------------- //
    //                    Safety                     //
    // --------------------------------------------- //
    /// @custom:selector 0x92dcd254
    error NotWhenFrozen();
    /// @custom:selector 0x23328246
    error NotWhenClosed();

    // --------------------------------------------- //
    //                Initialization                 //
    // --------------------------------------------- //
    /// @custom:selector 0x0d622feb
    error UnauthorizedInitializer();

    // --------------------------------------------- //
    //              AtomicUnstakePool                //
    // --------------------------------------------- //
    /// @custom:selector 0x7d61b360
    error InsufficientPoolLiquidity(uint256 requested, uint256 available);
    /// @custom:selector 0xf22893a6
    error TargetLiquidityCannotExceed100Percent();
    /// @custom:selector 0x44ba8133
    error YInterceptExceedsRay();
    /// @custom:selector 0xb3cf4ada
    error SlopeRateExceedsRay();
    /// @custom:selector 0xd3fe07e7
    error FeeCurveFullUtilizationExceedsRay();

    // --------------------------------------------- //
    //                 StakeTracker                  //
    // --------------------------------------------- //
    /// @custom:selector 0xdaccb93d
    error WillOverflowOnBitshift();
    /// @custom:selector 0x4cce29f0
    error ValidatorAvailableExceedsTargetStake(uint256 availableMON, uint256 targetStakeMON);

    // --------------------------------------------- //
    //           Legacy Migration errors             //
    // --------------------------------------------- //
    /// @custom:selector 0x2235bb35
    error LegacyStakeDetected();
    /// @custom:selector 0xed9fd637
    error LegacyLiabilitiesDetected();
    /// @custom:selector 0xc960fad8
    error LegacyAtomicStateDetected();
    /// @custom:selector 0xcb84d37a
    error LegacyDelegationsDetected();
    /// @custom:selector 0x8ed2a98e
    error LegacyDelegationsPaginationIncomplete();
}
