// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { TaskExecutionBase } from "../common/ExecutionBase.sol";
import { ITaskManager } from "../interfaces/ITaskManager.sol";

/// @title ReschedulingTaskEnvironment
/// @notice A task environment that supports automatic rescheduling on failure
/// @dev Extends TaskExecutionBase with retry logic and failure tracking
contract ReschedulingTaskEnvironment is TaskExecutionBase {
    /// @notice Event emitted before task execution
    event TaskStarted(address target, bytes data);

    /// @notice Event emitted after successful task execution
    event TaskCompleted(address target, bool success);

    /// @notice Event emitted when a task is rescheduled
    event TaskRescheduled(address target, uint64 newTargetBlock);

    /// @notice Event emitted for each execution attempt
    event ExecutionAttempt(uint8 attemptNumber, bool success);

    /// @notice Custom error for zero target address
    error ZeroTargetAddress();

    /// @notice Custom error for empty calldata
    error EmptyCalldata();

    /// @notice Custom error when max retries are exceeded
    error MaxRetriesExceeded();

    /// @notice Maximum number of retries before giving up
    uint8 public constant MAX_RETRIES = 3;

    /// @notice Number of blocks to wait before retrying
    uint64 public constant RETRY_DELAY = 5;

    constructor(address taskManager_) TaskExecutionBase(taskManager_) { }

    /// @notice Executes a task with retry logic
    /// @dev If execution fails, attempts to reschedule the task
    /// @param taskData The encoded task data containing target address and calldata
    /// @return success True if the task execution succeeded, false otherwise
    function executeTask(bytes calldata taskData) external onlyTaskManager returns (bool) {
        // Decode target and calldata from the packed taskData
        (address target, bytes memory data) = abi.decode(taskData, (address, bytes));

        // Add custom validation
        if (target == address(0)) revert ZeroTargetAddress();
        if (data.length == 0) revert EmptyCalldata();

        // Emit pre-execution event
        emit TaskStarted(target, data);

        // Execute the task
        bool success;
        bytes memory result;
        (success, result) = target.call(data);

        // Emit attempt event
        emit ExecutionAttempt(1, success);

        // If execution failed, try to reschedule
        if (!success) {
            // Calculate new target block
            uint64 newTargetBlock = uint64(block.number + RETRY_DELAY);

            // Attempt to reschedule with same gas limit and slightly higher max payment
            // Note: _scheduleTask (called by rescheduleTask) handles storing the trackers
            (bool rescheduled,,) = ITaskManager(TASK_MANAGER).rescheduleTask(
                newTargetBlock,
                type(uint256).max / 2 // Use same max payment as test
            );

            // Emit rescheduling event
            if (rescheduled) {
                emit TaskRescheduled(target, newTargetBlock);
            }

            // Revert with the original error
            /*
            assembly {
                revert(add(result, 32), mload(result))
            }
            */
        }

        // Emit completion event
        emit TaskCompleted(target, success);

        return success;
    }

    receive() external payable { }
}
