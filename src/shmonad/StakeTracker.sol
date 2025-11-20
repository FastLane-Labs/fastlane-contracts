//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

import { ValidatorRegistry } from "./ValidatorRegistry.sol";
import {
    Epoch,
    PendingBoost,
    CashFlows,
    StakingEscrow,
    AtomicCapital,
    ValidatorData,
    WorkingCapital,
    CashFlowType,
    CurrentLiabilities,
    RevenueSmoother,
    Revenue
} from "./Types.sol";
import { StakeAllocationLib } from "./libraries/StakeAllocationLib.sol";
import { StorageLib } from "./libraries/StorageLib.sol";
import { IMonadStaking } from "./interfaces/IMonadStaking.sol";
import { ICoinbase } from "./interfaces/ICoinbase.sol";
import {
    MIN_VALIDATOR_DEPOSIT,
    SCALE,
    TARGET_FLOAT,
    STAKING,
    SHMONAD_VALIDATOR_DEACTIVATION_PERIOD,
    FLOAT_PLACEHOLDER,
    FLOAT_REBALANCE_SENSITIVITY,
    BPS_SCALE,
    EPOCHS_TRACKED,
    UINT120_MASK,
    DUST_THRESHOLD,
    UNKNOWN_VAL_ID,
    UNKNOWN_VAL_ADDRESS,
    LAST_VAL_ID,
    FIRST_VAL_ID,
    SLASHING_FREEZE_THRESHOLD,
    OWNER_COMMISSION_ACCOUNT,
    COINBASE_PROCESS_GAS_LIMIT
} from "./Constants.sol";

import { AccountingLib } from "./libraries/AccountingLib.sol";

/// @notice Consolidated StakeTracker using Monad precompile epochs and a single crank() entrypoint.
/// @dev Removes legacy startNextEpoch()/queue/bitmap flows; relies on _crankGlobal + _crankActiveValidators.
abstract contract StakeTracker is ValidatorRegistry {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using SafeCastLib for uint128;
    using Math for uint256;
    using AccountingLib for WorkingCapital;
    using AccountingLib for AtomicCapital;
    using AccountingLib for CurrentLiabilities;
    using StorageLib for CashFlows;
    using StorageLib for StakingEscrow;
    using StorageLib for PendingBoost;
    using StorageLib for Revenue;

    // ================================================== //
    //                        Init                        //
    // ================================================== //

    /// @notice Initializes the StakeTracker contract with initial state and validator setup
    /// @dev Sets up the initial epoch structure, registers placeholder validators, and initializes global state
    function __StakeTracker_init() internal {
        if (globalEpochPtr_N(0).epoch != 0) return;

        if (s_admin.internalEpoch == 0) {
            // Register the "unregistered" validator placeholder
            s_valLinkNext[FIRST_VAL_ID] = LAST_VAL_ID;
            s_valLinkPrevious[LAST_VAL_ID] = FIRST_VAL_ID;
            _addValidator(UNKNOWN_VAL_ID, UNKNOWN_VAL_ADDRESS);
            s_nextValidatorToCrank = UNKNOWN_VAL_ID;

            // Do not count the placeholder validator as an active validator
            // for purposes of rolling stake / unstake queue forward
            --s_activeValidatorCount;

            s_validatorData[UNKNOWN_VAL_ID].inActiveSet_Last = true;
            s_validatorData[UNKNOWN_VAL_ID].inActiveSet_Current = true;

            // we initialize the epoch to 10 to avoid the first epoch being 0, which is not valid.
            // internal, the epoch is independent of the monad epoch.
            uint64 _currentEpoch = 10;

            // Start s_admin off as the current monad epoch
            // NOTE: They will diverge over time.
            s_admin.internalEpoch = _currentEpoch;

            globalEpochPtr_N(-2).epoch = _currentEpoch < 3 ? 0 : _currentEpoch - 3;
            globalEpochPtr_N(-2).epoch = _currentEpoch < 2 ? 0 : _currentEpoch - 2;
            globalEpochPtr_N(-1).epoch = _currentEpoch < 1 ? 0 : _currentEpoch - 1;
            globalEpochPtr_N(0).epoch = _currentEpoch;
            globalEpochPtr_N(1).epoch = _currentEpoch + 1;
            globalEpochPtr_N(2).epoch = _currentEpoch + 2;

            s_pendingTargetAtomicLiquidityPercent = TARGET_FLOAT;

            for (int256 i; i < int256(EPOCHS_TRACKED); i++) {
                globalRevenuePtr_N(i).alwaysTrue = true;
                globalCashFlowsPtr_N(i).alwaysTrue = true;
            }

            uint256 _goodwill = s_globalCapital.goodwill(s_atomicAssets, globalCashFlowsPtr_N(0), address(this).balance);

            // this is a hack to get the legacy balance into the system. We should remove this migration after the
            // initial testnet upgrade.
            if (_goodwill > 0) {
                (bool _delegationsDone,, uint64[] memory _delegatedValidators) =
                    STAKING.getDelegations(address(this), 0);
                if (!_delegationsDone) revert LegacyDelegationsPaginationIncomplete();
                if (_delegatedValidators.length != 0) revert LegacyDelegationsDetected();

                if (s_globalCapital.stakedAmount != 0 || s_globalCapital.reservedAmount != 0) {
                    revert LegacyStakeDetected();
                }
                if (
                    s_globalLiabilities.rewardsPayable != 0 || s_globalLiabilities.redemptionsPayable != 0
                        || s_admin.totalZeroYieldPayable != 0
                ) {
                    revert LegacyLiabilitiesDetected();
                }
                if (s_atomicAssets.allocatedAmount != 0 || s_atomicAssets.distributedAmount != 0) {
                    revert LegacyAtomicStateDetected();
                }
                globalCashFlowsPtr_N(0).queueToStake += _goodwill.toUint120();
            }

            _crankGlobal();
            _crankValidators();
        }
    }

    // ================================================== //
    //                `receive()` Function                //
    // ================================================== //

    /// @notice Handles incoming ETH payments and classifies them for proper accounting
    /// @dev Processes received ETH and updates transient capital tracking for staking operations
    receive() external payable {
        (CashFlowType flowType, uint256 existingAmountIn, uint256 lastKnownBalance) = _getTransientCapital();

        // Goodwill is the null type of CashFlowType
        if (flowType == CashFlowType.Goodwill) {
            // NOTE: must clear if contract does any payments in between receives.
            if (address(this).balance >= lastKnownBalance + msg.value) {
                globalCashFlowsPtr_N(0).queueToStake += msg.value.toUint120();
            }
        }
        _setTransientCapital(flowType, existingAmountIn + msg.value);
    }

    // t_cashFlowClassifier pack layout (uint256):
    // [255..128] lastKnownBalance
    // [127..8]   existingAmountIn (uint120)
    // [7..0]     flowType (CashFlowType as uint8)
    /// @notice Retrieves current transient capital state for cash flow classification
    /// @return flowType The type of cash flow currently being processed
    /// @return existingAmountIn The amount already processed in the current flow
    /// @return lastKnownBalance The last recorded contract balance
    function _getTransientCapital()
        internal
        view
        returns (CashFlowType flowType, uint256 existingAmountIn, uint256 lastKnownBalance)
    {
        uint256 _checkValue = t_cashFlowClassifier;
        flowType = CashFlowType(uint8(_checkValue));
        existingAmountIn = (_checkValue >> 8) & UINT120_MASK;
        lastKnownBalance = _checkValue >> 128;
    }

    /// @notice Updates transient capital state with new flow type and amount
    /// @param flowType The type of cash flow being processed
    /// @param existingAmount The amount to set for the current flow
    function _setTransientCapital(CashFlowType flowType, uint256 existingAmount) internal {
        require(existingAmount <= type(uint120).max, WillOverflowOnBitshift());
        uint256 _setValue = (address(this).balance << 128) | existingAmount << 8 | uint256(uint8(flowType));
        t_cashFlowClassifier = _setValue;
    }

    /// @notice Clears transient capital state and resets cash flow classification
    /// @dev This also deletes the last known balance - watch out!
    function _clearTransientCapital() internal {
        t_cashFlowClassifier = 0;
    }

    // ================================================== //
    //                 Crank Entry Point                  //
    // ================================================== //

    /// @notice Single public entrypoint to advance global + per-validator state
    /// Can be called by anyone, timing does not affect the outcome.
    /// @dev Processes global epoch advancement and validator state updates
    /// @return complete True if all cranking operations completed successfully
    function crank() public notWhenFrozen returns (bool complete) {
        complete = _crankGlobal();
        if (!complete) {
            complete = _crankValidators();
        }
    }

    /// @notice Processes validator state updates for all validators
    /// @dev Iterates through validators and updates their state within gas limits
    /// @return allValidatorsCranked True if all validators were processed successfully
    function _crankValidators() internal returns (bool allValidatorsCranked) {
        uint64 _nextValidatorToCrank = s_nextValidatorToCrank;

        // TODO: calculate the actual gas needed per validator crank
        while (gasleft() > 1_000_000) {
            if (_nextValidatorToCrank == LAST_VAL_ID) break;
            t_validatorActiveSetCheckValId = 0;
            _crankValidator(_nextValidatorToCrank);
            t_validatorActiveSetCheckValId = 0;
            _nextValidatorToCrank = s_valLinkNext[_nextValidatorToCrank];
        }

        s_nextValidatorToCrank = _nextValidatorToCrank;
        return _nextValidatorToCrank == LAST_VAL_ID;
    }

    // ================================================== //
    //        Core Crank Functions & Accounting           //
    // ================================================== //

    /// @notice Advances global epoch state and updates global accounting in one pass.
    /// @dev Steps (ordering matters):
    ///  1) Prime next epoch storage (carry flags, compute target stake)
    ///  2) Offset uncovered liabilities using deposits (queueToStake vs queueForUnstake vs currentAssets)
    ///  3) Reconcile atomic pool accounting without changing utilization jumps
    ///  4) Carry over atomic-unstake into the global unstake queue
    ///  5) Apply goodwill (unexpected donations) into stake queue
    ///  6) Clamp queues to stakable/unstakable capacity (or roll excess forward)
    ///  7) Update revenue smoother and bump internal epoch
    ///  8) Reset validator cursor to start of linked list
    /// Returns false early if monad epoch did not advance or validators are still pending from prior round.
    /// @return complete True if global crank completed (epoch advanced and validators ready to crank)
    function _crankGlobal() internal returns (bool complete) {
        uint64 _monadEpoch = _getEpoch();

        // All validators must have finished cranking in the previous round
        if (s_nextValidatorToCrank != LAST_VAL_ID) return false;

        // Monad epoch must have increased
        if (globalEpochPtr_N(0).epoch >= _monadEpoch) return true;

        // Load the just-ended epoch's data into memory to help with rolling the epoch forwards
        Epoch memory _epochThatJustEnded = globalEpochPtr_N(0);

        _primeNextGlobalEpoch(_epochThatJustEnded);

        // Prepare the upcoming epoch's data by zeroing out any previous values and setting any carryovers.
        globalRevenuePtr_N(2).clear();
        globalCashFlowsPtr_N(2).clear();

        // Handle any net staking allocations to the reserved MON amount
        _offsetLiabilitiesWithDeposits();

        // Adjust for any goodwill (unexpected donations)
        _applyGoodwillToStakeQueue();

        // Update (if applicable) and adjust the global net cash flow (MON) for flows to the atomic unstaking pool,
        // while being sure to keep the utilization rate unchanged.
        _settleGlobalNetMONAgainstAtomicUnstaking();

        // Calculate and carry forward the unstaking aount from the atomic unstaking pool
        _carryOverAtomicUnstakeIntoQueue();

        // Net excess queue capacity, roll unassignable stake, and then roll any unnetted surpluses to the next epoch
        _offsetExcessQueueCapacityWithNet();
        _rollUnassignableStakingQueue();
        _clampQueuesToCapacityOrRoll();

        _updateRevenueSmootherAfterEpochChange();

        _advanceEpochPointersAndResetValidatorCursor();

        return false;
    }

    /// @notice Offsets uncovered liabilities using available deposits and current assets.
    /// @dev Increases reservedAmount and reduces both `queueToStake` and `queueForUnstake` by the settled amount.
    /// Caps by: uncovered liabilities, `queueForUnstake`, `queueToStake`, and current assets.
    function _offsetLiabilitiesWithDeposits() internal {
        uint256 _queueToStake = globalCashFlowsPtr_N(0).queueToStake;
        uint256 _queueForUnstake = globalCashFlowsPtr_N(0).queueForUnstake;

        // Check for any outstanding liabilities
        uint256 _currentLiabilities = s_globalLiabilities.currentLiabilities();
        uint256 _reserves = s_globalCapital.reservedAmount;
        uint256 _pendingUnstaking = s_globalPending.pendingUnstaking;

        if (_currentLiabilities > _reserves + _pendingUnstaking) {
            // Start with the max value of the uncovered liabilities
            uint256 _liabilitiesToSettleWithDeposits = _currentLiabilities - _reserves - _pendingUnstaking;

            // Do not settle more than is currently requested to queue for unstaking
            if (_liabilitiesToSettleWithDeposits > _queueForUnstake) {
                _liabilitiesToSettleWithDeposits = _queueForUnstake;
            }

            // Do not use more than is currently queued for staking in the settlement process
            if (_liabilitiesToSettleWithDeposits > _queueToStake) {
                _liabilitiesToSettleWithDeposits = _queueToStake;
            }

            // We can only settle with MON (currentAssets) that hasn't been allocated for another purpose
            uint256 _currentAssets = s_globalCapital.currentAssets(s_atomicAssets, address(this).balance);
            if (_liabilitiesToSettleWithDeposits > _currentAssets) {
                _liabilitiesToSettleWithDeposits = _currentAssets;
            }

            // If we have enough funds to offset, perform the offset
            if (_liabilitiesToSettleWithDeposits > 0) {
                // Increase the reserved amount
                s_globalCapital.reservedAmount += _liabilitiesToSettleWithDeposits.toUint128();
                // Implied: currentAssets -= _liabilitiesToSettleWithDeposits

                emit ReservesIncreasedBySurplusDeposits(_liabilitiesToSettleWithDeposits);

                // Remove the funds from both the queueToStake and the queueForUnstake - the deposit offsets the
                // withdrawal.
                globalCashFlowsPtr_N(0).queueToStake = (_queueToStake - _liabilitiesToSettleWithDeposits).toUint120();
                globalCashFlowsPtr_N(0).queueForUnstake =
                    (_queueForUnstake - _liabilitiesToSettleWithDeposits).toUint120();
            }
        }
    }

    /// @notice Carries over atomic pool unstake amount into the global unstake queue for the current epoch.
    function _carryOverAtomicUnstakeIntoQueue() internal {
        // NOTE: We set this to globalRevenue.earnedRevenue so that there is no "jump" in the fee cost
        // whenever we crank
        uint120 _amountToSettle =
            Math.min(globalRevenuePtr_N(0).earnedRevenue, s_atomicAssets.distributedAmount).toUint120();

        // NOTE: allocatedRevenue cannot exceed either earnedRevenue or distributedAmount.
        globalRevenuePtr_N(0).allocatedRevenue = 0;

        s_atomicAssets.distributedAmount -= _amountToSettle; // -Contra_Asset Dr _amountToSettle
        // Implied: currentAssets -= _amountToSettle; // -Asset Cr _amountToSettle

        globalCashFlowsPtr_N(0).queueForUnstake += _amountToSettle;
    }

    /// @notice Applies any goodwill (unexpected donations) to the queueToStake and emits tracking event.
    function _applyGoodwillToStakeQueue() internal {
        uint256 _goodwill =
            AccountingLib.goodwill(s_globalCapital, s_atomicAssets, globalCashFlowsPtr_N(0), address(this).balance);
        if (_goodwill > 0) {
            globalCashFlowsPtr_N(0).queueToStake += _goodwill.toUint120();
            emit UnexpectedGoodwill(s_admin.internalEpoch, _goodwill);
        }
    }

    /// @notice Updates revenue smoother using just-ended epoch's earnedRevenue and current block number.
    function _updateRevenueSmootherAfterEpochChange() internal {
        // Update the revenue smoother so that we can offset _totalEquity by a smoothed revenue
        // from this epoch (which will be last epoch by the end of this call).
        s_revenueSmoother = RevenueSmoother({
            earnedRevenueLast: globalRevenuePtr_N(0).earnedRevenue,
            epochChangeBlockNumber: uint64(block.number)
        });
    }

    /// @notice Advances internal epoch pointer and resets validator crank cursor to the start of the list.
    function _advanceEpochPointersAndResetValidatorCursor() internal {
        // Increase the global internal epoch.
        // NOTE: After incrementing the internal epoch:
        //      epoch_N(-1) is now epoch_N(-2)
        //      epoch_N(0) is now epoch_N(-1)
        //      epoch_N(1) is now epoch_N(0)
        // ETC...
        ++s_admin.internalEpoch;

        // Set the next validator to crank - always start off with the FIRST_VAL_ID sentinel
        s_nextValidatorToCrank = FIRST_VAL_ID;
    }

    /// @notice Primes the next global epoch storage entry with carried flags and new target.
    function _primeNextGlobalEpoch(Epoch memory epochThatJustEnded) internal {
        // Prepare the upcoming epoch's storage slot
        _setEpochStorage(
            globalEpochPtr_N(1),
            Epoch({
                epoch: _getEpochBarrierAdj(), // Use the potentially higher epoch check here to make sure at least one
                    // full epoch passes
                withdrawalId: 0, // unused
                hasWithdrawal: false, // unused
                hasDeposit: false, // unused
                crankedInBoundaryPeriod: _inEpochDelayPeriod(), // can probably use later on
                wasCranked: false, // bool indicating if the placeholder validator was cranked
                frozen: epochThatJustEnded.frozen,
                closed: epochThatJustEnded.closed,
                targetStakeAmount: 0 // unused at the Global Epoch level, only used at Validator Epoch level
             })
        );
    }

    /// @notice Advances in-active-set flags for a validator at the start of its crank.
    function _advanceActiveSetFlags(uint64 validatorId) internal {
        if (s_validatorData[validatorId].isActive) {
            s_validatorData[validatorId].inActiveSet_Last = s_validatorData[validatorId].inActiveSet_Current;
            s_validatorData[validatorId].inActiveSet_Current = true; // Assume active, adjust later if needed
        }
    }

    /// @notice Settles ready staking/unstaking edges across the last three epochs for a validator.
    function _settlePastEpochEdges(uint64 valId) internal {
        // Check the last three epochs for completion of staking and unstaking actions
        Epoch storage _validatorEpochPtr = validatorEpochPtr_N(-3, valId);
        if (_validatorEpochPtr.crankedInBoundaryPeriod) {
            // The "three-epochs-ago" slot should have a withdrawal if it was initiated late during the boundary period.
            if (_validatorEpochPtr.hasWithdrawal) {
                _settleCompletedStakeAllocationDecrease(valId, _validatorEpochPtr, validatorPendingPtr_N(-3, valId));
            }
        }

        _validatorEpochPtr = validatorEpochPtr_N(-2, valId);
        if (!_validatorEpochPtr.crankedInBoundaryPeriod) {
            // The unstaking initiated in epoch n-2 should be ready as long as it didn't start in a boundary period
            if (_validatorEpochPtr.hasWithdrawal) {
                _settleCompletedStakeAllocationDecrease(valId, _validatorEpochPtr, validatorPendingPtr_N(-2, valId));
            }
        } else {
            // The staking initiated in epoch n-2 that was delayed by the boundary period should now be ready
            if (_validatorEpochPtr.hasDeposit) {
                _handleCompleteIncreasedAllocation(_validatorEpochPtr, validatorPendingPtr_N(-2, valId));
            }
        }

        _validatorEpochPtr = validatorEpochPtr_N(-1, valId);
        if (!_validatorEpochPtr.crankedInBoundaryPeriod) {
            // The staking initiated in epoch n-1 should be ready now as long as it wasn't cranked in a boundary period
            if (_validatorEpochPtr.hasDeposit) {
                _handleCompleteIncreasedAllocation(_validatorEpochPtr, validatorPendingPtr_N(-1, valId));
            }
        }
    }

    /// @notice Computes per-validator stake delta using last windows and availability snapshots.
    function _computeStakeDelta(uint64 validatorId)
        internal
        view
        returns (
            uint128 nextTarget,
            uint128 netAmount,
            bool isWithdrawal,
            uint256 stakeAllocationIncrease,
            uint256 stakeAllocationDecrease
        )
    {
        uint256 _validatorUnstakableAmount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
            validatorEpochPtr_N(-2, validatorId),
            validatorEpochPtr_N(-1, validatorId),
            validatorPendingPtr_N(-1, validatorId),
            validatorPendingPtr_N(-2, validatorId)
        );

        Epoch memory _validatorEpochLast = validatorEpochPtr_N(-1, validatorId);

        require(
            _validatorUnstakableAmount <= uint256(_validatorEpochLast.targetStakeAmount),
            ValidatorAvailableExceedsTargetStake(_validatorUnstakableAmount, _validatorEpochLast.targetStakeAmount)
        );

        uint256 _globalUnstakableAmount =
            StakeAllocationLib.getGlobalAmountAvailableToUnstake(s_globalCapital, s_globalPending);

        // Assume Validator is part of the active set to get the intended weights based on staking queue values
        (nextTarget, netAmount, isWithdrawal, stakeAllocationIncrease, stakeAllocationDecrease) = StakeAllocationLib
            .calculateValidatorEpochStakeDelta(
            globalCashFlowsPtr_N(-1),
            globalRevenuePtr_N(-2),
            globalRevenuePtr_N(-1),
            validatorRewardsPtr_N(-2, validatorId),
            validatorRewardsPtr_N(-1, validatorId),
            validatorEpochPtr_N(-1, validatorId),
            _validatorUnstakableAmount,
            _globalUnstakableAmount
        );
    }

    /// @notice Applies the computed stake delta via skip/decrease/increase helpers and returns updated values.
    function _applyStakeDelta(
        uint64 valId,
        uint128 nextTarget,
        uint128 netAmount,
        bool isWithdrawal
    )
        internal
        returns (uint128 nextTargetOut, uint128 netAmountOut)
    {
        nextTargetOut = nextTarget;
        netAmountOut = netAmount;

        if (netAmountOut < DUST_THRESHOLD) {
            // CASE: Amount is too small to warrant staking or unstaking
            (nextTargetOut, netAmountOut) =
                _initiateStakeAllocationSkip(valId, nextTargetOut, netAmountOut.toUint120(), isWithdrawal);
        } else if (isWithdrawal) {
            // CASE: Decrease allocation to validator
            (nextTargetOut, netAmountOut) = _initiateStakeAllocationDecrease(valId, nextTargetOut, netAmountOut);
        } else {
            // CASE: Increase allocation to validator
            (nextTargetOut, netAmountOut) = _initiateStakeAllocationIncrease(valId, nextTargetOut, netAmountOut);
        }
    }

    /// @notice Net any excess stake/unstake queue capacity against each other
    function _offsetExcessQueueCapacityWithNet() internal {
        // Perform this prior to clamping and rolling queue capacity but after adjusting queues
        // for the atomic unstaking pool deltas.

        // Get the available amounts and their respective queues
        uint256 _globalUnstakableAmount =
            StakeAllocationLib.getGlobalAmountAvailableToUnstake(s_globalCapital, s_globalPending);
        uint256 _queuedForUnstakeAmount = globalCashFlowsPtr_N(0).queueForUnstake;

        uint256 _globalStakableAmount = s_globalCapital.currentAssets(s_atomicAssets, address(this).balance);
        uint256 _queuedToStakeAmount = globalCashFlowsPtr_N(0).queueToStake;

        // First, get the max offset by taking the lesser queue amount
        uint256 _maxOffsetAmount =
            _queuedForUnstakeAmount > _queuedToStakeAmount ? _queuedToStakeAmount : _queuedForUnstakeAmount;

        // Second, calculate the target offset amount as the greater of the two queue's balance shortfalls
        uint256 _targetOffsetAmount =
            _queuedForUnstakeAmount > _globalUnstakableAmount ? _queuedForUnstakeAmount - _globalUnstakableAmount : 0;

        if (_queuedToStakeAmount > _globalStakableAmount) {
            uint256 _stakableMinOffsetAmount = _queuedToStakeAmount - _globalStakableAmount;
            if (_stakableMinOffsetAmount > _targetOffsetAmount) {
                _targetOffsetAmount = _stakableMinOffsetAmount;
            }
        }

        // Cap the target offset amount at the max offset amount
        // NOTE: Any "leftovers" will be picked up in the _clampQueuesToCapacityOrRoll() method, which rolls over any
        // surplus queue amounts to the next epoch
        if (_targetOffsetAmount > _maxOffsetAmount) {
            _targetOffsetAmount = _maxOffsetAmount;
        }

        // Get the amount that needs to be reserved
        uint256 _targetReservedAmount = s_globalLiabilities.currentLiabilities();
        uint256 _currentReservedAmount = s_globalCapital.reservedAmount;
        if (_targetReservedAmount > _currentReservedAmount) {
            uint256 _netToReservesAmount = _targetReservedAmount - _currentReservedAmount;

            // Can only move min(currentAssets, _reservesDeficit, _targetOffsetAmount) to reserves
            if (_netToReservesAmount > _globalStakableAmount) {
                _netToReservesAmount = _globalStakableAmount;
            }
            if (_netToReservesAmount > _targetOffsetAmount) {
                _netToReservesAmount = _targetOffsetAmount;
            }

            emit ReservesIncreasedByExcessQueueCapacity(_netToReservesAmount);

            // Increase the reserved amount
            s_globalCapital.reservedAmount += _netToReservesAmount.toUint128(); // +Asset Dr _netToReservesAmount
                // Implied: currentAssets -= _netToReservesAmount // -Asset Cr _netToReservesAmount
        }

        emit QueuesOffsetViaNet(
            _targetOffsetAmount,
            _globalUnstakableAmount,
            _queuedForUnstakeAmount,
            _globalStakableAmount,
            _queuedToStakeAmount
        );

        // Net the offsets against each other
        uint120 _targetOffsetAmount120 = _targetOffsetAmount.toUint120();
        globalCashFlowsPtr_N(0).queueToStake -= _targetOffsetAmount120;
        globalCashFlowsPtr_N(0).queueForUnstake -= _targetOffsetAmount120;

        // Any remaining queue surpluses will get rolled forward to the next epoch
    }

    /// @notice Rolls any staking queued balance forward if the target validator is unassignable
    function _rollUnassignableStakingQueue() internal {
        // Stake deposits are assigned based on revenue. If global revenue is less than MIN_VALIDATOR_DEPOSIT,
        // no stake will be assigned
        if (s_activeValidatorCount > 0 && globalRevenuePtr_N(0).earnedRevenue < MIN_VALIDATOR_DEPOSIT) {
            uint120 _stakeQueue = globalCashFlowsPtr_N(0).queueToStake;

            emit StakeUnassignableNoGlobalRevenue(_stakeQueue);

            globalCashFlowsPtr_N(0).queueToStake = 0;
            globalCashFlowsPtr_N(1).queueToStake += _stakeQueue;
        }
        // NOTE: if s_activeValidatorCount == 0, the _clampQueuesToCapacityOrRoll() method called next will handle
        // rolling the stake queue forwards.
    }

    /// @notice Clamps queues to available stake/unstake capacity or rolls forward when no validators are active.
    function _clampQueuesToCapacityOrRoll() internal {
        // Handle accounting for max / min amounts that can be staked / unstaked, but only if there are
        // validators to stake / unstake with
        if (s_activeValidatorCount > 0) {
            // Calculate and carry forward any unstakable amount that cannot be covered by the global unstakable assets
            // during the next epoch. This could occur when the majority of assets are stuck in staking escrow or
            // unstaking escrow.
            uint256 _globalUnstakableAmount =
                StakeAllocationLib.getGlobalAmountAvailableToUnstake(s_globalCapital, s_globalPending);
            uint256 _queuedForUnstakeAmount = globalCashFlowsPtr_N(0).queueForUnstake;
            if (_queuedForUnstakeAmount > _globalUnstakableAmount) {
                uint256 _unstakeQueueDeficit = _queuedForUnstakeAmount - _globalUnstakableAmount;

                emit UnstakingQueueExceedsUnstakableAmount(_queuedForUnstakeAmount, _globalUnstakableAmount);

                uint120 _unstakeQueueDeficit120 = _unstakeQueueDeficit.toUint120();
                globalCashFlowsPtr_N(0).queueForUnstake -= _unstakeQueueDeficit120;
                globalCashFlowsPtr_N(1).queueForUnstake += _unstakeQueueDeficit120;
            }
            uint256 _queuedToStakeAmount = globalCashFlowsPtr_N(0).queueToStake;
            uint256 _globalStakableAmount = s_globalCapital.currentAssets(s_atomicAssets, address(this).balance);
            if (_queuedToStakeAmount > _globalStakableAmount) {
                uint256 _stakeQueueSurplus = _queuedToStakeAmount - _globalStakableAmount;

                emit StakingQueueExceedsStakableAmount(_queuedToStakeAmount, _globalStakableAmount);

                uint120 _stakeQueueSurplus120 = _stakeQueueSurplus.toUint120();
                globalCashFlowsPtr_N(0).queueToStake -= _stakeQueueSurplus120;
                globalCashFlowsPtr_N(1).queueToStake += _stakeQueueSurplus120;
            }

            // Next, we add in the "turnover" / "incentive-aligning" amount to the unstaking queue. This happens after
            // the settling of deposits against withdrawals in order to promote the rebalancing even when the net
            // cashflow is flat.
            // NOTE: The "staking" portion happens when this amount finishes unstaking.
            // NOTE: We only do this if there are multiple active validators from which to rebalance between.
            if (s_activeValidatorCount > 1 && _globalUnstakableAmount > 0) {
                uint256 _incentiveAlignmentPercentage = s_admin.incentiveAlignmentPercentage;
                if (_incentiveAlignmentPercentage > 0) {
                    // Divide by four because unstaking takes two epochs and depositing takes another two epochs
                    uint256 _alignmentUnstakeAmount =
                        _globalUnstakableAmount * _incentiveAlignmentPercentage / BPS_SCALE / 4;
                    uint256 _currentUnstakeAmount = globalCashFlowsPtr_N(0).queueForUnstake;

                    // Treat the incentive-aligning portion as a floor for withdrawals that should be inclusive of
                    // existing withdrawals.
                    if (_currentUnstakeAmount < _alignmentUnstakeAmount) {
                        globalCashFlowsPtr_N(0).queueForUnstake = _alignmentUnstakeAmount.toUint120();
                    }
                }
            }

            // If there are no active validators, roll forward any balances since there wont be anyone to stake them
            // with, then net them out since performance-weighting is not relevant
        } else {
            uint256 _queueToStake = globalCashFlowsPtr_N(0).queueToStake;
            uint256 _queueForUnstake = globalCashFlowsPtr_N(0).queueForUnstake;

            emit UnexpectedNoValidators(s_admin.internalEpoch, _queueToStake, _queueForUnstake);

            if (_queueToStake > _queueForUnstake) {
                uint256 _netQueueToStake = _queueToStake - _queueForUnstake;
                globalCashFlowsPtr_N(1).queueToStake += _netQueueToStake.toUint120();
                // Implied: globalCashFlowsPtr_N(1).queueForUnstake = 0;
            } else {
                uint256 _netQueueForUnstake = _queueForUnstake - _queueToStake;
                globalCashFlowsPtr_N(1).queueForUnstake += _netQueueForUnstake.toUint120();
                // Implied: globalCashFlowsPtr_N(1).queueToStake = 0;
            }
            globalCashFlowsPtr_N(0).clear();
        }
    }

    /// @notice Processes one validator's epoch roll, yield settlement, and (un)stake delta.
    /// @dev Skips placeholder and already-cranked validators to be idempotent within an epoch.
    /// Steps:
    ///  1) Guard for sentinel/unknown/zero-id validators
    ///  2) Mark last epoch as cranked (idempotency)
    ///  3) Advance active set flags and eligibility
    ///  4) Pull and book validator yield (precompile), updating rewards/liabilities
    ///  5) Settle past epoch edges and pay or redirect rewards
    ///  6) Compute per-validator stake delta (increase/decrease)
    ///  7) Apply delta (stake or unstake), respecting availability and dust rules
    ///  8) Roll validator epoch forwards with the next target
    /// @param valId The validator ID to process
    function _crankValidator(uint64 valId) internal {
        // If at start of the linked list, skip to the next, first real validator in list
        if (valId == FIRST_VAL_ID) return;

        // Make sure we have a valid valId before proceeding.
        uint64 _valId = valId;
        if (_valId == UNKNOWN_VAL_ID) {
            _crankPlaceholderValidator();
            return;
        } else if (_valId == 0) {
            // This should be unreachable, but emits diagnostic event just in case
            emit CrankSkippedOnValidatorIdZero(block.coinbase);
            return;
        }

        // Crank only once per epoch per validator and only after the global state advanced.
        Epoch storage _lastEpoch = validatorEpochPtr_N(-1, _valId);
        if (_lastEpoch.wasCranked) return;
        _lastEpoch.wasCranked = true;

        // NOTE:
        // Global has already been cranked.
        // The epoch that is currently ongoing is validatorEpochPtr_N(0, coinbase)
        // The most recent epoch that has fully completed is is validatorEpochPtr_N(-1, coinbase)

        _advanceActiveSetFlags(_valId);

        // Pull validator rewards (net of commission) so rebalancing reflects latest earnings.
        _settleEarnedStakingYield(_valId);

        _settlePastEpochEdges(_valId);

        // Send any unsent rewardsPayable (i.e., MEV payments)
        _settleValidatorRewardsPayable(_valId);

        _handleStakeBalanceVerification(_valId, validatorEpochPtr_N(-1, _valId));

        // Calculate and then handle the net staking / unstaking
        (uint128 _nextTargetStakeAmount, uint128 _netAmount, bool _isWithdrawal, uint256 _stakeAllocationIncrease,) =
            _computeStakeDelta(_valId);

        // CASE: Validator was tagged as inactive for the cranked period
        if (!s_validatorData[_valId].isActive || _nextTargetStakeAmount < MIN_VALIDATOR_DEPOSIT) {
            uint256 _validatorUnstakableAmount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
                validatorEpochPtr_N(-2, _valId),
                validatorEpochPtr_N(-1, _valId),
                validatorPendingPtr_N(-1, _valId),
                validatorPendingPtr_N(-2, _valId)
            );
            // We're withdrawing _validatorUnstakableAmount, Roll forward any allocations that should've happened but
            // were blocked due to inactivity
            if (_stakeAllocationIncrease > 0) {
                // NOTE: The max value for _netAmount is _validatorUnstakableAmount, which is only reached when
                // _stakeAllocationIncrease is zero. We need to re-queue net stake that goes unstaked due to the
                // adjustment to be staked next epoch, since it won't be staked this epoch.
                uint256 _maxDelta = _isWithdrawal
                    ? _validatorUnstakableAmount - uint256(_netAmount)
                    : _validatorUnstakableAmount + uint256(_netAmount);
                uint256 _maxCarryover = Math.min(_maxDelta, _stakeAllocationIncrease);
                if (_maxCarryover > 0) globalCashFlowsPtr_N(0).queueToStake += _maxCarryover.toUint120();
                // NOTE: No need to de-queue surplus unstake.
            }

            _netAmount = _validatorUnstakableAmount.toUint128();
            _nextTargetStakeAmount = validatorEpochPtr_N(-1, _valId).targetStakeAmount - _netAmount;
            _isWithdrawal = true;
        }

        (_nextTargetStakeAmount, _netAmount) =
            _applyStakeDelta(_valId, _nextTargetStakeAmount, _netAmount, _isWithdrawal);

        // Roll the storage slots forwards
        _rollValidatorEpochForwards(_valId, _nextTargetStakeAmount);

        // If coinbase is a contract, attempt to process it via a try/catch
        address coinbase = _validatorCoinbase(_valId);
        if (coinbase.code.length > 0) {
            try ICoinbase(coinbase).process{ gas: COINBASE_PROCESS_GAS_LIMIT }() { } catch { }
        }
    }

    /// @notice Handles cranking for the placeholder validator (unregistered validators)
    /// @dev Processes revenue attribution for unregistered validators
    function _crankPlaceholderValidator() internal {
        if (globalEpochPtr_N(-1).wasCranked) return;

        emit UnregisteredValidatorRevenue(
            globalEpochPtr_N(-1).epoch,
            uint256(validatorRewardsPtr_N(0, UNKNOWN_VAL_ID).rewardsPayable),
            uint256(validatorRewardsPtr_N(0, UNKNOWN_VAL_ID).earnedRevenue)
        );

        // Set the placeholder validator as having been cranked via the global epoch
        _rollValidatorEpochForwards(UNKNOWN_VAL_ID, 0);
    }

    /// @notice Advances validator epoch state and updates validator accounting
    /// @param valId The validator's ID
    /// @param newTargetStakeAmount The new target stake amount for the validator
    function _rollValidatorEpochForwards(uint64 valId, uint128 newTargetStakeAmount) internal {
        // Load the ongoing validator epoch into memory for convenience
        Epoch memory _ongoingValidatorEpoch = validatorEpochPtr_N(0, valId);
        uint64 _internalEpoch = s_admin.internalEpoch;

        // Store the next withdrawal id after incrementing if a withdrawal was initiated during this crank.
        uint8 _withdrawalId = _ongoingValidatorEpoch.withdrawalId;
        if (_ongoingValidatorEpoch.hasWithdrawal) {
            unchecked {
                if (++_withdrawalId == 0) _withdrawalId = 1;
            }
        }

        // Set the target stake amount
        validatorEpochPtr_N(0, valId).targetStakeAmount = newTargetStakeAmount;

        // Clear out the next next shmonad epoch's slots
        validatorRewardsPtr_N(2, valId).clear();
        validatorPendingPtr_N(2, valId).clear();
        _setEpochStorage(
            validatorEpochPtr_N(1, valId),
            Epoch({
                epoch: _internalEpoch + 1,
                withdrawalId: _withdrawalId,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: false,
                frozen: _ongoingValidatorEpoch.frozen,
                closed: _ongoingValidatorEpoch.closed,
                targetStakeAmount: 0
            })
        );

        // Update ValidatorData
        if (s_validatorData[valId].isActive) {
            s_validatorData[valId].epoch = _internalEpoch;

            // Handle special deactivation logic - we don't increment the validatorData epoch if they're deactivated
            // (even though we do increment the s_validatorEpoch if they're deactivated)
            if (!s_validatorData[valId].inActiveSet_Last && !s_validatorData[valId].inActiveSet_Current) {
                _beginDeactivatingValidator(valId);
            }

            // Handle special deactivation logic - we don't increment the validatorData epoch if they're deactivated
            // (even though we do increment the s_validatorEpoch if they're deactivated)
        } else {
            // If SHMONAD_VALIDATOR_DEACTIVATION_PERIOD epochs have passed, fully remove the validator
            if (_internalEpoch >= s_validatorData[valId].epoch + SHMONAD_VALIDATOR_DEACTIVATION_PERIOD) {
                _completeDeactivatingValidator(valId);
            }
        }
    }

    /// @notice Checks and sets new atomic liquidity target based on current conditions
    /// @param oldAllocatedAmount The previous allocated amount for comparison
    /// @return scaledTargetPercent The new scaled target percentage
    /// @return newAllocatedAmount The new allocated amount for atomic unstaking
    function _checkSetNewAtomicLiquidityTarget(
        uint128 oldUtilizedAmount,
        uint128 oldAllocatedAmount
    )
        internal
        returns (uint256 scaledTargetPercent, uint128 newAllocatedAmount)
    {
        // Load any pending atomic liquidity percentage
        uint256 _newScaledTargetPercent = s_pendingTargetAtomicLiquidityPercent;

        // Load relevant values
        WorkingCapital memory _globalCapital = s_globalCapital;
        uint256 _totalEquity = _globalCapital.totalEquity(s_globalLiabilities, s_admin, address(this).balance);
        uint256 _currentAssets = _globalCapital.currentAssets(s_atomicAssets, address(this).balance);

        // See if there is a new target percent - if not, check for minor rebalances and then return the old data.

        if (_newScaledTargetPercent == FLOAT_PLACEHOLDER) {
            // Check to see if the allocated amount has drifted too far away due to increases during
            // _accountForWithdraw
            uint256 _scaledTargetAllocatedPercentage = _scaledTargetLiquidityPercentage();
            uint256 _scaledCurrentAllocatedPercentage = _scaledPercentFromAmounts(oldAllocatedAmount, _totalEquity);

            if (_scaledTargetAllocatedPercentage > _scaledCurrentAllocatedPercentage + FLOAT_REBALANCE_SENSITIVITY) {
                // CASE: Need to rebalance up
                _newScaledTargetPercent = _scaledTargetAllocatedPercentage;
                s_pendingTargetAtomicLiquidityPercent = _scaledTargetAllocatedPercentage;
            } else if (
                // CASE: rebalance down
                _scaledTargetAllocatedPercentage + FLOAT_REBALANCE_SENSITIVITY < _scaledCurrentAllocatedPercentage
            ) {
                _newScaledTargetPercent = _scaledTargetAllocatedPercentage;
                s_pendingTargetAtomicLiquidityPercent = _scaledTargetAllocatedPercentage;
            } else {
                // CASE: Allocation is within threshold
                return (_scaledTargetAllocatedPercentage, oldAllocatedAmount);
            }
        }

        // Calculate an initial allocation amount for the atomic unstaking pool
        newAllocatedAmount = _amountFromScaledPercent(_totalEquity, _newScaledTargetPercent).toUint128();

        if (newAllocatedAmount > oldAllocatedAmount) {
            // CASE: Increasing the liquidity target
            uint128 _maxNetAmount = _currentAssets.toUint128();

            if (oldAllocatedAmount + _maxNetAmount < newAllocatedAmount) {
                // CASE: we cannot increase by the full max amount, so calculate the new scaledTargetPercent
                newAllocatedAmount = oldAllocatedAmount + _maxNetAmount;
                _newScaledTargetPercent = _scaledPercentFromAmounts(newAllocatedAmount, _totalEquity);
            } else {
                // CASE: we can increase by the full net amount, so we fully remove the
                // s_pendingTargetAtomicLiquidityPercent and consider the update complete.

                // Clear the pending target - we can fully update.
                s_pendingTargetAtomicLiquidityPercent = FLOAT_PLACEHOLDER;
            }
        } else {
            if (newAllocatedAmount < oldUtilizedAmount) {
                // CASE: Trying to reduce beyond the utilized amount - we must adjust to avoid underflowing in other
                // calculations.

                // Apply cap and then backwards calculate the in-step target percent
                newAllocatedAmount = oldUtilizedAmount;
                _newScaledTargetPercent = _scaledPercentFromAmounts(newAllocatedAmount, _totalEquity);
            } else {
                // Fully remove the  s_pendingTargetAtomicLiquidityPercent
                s_pendingTargetAtomicLiquidityPercent = FLOAT_PLACEHOLDER;
            }
        }

        // Store data and return
        s_admin.targetLiquidityPercentage = _unscaledTargetLiquidityPercentage(Math.min(_newScaledTargetPercent, SCALE));

        return (_newScaledTargetPercent, newAllocatedAmount);
    }

    /// @notice Settles completed stake allocation changes (staking/unstaking) for a validator
    /// @param valId The validator ID
    /// @param validatorEpochPtr Storage pointer to validator epoch data
    /// @param validatorPendingPtr Storage pointer to validator pending data
    function _settleCompletedStakeAllocationDecrease(
        uint64 valId,
        Epoch storage validatorEpochPtr,
        StakingEscrow storage validatorPendingPtr
    )
        internal
    {
        address coinbase = _validatorCoinbase(valId);
        (uint128 _amountReceived, bool _success, bool _delayed) =
            _completeWithdrawal(valId, validatorEpochPtr.withdrawalId);
        if (_delayed) {
            // Treat boundary-period delays as cranked-in-boundary so the N(-3) path retries next epoch.
            validatorEpochPtr.crankedInBoundaryPeriod = true;
            // NOTE: This frame is just for testing purposes - it indicates a timing synchronization problem
            emit WithdrawSettlementDelayed(
                coinbase,
                valId,
                _getEpoch(),
                validatorPendingPtr.pendingUnstaking,
                _amountReceived,
                validatorEpochPtr.withdrawalId
            );
        } else if (_success) {
            _handleCompleteDecreasedAllocation(
                valId, validatorEpochPtr, validatorPendingPtr, _amountReceived.toUint120()
            );

            emit UnexpectedStakeSettlementError(coinbase, valId, _amountReceived, 1);
        } else {
            _markValidatorNotInActiveSet(valId, 2);

            emit UnexpectedStakeSettlementError(coinbase, valId, _amountReceived, 2);
        }
    }

    /// @notice Settles earned (received) staking yield from a validator
    /// @param valId The validator ID
    function _settleEarnedStakingYield(uint64 valId) internal {
        (uint120 _amountRewarded, bool _success) = _claimRewards(valId);
        if (_success) {
            _handleEarnedStakingYield(valId, _amountRewarded);
        } else {
            _markValidatorNotInActiveSet(valId, 1);

            address coinbase = _validatorCoinbase(valId);
            emit UnexpectedYieldSettlementError(coinbase, valId, _amountRewarded, address(this).balance, 1);
        }
    }

    /// @notice Settles validator rewards payable (MEV payments *TO* a validator).
    /// @param valId The validator ID
    function _settleValidatorRewardsPayable(uint64 valId) internal {
        uint120 _validatorRewardsPayable = validatorRewardsPtr_N(-1, valId).rewardsPayable;
        if (_validatorRewardsPayable >= MIN_VALIDATOR_DEPOSIT) {
            // NOTE: if _sendRewards fails it means the validator is no longer a part of the active validator set
            (bool _success, uint120 _actualAmountSent) = _sendRewards(valId, _validatorRewardsPayable);
            if (_success) {
                if (_actualAmountSent < _validatorRewardsPayable) {
                    // NOTE: This frame is for testing - if it's triggered it signifies an underlying issue
                    emit InsufficientLocalBalance(
                        _validatorRewardsPayable, _actualAmountSent, address(this).balance, _totalEquity(false), 2
                    );
                    address coinbase = _validatorCoinbase(valId);
                    emit UnexpectedValidatorRewardsPayError(
                        coinbase, valId, _validatorRewardsPayable, address(this).balance, 1
                    );

                    _handleRewardsPaidFail(valId, _validatorRewardsPayable - _actualAmountSent);
                    _handleRewardsPaidSuccess(_actualAmountSent);
                } else {
                    _handleRewardsPaidSuccess(_validatorRewardsPayable);
                }
            } else {
                address coinbase = _validatorCoinbase(valId);
                emit UnexpectedValidatorRewardsPayError(
                    coinbase, valId, _validatorRewardsPayable, address(this).balance, 2
                );
                _handleRewardsRedirect(_validatorRewardsPayable);
                _markValidatorNotInActiveSet(valId, 3);
            }
        } else if (_validatorRewardsPayable > 0) {
            address coinbase = _validatorCoinbase(valId);
            emit UnexpectedValidatorRewardsPayError(coinbase, valId, _validatorRewardsPayable, address(this).balance, 3);
            _handleRewardsPaidFail(valId, _validatorRewardsPayable);
        }
    }

    /// @notice Handles stake allocation skip when amount is below dust threshold
    /// @param valId The validator ID
    /// @param nextTargetStakeAmount The next target stake amount
    /// @param netAmount The net amount to process
    /// @param isWithdrawal Whether this is a withdrawal operation
    /// @return The updated target stake amount and net amount
    function _initiateStakeAllocationSkip(
        uint64 valId,
        uint128 nextTargetStakeAmount,
        uint120 netAmount,
        bool isWithdrawal
    )
        internal
        returns (uint128, uint120)
    {
        if (netAmount == 0) {
            // pass
            address coinbase = _validatorCoinbase(valId);
            emit LowValidatorStakeDeltaNetZero(
                coinbase,
                valId,
                globalEpochPtr_N(-1).epoch,
                nextTargetStakeAmount,
                netAmount,
                s_validatorData[valId].inActiveSet_Current,
                s_validatorData[valId].inActiveSet_Last
            );
        } else if (isWithdrawal) {
            // Adjust the target, then resubmit the amount into the unstaking queue
            nextTargetStakeAmount += netAmount;
            globalCashFlowsPtr_N(0).queueForUnstake += netAmount;
            netAmount = 0;

            address coinbase = _validatorCoinbase(valId);
            emit LowValidatorStakeDeltaOnDecrease(
                coinbase,
                valId,
                globalEpochPtr_N(-1).epoch,
                nextTargetStakeAmount,
                netAmount,
                s_validatorData[valId].inActiveSet_Current,
                s_validatorData[valId].inActiveSet_Last
            );
        } else {
            // Adjust the target, then resubmit the amount into the staking queue
            nextTargetStakeAmount -= netAmount;
            globalCashFlowsPtr_N(0).queueToStake += netAmount;
            netAmount = 0;

            address coinbase = _validatorCoinbase(valId);
            emit LowValidatorStakeDeltaOnIncrease(
                coinbase,
                valId,
                globalEpochPtr_N(-1).epoch,
                nextTargetStakeAmount,
                netAmount,
                s_validatorData[valId].inActiveSet_Current,
                s_validatorData[valId].inActiveSet_Last
            );
        }
        return (nextTargetStakeAmount, netAmount);
    }

    /// @notice Initiates stake allocation decrease for a validator
    /// @param valId The validator ID
    /// @param nextTargetStakeAmount The next target stake amount
    /// @param netAmount The net amount to decrease
    /// @return The updated target stake amount and net amount
    function _initiateStakeAllocationDecrease(
        uint64 valId,
        uint128 nextTargetStakeAmount,
        uint128 netAmount
    )
        internal
        returns (uint128, uint128)
    {
        // Kick off the next-stage unstake;
        (bool _success, uint128 _amountWithdrawing) =
            _initiateWithdrawal(valId, netAmount, validatorEpochPtr_N(0, valId).withdrawalId);

        if (_success) {
            // CASE: Unstaking initiated successfully
            if (_amountWithdrawing < netAmount) {
                // CASE: Unstaking initiated successfully but unable to initiate the intended amount
                address coinbase = _validatorCoinbase(valId);
                emit InsufficientActiveDelegatedBalance(coinbase, valId, _getEpoch(), netAmount, _amountWithdrawing);

                // Readd the netAmount to the nextTargetStakeAmount and resubmit the amount to the unstaking queue.
                uint120 _deficit = (netAmount - _amountWithdrawing).toUint120();
                nextTargetStakeAmount += _deficit;
                globalCashFlowsPtr_N(0).queueForUnstake += _deficit;
                netAmount -= _deficit;
            }
            _handleInitiateDecreasedAllocation(valId, _amountWithdrawing.toUint120());
        } else {
            // CASE: Unstaking failed to initiate
            _markValidatorNotInActiveSet(valId, 4);
            // Readd the netAmount to the nextTargetStakeAmount and resubmit the amount to the unstaking queue.
            nextTargetStakeAmount += netAmount;
            globalCashFlowsPtr_N(0).queueForUnstake += netAmount.toUint120();
            netAmount = 0;

            address coinbase = _validatorCoinbase(valId);
            emit UnexpectedFailureInitiateUnstake(coinbase, valId, nextTargetStakeAmount, netAmount);
        }
        return (nextTargetStakeAmount, netAmount);
    }

    /// @notice Initiates stake allocation increase for a validator
    /// @param valId The validator ID
    /// @param nextTargetStakeAmount The next target stake amount
    /// @param netAmount The net amount to increase
    /// @return The updated target stake amount and net amount
    function _initiateStakeAllocationIncrease(
        uint64 valId,
        uint128 nextTargetStakeAmount,
        uint128 netAmount
    )
        internal
        returns (uint128, uint128)
    {
        // Deploy additional stake to the validator
        (bool _success, uint128 _actualAmount) = _initiateStaking(valId, netAmount);

        if (_success) {
            // CASE: Staking initiated successfully
            if (_actualAmount < netAmount) {
                // CASE: Staking initiated successfully but unable to initiate the intended amount
                // NOTE: This frame is for testing - if it's triggered it signifies an underlying issue
                emit InsufficientLocalBalance(netAmount, _actualAmount, address(this).balance, _totalEquity(false), 1);

                // Reduce the nextTargetStakeAmount and the netAmount by the missing allocation and then
                // resubmit the amount to the staking queue.
                uint120 _deficit = (netAmount - _actualAmount).toUint120();
                nextTargetStakeAmount -= _deficit;
                globalCashFlowsPtr_N(0).queueToStake += _deficit;
                netAmount = _actualAmount;
            }
            _handleInitiateIncreasedAllocation(valId, netAmount.toUint120());
        } else {
            // CASE: Staking failed to initiate
            _markValidatorNotInActiveSet(valId, 5);

            // Remove the netAmount from the nextTargetStakeAmount and resubmit the missing amount to the staking queue.
            nextTargetStakeAmount -= netAmount;
            globalCashFlowsPtr_N(0).queueToStake += netAmount.toUint120();
            netAmount = 0;

            address coinbase = _validatorCoinbase(valId);
            emit UnexpectedFailureInitiateStake(coinbase, valId, nextTargetStakeAmount, netAmount);
        }
        return (nextTargetStakeAmount, netAmount);
    }

    // ================================================== //
    //       Accounting Handlers - MEV and Revenue        //
    // ================================================== //

    /// @notice Handles the accounting, collection and escrow of MEV rewards that will be paid out to a validator in the
    /// next epoch. This also collects and processes shMonad's share of the MEV payments.
    /// @param valId The validator ID
    /// @param amount The total reward amount
    /// @param feeRate The fee rate to apply
    /// @return validatorPayout The amount paid to the validator
    /// @return feeTaken The fee amount taken by the protocol
    function _handleValidatorRewards(
        uint64 valId,
        uint256 amount,
        uint256 feeRate
    )
        internal
        override
        returns (uint120 validatorPayout, uint120 feeTaken)
    {
        // NOTE: The `feeTaken` portion is earnedRevenue - realized as shMON yield immediately.
        // The validator payout after fees is delayed until the next epoch's crank is called.
        uint120 _grossFeeTaken = _amountFromScaledPercent(amount, feeRate).toUint120();
        uint256 _boostCommissionRate = s_admin.boostCommissionRate;

        uint120 _commissionTaken = (_grossFeeTaken * _boostCommissionRate / BPS_SCALE).toUint120();
        feeTaken = _grossFeeTaken - _commissionTaken;
        validatorPayout = amount.toUint120() - feeTaken - _commissionTaken;

        // Load the validator's data
        ValidatorData memory _vData = _getValidatorData(valId);

        if (!_vData.isPlaceholder && _vData.inActiveSet_Current) {
            // CASE: Validator is registered with FastLane - hold their MEV rewards (net of FastLane fee)
            // in escrow for them and pay them out next epoch.
            PendingBoost storage validatorRewardsPtr = validatorRewardsPtr_N(0, valId);
            validatorRewardsPtr.rewardsPayable += validatorPayout;
            validatorRewardsPtr.earnedRevenue += feeTaken;

            globalRevenuePtr_N(0).earnedRevenue += feeTaken;

            s_globalLiabilities.rewardsPayable += validatorPayout; // +Liability Cr validatorPayout
            s_admin.totalZeroYieldPayable += _commissionTaken; // +Liability Cr _commissionTaken
            s_globalCapital.reservedAmount += validatorPayout; // +Asset Dr validatorPayout,
                // Implied currentAssets += _commissionTaken //  +Asset Dr +_commissionTaken
        } else {
            // CASE: Validator is NOT registered with FastLane - use all the MEV to boost shMON yield,
            // but don't increase the global (all validators) earnedRevenue because we don't want this
            // revenue to 'dilute' the revenue weights of the registered validators.
            PendingBoost storage validatorRewardsPtr = validatorRewardsPtr_N(0, UNKNOWN_VAL_ID);
            validatorRewardsPtr.rewardsPayable += validatorPayout;
            validatorRewardsPtr.earnedRevenue += feeTaken;

            // Treat full amount as a debit rather than revenue to avoid diluting the revenue of active validators.
            feeTaken += validatorPayout;
            validatorPayout = 0;
            s_admin.totalZeroYieldPayable += _commissionTaken; // +Liability Cr _commissionTaken
                // Implied currentAssets += _commissionTaken; // +Asset Dr _commissionTaken
                // Implied currentAssets += feeTaken; // +Asset Dr feeTaken
                // Implied equity += feeTaken; // +Equity Cr feeTaken
        }

        // Track commission taken above by increasing the owner's zero-yield balance
        s_zeroYieldBalances[OWNER_COMMISSION_ACCOUNT] += _commissionTaken;

        // Queue the net new unencumbered MON for staking
        globalCashFlowsPtr_N(0).queueToStake += (feeTaken + _commissionTaken);

        // Re-add _commissionTaken to feeTaken when returning the amount that doesn't go to the validator
        return (validatorPayout, feeTaken + _commissionTaken);
    }

    /// @notice Handles the accounting for contract interactions that boost shMonad's yield.
    /// @param amount The boost yield amount to distribute
    function _handleBoostYield(uint128 amount) internal override {
        // NOTE: `amount` is pure earnedRevenue - realized as shMON yield immediately.

        uint128 _grossBoostCommission = amount * s_admin.boostCommissionRate / BPS_SCALE;

        if (_grossBoostCommission > 0) {
            s_admin.totalZeroYieldPayable += _grossBoostCommission; // +Liability Cr _grossBoostCommission
            // Implied: currentAssets +=  _grossBoostCommission // +Asset Dr _grossBoostCommission

            // Track commission taken above by increasing the owner's zero-yield balance
            s_zeroYieldBalances[OWNER_COMMISSION_ACCOUNT] += _grossBoostCommission;

            amount -= _grossBoostCommission;
        }

        // Implied currentAssets += amount; // +Asset Dr amount
        // Implied equity += amount; // +Equity Cr amount

        // Load the validator's data
        uint64 _currentValId = _getCurrentValidatorId();
        ValidatorData memory _vData = _getValidatorData(_currentValId);
        uint120 _amount120 = amount.toUint120();

        // Only increment global earned revenus if validator is not placeholder -
        // this is to prevent diluting real validators' proportional revenue-weighted allocations
        if (!_vData.isPlaceholder && _vData.inActiveSet_Current) {
            // CASE: Active, valid validator
            validatorRewardsPtr_N(0, _currentValId).earnedRevenue += _amount120;
            globalRevenuePtr_N(0).earnedRevenue += _amount120;
        } else {
            // CASE: Inactive or placeholder validator
            validatorRewardsPtr_N(0, UNKNOWN_VAL_ID).earnedRevenue += _amount120;
        }
        globalCashFlowsPtr_N(0).queueToStake += (amount + _grossBoostCommission).toUint120();
    }

    /// @notice Handles the accounting for contract interactions that boost shMonad's yield.
    /// @param assetValueOfShares The boost yield amount to distribute that came from existing
    /// shares
    function _handleBoostYieldFromShares(uint128 assetValueOfShares) internal override {
        // NOTE: `assetValueOfShares` comes from burning existing shMON shares without paying out
        // the equivalent amount of MON to any party. No unstaking required, but we must be mindful
        // of accounting invariants - specifically that an increase in earnedRevenue is assumed to be matched entirely
        // by MON in this contract and that no portion of that earnedRevenue increase is currently staked.
        // see `_accountForWithdraw()`

        uint128 _grossBoostCommission = assetValueOfShares * s_admin.boostCommissionRate / BPS_SCALE;

        if (_grossBoostCommission > 0) {
            s_admin.totalZeroYieldPayable += _grossBoostCommission; // +Liability Cr _grossBoostCommission
            // Implied: currentAssets +=  _grossBoostCommission // +Asset Dr _grossBoostCommission

            // Track commission taken above by increasing the owner's zero-yield balance
            s_zeroYieldBalances[OWNER_COMMISSION_ACCOUNT] += _grossBoostCommission;

            assetValueOfShares -= _grossBoostCommission;
        }

        // No accounting entries - equity stays the same, it's just divided up among fewer issued shares.

        // Load the validator's data
        uint64 _currentValId = _getCurrentValidatorId();
        ValidatorData memory _vData = _getValidatorData(_currentValId);

        // Only increment global earned revenus if validator is not placeholder -
        // this is to prevent diluting real validators' proportional revenue-weighted allocations
        if (!_vData.isPlaceholder && _vData.inActiveSet_Current) {
            // CASE: Active, valid validator
            // We must clamp the amount added to revenue and then offset the appropriate buckets due to the
            // atomicUnstakingPool assuming all revenue is collected in MON.
            AtomicCapital memory _atomicCapital = s_atomicAssets;
            uint128 _atomicLiquidityAvailable = _atomicCapital.allocatedAmount - _atomicCapital.distributedAmount;
            if (_atomicLiquidityAvailable < assetValueOfShares) {
                // We must clamp the tracked revenue to prevent the atomic unstaking pool from thinking
                // it has MON available that is still staked shMON.
                assetValueOfShares = _atomicLiquidityAvailable;
            }

            // NOTE: distributedAmount is offset by revenue. First we increase the distributed amount, and then
            // we increase the revenue - this offset is to make sure that we have have MON liquidity for the atomic
            // unstaking pool from these burned shMON shares.

            _atomicCapital.distributedAmount += assetValueOfShares; // +ContraAsset Cr assetValueOfShares
            // Implied: currentAssets += assetValueOfShares // +Asset Dr assetValueOfShares

            // Persist AtomicCapital changes to storage
            s_atomicAssets = _atomicCapital;

            uint120 _amount120 = assetValueOfShares.toUint120();
            validatorRewardsPtr_N(0, _currentValId).earnedRevenue += _amount120;
            globalRevenuePtr_N(0).earnedRevenue += _amount120;
        } else {
            // CASE: Inactive or placeholder validator

            // No clamp on amount for inactive validator since this revenue does not flow to the
            // atomicLiquidityAvailable.

            uint120 _amount120 = assetValueOfShares.toUint120();
            validatorRewardsPtr_N(0, UNKNOWN_VAL_ID).earnedRevenue += _amount120;
        }
    }

    // ================================================== //
    //     Accounting Handlers - Validators / Crank       //
    // ================================================== //

    /// @notice Verifies that expected staking balances match actual staking balances and then handles any discrepancies
    /// @param valId The validator ID in the Monad staking precompile
    /// @param validatorEpochPtrLast Storage pointer to validator's last epoch data
    function _handleStakeBalanceVerification(uint64 valId, Epoch storage validatorEpochPtrLast) internal {
        // Call the monad staking precompile to get the current balances staked with this validator
        (uint256 _actualActiveStake, uint256 _actualPendingDeposits) = _getStakeInfo(valId);

        // Declare variables and calculate expected values
        uint256 _expectedTotalStake = validatorEpochPtrLast.targetStakeAmount;
        uint256 _actualTotalStake = _actualActiveStake + _actualPendingDeposits;

        uint256 _expectedPendingDeposits;
        uint256 _expectedPendingWithdrawals;
        uint256 _actualPendingWithdrawals;

        // NOTE: Because the shMonad epochs are always at least equal to but could be longer than Monad epochs,
        // we always sum up the pending totals rather than breaking down per epoch and finding a false negative.
        for (int256 i = -4; i < 0; i++) {
            Epoch storage _validatorEpochPtr = validatorEpochPtr_N(i, valId);
            StakingEscrow storage _validatorPendingPtr = validatorPendingPtr_N(i, valId);

            if (_validatorEpochPtr.hasWithdrawal) {
                _expectedPendingWithdrawals += _validatorPendingPtr.pendingUnstaking;
                _actualPendingWithdrawals += _getWithdrawalAmount(valId, _validatorEpochPtr.withdrawalId);
            }

            if (_validatorEpochPtr.hasDeposit) {
                _expectedPendingDeposits += _validatorPendingPtr.pendingStaking;
            }
        }

        // Check the total stake first and emit an event identifying anything unexpected
        if (_actualTotalStake != _expectedTotalStake) {
            emit UnexpectedTotalStakeExpectedIsNotActual(
                valId,
                s_admin.internalEpoch,
                _expectedTotalStake,
                _actualTotalStake,
                _expectedPendingWithdrawals,
                _actualPendingWithdrawals,
                _expectedPendingDeposits,
                _actualPendingDeposits
            );
        }

        // Flag any mismatches between pending withdrawals and actual withdrawals but do not adjust yet - wait until
        // the withdrawal completes.
        if (_expectedPendingWithdrawals != _actualPendingWithdrawals) {
            emit UnexpectedStakeWithdrawalsExpectedIsNotActual(
                valId, s_admin.internalEpoch, _expectedPendingWithdrawals, _actualPendingWithdrawals
            );
        }

        // Track and flag any mismatches in expected deposits but do not adjust them - wait until we the stake
        // is active (and therefore finalized) to adjust.
        if (_expectedPendingDeposits != _actualPendingDeposits) {
            emit UnexpectedPendingStakeExpectedIsNotActual(
                valId, s_admin.internalEpoch, _expectedPendingDeposits, _actualPendingDeposits
            );

            // NOTE: Because multiple Monad epochs can pass during a single ShMonad epoch, it is possible
            // and within expectations for _expectedPendingDeposits to be greater than _pendingDeposits due to
            // the Monad epoch settling what the ShMonad epoch hasn't reached yet. If this is the case, the actual
            // active stake balance should be greater than the expected stake balance by the same amount that the
            // actual pending stake is less than the expected pending stake.
        }

        // Check for underflow and return early if detected - totalStake should include pendingDeposits
        if (_actualPendingDeposits > _expectedTotalStake) {
            emit UnexpectedPendingStakeExceedsExpectedActive(
                valId, s_admin.internalEpoch, _actualPendingDeposits, _expectedTotalStake
            );
            return;
        }

        // Expected active is calculated by subtracting expected pending from expected total, so we subtract expected
        // total by the real actual to compare and flag a mismatch, which let's us identify any actual settled
        // difference.
        uint256 _expectedActiveStake = _expectedTotalStake - _actualPendingDeposits;
        if (_expectedActiveStake != _actualActiveStake) {
            emit UnexpectedActiveStakeExpectedIsNotActual(
                valId, s_admin.internalEpoch, _expectedActiveStake, _actualActiveStake
            );

            // There are many "dilutive" attack vectors through which someone with prior knowledge
            // of slashing or an unexpected "increase" could manipulate balances to profit from this
            // spontaneous change in equity value. Unfortunately, such an actor could still do the attack even without
            // shMonad's delays. Our approach is therefore to avoid scenarios in which this can happen rather than to
            // focus on mitigating the damage in the unlikely (or impossible) event in which it occurs.

            // NOTE: In future versions of shMonad, the validator-specific staking system from testnet will be
            // re-integrated and the unexpected changes to equity will be absorbed first by any validator-specific
            // stakers.
            if (_actualActiveStake > _expectedActiveStake) {
                // Unexpected windfall
                uint256 _delta = _actualActiveStake - _expectedActiveStake;

                // If expected deposits are too high, subtract that delta from the active stake delta
                if (_expectedPendingDeposits > _actualPendingDeposits) {
                    uint256 _pendingDepositDelta = _expectedPendingDeposits - _actualPendingDeposits;
                    _delta = _delta > _pendingDepositDelta ? _delta - _pendingDepositDelta : 0;
                }

                uint128 _delta128 = _delta.toUint128();

                validatorEpochPtrLast.targetStakeAmount += _delta128;

                s_globalCapital.stakedAmount += _delta128; // +Asset Dr _delta
                    // Implied equity += _delta; // +Equity Cr _delta
            } else {
                // NOTE: Slashing is not live yet on Monad.
                uint256 _delta = _expectedActiveStake - _actualActiveStake;

                // If expected deposits are too low, subtract that delta from the active stake delta
                if (_actualPendingDeposits > _expectedPendingDeposits) {
                    uint256 _pendingDepositDelta = _actualPendingDeposits - _expectedPendingDeposits;
                    _delta = _delta > _pendingDepositDelta ? _delta - _pendingDepositDelta : 0;
                }

                // Check the circuit breaker and freeze the protocol if threshold is passed
                if (_delta * SCALE > _totalEquity(true) * SLASHING_FREEZE_THRESHOLD) {
                    globalEpochPtr_N(0).frozen = true; // Freeze crank
                    globalEpochPtr_N(0).closed = true; // Block deposits and non-atomic withdrawals
                        // NOTE: Many apps have dependencies on atomic withdrawals, and the amount of value
                        // that shMonad can lose due to atomic withdrawals is capped at TARGET_FLOAT% of equity.
                        // NOTE: This is currently expected to never be triggered and is meant to catch theoretical
                        // exploits on either shMonad or the staking precompile itself. Once slashing is added to Monad
                        // staking, the circuit breaker thresholds can be reevaluated with bespoke logic.
                }

                // Convert to uint128 while checking for underflow
                uint128 _delta128 = (_delta > _expectedTotalStake ? _delta - _expectedTotalStake : 0).toUint128();

                validatorEpochPtrLast.targetStakeAmount -= _delta128;

                s_globalCapital.stakedAmount -= _delta128; // -Asset Cr _delta
                    // Implied equity -= _delta128; // -Equity Dr _delta
            }
        }
    }

    /// @notice Handles accounting of the initiation of increased stake allocation with a validator
    /// @param amount The amount to allocate
    function _handleInitiateIncreasedAllocation(uint64 valId, uint120 amount) internal {
        // Method called before calling the validator

        // NOTE: This is called after any handleComplete_Allocation methods
        // Push forward but don't rotate the withdrawal ID

        // Update the target amount and flag as not having a withdrawal
        Epoch storage validatorEpochPtr = validatorEpochPtr_N(0, valId);
        validatorEpochPtr.hasDeposit = true;
        validatorEpochPtr.hasWithdrawal = false;
        validatorEpochPtr.crankedInBoundaryPeriod = _inEpochDelayPeriod();

        // Initiate ShMonad MON -> Validator
        validatorPendingPtr_N(0, valId).pendingStaking += amount;
        s_globalPending.pendingStaking += amount;
        s_globalCapital.stakedAmount += amount; // +Asset Dr amount
            // Implied currentAssets -= amount; // -Asset Cr amount
    }

    /// @notice Handles accounting of the completion of increased stake allocation with a validator
    /// @param validatorEpochPtr Storage pointer to validator epoch data
    /// @param validatorPendingPtr Storage pointer to validator pending data
    function _handleCompleteIncreasedAllocation(
        Epoch storage validatorEpochPtr,
        StakingEscrow storage validatorPendingPtr
    )
        internal
    {
        // Complete ShMonad MON -> Validator
        // validatorPendingPtr_N(-2, coinbase).pendingStaking -= amount;
        validatorEpochPtr.hasDeposit = false;
        uint120 _amount = validatorPendingPtr.pendingStaking;
        s_globalPending.pendingStaking -= _amount;
    }

    /// @notice Handles initiation of decreased stake allocation for a validator
    /// @param amount The amount to deallocate
    function _handleInitiateDecreasedAllocation(uint64 valId, uint120 amount) internal {
        // Method called before calling the validator

        // Flag as having a withdrawal
        // NOTE: This is after any handleComplete_Allocation methods
        validatorEpochPtr_N(0, valId).hasWithdrawal = true;
        validatorEpochPtr_N(0, valId).hasDeposit = false;
        validatorEpochPtr_N(0, valId).crankedInBoundaryPeriod = _inEpochDelayPeriod();

        // Initiate Validator MON -> ShMonad
        validatorPendingPtr_N(0, valId).pendingUnstaking += amount;
        s_globalPending.pendingUnstaking += amount;
    }

    /// @notice Handles accounting of the completion of decreased stake allocation with a validator
    /// @param validatorEpochPtr Storage pointer to validator epoch data
    /// @param validatorPendingPtr Storage pointer to validator pending data
    /// @param amount The amount that was deallocated
    function _handleCompleteDecreasedAllocation(
        uint64 valId,
        Epoch storage validatorEpochPtr,
        StakingEscrow storage validatorPendingPtr,
        uint120 amount
    )
        internal
    {
        // Complete Validator MON -> ShMonad
        // NOTE: Global has been cranked already. Validator is in the process of being cranked
        // but the validator storage has not yet been shifted forwards. Therefore,
        // Global_LastLast corresponds with Validator_Last
        uint256 _amount = amount; // Gives us a uint256 and a uint128 version of `amount`
        uint120 _expectedAmount = validatorPendingPtr.pendingUnstaking;

        // Adjust globals with the expected amount
        s_globalPending.pendingUnstaking -= _expectedAmount;

        // Implied currentAssets += _expectedAmount; // +Asset Dr _expectedAmount
        s_globalCapital.stakedAmount -= _expectedAmount; // -Asset Cr _expectedAmount

        // Mark withdrawal as complete
        validatorEpochPtr.hasWithdrawal = false;

        uint120 _surplus;

        // Reconcile the difference between expected and actual amount received.
        if (amount > _expectedAmount) {
            // CASE: Received more than expected
            _surplus = amount - _expectedAmount;

            // Implied currentAssets += _surplus // +Asset Dr _surplus
            // Implied equity += _surplus // +Equity Cr _surplus

            // Update global target w/ the surplus then correct the unstaking journal entry
            validatorPendingPtr.pendingUnstaking += _surplus;

            // Track any surplus as earned staking yield for the validator
            _handleEarnedStakingYield(valId, _surplus);

            // Global accounting entries:
            // Implied currentAssets += _surplus; // +Asset Dr _expectedAmount
            // Implied equity += _surplus // +Equity Cr _surplus
        } else if (amount < _expectedAmount) {
            // CASE: Received less than expected
            uint120 _deficit = _expectedAmount - amount;

            // Update global target w/ the deficit then correct the unstaking journal entry
            validatorPendingPtr.pendingUnstaking -= _deficit;

            // Global accounting entries:
            // Implied currentAssets -= _deficit; // -Asset Cr _deficit
            // Implied equity -= _deficit // -Equity Dr _deficit

            emit UnexpectedDeficitOnUnstakeSettle(_expectedAmount, _amount, 1);
        }

        // Assign the unstaking funds to the 'reservedAssets' account if it does not
        // currently have enough to cover the liabilities
        uint256 _reservedAssets = s_globalCapital.reservedAmount;
        uint256 _currentLiabilities = s_globalLiabilities.currentLiabilities();

        // If any surplus was queued to stake in the `_handleEarnedStakingYield()` call above, this reflects the portion
        // of `_amount` that is not yet queued to stake
        uint120 _unqueuedAmount = uint120(_amount) - _surplus;

        if (_currentLiabilities > _reservedAssets) {
            // CASE: `_currentLiabilities` not fully covered by `_reservedAssets`, so received funds top up
            // `_reservedAssets` first.

            uint256 _shortfall = _currentLiabilities - _reservedAssets;
            if (_shortfall > _unqueuedAmount) {
                s_globalCapital.reservedAmount += _unqueuedAmount; // +Asset Dr _unqueuedAmount
                    // Implied: currentAssets -= _unqueuedAmount; // -Asset Cr _unqueuedAmount
            } else {
                s_globalCapital.reservedAmount += _shortfall.toUint128(); // +Asset Dr _shortfall
                    // Implied: currentAssets -= _shortfall // -Asset Cr _shortfall

                // Queue the remainder to be staked
                globalCashFlowsPtr_N(0).queueToStake += (_unqueuedAmount - _shortfall).toUint120();
            }
        } else {
            // CASE: `_currentLiabilities` is already fully covered by `_reservedAssets`, so all received funds can be
            // queued to stake.

            globalCashFlowsPtr_N(0).queueToStake += _unqueuedAmount;
        }
    }

    /// @notice Handles accounting of earned (realized and received) staking yield for a validator
    /// @param valId The validator's ID
    /// @param amount The earned yield amount
    function _handleEarnedStakingYield(uint64 valId, uint120 amount) internal {
        // Implied currentAssets += _surplus; // +Asset Dr amount
        // Implied equity += _surplus // +Equity Cr amount

        uint256 _stakingCommissionRate = s_admin.stakingCommission;
        uint120 _grossStakingCommission;
        if (_stakingCommissionRate > 0) {
            _grossStakingCommission = (amount * _stakingCommissionRate / BPS_SCALE).toUint120();
            s_admin.totalZeroYieldPayable += _grossStakingCommission; // +Liability Cr _grossStakingCommission
            // Implied currentAssets += _grossStakingCommission // +Asset Dr _grossStakingCommission

            // Track commission taken above by increasing the owner's zero-yield balance
            s_zeroYieldBalances[OWNER_COMMISSION_ACCOUNT] += _grossStakingCommission;

            amount -= _grossStakingCommission;
        }
        // Validator MON -> ShMonad
        validatorRewardsPtr_N(0, valId).earnedRevenue += amount;

        // Validator is being cranked.
        globalRevenuePtr_N(0).earnedRevenue += amount;

        // Queue the rewards to be staked
        globalCashFlowsPtr_N(0).queueToStake += (amount + _grossStakingCommission);
    }

    /// @notice Handles accounting of successful payment / transfer of escrowed MEV rewards to a validator
    /// @param amount The amount successfully paid
    function _handleRewardsPaidSuccess(uint128 amount) internal {
        // ShMonad MON -> Validator
        s_globalCapital.reservedAmount -= amount; // -Asset Cr amount
        s_globalLiabilities.rewardsPayable -= amount; // -Liability Dr amount
    }

    /// @notice Handles accounting of failed payment / transfer of escrowed MEV rewards to a validator
    /// @param valId The validator's ID
    /// @param amount The amount that failed to be paid
    function _handleRewardsPaidFail(uint64 valId, uint120 amount) internal {
        // ShMonad MON -> Validator
        // Shift epoch from last to current
        validatorRewardsPtr_N(-1, valId).rewardsPayable -= amount;
        validatorRewardsPtr_N(0, valId).rewardsPayable += amount;
    }

    /// @notice Handles accounting of rewards redirection when validator payment fails due to ineligibility
    /// @param amount The amount to redirect
    function _handleRewardsRedirect(uint120 amount) internal {
        // ShMonad MON -> ShMonad MON
        // Remove it as rewards / reserved amount and queue it to stake
        s_globalCapital.reservedAmount -= amount; // -Asset Cr amount
        s_globalLiabilities.rewardsPayable -= amount; // -Liability Dr amount

        globalCashFlowsPtr_N(0).queueToStake += amount;
    }

    /// @notice Reconciles atomic pool allocation/utilization with current state during global crank.
    /// @dev Preserves utilization continuity across cranks by proportionally adjusting `distributedAmount`
    /// and `allocatedAmount` to the new target, then books their effects into stake/unstake queues.
    function _settleGlobalNetMONAgainstAtomicUnstaking() internal {
        // Called during the Global crank
        // Get the current utilization rate - we want to make sure the utilization doesn't jump due to being cranked
        (uint128 _oldUtilizedAmount, uint128 _oldAllocatedAmount) = _getAdjustedAmountsForAtomicUnstaking();

        // Handle any overflow that may have been created by updating the targetLiquidityPercent to a smaller
        // percentage of total and potentially overflowing the atomic liquidity pool. Get the new allocated and
        // utilized amounts
        (, uint128 _newAllocatedAmount) = _checkSetNewAtomicLiquidityTarget(_oldUtilizedAmount, _oldAllocatedAmount);

        // Calculate the utilized numbers. Avoid div by zero
        // Keep utilization ratio constant relative to allocation size.
        uint256 _utilizedFraction =
            _oldAllocatedAmount > 0 ? _scaledPercentFromAmounts(_oldUtilizedAmount, _oldAllocatedAmount) : 0;
        uint128 _newUtilizedAmount = _amountFromScaledPercent(_newAllocatedAmount, _utilizedFraction).toUint128();

        // Calculate the deltas
        uint120 _allocatedAmountDelta = Math.dist(_oldAllocatedAmount, _newAllocatedAmount).toUint120();
        uint120 _utilizedAmountDelta = Math.dist(_oldUtilizedAmount, _newUtilizedAmount).toUint120();

        // NOTE: This occurs during the global crank right before the shift of globalCashFlowsPtr_N(0) ->
        // globalCashFlowsPtr_N(-1). Track the adjustments we need to make to the amount being staked.
        uint120 _stakeIn;
        uint120 _unstakeOut;

        if (_newAllocatedAmount > _oldAllocatedAmount) {
            // CASE: We are increasing the atomic unstaking pool's liquidity and therefore decreasing the amount
            // that will be staked next epoch.
            _unstakeOut += _allocatedAmountDelta;
            s_atomicAssets.allocatedAmount += _allocatedAmountDelta;
            // Implied: currentAssets -= _allocatedAmountDelta;
        } else {
            // CASE: We are decreasing the atomic unstaking pool's liquidity and therefore increasing the amount
            // that will be staked next epoch.
            _stakeIn += _allocatedAmountDelta;
            s_atomicAssets.allocatedAmount -= _allocatedAmountDelta; // -Asset Cr _allocatedAmountDelta
                // Implied: currentAssets += _allocatedAmountDelta; // +Asset Dr _allocatedAmountDelta
        }

        // Avoid overflow / underflow - we can't assume that allocatedAmountDelta and utilizedAmountDelta
        // are moving in the same direction
        if (_newUtilizedAmount > _oldUtilizedAmount) {
            // CASE: We are decreasing the atomic unstaking pool's liquidity by increasing the amount
            // we treat as having already been distributed
            _stakeIn += _utilizedAmountDelta;
            s_atomicAssets.distributedAmount += _utilizedAmountDelta; // Contra Asset Cr +_utilizedAmountDelta
                // Implied: currentAssets += _utilizedAmountDelta; // +Asset Dr _utilizedAmountDelta
        } else {
            // CASE: We are increasing the atomic unstaking pool's liquidity by decreasing the amount
            // we treat as having already been distributed
            _unstakeOut += _utilizedAmountDelta;
            s_atomicAssets.distributedAmount -= _utilizedAmountDelta; // -Contra_Asset Dr _utilizedAmountDelta
                // Implied: currentAssets -= _utilizedAmountDelta; // -Asset Cr _utilizedAmountDelta
        }

        // Apply the adjustments to the assets that will be staked next epoch
        // NOTE: we try to offset debits against credits and vice versa when possible because
        // this will reduce the net turnover and therefore the amount of 'unproductive' assets
        CashFlows memory _globalCashFlows = globalCashFlowsPtr_N(0);

        // CASE: stake delta is positive - we need to stake more unstaked assets
        if (_stakeIn > _unstakeOut) {
            uint120 _netStakeIn = _stakeIn - _unstakeOut;
            uint120 _currentQueueForUnstake = _globalCashFlows.queueForUnstake;

            // First try to net the net stake in against the queueForUnstake
            if (_netStakeIn > _globalCashFlows.queueForUnstake) {
                _globalCashFlows.queueForUnstake -= _currentQueueForUnstake; // = 0
                _globalCashFlows.queueToStake += (_netStakeIn - _currentQueueForUnstake);
            } else {
                _globalCashFlows.queueForUnstake -= _netStakeIn;
            }

            // CASE: stake delta is negative - we need to unstake more staked assets.
        } else {
            uint120 _netUnstakeOut = _unstakeOut - _stakeIn;
            uint120 _currentQueueToStake = _globalCashFlows.queueToStake;

            // First try to net the net unstake out against the queueToStake
            if (_netUnstakeOut > _currentQueueToStake) {
                uint120 _netUnavailableAssets = _netUnstakeOut - _currentQueueToStake;

                _globalCashFlows.queueToStake -= _currentQueueToStake; // = 0
                _globalCashFlows.queueForUnstake += _netUnavailableAssets;

                emit UnexpectedAtomicSettlementUnavailableAssets(
                    s_admin.internalEpoch,
                    _netUnavailableAssets,
                    _stakeIn,
                    _unstakeOut,
                    _globalCashFlows.queueToStake,
                    _globalCashFlows.queueForUnstake,
                    s_atomicAssets.distributedAmount,
                    s_atomicAssets.allocatedAmount,
                    uint256(s_atomicAssets.allocatedAmount) - uint256(_netUnavailableAssets)
                );

                // The _netUnavailableAssets take time to unstake and are not currently
                // usable for atomic unstaking, so for now we decrease the allocated amount
                // NOTE: _unstakeOut (and therefore _netUnstakeOut and _netUnavailableAssets)
                // cannot exceed the sum of (net increase to allocatedAmount + net decrease to
                // distributedAmount), making it impossible for this subtraction to break the
                // invariant "allocatedAmount >= distributedAmount."
                s_atomicAssets.allocatedAmount -= uint256(_netUnavailableAssets).toUint128();
            } else {
                _globalCashFlows.queueToStake -= _netUnstakeOut;
            }
        }

        _setStakingQueueStorage(globalCashFlowsPtr_N(0), _globalCashFlows);
    }

    // ================================================== //
    // Accounting Handlers - User Withdrawals + Deposits  //
    // ================================================== //

    /// @notice Handles accounting for user withdrawals from atomic unstaking pool
    /// @param netAmount The withdrawal amount (net of fee)
    /// @param fee The fee amount
    function _accountForWithdraw(uint256 netAmount, uint256 fee) internal override {
        uint256 _allocatedAmount = s_atomicAssets.allocatedAmount;
        uint256 _distributedAmount = s_atomicAssets.distributedAmount;

        // Avoid SLOAD'ing the globalRevenuePtr_N(0) unless necessary. We aren't finding fee here.
        // NOTE: In most cases the slot is already hot because of _getAdjustedAmountsForAtomicUnstaking()
        if (_distributedAmount + netAmount > _allocatedAmount) {
            Revenue storage _globalRevenuePtr = globalRevenuePtr_N(0);
            uint256 _maxEarnedRevenueOffset = _globalRevenuePtr.earnedRevenue - _globalRevenuePtr.allocatedRevenue;

            if (_distributedAmount + netAmount > _allocatedAmount + _maxEarnedRevenueOffset) {
                revert InsufficientBalanceAtomicUnstakingPool(netAmount + fee, _allocatedAmount - _distributedAmount);
            }

            // Offset directly with a credit entry, initiating the unstaking process
            uint120 _shortfallAmount = (_distributedAmount + netAmount - _allocatedAmount).toUint120();
            globalCashFlowsPtr_N(0).queueForUnstake += _shortfallAmount;
            _globalRevenuePtr.allocatedRevenue += _shortfallAmount;

            // Global Accounting entries
            s_atomicAssets.allocatedAmount += _shortfallAmount; // +Asset Dr _shortfallAmount
                // Implied: currentAssets -= _shortfallAmount -Asset Cr _shortfallAmount
        }

        s_atomicAssets.distributedAmount += netAmount.toUint128();
    }

    /// @notice Handles accounting for user deposits
    /// @param assets The deposit amount
    function _accountForDeposit(uint256 assets) internal virtual override {
        // Queue up the necessary staking cranks with the debit entry
        globalCashFlowsPtr_N(0).queueToStake += assets.toUint120();

        // Implied: currentAssets += assets; // +Asset Dr assets
        // Implied: equity += assets; // +Equity Cr assets
    }

    /// @notice Handles accounting after unstake request is made
    /// @param amount The unstake request amount
    function _afterRequestUnstake(uint256 amount) internal virtual override {
        // Queue up the recording unstaking activity, if necessary
        uint120 _amount = amount.toUint120();
        s_globalLiabilities.redemptionsPayable += _amount; // +Liability Cr amount
            // Implied: equity -= amount; // -Equity Dr amount

        // In extreme drawdown scenarios, clamp the allocated amount at remaining equity (excluding recent revenue)
        AtomicCapital memory _atomicAssets = s_atomicAssets;
        uint256 _allocatedAmount = _atomicAssets.allocatedAmount;
        uint256 _remainingEquity = s_globalCapital.totalEquity(s_globalLiabilities, s_admin, address(this).balance);
        uint256 _recentRevenue = _recentRevenueOffset();

        // NOTE: The atomic unstaking pool is vulnerable to "sandwich" attacks if shMonad has a single large depositor
        // who times their unstakes. To counter this, we optimistically reduce utilized and allocated values and at the
        // cost of receiving reduced atomic unstaking fees for that epoch.
        if (_allocatedAmount + _recentRevenue + amount > _remainingEquity) {
            _atomicAssets.allocatedAmount -= _atomicAssets.distributedAmount; // -Asset Cr distributedAmount
            _atomicAssets.distributedAmount = 0; // -ContraAsset Dr distributedAmount
            s_atomicAssets = _atomicAssets;
        }

        globalCashFlowsPtr_N(0).queueForUnstake += amount.toUint120();
    }

    /// @notice Handles accounting of completion of unstake request
    /// @param amount The unstake completion amount
    function _beforeCompleteUnstake(uint128 amount) internal virtual override {
        uint128 reservedAmount = s_globalCapital.reservedAmount;
        if (reservedAmount < amount) {
            // CASE: The reserved amount alone is not enough to meet the redemptions
            // To get the missing amount, we remove it from the atomic liquidity pool.
            uint128 _amountNeededFromAtomicLiquidity = amount - reservedAmount;

            AtomicCapital memory _atomicAssets = s_atomicAssets;
            uint128 _atomicAllocatedAmount = _atomicAssets.allocatedAmount;
            uint128 _atomicUtilizedAmount = _atomicAssets.distributedAmount;

            // The unutilized liquidity in the atomic unstaking pool must be enough to cover the required amount
            require(
                _atomicAllocatedAmount - Math.min(_atomicUtilizedAmount, _atomicAllocatedAmount)
                    >= _amountNeededFromAtomicLiquidity,
                InsufficientReservedLiquidity(amount, reservedAmount)
            );

            // Take the last bit of the withdrawal from the atomic liquidity pool by crediting the allocated asset,
            // offset by debiting the reserved amount.
            s_atomicAssets.allocatedAmount -= _amountNeededFromAtomicLiquidity; // -Asset Cr
                // _amountNeededFromAtomicLiquidity
            s_globalCapital.reservedAmount += _amountNeededFromAtomicLiquidity; // +Asset Dr
                // _amountNeededFromAtomicLiquidity;
        }

        // Reduce the reserved amount and the liability by the amount withdrawn
        s_globalCapital.reservedAmount -= amount; // -Asset Cr amount
        s_globalLiabilities.redemptionsPayable -= amount; // -Liability Dr amount
    }

    // ================================================== //
    //                        Math                        //
    // ================================================== //

    /// @notice Returns atomic pool utilization/allocation adjusted for pending revenue settlement.
    /// @dev Offsets `distributedAmount` by min(currentRevenue, distributed) so fee math doesn't jump at crank.
    /// @return utilizedAmount Adjusted utilized (distributed) amount.
    /// @return allocatedAmount Current allocated amount (unchanged).
    function _getAdjustedAmountsForAtomicUnstaking()
        internal
        view
        returns (uint128 utilizedAmount, uint128 allocatedAmount)
    {
        // Get the initial total amount
        AtomicCapital memory _atomicAssets = s_atomicAssets;
        allocatedAmount = _atomicAssets.allocatedAmount;
        utilizedAmount = _atomicAssets.distributedAmount;

        // If this occurs during the global crank, globalRevenuePtr_N(0) is the epoch that just ended.
        // Otherwise, globalRevenuePtr_N(0) is the ongoing epoch.
        Revenue memory _globalRevenue = globalRevenuePtr_N(0);
        // We must subtracted any already-allocated revenue from the earned revenue to get the amount still
        // available for use by the atomic unstaking pool.
        uint256 _availableRevenue = uint256(_globalRevenue.earnedRevenue - _globalRevenue.allocatedRevenue);

        // The _carryOverAtomicUnstakeIntoQueue() method will only settle a max amount of
        // globalRevenuePtr_N(0).earnedRevenue during the global crank. This means that we can offset that
        // future-settled amount here and avoid any sharp adjustments to the fee whenever we crank
        utilizedAmount -= Math.min(_availableRevenue, utilizedAmount).toUint128();

        return (utilizedAmount, allocatedAmount);
    }

    /// @notice Returns available liquidity and total allocation for atomic unstaking pool.
    /// @dev Mirrors `_getAdjustedAmountsForAtomicUnstaking` adjustment to avoid fee discontinuity in previews.
    /// @return currentAvailableAmount Currently withdrawable amount (allocated - adjusted utilized).
    /// @return totalAllocatedAmount Total allocated (float target) for atomic pool.
    function _getLiquidityForAtomicUnstaking()
        internal
        view
        returns (uint256 currentAvailableAmount, uint256 totalAllocatedAmount)
    {
        // Get the initial total amount
        AtomicCapital memory _atomicAssets = s_atomicAssets;
        totalAllocatedAmount = uint256(_atomicAssets.allocatedAmount);
        uint256 _utilizedAmount = uint256(_atomicAssets.distributedAmount);

        Revenue memory _globalRevenue = globalRevenuePtr_N(0);
        // We must subtracted any already-allocated revenue from the earned revenue to get the amount still
        // available for use by the atomic unstaking pool.
        uint256 _availableRevenue = uint256(_globalRevenue.earnedRevenue - _globalRevenue.allocatedRevenue);

        // The _carryOverAtomicUnstakeIntoQueue() method will only settle a max amount of
        // globalRevenuePtr_N(0).earnedRevenue during the global crank, which also resets
        // globalRevenuePtr_N(0).earnedRevenue to zero. This means that we can offset that
        // future-settled amount here and avoid any sharp adjustments to the fee whenever we crank
        _utilizedAmount -= Math.min(_availableRevenue, _utilizedAmount).toUint128();

        currentAvailableAmount = totalAllocatedAmount - _utilizedAmount;

        return (currentAvailableAmount, totalAllocatedAmount);
    }

    // ================================================== //
    //                    Percent Math                   //
    // ================================================== //

    /// @notice Gets target liquidity percentage scaled to `SCALE` (1e18).
    /// @dev Converts `s_admin.targetLiquidityPercentage` (BPS) → scaled (1e18).
    /// @return Scaled target percentage in 1e18 units.
    function _scaledTargetLiquidityPercentage() internal view returns (uint256) {
        return s_admin.targetLiquidityPercentage * SCALE / BPS_SCALE;
    }

    /// @notice Converts scaled (1e18) target liquidity percentage to unscaled BPS.
    /// @param scaledTargetLiquidityPercentage Target liquidity percentage in 1e18 units.
    /// @return Unscaled percentage in BPS.
    function _unscaledTargetLiquidityPercentage(uint256 scaledTargetLiquidityPercentage)
        internal
        pure
        returns (uint16)
    {
        return (scaledTargetLiquidityPercentage * BPS_SCALE / SCALE).toUint16();
    }

    /// @notice Computes a scaled percentage from two unscaled amounts.
    /// @dev Returns `numerator * SCALE / denominator`. Caller must ensure `denominator > 0`.
    /// @param unscaledNumeratorAmount Numerator amount (unscaled).
    /// @param unscaledDenominatorAmount Denominator amount (unscaled, must be > 0).
    /// @return Scaled percentage in 1e18 units.
    function _scaledPercentFromAmounts(
        uint256 unscaledNumeratorAmount,
        uint256 unscaledDenominatorAmount
    )
        internal
        pure
        returns (uint256)
    {
        return unscaledNumeratorAmount * SCALE / unscaledDenominatorAmount;
    }

    /// @notice Applies a scaled percentage to a gross amount.
    /// @dev Returns `grossAmount * scaledPercent / SCALE`.
    /// @param grossAmount Gross (unscaled) amount.
    /// @param scaledPercent Percentage in 1e18 units.
    /// @return Resulting unscaled amount after applying percentage.
    function _amountFromScaledPercent(uint256 grossAmount, uint256 scaledPercent) internal pure returns (uint256) {
        return grossAmount * scaledPercent / SCALE;
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    /// @notice Returns true if global crank can run based on basic readiness checks.
    /// @dev Ready when: contract not frozen, all validators cranked, and new epoch available. This is essentially a
    /// view function but cannot be declared as such because the Monad staking precompile absolutely hates when we call
    /// its function calls view or staticcall.
    function isGlobalCrankAvailable() external returns (bool) {
        if (globalEpochPtr_N(0).frozen) return false;

        return s_nextValidatorToCrank == LAST_VAL_ID && globalEpochPtr_N(0).epoch < _getEpoch();
    }

    /// @notice Returns true if a specific validator can be cranked based on basic checks.
    /// @dev Ready when: contract not frozen, validatorId is valid and last epoch not cranked.
    function isValidatorCrankAvailable(uint64 validatorId) external view returns (bool) {
        if (globalEpochPtr_N(0).frozen) return false;
        if (validatorId == 0 || validatorId == UNKNOWN_VAL_ID) return false;
        address _coinbase = _validatorCoinbase(validatorId);
        if (_coinbase == address(0)) return false;
        return !validatorEpochPtr_N(-1, validatorId).wasCranked;
    }

    /// @notice Returns current working capital snapshot (no structs).
    /// @return stakedAmount Total staked amount
    /// @return reservedAmount Total reserved amount
    function getWorkingCapital() external view returns (uint128 stakedAmount, uint128 reservedAmount) {
        WorkingCapital memory _workingCapital = s_globalCapital;
        return (_workingCapital.stakedAmount, _workingCapital.reservedAmount);
    }

    /// @notice Returns atomic capital snapshot (no structs).
    /// @return allocatedAmount Total allocated amount for atomic pool
    /// @return distributedAmount Amount already distributed to atomic unstakers
    function getAtomicCapital() external view returns (uint128 allocatedAmount, uint128 distributedAmount) {
        AtomicCapital memory _atomicCapital = s_atomicAssets;
        return (_atomicCapital.allocatedAmount, _atomicCapital.distributedAmount);
    }

    /// @notice Returns global pending escrow snapshot (no structs).
    /// @return pendingStaking Pending staking amount
    /// @return pendingUnstaking Pending unstaking amount
    function getGlobalPending() external view returns (uint120 pendingStaking, uint120 pendingUnstaking) {
        StakingEscrow memory _stakingEscrow = s_globalPending;
        return (_stakingEscrow.pendingStaking, _stakingEscrow.pendingUnstaking);
    }

    /// @notice Returns selected epoch global cash flows (no structs).
    /// @param epochPointer Epoch selector: -2=LastLast, -1=Last, 0=Current, 1=Next (others wrap modulo tracking)
    /// @return queueToStake Queue to stake for selected epoch
    /// @return queueForUnstake Queue for unstake for selected epoch
    function getGlobalCashFlows(int256 epochPointer)
        external
        view
        returns (uint120 queueToStake, uint120 queueForUnstake)
    {
        CashFlows memory _cashFlows = globalCashFlowsPtr_N(epochPointer);
        return (_cashFlows.queueToStake, _cashFlows.queueForUnstake);
    }

    /// @notice Returns selected epoch global rewards (no structs).
    /// @param epochPointer Epoch selector: -2=LastLast, -1=Last, 0=Current, 1=Next (others wrap modulo tracking)
    /// @return allocatedRevenue Revenue that has been allocated to the atomic unstaking pool this epoch
    /// @return earnedRevenue Earned revenue for selected epoch
    function getGlobalRevenue(int256 epochPointer)
        external
        view
        returns (uint120 allocatedRevenue, uint120 earnedRevenue)
    {
        Revenue memory _revenue = globalRevenuePtr_N(epochPointer);
        return (_revenue.allocatedRevenue, _revenue.earnedRevenue);
    }

    /// @notice Returns selected global epoch data (no structs).
    /// @param epochPointer Epoch selector: -2=LastLast, -1=Last, 0=Current, 1=Next (others wrap modulo tracking)
    function getGlobalEpoch(int256 epochPointer)
        external
        view
        returns (
            uint64 epoch,
            uint8 withdrawalId,
            bool hasWithdrawal,
            bool hasDeposit,
            bool crankedInBoundaryPeriod,
            bool wasCranked,
            bool frozen,
            bool closed,
            uint128 targetStakeAmount
        )
    {
        Epoch memory _epoch = globalEpochPtr_N(epochPointer);
        return (
            _epoch.epoch,
            _epoch.withdrawalId,
            _epoch.hasWithdrawal,
            _epoch.hasDeposit,
            _epoch.crankedInBoundaryPeriod,
            _epoch.wasCranked,
            _epoch.frozen,
            _epoch.closed,
            _epoch.targetStakeAmount
        );
    }

    /// @notice Returns internal epoch counter used by StakeTracker.
    function getInternalEpoch() external view returns (uint64) {
        return s_admin.internalEpoch;
    }

    /// @notice Returns selected epoch frozen/closed status convenience flags.
    /// @param epochPointer Epoch selector: -2=LastLast, -1=Last, 0=Current, 1=Next (others wrap modulo tracking)
    function getGlobalStatus(int256 epochPointer) external view returns (bool frozen, bool closed) {
        Epoch memory _epoch = globalEpochPtr_N(epochPointer);
        return (_epoch.frozen, _epoch.closed);
    }

    /// @notice Returns the current target liquidity percentage scaled to 1e18.
    function getScaledTargetLiquidityPercentage() external view returns (uint256) {
        return _scaledTargetLiquidityPercentage();
    }

    /// @notice Returns the global amount currently eligible to be unstaked.
    function getGlobalAmountAvailableToUnstake() external view returns (uint256 amount) {
        return StakeAllocationLib.getGlobalAmountAvailableToUnstake(s_globalCapital, s_globalPending);
    }

    /// @notice Returns current-assets per AccountingLib.
    function getCurrentAssets() external view returns (uint256) {
        return s_globalCapital.currentAssets(s_atomicAssets, address(this).balance);
    }

    // ================================================== //
    //                 Overriding Methods                 //
    // ================================================== //
    /// @notice Returns the Monad staking precompile interface
    /// @return IMonadStaking The staking precompile interface
    function STAKING_PRECOMPILE() public pure override(ValidatorRegistry) returns (IMonadStaking) {
        return STAKING;
    }

    /// @notice Modifier that sets up transient capital for unstaking settlement
    modifier expectsUnstakingSettlement() override {
        _setTransientCapital(CashFlowType.AllocationReduction, 0);
        _;
        _clearTransientCapital();
    }

    /// @notice Modifier that sets up transient capital for rewards settlement
    modifier expectsStakingRewards() override {
        _setTransientCapital(CashFlowType.Revenue, 0);
        _;
        _clearTransientCapital();
    }
}
