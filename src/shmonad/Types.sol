//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// 3 types of mutually exclusive shMON balances:
// - Unbonded: shMON that can be transferred freely.
// - Bonded: shMON that is bonded in a Policy and has not yet start unbonding.
// - Unbonding: shMON that is in the process of unbonding from a Policy.

// NOTE: we do not track an account's total unbonding balance.
// Would need to add array of policies active per account to calc total unbonding balance.
struct Balance {
    uint128 unbonded; // Account's unbonded shMON balance
    uint128 bonded; // Account's bonded shMON balance across all policies
}

struct BondedData {
    uint128 bonded; // Account's bonded amount in the current Policy (excl. unbonding)
    uint128 minBonded; // Account's minimum bonded amount in the current Policy
}

struct UnbondingData {
    uint128 unbonding; // Account's unbonding amount in the current Policy
    uint48 unbondStartBlock; // Block at which account last started unbonding
    uint80 placeholder; // Placeholder for future use
}

struct TopUpData {
    uint128 totalPeriodTopUps; // Sum of all top-ups in the current top-up period
    uint48 topUpPeriodStartBlock; // block.number of start of last top-up period
    uint80 placeholder; // Placeholder for future use
}

struct TopUpSettings {
    uint128 maxTopUpPerPeriod; // Max unbonded shMON allowed per top-up of bonded
    uint32 topUpPeriodDuration; // Duration of the top-up period, in blocks
    uint96 placeholder; // Placeholder for future use
}

struct Policy {
    uint48 escrowDuration; // Unbonding period of the Policy
    bool active; // Whether the Policy is active or not
}

// For HoldsLib - never used in storage
struct PolicyAccount {
    uint64 policyID;
    address account;
}
