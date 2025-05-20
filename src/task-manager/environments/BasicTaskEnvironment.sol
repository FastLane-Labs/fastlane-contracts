// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { TaskExecutionBase } from "../common/ExecutionBase.sol";

/// @title BasicTaskEnvironment
/// @notice A helper environment that provides pre-execution validation and execution logging
/// @dev Adds safety checks and event logging around task execution while maintaining isolation
contract BasicTaskEnvironment is TaskExecutionBase {
    /// @notice Event emitted before task execution
    event TaskStarted(address target, bytes data);

    /// @notice Event emitted after successful task execution
    event TaskCompleted(address target, bool success);

    /// @notice Custom error for zero target address
    error ZeroTargetAddress();

    /// @notice Custom error for empty calldata
    error EmptyCalldata();

    constructor(address taskManager_) TaskExecutionBase(taskManager_) { }

    /// @notice Executes a task with validation and logging
    /// @dev Only callable by the TaskManager contract
    /// @param taskData The encoded task data containing target address and calldata
    /// @return success True if the task execution succeeded, false otherwise
    function executeTask(bytes calldata taskData) external onlyTaskManager returns (bool) {
        // Decode target and calldata from the packed taskData
        (address target, bytes memory data) = abi.decode(taskData, (address, bytes));

        // Add custom validation
        if (target == address(0)) revert ZeroTargetAddress();
        if (data.length == 0) revert EmptyCalldata();

        // Emit pre-execution event with more details
        emit TaskStarted(target, data);

        // Execute the task
        bool success;
        bytes memory result;
        (success, result) = target.call(data);

        // Emit post-execution event with more details
        emit TaskCompleted(target, success);

        // If the call failed, revert with the error message
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        return success;
    }

    receive() external payable { }
}
