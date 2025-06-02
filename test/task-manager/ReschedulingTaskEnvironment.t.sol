// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { VmSafe } from "forge-std/Vm.sol";

import { TaskManagerTestHelper } from "./helpers/TaskManagerTestHelper.sol";
import { BasicTaskEnvironment } from "../../src/task-manager/environments/BasicTaskEnvironment.sol";
import { Task, Size } from "../../src/task-manager/types/TaskTypes.sol";
import { TaskStorage } from "../../src/task-manager/core/Storage.sol";
import { TaskBits } from "../../src/task-manager/libraries/TaskBits.sol";
import { ReschedulingTaskEnvironment } from "../../src/task-manager/environments/ReschedulingTaskEnvironment.sol";

contract MockFailingTarget {
    error TaskFailed();
    
    function increment() external pure returns (bool) {
        revert TaskFailed();
    }
}

contract ReschedulingTaskEnvironmentTest is TaskManagerTestHelper {
    using TaskBits for bytes32;
    ReschedulingTaskEnvironment public environment;
    
    event TaskStarted(address target, bytes data);
    event TaskCompleted(address target, bool success);
    event TaskRescheduled(address target, uint64 newTargetBlock);
    event ExecutionAttempt(uint8 attemptNumber, bool success);
    event TaskScheduled(bytes32 taskId, address owner, uint64 nextBlock);
    
    bytes4 constant EXECUTE_TASK_SELECTOR = bytes4(keccak256("executeTask(bytes)"));
    
    // Add receive function to accept ETH payments
    receive() external payable {}
    
    function setUp() public override {
        super.setUp();
        vm.deal(user, 100 ether);
        _bondWithTaskManager(user, 100 ether);
        environment = new ReschedulingTaskEnvironment(address(taskManager));
        
        // Ensure payout address can receive ETH
        vm.deal(payout, 1 ether);
    }

    /// @notice Helper function to get task ID from the most recent TaskScheduled event
    /// @dev Searches through recorded logs in reverse to find the last TaskScheduled event
    /// @param logs Array of logs to search through
    /// @return taskId The task ID from the most recent TaskScheduled event
    function _getLastScheduledTaskId(VmSafe.Log[] memory logs) internal pure returns (bytes32) {
        // Search in reverse to find the last TaskScheduled event
        bytes32 eventSelector = keccak256("TaskScheduled(bytes32,address,uint64)");
        for (uint i = logs.length; i > 0; i--) {
            if (logs[i-1].topics[0] == eventSelector) {
                return logs[i-1].topics[1];
            }
        }
        revert("No TaskScheduled event found");
    }
    
    function test_ReschedulingTask() public {
        // Deploy the target contract
        MockFailingTarget testTarget = new MockFailingTarget();

        // Encode the task data
        bytes memory taskData = abi.encodeWithSelector(
            EXECUTE_TASK_SELECTOR,
            abi.encode(
                address(testTarget),
                abi.encodeWithSelector(MockFailingTarget.increment.selector)
            )
        );

        // Schedule task for next block
        uint64 targetBlock = uint64(block.number + 1);
        vm.prank(user);
        vm.recordLogs();  // Record logs for the entire test
        (bool scheduled, uint256 executionCost, bytes32 taskId) = taskManager.scheduleWithBond(
            address(environment),
            250_000,
            targetBlock,
            type(uint256).max/2,
            taskData
        );

        assertTrue(scheduled, "Task should be scheduled");
        assertGt(executionCost, 0, "Execution cost should be greater than 0");

        // First execution attempt
        vm.roll(targetBlock+1);
        uint256 feesEarned = taskManager.executeTasks(address(this), 0);
        assertTrue(feesEarned > 0, "Should earn fees for execution attempt");
        assertTrue(taskManager.isTaskExecuted(taskId), "Original task should be executed (via rescheduling)");

        // Store all logs for later use
        VmSafe.Log[] memory allLogs = vm.getRecordedLogs();

        // Get the new task ID from the last TaskScheduled event
        bytes32 newTaskId = _getLastScheduledTaskId(allLogs);

        // Get the target block from the task schedule event
        (,, uint64 nextTargetBlock) = _getLastTaskScheduledEvent(allLogs);

        // Roll to block after target (task needs to be in the past to be executed)
        vm.roll(nextTargetBlock + 6);
        feesEarned = taskManager.executeTasks(address(this), 0);
        assertTrue(taskManager.isTaskExecuted(newTaskId), "Second task should be executed (via rescheduling)");
        assertTrue(feesEarned > 0, "Should earn fees for execution attempt");
        
        // Update stored logs
        allLogs = vm.getRecordedLogs();

        // Get the next task ID and target block
        newTaskId = _getLastScheduledTaskId(allLogs);
        (,, nextTargetBlock) = _getLastTaskScheduledEvent(allLogs);

        // Roll to block after target for third attempt
        vm.roll(nextTargetBlock + 6);
        feesEarned = taskManager.executeTasks(address(this), 0);
        assertTrue(feesEarned > 0, "Should earn fees for execution attempt");
        // No need to check isTaskExecuted here since this is the final attempt and it won't be rescheduled
    }

    /// @notice Helper function to get the last TaskScheduled event details
    /// @param logs Array of logs to search through
    /// @return owner The task owner
    /// @return taskId The task ID
    /// @return targetBlock The target block for execution
    function _getLastTaskScheduledEvent(VmSafe.Log[] memory logs) internal pure returns (address owner, bytes32 taskId, uint64 targetBlock) {
        // The actual event selector from the logs
        bytes32 eventSelector = 0xc7bae2d28bc1cb106de3cc70d106afe36790432a12d3c8e8e41d79c64e4da6ab;
        
        // Search in reverse to find the last TaskScheduled event
        for (uint i = logs.length; i > 0; i--) {
            VmSafe.Log memory entry = logs[i-1];
            if (entry.topics[0] == eventSelector) {
                // TaskScheduled(bytes32 taskId, address owner, uint64 nextBlock)
                taskId = entry.topics[1];  // taskId is first indexed parameter
                owner = address(uint160(uint256(entry.topics[2])));  // owner is second indexed parameter
                targetBlock = abi.decode(entry.data, (uint64));  // nextBlock is in data field
                return (owner, taskId, targetBlock);
            }
        }
        revert("No TaskScheduled event found");
    }

    function test_EnvironmentAuthorityAcrossReschedules() public {
        address canceller = makeAddr("canceller");
        vm.startPrank(user);

        // Deploy the target contract that will fail
        MockFailingTarget testTarget = new MockFailingTarget();

        // Encode the task data
        bytes memory taskData = abi.encodeWithSelector(
            EXECUTE_TASK_SELECTOR,
            abi.encode(
                address(testTarget),
                abi.encodeWithSelector(MockFailingTarget.increment.selector)
            )
        );

        // Schedule initial task
        uint64 targetBlock = uint64(block.number + 1);
        vm.recordLogs();  // Start recording logs
        (bool scheduled, uint256 executionCost, bytes32 taskId) = taskManager.scheduleWithBond(
            address(environment),
            250_000,
            targetBlock,
            type(uint256).max/2,
            taskData
        );
        assertTrue(scheduled, "Task should be scheduled");
        assertGt(executionCost, 0, "Execution cost should be greater than 0");

        // Register environment canceller
        taskManager.addEnvironmentCanceller(taskId, canceller);
        
        // First execution attempt - will fail and reschedule
        vm.roll(targetBlock + 1);
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees for execution attempt");
        assertTrue(taskManager.isTaskExecuted(taskId), "Original task should be executed (via rescheduling)");

        // Get the new task ID from the last TaskScheduled event
        VmSafe.Log[] memory allLogs = vm.getRecordedLogs();
        (, bytes32 newTaskId, uint64 nextTargetBlock) = _getLastTaskScheduledEvent(allLogs);

        // Roll to block after target for second attempt
        vm.roll(nextTargetBlock + 1);
        feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees for execution attempt");
        assertTrue(taskManager.isTaskExecuted(newTaskId), "Second task should be executed (via rescheduling)");

        // Get the next rescheduled task
        allLogs = vm.getRecordedLogs();
        (, bytes32 finalTaskId,) = _getLastTaskScheduledEvent(allLogs);
        
        // Verify the environment canceller can still cancel the final rescheduled task
        vm.stopPrank();
        vm.startPrank(canceller);
        taskManager.cancelTask(finalTaskId);
        assertTrue(taskManager.isTaskCancelled(finalTaskId), "Final rescheduled task should be cancelled by environment canceller");
        vm.stopPrank();
    }

    function test_RescheduleTask_RefundsInsufficientMsgValue() public {
        // Deploy the target contract that will fail
        MockFailingTarget testTarget = new MockFailingTarget();

        // Encode the task data for a rescheduling task
        bytes memory taskData = abi.encodeWithSelector(
            EXECUTE_TASK_SELECTOR,
            abi.encode(
                address(testTarget),
                abi.encodeWithSelector(MockFailingTarget.increment.selector)
            )
        );

        // Schedule initial task for next block
        uint64 targetBlock = uint64(block.number + 1);
        vm.prank(user);
        (bool scheduled, uint256 executionCost, bytes32 taskId) = taskManager.scheduleWithBond(
            address(environment),
            250_000,
            targetBlock,
            type(uint256).max/2,
            taskData
        );
        assertTrue(scheduled, "Task should be scheduled");
        assertGt(executionCost, 0, "Execution cost should be greater than 0");

        // Store initial user balance
        uint256 initialUserBalance = user.balance;
        
        // Execute the task - it will fail and try to reschedule with insufficient msg.value
        vm.roll(targetBlock + 1);
        
        // The environment will try to reschedule during execution
        // We need to provide some ETH to the environment for it to send during reschedule
        vm.deal(address(environment), 1 ether);
        
        // Record the environment's balance before execution
        uint256 envBalanceBefore = address(environment).balance;
        
        // Execute the task - this will trigger a reschedule attempt with insufficient funds
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees for execution attempt");
        assertTrue(taskManager.isTaskExecuted(taskId), "Original task should be executed (via rescheduling)");
        
        // Verify that if the environment had sent some ETH during reschedule but it was insufficient,
        // it should have been refunded (this tests the bug fix)
        // The exact balance check depends on the rescheduling implementation, but we verify
        // that the environment didn't lose ETH unnecessarily
        uint256 envBalanceAfter = address(environment).balance;
        
        // The environment should not have lost significant ETH if the reschedule used bonded shMONAD
        // (allowing for small gas costs)
        assertLe(envBalanceBefore - envBalanceAfter, 0.01 ether, "Environment should not lose significant ETH on insufficient msg.value");
    }

    function test_RescheduleTask_CorrectUnitConversion() public {
        // This test specifically targets the unit conversion bug where
        // executionCost (in MON) was incorrectly passed to _takeBondedShmonad (expects shMONAD)
        
        // Deploy the target contract that will fail
        MockFailingTarget testTarget = new MockFailingTarget();

        // Encode the task data for a rescheduling task  
        bytes memory taskData = abi.encodeWithSelector(
            EXECUTE_TASK_SELECTOR,
            abi.encode(
                address(testTarget),
                abi.encodeWithSelector(MockFailingTarget.increment.selector)
            )
        );

        // Schedule initial task
        uint64 targetBlock = uint64(block.number + 1);
        vm.prank(user);
        (bool scheduled, uint256 executionCost, bytes32 taskId) = taskManager.scheduleWithBond(
            address(environment),
            250_000,
            targetBlock,
            type(uint256).max/2,
            taskData
        );
        assertTrue(scheduled, "Task should be scheduled");
        assertGt(executionCost, 0, "Execution cost should be greater than 0");

        // Get user's bonded shMONAD balance before execution
        uint64 policyId = taskManager.POLICY_ID();
        uint256 bondedBalanceBefore = shMonad.balanceOfBonded(policyId, user);
        
        // Execute the task - it will fail and reschedule using bonded shMONAD
        vm.roll(targetBlock + 1);
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees for execution attempt");
        assertTrue(taskManager.isTaskExecuted(taskId), "Original task should be executed (via rescheduling)");
        
        // Get user's bonded shMONAD balance after execution
        uint256 bondedBalanceAfter = shMonad.balanceOfBonded(policyId, user);
        
        // Verify that the correct amount was deducted from bonded shMONAD
        // The deduction should be reasonable (not zero, not excessively large)
        uint256 deducted = bondedBalanceBefore - bondedBalanceAfter;
        assertGt(deducted, 0, "Some bonded shMONAD should have been deducted for rescheduling");
        
        // The deducted amount should be reasonable (less than 10% of initial balance as a sanity check)
        assertLt(deducted, bondedBalanceBefore / 10, "Deducted amount should not be excessively large");
    }
} 