//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAddressHub } from "../../IAddressHub.sol";
import { GeneralReschedulingTask } from "../tasks/GeneralReschedulingTask.sol";

/// @title TaskConstants
/// @notice Constants and base functionality for task scheduling and execution
/// @dev Abstract contract providing core task-related constants and gas management functions
abstract contract TaskConstants {
    /// @notice Address of the FastLane address hub contract on Monad
    /// @dev Used to fetch addresses of other FastLane contracts
    address private constant _address_hub = 0xC9f0cDE8316AbC5Efc8C3f5A6b571e815C021B51;

    /// @notice Address of the general task implementation contract
    /// @dev Deployed during construction and used as the implementation for general rescheduling tasks
    address public immutable GENERAL_TASK_IMPL;

    /// @notice Initializes the task constants and deploys the general task implementation
    /// @dev Fetches necessary addresses from the address hub and deploys the GeneralReschedulingTask
    constructor() {
        address _taskManager = IAddressHub(_address_hub).taskManager();
        address _shMonad = IAddressHub(_address_hub).shMonad();

        GeneralReschedulingTask generalTaskImpl = new GeneralReschedulingTask(_taskManager, _shMonad);
        GENERAL_TASK_IMPL = address(generalTaskImpl);
    }

    /// @notice Returns the maximum gas allowed for searching scheduled tasks
    /// @dev Must be implemented by derived contracts
    /// @return maxGasUsage The maximum gas that can be used for task search
    function _maxSearchGas() internal view virtual returns (uint256 maxGasUsage);

    /// @notice Returns the minimum gas that must remain for task execution
    /// @dev Must be implemented by derived contracts
    /// @return minRemainingGasUsage The minimum gas that must be available for execution
    function _minExecutionGasRemaining() internal view virtual returns (uint256 minRemainingGasUsage);
}
