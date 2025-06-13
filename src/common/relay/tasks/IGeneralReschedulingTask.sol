// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITaskManager } from "../../../task-manager/interfaces/ITaskManager.sol";
import { IShMonad } from "../../../shmonad/interfaces/IShMonad.sol";

/// @title IGeneralReschedulingTask
/// @notice Interface for task rescheduling functionality in the FastLane relay system
/// @dev Defines the contract interface for managing task execution and rescheduling
interface IGeneralReschedulingTask {
    /// @notice Executes a task on a target contract
    /// @param target Address of the contract to execute the task on
    /// @param data Calldata to execute on the target contract
    function execute(address target, bytes calldata data) external;

    /// @notice Marks a target for task execution and stores its data
    /// @param target Address of the target contract
    /// @param data Calldata to be executed
    function markTarget(address target, bytes calldata data) external;

    /// @notice Retrieves the stored target, task, and calldata hash
    /// @return target Address of the target contract
    /// @return task Address of the task contract
    /// @return calldataHash Hash of the stored calldata
    function getTargetTaskCalldataHash() external view returns (address target, address task, bytes32 calldataHash);

    /// @notice Validates if provided target and data match stored values
    /// @param target Address to validate against stored target
    /// @param data Calldata to validate against stored hash
    /// @return validMatch True if target and data match stored values
    function matchCalldataHash(address target, bytes calldata data) external view returns (bool validMatch);

    /// @notice Sets rescheduling parameters for a task
    /// @param task Address of the task to reschedule
    /// @param maxCost Maximum cost allowed for rescheduling
    /// @param targetBlock Target block for rescheduling
    /// @param reschedule Whether to enable rescheduling
    function setRescheduleData(address task, uint256 maxCost, uint256 targetBlock, bool reschedule) external;

    /// @notice Sets rescheduling data if target and data match stored values
    /// @param target Address to validate against stored target
    /// @param data Calldata to validate against stored hash
    /// @param task Address of the task to reschedule
    /// @param maxCost Maximum cost allowed for rescheduling
    /// @param targetBlock Target block for rescheduling
    /// @param reschedule Whether to enable rescheduling
    /// @return valid True if data was set successfully
    function setRescheduleDataIfMatch(
        address target,
        bytes calldata data,
        address task,
        uint256 maxCost,
        uint256 targetBlock,
        bool reschedule
    )
        external
        returns (bool valid);

    /// @notice Retrieves and clears stored rescheduling data
    /// @dev This function will clear all stored data after returning it
    /// @param target Address of the target contract
    /// @return maxCost Maximum cost allowed for rescheduling
    /// @return targetBlock Target block for rescheduling
    /// @return reschedule Whether rescheduling is enabled
    function returnRescheduleData(address target)
        external
        returns (uint256 maxCost, uint256 targetBlock, bool reschedule);

    /// @notice Clears all stored rescheduling data
    /// @dev Can only be called by the active task or target contract
    function clearRescheduleData() external;
}
