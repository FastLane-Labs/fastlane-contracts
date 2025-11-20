//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

// 3 types of mutually exclusive shMON balances:
// - Uncommitted: shMON that can be transferred freely.
// - Committed: shMON that is committed to a Policy and has not yet started uncommitting.
// - Uncommitting: shMON that is in the process of uncommitting from a Policy.

// NOTE: we do not track an account's total uncommitting balance.
// Would need to add array of policies active per account to calc total uncommitting balance.
struct Balance {
    uint128 uncommitted; // Account's uncommitted shMON balance
    uint128 committed; // Account's committed shMON balance across all policies
}

struct Supply {
    uint128 total;
    uint128 committedTotal;
}

struct CommittedData {
    uint128 committed; // Account's committed amount in the current Policy (excl. uncommitting)
    uint128 minCommitted; // Account's minimum committed amount in the current Policy
}

struct UncommittingData {
    uint128 uncommitting; // Account's uncommitting amount in the current Policy
    uint48 uncommitStartBlock; // Block at which account last started uncommitting
    uint80 placeholder; // Placeholder for future use
}

struct TopUpData {
    uint128 totalPeriodTopUps; // Sum of all top-ups in the current top-up period
    uint48 topUpPeriodStartBlock; // block.number of start of last top-up period
    uint80 placeholder; // Placeholder for future use
}

struct TopUpSettings {
    uint128 maxTopUpPerPeriod; // Max uncommitted shMON allowed per top-up of committed
    uint32 topUpPeriodDuration; // Duration of the top-up period, in blocks
    uint96 placeholder; // Placeholder for future use
}

struct Policy {
    uint48 escrowDuration; // Uncommitting period of the Policy
    bool active; // Whether the Policy is active or not
    address primaryAgent; // Most frequently-calling agent (for gas efficiency)
}

// For HoldsLib - never used in storage
struct PolicyAccount {
    uint64 policyID;
    address account;
}

struct UncommitApproval {
    address completor; // Account allowed to `completeUncommit()` on user's behalf
    uint96 shares; // Max shares where uncommit can be completed on user's behalf
}

enum Delivery {
    Committed,
    Uncommitted,
    Underlying
}

// ================================================== //
//                 CapitalAllocator Types             //
// ================================================== //

// Lightweight view snapshot assembled from validator epoch/reward trackers.
struct ValidatorStats {
    bool isActive;
    address coinbase;
    uint64 lastEpoch;
    uint128 targetStakeAmount;
    uint128 rewardsPayableLast;
    uint128 earnedRevenueLast;
    uint128 rewardsPayableCurrent;
    uint128 earnedRevenueCurrent;
}

// UnstakeRequest at the User <> ShMonad level
struct UserUnstakeRequest {
    uint128 amountMon; // Amount in MON being unstaked
    uint64 completionEpoch; // Epoch when the unstake request is able to be completed
}

// ================================================== //
//                 StakeTracker Types                 //
// ================================================== //

struct Epoch {
    uint64 epoch;
    uint8 withdrawalId;
    bool hasWithdrawal;
    bool hasDeposit;
    bool crankedInBoundaryPeriod;
    bool wasCranked; // refers to the placeholder validator if global, or the validator if specific
    bool frozen;
    bool closed;
    uint128 targetStakeAmount;
}

struct RevenueSmoother {
    uint120 earnedRevenueLast;
    uint64 epochChangeBlockNumber;
}

struct ValidatorDataStorage {
    uint64 epoch;
    uint64 id;
    bool isActive;
    bool inActiveSet_Current;
    bool inActiveSet_Last;
}

struct ValidatorData {
    uint64 epoch;
    uint64 id;
    bool isPlaceholder;
    bool isActive;
    bool inActiveSet_Current;
    bool inActiveSet_Last;
    address coinbase;
}

struct AdminValues {
    uint64 internalEpoch;
    uint16 targetLiquidityPercentage;
    uint16 incentiveAlignmentPercentage;
    uint16 stakingCommission;
    uint16 boostCommissionRate; // measured in basis points
    uint128 totalZeroYieldPayable; // liability, total zero-yield tranche funds, incl owner commission
}

struct FeeParams {
    uint128 mRay; // slope rate (RAY)
    uint128 cRay; // y-intercept/base fee rate (RAY)
}

struct CashFlows {
    uint120 queueToStake; // MON units,
    uint120 queueForUnstake; // MON units
    bool alwaysTrue; // Avoids storing a zero slot to save gas on future writes
}

struct AtomicCapital {
    uint128 allocatedAmount;
    uint128 distributedAmount;
}

struct StakingEscrow {
    uint120 pendingStaking; // MON units
    uint120 pendingUnstaking; // MON units
    bool alwaysTrue; // Avoids storing a zero slot to save gas on future writes
}

struct Revenue {
    uint120 allocatedRevenue; // MON units used to offset the atomic unstaking pool
    uint120 earnedRevenue; // MON units retained by protocol
    bool alwaysTrue; // Avoids storing a zero slot to save gas on future writes
}

struct PendingBoost {
    uint120 rewardsPayable; // MON units earmarked for validator payouts
    uint120 earnedRevenue; // MON units retained by protocol
    bool alwaysTrue; // Avoids storing a zero slot to save gas on future writes
}

struct WorkingCapital {
    uint128 stakedAmount;
    uint128 reservedAmount; // portion reserved for validator payments or withdrawals
}

struct CurrentLiabilities {
    uint128 rewardsPayable; // to validators
    uint128 redemptionsPayable; // illiquid
}

enum CashFlowType {
    Goodwill, // The null value
    Deposit,
    Revenue,
    AllocationReduction
}
