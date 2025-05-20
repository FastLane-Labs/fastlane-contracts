// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ITaskExecutionEnvironment
/// @notice Interface for isolated task execution environments
/// @dev Each user gets their own dedicated environment for task execution to ensure isolation and security
interface ITaskExecutionEnvironment {
    /// @notice Executes a task within the isolated environment
    /// @dev Only callable by the TaskManager contract
    /// @param taskData The encoded task data containing target address and calldata
    /// @return success True if the task execution succeeded, false otherwise
    function executeTask(bytes calldata taskData) external returns (bool success);
}
