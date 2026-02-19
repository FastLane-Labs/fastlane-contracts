// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { ShMonad } from "../../../src/shmonad/ShMonad.sol";
import {
    PendingBoost,
    Epoch,
    WorkingCapital,
    CurrentLiabilities,
    AtomicCapital,
    StakingEscrow,
    CashFlows,
    Revenue,
    ValidatorData
} from "../../../src/shmonad/Types.sol";
import { UNKNOWN_VAL_ID, UNKNOWN_VAL_ADDRESS, FIRST_VAL_ID, LAST_VAL_ID } from "../../../src/shmonad/Constants.sol";
import { AccountingLib } from "../../../src/shmonad/libraries/AccountingLib.sol";

// TODO this needs a massive refactor:
// - There should be no custom `exposeXYZ` functions - instead we should add those as real view functions to ShMonad
// - Any tests that pass in coinbase address to these expose functions should be changed to pass in valId instead

/// @title TestShMonad
/// @notice A thin test-only wrapper to expose internal AtomicUnstakePool fee math for unit tests.
contract TestShMonad is ShMonad {
    constructor() { }

    function exposeTotalAssets(bool treatAsWithdrawal) external view returns (uint256 assets) {
        assets = _totalEquity({ deductRecentRevenue: treatAsWithdrawal });
    }

    function exposeCurrentAssets() external view returns (uint128 assets) {
        assets = uint128(AccountingLib.currentAssets(s_globalCapital, s_atomicAssets, address(this).balance));
    }

    function exposeAttributedCoinbase(address coinbase) external view returns (address) {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        if (valId == 0) return UNKNOWN_VAL_ADDRESS;
        return s_valCoinbases[valId];
    }

    function exposeGlobalTargetStakeNext() external view returns (uint128 totalAmount, uint128 reservedAmount) {
        (, reservedAmount) = this.getWorkingCapital();
        (,,,,,,,, totalAmount) = this.getGlobalEpoch(0);
    }

    function exposeGlobalAssetsCurrent() external view returns (uint120 debits, uint120 credits) {
        return this.getGlobalCashFlows(0);
    }

    function exposeGlobalAtomicCapital() external view returns (uint128 allocatedAmount, uint128 distributedAmount) {
        return this.getAtomicCapital();
    }

    function exposeGlobalAssetsLast() external view returns (uint120 debits, uint120 credits) {
        return this.getGlobalCashFlows(-1);
    }

    function exposeGlobalRevenueCurrent() external view returns (uint120 rewardsPayable, uint120 earnedRevenue) {
        return this.getGlobalRevenue(0);
    }

    function exposeInternalEpoch() external view returns (uint64) {
        return this.getInternalEpoch();
    }

    function setInternalEpoch(uint64 epoch) external {
        s_admin.internalEpoch = epoch;
    }

    function exposeValidatorRewardsCurrent(address coinbase)
        external
        view
        returns (uint120 rewardsPayable, uint120 earnedRevenue)
    {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        if (valId == 0) valId = UNKNOWN_VAL_ID;
        PendingBoost memory rewards = validatorRewardsPtr_N(0, valId);
        rewardsPayable = rewards.rewardsPayable;
        earnedRevenue = rewards.earnedRevenue;
        // if (rewardsPayable > 0) --rewardsPayable;
    }

    function exposeValidatorRewardsLast(address coinbase)
        external
        view
        returns (uint120 rewardsPayable, uint120 earnedRevenue)
    {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        if (valId == 0) valId = UNKNOWN_VAL_ID;
        PendingBoost memory rewards = validatorRewardsPtr_N(-1, valId);
        rewardsPayable = rewards.rewardsPayable;
        earnedRevenue = rewards.earnedRevenue;
        // if (!validatorEpochPtr_N(0, coinbase).wasCranked) --rewardsPayable;
    }

    function exposeValidatorRewardsNext(address coinbase)
        external
        view
        returns (uint120 rewardsPayable, uint120 earnedRevenue)
    {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        if (valId == 0) valId = UNKNOWN_VAL_ID;
        PendingBoost memory rewards = validatorRewardsPtr_N(1, valId);
        rewardsPayable = rewards.rewardsPayable;
        earnedRevenue = rewards.earnedRevenue;
        // if (validatorEpochPtr_N(0, coinbase).wasCranked) --rewardsPayable;
    }

    function exposeValidatorEpochLast(address coinbase) external view returns (Epoch memory epochData) {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        if (valId == 0) valId = UNKNOWN_VAL_ID;
        epochData = validatorEpochPtr_N(-1, valId);
    }

    function exposeValidatorEpochLastLast(address coinbase) external view returns (Epoch memory epochData) {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        if (valId == 0) valId = UNKNOWN_VAL_ID;
        epochData = validatorEpochPtr_N(-2, valId);
    }

    function exposeValidatorEpochCurrent(address coinbase) external view returns (Epoch memory epochData) {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        epochData = validatorEpochPtr_N(0, valId);
    }

    function exposeValidatorEpochLastLastLast(address coinbase) external view returns (Epoch memory epochData) {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        epochData = validatorEpochPtr_N(-3, valId);
    }

    function exposeValidatorPending(
        address coinbase,
        int8 offset
    )
        external
        view
        returns (uint120 pendingStaking, uint120 pendingUnstaking)
    {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        StakingEscrow storage escrow = validatorPendingPtr_N(offset, valId);
        pendingStaking = escrow.pendingStaking;
        pendingUnstaking = escrow.pendingUnstaking;
    }

    function harnessRollValidatorEpochForwards(address coinbase, uint128 newTargetStakeAmount) external {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        _rollValidatorEpochForwards(valId, newTargetStakeAmount);
    }

    function harnessSettlePastEpochEdges(address coinbase) external {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        ValidatorData memory data = _getValidatorData(valId);
        _settlePastEpochEdges(data.id);
    }

    function harnessSettleCoinbaseContract(uint64 valId, address coinbase) external {
        _settleCoinbaseContract(valId, coinbase);
    }

    function harnessMarkPendingWithdrawal(address coinbase, uint120 amount) external {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        Epoch storage epoch = validatorEpochPtr_N(0, valId);
        epoch.hasWithdrawal = true;
        epoch.hasDeposit = false;
        epoch.crankedInBoundaryPeriod = false;
        // epoch.targetStakeAmount -= uint128(amount); // TODO: <-- Fix tests that underflow on this line
        validatorPendingPtr_N(0, valId).pendingUnstaking += amount;
        s_globalPending.pendingUnstaking += amount;
    }

    function harnessMarkPendingDeposit(address coinbase, uint120 amount, bool crankedInBoundaryPeriod) external {
        uint64 valId = _validatorIdForCoinbase(coinbase);
        Epoch storage epoch = validatorEpochPtr_N(0, valId);
        epoch.hasDeposit = true;
        epoch.hasWithdrawal = false;
        epoch.crankedInBoundaryPeriod = crankedInBoundaryPeriod;
        epoch.targetStakeAmount += uint128(amount);
        validatorPendingPtr_N(0, valId).pendingStaking += amount;
        s_globalPending.pendingStaking += amount;
        s_globalCapital.stakedAmount += amount;
    }

    function harnessSetGlobalStakedAmount(uint128 amount) external {
        s_globalCapital.stakedAmount = amount;
    }

    function harnessSetAtomicCapital(uint128 allocatedAmount, uint128 distributedAmount) external {
        s_atomicAssets.allocatedAmount = allocatedAmount;
        s_atomicAssets.distributedAmount = distributedAmount;
    }

    function harnessSetGlobalRevenue(uint120 allocatedRevenue, uint120 earnedRevenue) external {
        Revenue storage revenue = globalRevenuePtr_N(0);
        revenue.allocatedRevenue = allocatedRevenue;
        revenue.earnedRevenue = earnedRevenue;
        revenue.alwaysTrue = true;
    }

    function harnessSetGlobalCashFlows(uint120 queueToStake, uint120 queueForUnstake) external {
        CashFlows storage cashFlows = globalCashFlowsPtr_N(0);
        cashFlows.queueToStake = queueToStake;
        cashFlows.queueForUnstake = queueForUnstake;
        cashFlows.alwaysTrue = true;
    }

    function harnessCarryOverAtomicUnstakeIntoQueue() external {
        _carryOverAtomicUnstakeIntoQueue();
    }

    // Force the internal crank cursor to the FIRST_VAL_ID sentinel so that
    // getNextValidatorToCrank() returns the first real validator's coinbase.
    function harnessSetNextValidatorCursorToFirst() external {
        s_nextValidatorToCrank = FIRST_VAL_ID;
    }

    // Force the internal crank cursor to the UNKNOWN_VAL_ID placeholder.
    // Used to verify that the next-to-crank view properly skips the placeholder.
    function harnessSetNextValidatorCursorToUnknown() external {
        s_nextValidatorToCrank = UNKNOWN_VAL_ID;
    }

    // Force `s_nextValidatorToCrank` to `LAST_VAL_ID` and run a global crank only (no validator loop).
    // Intended for fork-mode tests that need deterministic global-epoch effects without paying O(n_validators) runtime.
    function harnessCrankGlobalOnly() external returns (bool complete) {
        s_nextValidatorToCrank = LAST_VAL_ID;
        complete = _crankGlobal();
    }

    function harnessCrankValidator(uint64 valId) external {
        _crankValidator(valId);
    }

    function harnessSeedGlobalPendingLast() external {
        StakingEscrow memory pending = s_globalPending;
        pending.alwaysTrue = true;
        s_globalPendingLast = pending;
        s_globalCapitalLast = s_globalCapital;
    }

    // Expose linked list internals for testing sentinel/placeholder placement.
    function exposeFirstAfterSentinel() external view returns (uint64) {
        return s_valLinkNext[FIRST_VAL_ID];
    }

    function exposePrevOfLast() external view returns (uint64) {
        return s_valLinkPrevious[LAST_VAL_ID];
    }

    function exposeNextId(uint64 id) external view returns (uint64) {
        return s_valLinkNext[id];
    }

    function exposePrevId(uint64 id) external view returns (uint64) {
        return s_valLinkPrevious[id];
    }

    function exposeGlobalPendingLastRaw()
        external
        view
        returns (uint120 pendingStaking, uint120 pendingUnstaking, bool alwaysTrue)
    {
        StakingEscrow memory escrow = s_globalPendingLast;
        return (escrow.pendingStaking, escrow.pendingUnstaking, escrow.alwaysTrue);
    }

    function harnessClearGlobalPendingLast() external {
        delete s_globalPendingLast;
    }

    function getGrossAndFeeFromNetAssets(uint256 netAssets)
        external
        view
        returns (uint256 grossAssets, uint256 feeAssets)
    {
        return _getGrossAndFeeFromNetAssets(netAssets);
    }

    function quoteFeeFromGrossAssetsNoLiquidityLimit(uint256 grossRequested)
        external
        view
        returns (uint256 feeAssets)
    {
        feeAssets = _quoteFeeFromGrossAssetsNoLiquidityLimit(grossRequested);
    }

    function exposePendingTargetAtomicLiquidityPercent() external view returns (uint256) {
        return s_pendingTargetAtomicLiquidityPercent;
    }

    // Fees are always on; to disable fees in tests, call setUnstakeFeeCurve(0, 0)
    function scaledTargetLiquidityPercentage() external view returns (uint256) {
        return _scaledTargetLiquidityPercentage();
    }

    function exposeGlobalCapitalRaw() external view returns (uint128 stakedAmount, uint128 reservedAmount) {
        return this.getWorkingCapital();
    }

    function exposeGlobalPendingRaw() external view returns (uint128 pendingStaking, uint128 pendingUnstaking) {
        return this.getGlobalPending();
    }

    function exposeNextValidatorToCrank() external view returns (address) {
        return this.getNextValidatorToCrank();
    }

    function harnessMarkValidatorNotInActiveSet(uint64 valId, uint256 detectionIndex) external {
        _markValidatorNotInActiveSet(valId, detectionIndex);
    }
}
