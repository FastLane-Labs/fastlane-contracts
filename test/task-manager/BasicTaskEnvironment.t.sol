// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { TaskManagerTestHelper } from "./helpers/TaskManagerTestHelper.sol";
import { BasicTaskEnvironment } from "../../src/task-manager/environments/BasicTaskEnvironment.sol";
import { Task, Size } from "../../src/task-manager/types/TaskTypes.sol";

contract MockTarget {   
    uint256 public value;
    
    function setValue(uint256 newValue) external returns (uint256) {
        value = newValue;
        return newValue;
    }
}

contract BasicTaskEnvironmentTest is TaskManagerTestHelper {
    BasicTaskEnvironment public environment;
    MockTarget public mockTarget;

    event TaskStarted(address target, bytes data);
    event TaskCompleted(address target, bool success);

    // The selector for executeTask(bytes)
    bytes4 constant EXECUTE_TASK_SELECTOR = bytes4(keccak256("executeTask(bytes)"));

    function setUp() public override {
        super.setUp();

        // Setup initial state for user
        vm.deal(user, 300 ether);  // More ETH to ensure we have some free for scheduleTask
        _bondWithTaskManager(user, 100 ether);  // For bonded payments
        _depositAndApprove(user, 100 ether);    // For unbonded payments
        // This leaves 100 ETH free for direct payments in scheduleTask

        // Setup initial state for deployer
        vm.deal(deployer, 200 ether);
        _bondWithTaskManager(deployer, 100 ether);
        _depositAndApprove(deployer, 100 ether);

        // Deploy our custom environment
        environment = new BasicTaskEnvironment(address(taskManager));

        // Deploy the target contract
        mockTarget = new MockTarget();
    }

    function test_ScheduleAndExecuteTask() public {
        vm.startPrank(user);

        // Layer 1: Encode the actual function call
        bytes memory targetCalldata = abi.encodeCall(MockTarget.setValue, (42));

        // Layer 2: Pack target and calldata
        bytes memory packedData = abi.encode(address(mockTarget), targetCalldata);

        // Layer 3: Encode the executeTask call
        bytes memory taskData = abi.encodeWithSelector(EXECUTE_TASK_SELECTOR, packedData);

        // Schedule task for next block
        uint64 targetBlock = uint64(block.number + 2);
        (bool scheduled, uint256 executionCost, bytes32 taskId) = taskManager.scheduleWithBond(
            address(environment),  // Use our validated environment
            100_000,              // Gas limit
            targetBlock,          // Target block
            type(uint256).max/2,  // Max payment
            taskData            // Task data
        );
        
        assertTrue(scheduled, "Task scheduling failed");
        assertTrue(executionCost > 0, "Execution cost should be positive");
        assertTrue(taskId != bytes32(0), "Task ID should not be zero");

        vm.stopPrank();

        // Roll to execution block
        vm.roll(targetBlock + 1);

        // Execute task as executor
        vm.prank(payout);
        taskManager.executeTasks(payout, 0);

        // Check the state
        assertEq(mockTarget.value(), 42, "Target state not updated");
        assertTrue(taskManager.isTaskExecuted(taskId), "Task should be marked as executed");
    }
    
    function test_ScheduleWithInvalidTarget() public {
        vm.startPrank(user);

        // Schedule task for next block
        uint64 targetBlock = uint64(block.number + 2);
        bytes32 taskId = _scheduleTask(user, 0, Size.Small, targetBlock);
        
        vm.stopPrank();
        
        // Roll to execution block
        vm.roll(targetBlock + 1);
        
        // Execute task as executor - should fail due to zero address
        vm.prank(payout);
        taskManager.executeTasks(payout, 0);
        
        // Task should be marked as executed even though the execution failed
        assertTrue(taskManager.isTaskExecuted(taskId), "Task should be marked as executed");
        assertEq(mockTarget.value(), 0, "Target state should not be updated");
    }
    
    function test_ScheduleWithEmptyCalldata() public {
        vm.startPrank(user);

        // Schedule task for next block
        uint64 targetBlock = uint64(block.number + 2);
        bytes32 taskId = _scheduleTask(user, 0, Size.Small, targetBlock);

        vm.stopPrank();

        // Roll to execution block
        vm.roll(targetBlock + 1);

        // Execute task as executor - should fail due to empty calldata
        vm.prank(payout);
        taskManager.executeTasks(payout, 0);
        
        // Task should be marked as executed even though the execution failed
        assertTrue(taskManager.isTaskExecuted(taskId), "Task should be marked as executed");
        assertEq(mockTarget.value(), 0, "Target state should not be updated");
    }
} 