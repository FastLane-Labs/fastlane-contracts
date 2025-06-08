// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { NoncesUpgradeable } from "@openzeppelin-upgradeable/contracts/utils/NoncesUpgradeable.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IShMonad } from "../../shmonad/interfaces/IShMonad.sol";
import { Task, Size, Depth, LoadBalancer, Tracker, Trackers, TaskMetadata } from "../types/TaskTypes.sol";
import { TaskExecutor } from "./Executor.sol";
import { TaskFactory } from "./Factory.sol";
import { TaskBits } from "../libraries/TaskBits.sol";

/// @title TaskScheduler
/// @notice Handles task scheduling and queue management
/// @dev Core component responsible for:
/// 1. Task Scheduling:
///    - Validates scheduling parameters
///    - Determines task size and gas requirements
///    - Manages task queue insertion
///
/// 2. Task Management:
///    - Handles task cancellation
///    - Manages task ownership and permissions
///    - Tracks task execution status
///
/// 3. Bond Management:
///    - Handles bond collection for scheduled tasks
///    - Manages bond transfers and accounting
///    - Ensures economic security of the system
///
/// TODO: Consider implementing task priority levels
/// TODO: Add support for conditional task scheduling

abstract contract TaskScheduler is TaskExecutor, TaskFactory, NoncesUpgradeable {
    using TaskBits for bytes32;
    using SafeTransferLib for address;

    /// @notice Constructor to set immutable variables
    /// @param shMonad The address of the shMonad contract
    /// @param policyId The policy ID for the task manager
    constructor(address shMonad, uint64 policyId) TaskExecutor(shMonad, policyId) { }

    /// @notice Cancel a task
    /// @param taskId The task ID to cancel
    function _cancelTask(bytes32 taskId) internal onlyCancelAuthority(taskId) {
        // Get mimic address from taskId
        (address _environment, uint64 _initBlock, uint16 _initIndex, Size _size,) = taskId.unpack();

        // Verify the task queue exists and index is valid
        bytes32 _currentTaskId = _loadTaskId(_size, _initBlock, _initIndex);
        if (_currentTaskId == bytes32(0)) {
            revert TaskNotFound(taskId);
        }

        // See if task is cancelled
        (,,,, bool _cancelled) = _currentTaskId.unpack();

        // Then verify task is still active
        if (_cancelled) {
            revert TaskAlreadyCancelled(taskId);
        }

        // Check if task has been executed using internal function
        if (_isTaskExecuted(_initBlock, _initIndex, _size)) {
            revert TaskAlreadyExecuted(taskId);
        }

        // Update the task with the cancelled status
        bytes32 _newTaskId = TaskBits.pack(_environment, _initBlock, _initIndex, _size, true);
        _addTaskId(_newTaskId, _size, _initBlock, _initIndex);

        emit TaskCancelled(taskId, msg.sender);
    }

    function _buildTaskMetadata(
        uint256 taskGasLimit,
        address owner
    )
        internal
        returns (TaskMetadata memory taskMetaData)
    {
        taskMetaData.owner = owner;
        taskMetaData.nonce = uint64(_useNonce(owner));

        // Revert if larger than large_gas
        if (taskGasLimit > LARGE_GAS) revert TaskGasTooLarge(taskGasLimit);
        taskMetaData.size = _sizeFromGasLimit(taskGasLimit);
    }

    /// @dev Get quote for task execution at target block
    function _getTaskQuote(
        Size size,
        uint64 targetBlock
    )
        internal
        view
        returns (Trackers memory trackers, uint256 executionCost)
    {
        // Validate scheduling window - must be at least 2 blocks in future but not too far
        _validateBlock(targetBlock);

        // Load the trackers so we can generate a quote
        trackers = _forecastTrackers(targetBlock, size);

        // Get the execution cost (adjusted by _FEE_SIG_FIG)
        executionCost = _getExecutionQuote(trackers);
    }

    /// @notice Validate task parameters before scheduling
    /// @param targetBlock The block to schedule for
    function _validateBlock(uint64 targetBlock) internal view {
        // Validate target block - must be in future but not too far
        uint64 _currentBlock = uint64(block.number);
        if (targetBlock <= _currentBlock) {
            revert TaskValidation_TargetBlockInPast(targetBlock, _currentBlock);
        }

        if (targetBlock > _currentBlock + MAX_SCHEDULE_DISTANCE) {
            revert TaskValidation_TargetBlockTooFar(targetBlock, _currentBlock);
        }
    }

    /// @notice Validate task parameters before scheduling
    /// @param implementation The task's bytecode to validate
    function _validateImplementation(address implementation) internal view {
        // Validate target address
        if (implementation == address(0) || implementation == address(this)) {
            revert TaskValidation_InvalidTargetAddress();
        }

        /*
        // Allowing late deployment of implementation might have nice
        // MEV / privacy features.

        if (implementation.code.length == 0) {
            revert TaskValidation_InvalidTargetAddress();
        }
        */
    }

    /// @notice Take payment from user for task execution
    /// @param from The address to take payment from
    /// @param amount The amount to take
    function _takeMonad(address from, uint256 amount) internal {
        // Revert if not enough MON
        if (msg.value < amount) {
            revert InvalidPaymentAmount(amount, msg.value);
        }
        // Deposit the MON to get shMON
        (bool _success, bytes memory _returnData) =
            SHMONAD.call{ value: amount }(abi.encodeCall(IERC4626.deposit, (amount, address(this))));
        if (!_success) {
            assembly {
                revert(add(_returnData, 32), mload(_returnData))
            }
        }

        if (msg.value > amount) {
            from.safeTransferETH(msg.value - amount);
        }
    }

    /// @notice Take bonded shMONAD from user, transfer it to task manager, and convert to unbonded form
    /// @param from The address to take bonded tokens from
    /// @param shMonAmount The amount of tokens to take and unbond
    /// @dev First transfers bonded tokens to task manager, then unbonds them to be used for task payment
    function _takeBondedShmonad(address from, uint256 shMonAmount) internal {
        // Withdraw the tokens from the bonded policy and give them unbonded to the task manager
        (bool _success, bytes memory _returnData) = SHMONAD.call{ gas: gasleft() }(
            abi.encodeCall(IShMonad.agentTransferToUnbonded, (POLICY_ID, from, address(this), shMonAmount, 0, false))
        );
        if (!_success) {
            assembly {
                revert(add(_returnData, 32), mload(_returnData))
            }
        }
    }

    /// @notice Internal function to check if a task has been executed
    /// @param _initBlock The block the task was scheduled for
    /// @param _initIndex The index in the block
    /// @param _size The size of the task
    /// @return executed Bool for whether or not the task was executed
    function _isTaskExecuted(uint64 _initBlock, uint16 _initIndex, Size _size) internal view returns (bool executed) {
        // Load up the current task head
        LoadBalancer memory loadBalancer = S_loadBalancer;
        uint64 _blockHead;
        if (_size == Size.Large) {
            _blockHead = loadBalancer.activeBlockLarge;
        } else if (_size == Size.Medium) {
            _blockHead = loadBalancer.activeBlockMedium;
        } else {
            _blockHead = loadBalancer.activeBlockSmall;
        }

        // CASE: We've finished executing that block
        if (_initBlock < _blockHead) {
            return true;

            // CASE: We haven't started executing that block
        } else if (_initBlock > _blockHead) {
            return false;
        }

        // CASE: We're in the middle of executing that block
        Tracker memory _tracker = S_metrics[_size][Depth.B][uint256(_initBlock)];

        // CASE: If all tasks in this block have been executed, consider them all executed.
        if (_tracker.totalTasks > 0 && _tracker.executedTasks == _tracker.totalTasks) {
            return true;
        }

        // Otherwise, check if the task has been executed.
        return uint256(_tracker.executedTasks) > uint256(_initIndex);
    }
}
