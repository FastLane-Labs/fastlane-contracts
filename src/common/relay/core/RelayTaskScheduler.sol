//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RelayTaskHelper } from "./RelayTaskHelper.sol";
import { TaskConstants } from "./TaskConstants.sol";
import { IGeneralReschedulingTask } from "../tasks/IGeneralReschedulingTask.sol";

/// @title RelayTaskScheduler
/// @notice Handles the scheduling and rescheduling of callback tasks in the gas relay system
/// @dev Extends RelayTaskHelper to provide task scheduling functionality with session key support
abstract contract RelayTaskScheduler is RelayTaskHelper {
    /// @notice Schedules or reschedules a callback task
    /// @dev Handles both new task creation and rescheduling of existing tasks with session key support
    /// @param data The callback data to be executed
    /// @param gas The amount of gas to allocate for task execution
    /// @param targetBlock The desired block number for task execution
    /// @param expirationBlock The block number after which the task expires
    /// @param setOwnerAsMsgSenderDuringTask If true, sets the task owner as msg.sender during task execution
    /// @return success Whether the scheduling operation was successful
    /// @return taskID The ID of the scheduled task (zero if rescheduling)
    function _scheduleCallback(
        bytes memory data,
        uint256 gas,
        uint256 targetBlock,
        uint256 expirationBlock,
        bool setOwnerAsMsgSenderDuringTask
    )
        internal
        virtual
        returns (bool success, bytes32 taskID)
    {
        (address _owner, uint256 _expiration, bool _isSessionKey, bool _isTask) = _abstractedMsgSenderWithContext();

        // Adjust target block - session key cant schedule a task farther out than the session key
        // is valid for, then sanity check the expiration block against target
        if (_isSessionKey || _isTask) {
            if (expirationBlock > _expiration) expirationBlock = _expiration;
            if (targetBlock > expirationBlock) {
                return (false, bytes32(0));
            }
        } else {
            _expiration = expirationBlock;
        }

        // Check if this can be rescheduled
        if (_isTask) {
            (address _task,,,) = _loadUnderlyingMsgSenderData();
            if (_matchCalldataHash(data)) {
                uint256 _maxTaskCost;
                (success, targetBlock, _maxTaskCost) =
                    _rescheduleTaskAccounting(_task, _owner, gas, _maxPayment(_owner), targetBlock, expirationBlock);
                if (success) {
                    _setRescheduleData(_task, _maxTaskCost, targetBlock, setOwnerAsMsgSenderDuringTask);
                }
                // TODO: Manually calculate future task ID in a gas-efficient manner (will require TaskManager
                // modification)
                return (success, bytes32(0));
            }
        }

        // Create task
        (success, taskID,,) = _createTask({
            payor: _owner,
            maxPayment: _maxPayment(_owner),
            minExecutionGasRemaining: _minExecutionGasRemaining(),
            targetBlock: targetBlock,
            expirationBlock: expirationBlock,
            taskImplementation: GENERAL_TASK_IMPL(),
            taskGas: gas,
            taskData: abi.encodeCall(IGeneralReschedulingTask.execute, (address(this), data))
        });

        // Set _abstractedMsgSender to owner during callback execution, if desired
        if (success && setOwnerAsMsgSenderDuringTask) {
            address _task = address(uint160(uint256(taskID)));
            // Set task's sessionKey expiration as expiration so that task can reschedule up until
            // its expiration. Using expirationBlock will cause reschedules to revert unexpectedly.
            _addTaskAsSessionKey(_task, _owner, _expiration);
        }
        return (success, taskID);
    }
}
