// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Task, Size, Depth, LoadBalancer, Tracker, Trackers } from "../types/TaskTypes.sol";
import { TaskPricing } from "./Pricing.sol";
import { TaskBits } from "../libraries/TaskBits.sol";
import { IShMonad } from "../../shmonad/interfaces/IShMonad.sol";
import { Directory } from "../../common/Directory.sol";
import { TaskAccountingMath } from "../libraries/TaskAccountingMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TaskExecutor
/// @notice Handles task execution and fee distribution
/// @dev Core component responsible for:
/// 1. Task Execution:
///    - Manages gas limits for different task sizes
///    - Handles task iteration and completion
///    - Processes multiple tasks in a single transaction
///
/// 2. Fee Management:
///    - Distributes fees between executors and protocol
///    - Handles bond transfers and accounting
///    - Manages execution reimbursements
///
/// 3. Gas Optimization:
///    - Maintains gas reserves for cleanup operations
///    - Optimizes iteration based on available gas
///    - Prevents gas exhaustion during execution
///
/// TODO: Consider implementing batch execution optimizations
/// TODO: Add support for partial fee refunds on task failure
abstract contract TaskExecutor is TaskPricing {
    using TaskBits for bytes32;

    constructor(address shMonad, uint64 policyId) TaskPricing(shMonad, policyId) { }

    // @dev Schedule a task with size determination and tracking updates
    function _checkRescheduleTask(Trackers memory trackers) internal returns (Trackers memory) {
        bytes32 _taskId = T_currentTaskId;
        (, uint64 _targetBlock, uint16 _initIndex, Size _size,) = _taskId.unpack();

        if (_targetBlock <= block.number) return trackers;

        // Load the fee and then clear it
        uint256 _executionCostUnadj = t_executionFee;
        delete t_executionFee;

        // Load scheduling trackers and merge with existing trackers in case there's overwrite
        Trackers memory _rescheduleTrackers = _swapInRescheduleTrackers(trackers, _targetBlock, _size);

        // Update trackers and load balancer
        uint16 _taskIndexInBlock;
        (_rescheduleTrackers, _taskIndexInBlock) = _markTaskScheduled(_rescheduleTrackers, _executionCostUnadj);

        require(_taskIndexInBlock == _initIndex, "ERR-UnmatchedIndex");

        // Push task to the end of the queue
        S_taskIdQueue[_size][_targetBlock].push(_taskId);

        // Swap back in the execution trackers
        trackers = _swapOutRescheduleTrackers(_rescheduleTrackers, trackers);

        emit TaskScheduled(_taskId, msg.sender, _targetBlock);

        return trackers;
    }

    /// @notice Main execution function that processes tasks across different queues
    /// @dev Handles task execution in the following sequence:
    /// 1. Initial gas check to ensure sufficient gas for execution
    /// 2. Initializes trackers for performance monitoring
    /// 3. Processes queues while gas remains, starting with largest tasks
    /// 4. Handles fee payouts and state updates
    ///
    /// Gas requirements:
    /// - SMALL_GAS for task execution
    /// - ITERATION_BUFFER for iteration overhead
    /// - targetGasReserve for post-execution operations
    /// - 5000 for final cleanup
    ///
    /// @param payoutAddress Address to receive execution fees
    /// @param targetGasReserve Gas to reserve for post-execution operations
    /// @return feesSharesEarned Total fees earned from task execution in shares
    function _execute(address payoutAddress, uint256 targetGasReserve) internal returns (uint256 feesSharesEarned) {
        // Return early if there is not enough gas available
        // We need:
        // - SMALL_GAS for task execution
        // - ITERATION_BUFFER for iteration overhead
        // - targetGasReserve (requested by executor)
        // - 5000 for final operations
        if (gasleft() < SMALL_GAS + ITERATION_BUFFER + targetGasReserve + 5000) {
            return 0;
        }

        // Initial allocation
        Trackers memory _trackers = _initTrackers(targetGasReserve);
        uint256 _minLeftoverGas = _maxGasFromSize(_trackers.size) + ITERATION_BUFFER + targetGasReserve + 5000;

        // Process queues while we have gas
        do {
            // Run the current queue and accumulate fees
            uint256 feesFromThisQueue;
            (_trackers, feesFromThisQueue) = _runQueue(_trackers, _minLeftoverGas);
            feesSharesEarned += feesFromThisQueue;

            if (_trackers.updateAllTrackers) {
                _trackers.updateAllTrackers = false;
                _storeAllTrackers(_trackers);
            }

            // Break already if we're on the small queue and there are no more tasks available
            if (_trackers.size == Size.Small) {
                break;
            }
            // Try to reallocate to a different queue
            _trackers = _reallocateLoad(_trackers);
            _minLeftoverGas = _maxGasFromSize(_trackers.size) + ITERATION_BUFFER + targetGasReserve + 5000;
        } while (gasleft() > _minLeftoverGas);

        // Handle payouts if we earned any fees
        if (feesSharesEarned > 0) {
            _handleExecutionFees(payoutAddress, feesSharesEarned);
        }

        // Store final state
        //if (_trackers.updateAllTrackers) {
        //    _trackers.updateAllTrackers = false;
        //    _storeAllTrackers(_trackers);
        //}
        if (_trackers.updateLoadBalancer) {
            _storeLoadBalancer(_trackers);
        }

        return feesSharesEarned;
    }

    /// @notice Processes tasks in the current queue until gas runs low or no tasks remain
    /// @dev For each iteration:
    /// 1. Checks if current block is complete and needs iteration
    /// 2. Loads and executes next task if available
    /// 3. Handles reimbursement and updates metrics
    /// 4. Continues until gas limit or no more tasks
    ///
    /// Gas requirements per iteration:
    /// - requiredGas based on task size
    /// - ITERATION_BUFFER for overhead
    /// - targetGasReserve for cleanup
    /// - 5000 for final operations
    ///
    /// @param trackers Current state of task metrics and execution progress
    /// @param targetGasReserve Gas to reserve for post-execution operations
    /// @return Updated trackers state and fees earned from execution
    function _runQueue(
        Trackers memory trackers,
        uint256 targetGasReserve
    )
        internal
        returns (Trackers memory, uint256 feesEarned)
    {
        // Process tasks while we have gas and tasks available
        while (gasleft() > targetGasReserve) {
            // Check if we've exhausted tasks in current block
            if (trackers.b.executedTasks >= trackers.b.totalTasks) {
                trackers = _iterate(trackers, targetGasReserve, uint64(block.number - 1));
            }

            // First try to iterate if needed
            if (!trackers.tasksAvailable) {
                break;
            }

            // Load and execute the next task
            bytes32 taskId = _loadNextTask(trackers);
            (address environment,,, Size taskSize, bool cancelled) = taskId.unpack();

            // Calculate reimbursement (prior to call or reschedule accounting)
            uint256 _thisIterationPayoutUnadj = _getReimbursementAmount(trackers);

            // Execute
            if (!cancelled) {
                T_currentTaskId = taskId;
                environment.call{ gas: _maxGasFromSize(taskSize) }("task");

                // Reload trackers and finish scheduling in case of reschedule
                trackers = _checkRescheduleTask(trackers);
            }

            // Mark task complete using the net fee value
            trackers = _markTaskComplete(trackers, _thisIterationPayoutUnadj);
            // Subtract 1 to account for rounding error
            feesEarned += (_thisIterationPayoutUnadj * _FEE_SIG_FIG);
        }

        return (trackers, feesEarned);
    }

    /// @notice Loads the next task from the queue for execution
    /// @dev Retrieves task ID from storage based on current block and execution count
    /// @param trackers Current execution state containing block number and metrics
    /// @return taskId The ID of the next task to execute
    function _loadNextTask(Trackers memory trackers) internal view returns (bytes32 taskId) {
        taskId = S_taskIdQueue[trackers.size][trackers.blockNumber][trackers.b.executedTasks];
    }

    /// @notice Determines task size category based on gas limit
    /// @dev Assumes gas limit has already been validated (taskGasLimit <= LARGE_GAS)
    /// @param taskGasLimit Gas limit specified for the task
    /// @return size Task size category (Small, Medium, or Large)
    function _sizeFromGasLimit(uint256 taskGasLimit) internal pure returns (Size size) {
        // NOTE: Assumes that the following has already been checked:
        //      if (taskGasLimit > LARGE_GAS) revert TaskGasTooLarge(taskGasLimit);
        //
        size = taskGasLimit > MEDIUM_GAS ? Size.Large : (taskGasLimit > SMALL_GAS ? Size.Medium : Size.Small);
    }

    /// @notice Handles distribution of execution fees and bond accounting
    /// @dev Splits fees between executor and protocol, updates bond balances
    /// @param executor Address of the task executor
    /// @param payoutInShares Total amount to distribute in shares
    function _handleExecutionFees(address executor, uint256 payoutInShares) internal {
        uint256 validatorPayout = Math.mulDiv(
            payoutInShares, TaskAccountingMath.VALIDATOR_FEE_BPS, TaskAccountingMath.BPS_SCALE, Math.Rounding.Floor
        );

        uint256 protocolPayout = Math.mulDiv(
            payoutInShares, TaskAccountingMath.PROTOCOL_FEE_BPS, TaskAccountingMath.BPS_SCALE, Math.Rounding.Floor
        );

        uint256 executorPayout = payoutInShares - validatorPayout - protocolPayout;

        // First distribute validator payout
        bool success;
        if (block.coinbase != address(0)) {
            (success,) =
                SHMONAD.call{ gas: gasleft() }(abi.encodeCall(IERC20.transfer, (block.coinbase, validatorPayout)));
            if (!success) {
                revert ValidatorReimbursementFailed(block.coinbase, validatorPayout);
            }
        } else {
            // Add validator payout to protocol payout if coinbase is not set
            protocolPayout += validatorPayout;
        }

        // Then distribute executor payout
        (success,) = SHMONAD.call{ gas: gasleft() }(abi.encodeCall(IERC20.transfer, (executor, executorPayout)));
        if (!success) {
            revert ExecutorReimbursementFailed(executor, executorPayout);
        }
        emit ExecutorReimbursed(executor, executorPayout);

        // Then boost yield with protocol fee instead
        (success,) =
            SHMONAD.call{ gas: gasleft() }(abi.encodeWithSelector(bytes4(0x2eac4115), protocolPayout, address(this)));
        if (!success) {
            revert BoostYieldFailed(address(this), protocolPayout);
        }
        emit ProtocolFeeCollected(protocolPayout);
    }
}
