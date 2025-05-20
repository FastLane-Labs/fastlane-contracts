// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { TaskExecutionBase } from "./ExecutionBase.sol";
import { ITaskExecutionEnvironment } from "../interfaces/IExecutionEnvironment.sol";

/// @title TaskExecutionEnvironment
/// @notice Default implementation for task execution environments
contract TaskExecutionEnvironment is TaskExecutionBase, ITaskExecutionEnvironment {
    constructor(address taskManager_) TaskExecutionBase(taskManager_) { }

    /// @inheritdoc ITaskExecutionEnvironment
    function executeTask(bytes calldata taskData) external returns (bool success) {
        // Decode target and calldata from the packed taskData
        (address target, bytes memory data) = abi.decode(taskData, (address, bytes));

        (success,) = target.call(data);
        return success;
    }

    receive() external payable { }
}
