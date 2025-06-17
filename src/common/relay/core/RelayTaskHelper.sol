//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITaskManager } from "../../../task-manager/interfaces/ITaskManager.sol";
import { IShMonad } from "../../../shmonad/interfaces/IShMonad.sol";
import { TaskConstants } from "./TaskConstants.sol";

import "forge-std/console.sol";

/// @title RelayTaskHelper
/// @notice Helper functions for task creation, scheduling, and bond management
/// @dev Extends TaskConstants and GasRelayBase to provide core task management functionality
abstract contract RelayTaskHelper is TaskConstants {
    uint256 private constant _MAX_SCHEDULING_AND_ESCROW_GAS_USAGE = 191_000;
    uint256 private constant _MAX_SCHEDULING_GAS_USAGE = 151_000;

    /// @notice Creates a new task with the specified parameters
    /// @dev Handles payment estimation, gas monitoring, and task scheduling
    /// @param payor Address that will pay for the task execution
    /// @param maxPayment Maximum amount willing to pay for task execution
    /// @param minExecutionGasRemaining Minimum gas that must remain after scheduling
    /// @param targetBlock Desired block for task execution
    /// @param expirationBlock Block after which the task expires
    /// @param taskImplementation Address of the task implementation contract
    /// @param taskGas Maximum gas allowed for task execution
    /// @param taskData Encoded data for task execution
    /// @return success Whether task creation was successful
    /// @return taskID Identifier of the created task
    /// @return blockNumber Block number where task is scheduled
    /// @return amountPaid Amount actually paid for the task
    function _createTask(
        address payor,
        uint256 maxPayment,
        uint256 minExecutionGasRemaining,
        uint256 targetBlock,
        uint256 expirationBlock,
        address taskImplementation,
        uint256 taskGas,
        bytes memory taskData
    )
        internal
        returns (bool success, bytes32 taskID, uint256 blockNumber, uint256 amountPaid)
    {
        // Calculate the payment
        uint256 amountEstimated;

        if (maxPayment == 0) {
            return (success, taskID, blockNumber, amountPaid);
        }

        // Monitor gas carefully while searching for a cheap block.
        uint256 searchGas = gasleft();
        // TODO: update task schedule gas cost (150_000 is rough estimate)
        if (searchGas < minExecutionGasRemaining + _MAX_SCHEDULING_AND_ESCROW_GAS_USAGE) {
            return (success, taskID, blockNumber, amountPaid);
        }
        searchGas -= (minExecutionGasRemaining + _MAX_SCHEDULING_AND_ESCROW_GAS_USAGE - 1);

        (amountEstimated, targetBlock) =
            _getNextAffordableBlock(maxPayment, targetBlock, expirationBlock, taskGas, searchGas);

        if (targetBlock == 0 || amountEstimated == 0 || amountEstimated > maxPayment) {
            return (success, taskID, blockNumber, amountPaid);
        }

        // Take the estimated amount from the payor and then bond it to task manager
        _takeFromOwnerBondedAmountInUnderlying(payor, amountEstimated);
        _bondAmountToTaskManager(amountEstimated);

        // Reset the gas limits
        searchGas = gasleft();
        if (searchGas < _MAX_SCHEDULING_GAS_USAGE + minExecutionGasRemaining) {
            return (success, taskID, blockNumber, amountPaid);
        }
        searchGas -= minExecutionGasRemaining;

        // Schedule the task
        bytes memory returndata;
        (success, returndata) = TASK_MANAGER.call{ gas: searchGas }(
            abi.encodeCall(
                ITaskManager.scheduleWithBond,
                (taskImplementation, taskGas, uint64(targetBlock), amountEstimated, taskData)
            )
        );

        // Validate and decode
        if (success) {
            (success, amountPaid, taskID) = abi.decode(returndata, (bool, uint256, bytes32));
        }

        // Return result
        return (success, taskID, targetBlock, amountPaid);
    }

    /// @notice Handles accounting for task rescheduling
    /// @dev Calculates costs and transfers necessary bonds for rescheduling
    /// @param task Address of the task to reschedule
    /// @param payor Address paying for the rescheduling
    /// @param gas New gas limit for task execution
    /// @param maxPayment Maximum amount willing to pay
    /// @param targetBlock Desired new execution block
    /// @param expirationBlock New expiration block
    /// @return success Whether rescheduling accounting succeeded
    /// @return nextBlock The block where task is rescheduled to
    /// @return amountEstimated Estimated cost for rescheduling
    function _rescheduleTaskAccounting(
        address task,
        address payor,
        uint256 gas,
        uint256 maxPayment,
        uint256 targetBlock,
        uint256 expirationBlock
    )
        internal
        returns (bool success, uint256 nextBlock, uint256 amountEstimated)
    {
        uint256 gasToUse = gasleft();
        if (gasToUse < _minExecutionGasRemaining()) {
            gasToUse = 0;
        } else {
            gasToUse -= _minExecutionGasRemaining();
        }
        if (gasToUse > _maxSearchGas()) gasToUse = _maxSearchGas();

        (amountEstimated, nextBlock) = _getNextAffordableBlock(maxPayment, targetBlock, expirationBlock, gas, gasToUse);
        if (nextBlock == 0 || amountEstimated > maxPayment) {
            return (false, 0, 0);
        }

        // Send rescheduling cost to the task as MON
        IShMonad(SHMONAD).agentWithdrawFromBonded(POLICY_ID(), payor, task, amountEstimated, 0, true);

        return (true, nextBlock, amountEstimated);
    }

    /// @notice Find the next affordable block for task execution
    /// @param maxPayment Maximum payment available
    /// @param targetBlock Target block to start searching from
    /// @param expirationBlock Lowest unacceptable block
    /// @param maxTaskGas Maximum gas for task execution
    /// @param maxSearchGas Maximum gas to use for the search
    /// @return amountEstimated Estimated cost for the block
    /// @return Next affordable block number or 0 if none found
    function _getNextAffordableBlock(
        uint256 maxPayment,
        uint256 targetBlock,
        uint256 expirationBlock,
        uint256 maxTaskGas,
        uint256 maxSearchGas
    )
        internal
        view
        returns (uint256 amountEstimated, uint256)
    {
        uint256 _targetGasLeft = gasleft();

        // NOTE: This is an internal function and has no concept of how much gas
        // its caller needs to finish the call. If 'targetGasLeft' is set to zero and no profitable block is found prior
        // to running out
        // of gas, then this function will simply cause an EVM 'out of gas' error. The purpose of
        // the check below is to prevent an integer underflow, *not* to prevent an out of gas revert.
        if (_targetGasLeft < maxSearchGas) {
            _targetGasLeft = 0;
        } else {
            _targetGasLeft -= maxSearchGas;
        }

        uint256 i = 1;
        do {
            if (targetBlock >= expirationBlock) {
                return (0, 0);
            }

            amountEstimated = _estimateTaskCost(targetBlock, maxTaskGas);

            // If block is too expensive, try jumping forwards
            if (amountEstimated > maxPayment) {
                // Distance between blocks increases incrementally as i increases.
                i += (i / 4 + 1);
                if (targetBlock + i > expirationBlock) {
                    ++targetBlock;
                } else {
                    targetBlock += i;
                }
            } else {
                return (amountEstimated, targetBlock);
            }
        } while (gasleft() > _targetGasLeft);
        return (0, 0);
    }

    /// @notice Registers a task as a session key
    /// @dev Allows tasks to act as session keys for specific owners
    /// @param taskAddress Address of the task to register
    /// @param owner Address of the task owner
    /// @param expirationBlock Block number when the session key expires
    function _addTaskAsSessionKey(address taskAddress, address owner, uint256 expirationBlock) internal {
        if (expirationBlock > type(uint64).max || expirationBlock <= block.number) {
            revert TaskDeadlineInvalid(expirationBlock);
        }

        if (taskAddress == owner || taskAddress == address(this)) {
            revert InvalidTaskOwner();
        }

        // Task can reschedule itself, return early if that's the case
        if (taskAddress == msg.sender) return;

        // Treat the task as a session key
        _updateSessionKey(taskAddress, true, owner, expirationBlock);
    }

    /// @notice Bonds shares to the task manager
    /// @dev Transfers shares to be bonded for task execution
    /// @param shares Number of shares to bond
    function _bondSharesToTaskManager(uint256 shares) internal {
        IShMonad(SHMONAD).bond(TASK_MANAGER_POLICY_ID, address(this), shares);
    }

    /// @notice Bonds native tokens to the task manager
    /// @dev Deposits and bonds native tokens for task execution
    /// @param amount Amount of native tokens to bond
    function _bondAmountToTaskManager(uint256 amount) internal {
        IShMonad(SHMONAD).depositAndBond{ value: amount }(TASK_MANAGER_POLICY_ID, address(this), type(uint256).max);
    }

    /// @notice Initiates the unbonding process from task manager
    /// @dev Starts the process of releasing bonded shares
    /// @param shares Number of shares to start unbonding
    function _beginUnbondFromTaskManager(uint256 shares) internal {
        IShMonad(SHMONAD).unbond(TASK_MANAGER_POLICY_ID, shares, 0);
    }

    /// @notice Gets the block when unbonding completes
    /// @dev Queries the completion block for current unbonding process
    /// @return blockNumber The block number when unbonding will complete
    function _taskManagerUnbondingBlock() internal view returns (uint256 blockNumber) {
        blockNumber = IShMonad(SHMONAD).unbondingCompleteBlock(TASK_MANAGER_POLICY_ID, address(this));
    }

    /// @notice Completes the unbonding process
    /// @dev Claims unbonded shares after unbonding period
    /// @param shares Number of shares to claim
    function _completeUnbondFromTaskManager(uint256 shares) internal {
        IShMonad(SHMONAD).claim(TASK_MANAGER_POLICY_ID, shares);
    }

    /// @notice Gets the amount of shares bonded to task manager
    /// @dev Queries current bonded balance for an owner
    /// @param owner Address to check bonded balance for
    /// @return shares Number of shares currently bonded
    function _sharesBondedToTaskManager(address owner) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).balanceOfBonded(TASK_MANAGER_POLICY_ID, owner);
    }

    /// @notice Gets the amount of shares currently unbonding
    /// @dev Queries current unbonding balance for an owner
    /// @param owner Address to check unbonding balance for
    /// @return shares Number of shares currently unbonding
    function _sharesUnbondingFromTaskManager(address owner) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).balanceOfUnbonding(TASK_MANAGER_POLICY_ID, owner);
    }

    /// @notice Estimates the cost of executing a task
    /// @dev Calculates execution cost based on target block and gas limit
    /// @param targetBlock Block number where task will execute
    /// @param maxTaskGas Maximum gas allowed for task execution
    /// @return cost Estimated cost in native tokens
    function _estimateTaskCost(uint256 targetBlock, uint256 maxTaskGas) internal view returns (uint256 cost) {
        cost = ITaskManager(TASK_MANAGER).estimateCost(uint64(targetBlock), maxTaskGas);
    }
}
