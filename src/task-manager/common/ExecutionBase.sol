// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title TaskExecutionBase
/// @notice Base contract for task execution environments with common functionality
/// @dev This is a base contract for task execution environments with common functionality
abstract contract TaskExecutionBase {
    /// @notice The task manager contract
    address internal immutable TASK_MANAGER;

    /// @dev Constructor to set task manager
    constructor(address taskManager_) {
        require(taskManager_ != address(0), "TaskExecutionBase: zero task manager");
        TASK_MANAGER = taskManager_;
    }

    /// @dev Ensures only task manager can call
    modifier onlyTaskManager() {
        require(msg.sender == TASK_MANAGER, "TaskExecutionBase: only task manager");
        _;
    }

    /// @notice Gets the task manager address
    /// @return The task manager address
    function _taskManager() internal view returns (address) {
        return TASK_MANAGER;
    }
}
