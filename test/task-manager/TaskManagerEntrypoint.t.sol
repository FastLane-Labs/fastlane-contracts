// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Task, Size, TaskMetadata, LoadBalancer, ScheduledTasks } from "../../src/task-manager/types/TaskTypes.sol";
import { TaskManagerEntrypoint } from "../../src/task-manager/core/Entrypoint.sol";
import { ITaskExecutionEnvironment } from "../../src/task-manager/interfaces/IExecutionEnvironment.sol";
import { TaskBits } from "../../src/task-manager/libraries/TaskBits.sol";
import { TaskManagerTestHelper } from "./helpers/TaskManagerTestHelper.sol";
import { TaskErrors } from "../../src/task-manager/types/TaskErrors.sol";


contract TaskManagerEntrypointTest is TaskManagerTestHelper {

    using TaskBits for bytes32;
    function setUp() public override {
        super.setUp();

        // Setup initial state for user
        vm.deal(user, 300 ether);  // Increased from 200 to 300 ether to leave 100 ether free for direct payments
        _bondWithTaskManager(user, 100 ether);  // For bonded payments
        _depositAndApprove(user, 100 ether);    // For unbonded payments
        
        // Setup initial state for deployer
        vm.deal(deployer, 300 ether);  // Increased from 200 to 300 ether
        _bondWithTaskManager(deployer, 100 ether);
        _depositAndApprove(deployer, 100 ether);
        
        // Setup initial state for taskOwner
        vm.deal(owner, 300 ether);  // Increased from 200 to 300 ether
        _bondWithTaskManager(owner, 100 ether);
        _depositAndApprove(owner, 100 ether);
    }

    function testSmokeScheduleAndCancel() public {
        vm.startPrank(user);

        // Schedule task for next block + some buffer within _GROUP_SIZE
        uint64 targetBlock = uint64(block.number + 10);
        bytes32 taskId = _scheduleTask(user, 1, Size.Small, targetBlock);
        assertNotEq(taskId, bytes32(0), "Task ID should not be zero");
        
        // Cancel task
        taskManager.cancelTask(taskId);
        
        vm.stopPrank();
    }

    function testViewAccountNonce() public {
        assertEq(taskManager.nonces(user), 0, "Initial nonce should be 0");

        vm.startPrank(user);
        _scheduleTask(user, 0, Size.Small, uint64(block.number + 10));
        assertEq(taskManager.nonces(user), 1, "Nonce should increment after scheduling");

        _scheduleTask(user, 0, Size.Small, uint64(block.number + 10));
        assertEq(taskManager.nonces(user), 2, "Nonce should increment after scheduling");

        vm.stopPrank();
    }

    function testViewTaskMetadata() public {
        vm.startPrank(user);

        // Schedule task for next block + some buffer within _GROUP_SIZE
        uint64 targetBlock = uint64(block.number + 10);
        bytes32 taskId = _scheduleTask(user, 0, Size.Small, targetBlock);
        vm.startPrank(user);
        
        // Get mimic address from taskId
        address mimic = TaskBits.getMimicAddress(taskId);
        
        // Check metadata from storage
        TaskMetadata memory taskData = taskManager.getTaskMetadata(mimic);
        assertEq(taskData.owner, user, "Owner should match");
        assertEq(taskData.nonce, 0, "Nonce should match");

        vm.stopPrank();
    }

    function testViewTaskMetadataComprehensive() public {
        vm.startPrank(user);

        uint64 currentBlock = uint64(block.number);
        
        // 1. Test initial scheduling
        uint64 targetBlock = currentBlock + 2;

        // Schedule task and get quote in one call
        bytes32 taskId = _scheduleTask(user, 1, Size.Small, targetBlock);
        
        address mimic = TaskBits.getMimicAddress(taskId);
        
        TaskMetadata memory taskData = taskManager.getTaskMetadata(mimic);
        assertEq(taskData.owner, user, "Owner should match after scheduling");
        assertEq(taskData.nonce, 0, "Nonce should match after scheduling");
        assertEq(uint8(taskData.size), uint8(Size.Small), "Size should match after scheduling");

        // 2. Test after cancellation
        taskManager.cancelTask(taskId);
        taskData = taskManager.getTaskMetadata(mimic);
        assertEq(taskData.owner, user, "Owner should match after cancellation");
        assertEq(taskData.nonce, 0, "Nonce should match after cancellation");
        assertEq(uint8(taskData.size), uint8(Size.Small), "Size should match after cancellation");

        // Roll forward one block to avoid TooManyTasksScheduled error
        vm.roll(currentBlock + 1);
        currentBlock = uint64(block.number);
        targetBlock = currentBlock + 2;

        // 3. Test with new task (incremented nonce)
        bytes32 newTaskId = _scheduleTask(user, 2, Size.Small, targetBlock);
        
        address newMimic = TaskBits.getMimicAddress(newTaskId);
        
        taskData = taskManager.getTaskMetadata(newMimic);
        assertEq(taskData.owner, user, "Owner should match for new task");
        assertEq(taskData.nonce, 1, "Nonce should be incremented for new task");
        assertEq(uint8(taskData.size), uint8(Size.Small), "Size should match for new task");

        // 4. Test after execution
        vm.roll(targetBlock + 1);
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees");
        
        taskData = taskManager.getTaskMetadata(newMimic);
        assertEq(taskData.owner, user, "Owner should match after execution");
        assertEq(taskData.nonce, 1, "Nonce should match after execution");
        assertEq(uint8(taskData.size), uint8(Size.Small), "Size should match after execution");
        
        vm.stopPrank();
    }

    function testViewTaskMetadataWithUnknownTask() public view {
        // Generate a random task ID that hasn't been scheduled
        bytes32 unknownTaskId = bytes32(uint256(1));
        address unknownMimic = TaskBits.getMimicAddress(unknownTaskId);
        
        // Get metadata for unscheduled task
        TaskMetadata memory taskData = taskManager.getTaskMetadata(unknownMimic);
        
        // Verify default values
        assertEq(taskData.owner, address(0), "Owner should be zero address for unknown task");
        assertEq(taskData.nonce, 0, "Nonce should be 0 for unknown task");
    }

    function testCancelTaskUnauthorized() public {
        vm.startPrank(user);

        // Schedule task
        bytes32 taskId = _scheduleTask(user, 0, Size.Small, uint64(block.number + 10));
        vm.stopPrank();

        // Try to cancel as different address
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TaskErrors.Unauthorized.selector, attacker, user));
        taskManager.cancelTask(taskId);
    }

    function testExecuteTask() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        
        // Create task using helper function
        _createTask(user, 1, Size.Small);
        
        // Schedule task for block 102 (must be at least 2 blocks in the future)
        uint64 targetBlock = uint64(currentBlock + 2);
        bytes32 taskId = _scheduleTask(user, 1, Size.Small, targetBlock);
        
        // Get mimic address from taskId
        address mimic = TaskBits.getMimicAddress(taskId);
        
        // Verify task is active before execution
        TaskMetadata memory preExecData = taskManager.getTaskMetadata(mimic);
        assertEq(preExecData.owner, user, "Task owner should be correct");
        assertEq(preExecData.nonce, 0, "Task nonce should be correct");
        
        // Roll to execution block
        vm.roll(targetBlock+2);
        
        // Execute tasks
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        
        // Verify execution
        assertTrue(feesEarned > 0, "Should earn fees for execution");
        
        vm.stopPrank();
    }

    function testCancelTask() public {
        vm.startPrank(user);

        uint64 targetBlock = uint64(block.number + 10);
        
        bytes32 taskId = _scheduleTask(user, 1, Size.Small, targetBlock);
        assertNotEq(taskId, bytes32(0), "Task ID should not be zero");

        // Try to cancel as different address - should revert
        vm.stopPrank();
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TaskErrors.Unauthorized.selector, attacker, user));
        taskManager.cancelTask(taskId);
        vm.stopPrank();

        // Cancel as user - should succeed
        vm.startPrank(user);
        taskManager.cancelTask(taskId);

        // Verify task is cancelled
        assertTrue(taskManager.isTaskCancelled(taskId), "Task should be cancelled");

        // Try to cancel again - should revert
        vm.expectRevert(abi.encodeWithSelector(TaskErrors.TaskAlreadyCancelled.selector, taskId));
        taskManager.cancelTask(taskId);
        vm.stopPrank();
    }

    function testValidateTaskParameters() public {
        vm.startPrank(user);

        // Test invalid target block (in past)
        Task memory task = _createTask(user, 1, Size.Small);
        uint64 pastBlock = uint64(block.number - 1);
        vm.expectRevert(abi.encodeWithSelector(TaskErrors.TaskValidation_TargetBlockInPast.selector, pastBlock, block.number));
        (,, bytes32 taskId) = taskManager.scheduleTask(task.implementation, _maxGasFromSize(task.size), pastBlock, type(uint256).max / 2, task.data);

        // Test invalid target block (too far in future)
        uint64 farFutureBlock = uint64(block.number + taskManager.MAX_SCHEDULE_DISTANCE()+1); // Assuming _GROUP_SIZE < 300
        vm.expectRevert(abi.encodeWithSelector(TaskErrors.TaskValidation_TargetBlockTooFar.selector, farFutureBlock, block.number));
        (,, taskId) = taskManager.scheduleTask(task.implementation, _maxGasFromSize(task.size), farFutureBlock, type(uint256).max / 2, task.data);

        vm.stopPrank();
    }

    function testCancelTaskWithMultipleTasks() public {
        vm.startPrank(user);

        // Create two tasks for the same block
        uint64 targetBlock = uint64(block.number + 10);
        
        // Schedule both tasks
        bytes32 taskId1 = _scheduleTask(user, 1, Size.Small, targetBlock);
        bytes32 taskId2 = _scheduleTask(user, 2, Size.Small, targetBlock);
        
        // Cancel first task
        taskManager.cancelTask(taskId1);
        
        // Try to cancel second task
        taskManager.cancelTask(taskId2);
        
        vm.stopPrank();
    }

    function testIsTaskCancelled() public {
        vm.startPrank(user);

        uint64 currentBlock = uint64(block.number);

        // Schedule task for block 102 (must be at least 2 blocks in the future)
        uint64 targetBlock = uint64(currentBlock + 2);
        bytes32 taskId = _scheduleTask(user, 1, Size.Small, targetBlock);

        // Verify task is not cancelled initially
        assertFalse(taskManager.isTaskCancelled(taskId), "Task should not be cancelled initially");

        // Cancel the task
        taskManager.cancelTask(taskId);

        // Verify task is now cancelled
        assertTrue(taskManager.isTaskCancelled(taskId), "Task should be cancelled after cancellation");

        vm.stopPrank();
    }

    function testIsTaskExecuted() public {
        vm.startPrank(user);

        uint64 currentBlock = uint64(block.number);

        // Schedule task for 2 blocks in the future
        uint64 targetBlock = currentBlock + 2;
        bytes32 taskId = _scheduleTask(user, 1, Size.Small, targetBlock);
        
        // Verify task is not executed initially
        assertFalse(taskManager.isTaskExecuted(taskId), "Task should not be executed initially");

        // Roll to execution block
        vm.roll(targetBlock + 1);

        // Execute tasks
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees for execution");

        // Verify task is now executed
        assertTrue(taskManager.isTaskExecuted(taskId), "Task should be executed after execution");

        vm.stopPrank();
    }

    function testTaskCancellationAuthorityDeregistration() public {
        address canceller = makeAddr("canceller");
        vm.startPrank(user);

        // Schedule a task
        uint64 targetBlock = uint64(block.number + 10);
        bytes32 taskId = _scheduleTask(user, 1, Size.Small, targetBlock);

        // Register task canceller
        taskManager.addTaskCanceller(taskId, canceller);

        // Deregister the canceller
        taskManager.removeTaskCanceller(taskId, canceller);

        // Test that canceller can no longer cancel the task
        vm.stopPrank();
        vm.startPrank(canceller);
        vm.expectRevert(abi.encodeWithSelector(TaskErrors.Unauthorized.selector, canceller, user));
        taskManager.cancelTask(taskId);
        vm.stopPrank();
    }

    function testTaskCancellationAuthorityValidation() public {
        vm.startPrank(user);

        // Create a valid task first
        uint64 targetBlock = uint64(block.number + 10);
        bytes32 taskId = _scheduleTask(user, 1, Size.Small, targetBlock);

        // Try to register zero address as canceller
        vm.expectRevert(TaskErrors.InvalidCancellerAddress.selector);
        taskManager.addTaskCanceller(taskId, address(0));

        // Try to register self as canceller
        vm.expectRevert(TaskErrors.InvalidCancellerAddress.selector);
        taskManager.addTaskCanceller(taskId, user);

        vm.stopPrank();
    }

    function testExecuteWithLimitedGas() public {
        vm.startPrank(user);

        uint64 currentBlock = uint64(block.number);

        // Schedule tasks at relative block distances
        bytes32 taskId1 = _scheduleTask(user, 1, Size.Small, currentBlock + 2);
        bytes32 taskId2 = _scheduleTask(user, 2, Size.Small, currentBlock + 5);
        bytes32 taskId3 = _scheduleTask(user, 3, Size.Small, currentBlock + 8);

        // Roll to block after last task
        vm.roll(currentBlock + 9);

        // Get initial block values
        (uint64 initialBlockSmall,,,,) = taskManager.S_loadBalancer();

        // We want to use enough gas to execute all three tasks
        uint256 gasLimit = 800_000;

        // Use low level call to limit gas precisely
        (bool success,) = address(taskManager).call{gas: gasLimit}(
            abi.encodeCall(taskManager.executeTasks, (payout, 0))
        );
        require(success, "Execution failed");

        // Get final blockSmall value
        (uint64 finalBlockSmall,,,,) = taskManager.S_loadBalancer();

        // We should have made progress in block processing
        assertTrue(finalBlockSmall > initialBlockSmall, "Should have made progress in block processing");

        // Check if any tasks were executed
        bool task1Executed = taskManager.isTaskExecuted(taskId1);
        bool task2Executed = taskManager.isTaskExecuted(taskId2);
        bool task3Executed = taskManager.isTaskExecuted(taskId3);

        assertEq(task1Executed, true, "Task 1 should have been executed");
        assertEq(task2Executed, true, "Task 2 should have been executed");
        assertEq(task3Executed, true, "Task 3 should have been executed");

        // We should have at least processed past the first task's block
        assertTrue(finalBlockSmall > currentBlock + 2, "Should have processed past first task block");

        vm.stopPrank();
    }

    function testBlockSkippingLogic() public {
        vm.startPrank(user);

        // Log initial block number from fork
        uint64 forkBlock = uint64(block.number);

        // Roll to a clean starting block (100 blocks after fork)
        uint64 startBlock = forkBlock + 100;
        vm.roll(startBlock);

        // Schedule tasks with specific gaps to test different skipping levels
        // Group size is 128 blocks, bitmap specificity is 4 blocks
        // So each bit in C-level bitmap represents 4 blocks
        // And D-level represents groups of 128 blocks

        // Task 1: In first 4-block chunk
        uint64 block1 = startBlock + 2;
        // Task 2: In a different 4-block chunk but same 128-block group
        uint64 block2 = startBlock + 10;
        // Task 3: In a different 128-block group
        uint64 block3 = startBlock + 130;
        // Task 4: Several 128-block groups later
        uint64 block4 = startBlock + 300;

        // Schedule the tasks using bond-based scheduling to avoid ETH payment issues
        bytes32 taskId1 = _scheduleTask(user, 1, Size.Small, block1);
        bytes32 taskId2 = _scheduleTask(user, 2, Size.Small, block2);
        bytes32 taskId3 = _scheduleTask(user, 3, Size.Small, block3);
        bytes32 taskId4 = _scheduleTask(user, 4, Size.Small, block4);

        // Roll to a block after all tasks are scheduled
        uint64 execBlock = block4 + 1;
        vm.roll(execBlock);

        // Get initial load balancer state
        (uint64 initialBlockSmall,,,,) = taskManager.S_loadBalancer();

        // Execute tasks with enough gas for all
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees from execution");

        // Get final load balancer state
        (uint64 finalBlockSmall,,,,) = taskManager.S_loadBalancer();

        // Verify all tasks were executed
        assertTrue(taskManager.isTaskExecuted(taskId1), "Task 1 should be executed");
        assertTrue(taskManager.isTaskExecuted(taskId2), "Task 2 should be executed");
        assertTrue(taskManager.isTaskExecuted(taskId3), "Task 3 should be executed");
        assertTrue(taskManager.isTaskExecuted(taskId4), "Task 4 should be executed");

        // Verify we made appropriate progress
        assertEq(finalBlockSmall, block4, "Should have processed past last task block");
        assertTrue(finalBlockSmall > initialBlockSmall, "Should have made progress in block processing");

        vm.stopPrank();
    }

    function testBlockSkippingWithDenseAndSparseRegions() public {
        vm.startPrank(user);

        // Log initial block number from fork
        uint64 forkBlock = uint64(block.number);

        // Roll to a clean starting block (100 blocks after fork)
        uint64 startBlock = forkBlock + 100;
        vm.roll(startBlock);

        // Create a series of tasks
        bytes32[] memory taskIds = new bytes32[](10);
        
        // Dense region: Schedule tasks in consecutive 4-block chunks
        // This tests C-level bitmap iteration
        for (uint256 i = 0; i < 5; i++) {
            uint64 targetBlock = startBlock + 4 * uint64(i) + 2; // Tasks at blocks +2, +6, +10, +14, +18
            taskIds[i] = _scheduleTask(user, uint64(i + 1), Size.Small, targetBlock);
        }

        // Sparse region: Schedule tasks with large gaps
        // This tests D-level bitmap iteration
        for (uint i = 0; i < 5; i++) {
            uint64 targetBlock = startBlock + 200 + 130 * uint64(i); // Tasks with 130-block gaps
            taskIds[i + 5] = _scheduleTask(user, uint64(i + 6), Size.Small, targetBlock);
        }

        // Roll to a block after all tasks
        uint64 execBlock = startBlock + 1000;
        vm.roll(execBlock);

        // Execute tasks
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees from execution");


        // Verify all tasks were executed
        for (uint i = 0; i < taskIds.length; i++) {
            assertTrue(taskManager.isTaskExecuted(taskIds[i]), string.concat("Task ", vm.toString(i), " should be executed"));
        }

        vm.stopPrank();
    }

    function testExecuteMediumTask() public {
        vm.startPrank(user);

        // Log initial block number from fork
        uint64 forkBlock = uint64(block.number);

        // Roll to a clean starting block (100 blocks after fork)
        uint64 startBlock = forkBlock + 100;
        vm.roll(startBlock);

        // Create a medium task
        uint64 targetBlock = startBlock + 2; // Schedule 2 blocks ahead

        // Schedule the task
        bytes32 taskId = _scheduleTask(user, 1, Size.Medium, targetBlock);

        // Roll to execution block
        vm.roll(targetBlock + 1);

        // Get initial load balancer state
        (uint64 initialBlockMedium,,,,) = taskManager.S_loadBalancer();

        // Execute tasks
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees from execution");

        // Get final load balancer state
        (uint64 finalBlockLarge, uint64 finalBlockMedium, uint64 finalBlockSmall, uint32 targetDelay, uint64 finalBlockUnknown2) = taskManager.S_loadBalancer();

        // Verify task was executed
        assertTrue(taskManager.isTaskExecuted(taskId), "Medium task should be executed");

        // Verify we made appropriate progress
        assertEq(finalBlockMedium, targetBlock, "Should be at the task block");
        assertEq(finalBlockLarge, targetBlock, "Should be at the task block");
        assertEq(finalBlockSmall, targetBlock, "Should be at the task block");
        assertEq(targetDelay, 3, "targetDelay should be 3");
        assertEq(finalBlockUnknown2, 0, "Unknown2 should be 0");
        assertTrue(finalBlockMedium > initialBlockMedium, "Should have made progress in medium block processing");

        vm.stopPrank();
    }

    function testMultipleTasksSameBlock() public {
        vm.startPrank(user);

        // Set target block (current block + 10 for safety)
        uint64 targetBlock = uint64(block.number) + 10;
        vm.roll(targetBlock - 1); // Roll to block before execution

        // Create and schedule 5 tasks for the same block
        bytes32[] memory taskIds = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            taskIds[i] = _scheduleTask(user, uint64(i + 1), Size.Small, targetBlock);
        }

        // Execute at target block
        vm.roll(targetBlock+1);
        uint256 feesEarned = taskManager.executeTasks(payout, 0);
        assertTrue(feesEarned > 0, "Should earn fees from execution");

        // Verify all tasks executed
        for (uint i = 0; i < taskIds.length; i++) {
            assertTrue(taskManager.isTaskExecuted(taskIds[i]), string.concat("Task ", vm.toString(i), " should be executed"));
        }

        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeBasicFunctionality() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        
        // Schedule tasks at different blocks
        _scheduleTask(user, 1, Size.Small, currentBlock + 2);
        _scheduleTask(user, 2, Size.Medium, currentBlock + 5);
        _scheduleTask(user, 3, Size.Large, currentBlock + 8);
        _scheduleTask(user, 4, Size.Small, currentBlock + 8); // Same block as task 3
        
        // Get schedule for next 10 blocks
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(10);
        
        // Verify schedule length (should be lookahead + 1)
        assertEq(schedule.length, 11, "Schedule should have 11 elements (0-10)");
        
        // Verify task counts at specific blocks
        assertEq(schedule[2].pendingSmallTasks, 1, "Should have 1 small task at block+2");
        assertEq(schedule[5].pendingMediumTasks, 1, "Should have 1 medium task at block+5");
        assertEq(schedule[8].pendingLargeTasks, 1, "Should have 1 large task at block+8");
        assertEq(schedule[8].pendingSmallTasks, 1, "Should have 1 small task at block+8");
        
        // Verify block numbers
        assertEq(schedule[2].blockNumber, currentBlock + 2, "Block number should match");
        assertEq(schedule[5].blockNumber, currentBlock + 5, "Block number should match");
        assertEq(schedule[8].blockNumber, currentBlock + 8, "Block number should match");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeEmptySchedule() public view {
        // Get schedule with no tasks scheduled
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(20);
        
        // Verify schedule length
        assertEq(schedule.length, 21, "Schedule should have 21 elements");
        
        // Verify all entries are empty
        for (uint256 i = 0; i < schedule.length; i++) {
            assertEq(schedule[i].pendingSmallTasks, 0, "Should have no small tasks");
            assertEq(schedule[i].pendingMediumTasks, 0, "Should have no medium tasks");
            assertEq(schedule[i].pendingLargeTasks, 0, "Should have no large tasks");
            assertEq(schedule[i].pendingSharesPayable, 0, "Should have no pending shares");
        }
    }

    function testGetTaskScheduleInRangeMaxLookahead() public {
        vm.startPrank(user);
        
        uint64 maxLookahead = taskManager.MAX_SCHEDULE_DISTANCE();
        uint64 currentBlock = uint64(block.number);
        
        // Test with a reasonable lookahead that won't cause memory issues
        uint64 testLookahead = 300; // Practical lookahead for testing
        
        // Schedule a task within the test range
        _scheduleTask(user, 1, Size.Small, currentBlock + testLookahead - 10);
        
        // Should not revert
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(testLookahead);
        
        // Verify schedule was returned
        assertEq(schedule.length, uint256(testLookahead) + 1, "Schedule should include all blocks");
        
        // Also verify that MAX_SCHEDULE_DISTANCE is indeed very large
        assertGt(maxLookahead, 1_000_000, "MAX_SCHEDULE_DISTANCE should be over 1 million blocks");
        
        // In practice, no one would look ahead millions of blocks
        // The function correctly validates the input but actually using max lookahead
        // would be impractical due to memory constraints
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeExceedsMaxLookahead() public {
        uint64 tooLargeLookahead = taskManager.MAX_SCHEDULE_DISTANCE() + 1;
        
        vm.expectRevert(abi.encodeWithSelector(
            TaskErrors.LookaheadExceedsMaxScheduleDistance.selector,
            tooLargeLookahead
        ));
        taskManager.getTaskScheduleInRange(tooLargeLookahead);
    }

    function testGetTaskScheduleInRangeLookaheadOverflow() public {
        // Test with lookahead that would cause overflow
        uint64 maxLookahead = type(uint64).max - uint64(block.number) + 1;
        
        vm.expectRevert(abi.encodeWithSelector(
            TaskErrors.LookaheadExceedsMaxScheduleDistance.selector,
            maxLookahead
        ));
        taskManager.getTaskScheduleInRange(maxLookahead);
    }

    function testGetTaskScheduleInRangeMixedTaskSizes() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        uint64 targetBlock = currentBlock + 5;
        
        // Schedule multiple tasks of different sizes at the same block
        _scheduleTask(user, 1, Size.Small, targetBlock);
        _scheduleTask(user, 2, Size.Small, targetBlock);
        _scheduleTask(user, 3, Size.Medium, targetBlock);
        _scheduleTask(user, 4, Size.Large, targetBlock);
        _scheduleTask(user, 5, Size.Large, targetBlock);
        _scheduleTask(user, 6, Size.Large, targetBlock);
        
        // Get schedule
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(10);
        
        // Verify counts at target block
        assertEq(schedule[5].pendingSmallTasks, 2, "Should have 2 small tasks");
        assertEq(schedule[5].pendingMediumTasks, 1, "Should have 1 medium task");
        assertEq(schedule[5].pendingLargeTasks, 3, "Should have 3 large tasks");
        assertEq(schedule[5].blockNumber, targetBlock, "Block number should match");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangePastDueTasks() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        
        // Schedule tasks for future blocks
        _scheduleTask(user, 1, Size.Small, currentBlock + 2); // Will become past due
        _scheduleTask(user, 2, Size.Medium, currentBlock + 5); // Future
        
        // Roll forward past first task's block so it becomes past due
        vm.roll(currentBlock + 3);
        
        // Get schedule
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(5);
        
        // Past due tasks should be in first element with blockNumber = 1
        assertEq(schedule[0].blockNumber, 1, "Past due tasks should have blockNumber = 1");
        assertEq(schedule[0].pendingSmallTasks, 1, "Should have 1 past due small task");
        
        // Future task should be at correct position
        assertEq(schedule[2].blockNumber, currentBlock + 5, "Future task block should be correct");
        assertEq(schedule[2].pendingMediumTasks, 1, "Should have 1 future medium task");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeDenseScheduling() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        
        // Schedule multiple tasks per block for 5 consecutive blocks
        for (uint64 i = 1; i <= 5; i++) {
            uint64 targetBlock = currentBlock + i;
            _scheduleTask(user, i * 3 - 2, Size.Small, targetBlock);
            _scheduleTask(user, i * 3 - 1, Size.Small, targetBlock);
            _scheduleTask(user, i * 3, Size.Medium, targetBlock);
        }
        
        // Get schedule
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(5);
        
        // Verify each block has correct counts
        bool foundTasks = false;
        for (uint256 i = 0; i < schedule.length; i++) {
            if (schedule[i].blockNumber >= currentBlock + 1 && schedule[i].blockNumber <= currentBlock + 5) {
                foundTasks = true;
                uint256 blockOffset = schedule[i].blockNumber - currentBlock;
                assertEq(schedule[i].pendingSmallTasks, 2, string.concat("Block ", vm.toString(blockOffset), " should have 2 small tasks"));
                assertEq(schedule[i].pendingMediumTasks, 1, string.concat("Block ", vm.toString(blockOffset), " should have 1 medium task"));
            }
        }
        assertTrue(foundTasks, "Should find scheduled tasks in the range");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeSparseScheduling() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        
        // Schedule tasks with large gaps
        _scheduleTask(user, 1, Size.Small, currentBlock + 10);
        _scheduleTask(user, 2, Size.Medium, currentBlock + 50);
        _scheduleTask(user, 3, Size.Large, currentBlock + 90);
        
        // Get schedule for 100 blocks
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(100);
        
        // Verify only specific blocks have tasks
        assertEq(schedule[10].pendingSmallTasks, 1, "Block+10 should have 1 small task");
        assertEq(schedule[50].pendingMediumTasks, 1, "Block+50 should have 1 medium task");
        assertEq(schedule[90].pendingLargeTasks, 1, "Block+90 should have 1 large task");
        
        // Verify most blocks are empty
        uint256 nonEmptyBlocks = 0;
        for (uint256 i = 0; i < schedule.length; i++) {
            if (schedule[i].pendingSmallTasks > 0 || 
                schedule[i].pendingMediumTasks > 0 || 
                schedule[i].pendingLargeTasks > 0) {
                nonEmptyBlocks++;
            }
        }
        assertEq(nonEmptyBlocks, 3, "Should only have 3 non-empty blocks");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeZeroLookahead() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        
        // Schedule a task for near future (will be past due after roll)
        _scheduleTask(user, 1, Size.Small, currentBlock + 1);
        
        // Roll forward so task is past due
        vm.roll(currentBlock + 2);
        
        // Get schedule with zero lookahead
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(0);
        
        // Should return array with single element
        assertEq(schedule.length, 1, "Should have single element");
        
        // With lookahead=0, we only get current block data
        // The past due task shows up in the current block's data
        assertEq(schedule[0].blockNumber, 0, "Current block data should have blockNumber 0");
        assertEq(schedule[0].pendingSmallTasks, 1, "Should have 1 past due task in current block");
        assertTrue(schedule[0].pendingSharesPayable > 0, "Should have pending shares for the task");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangePendingShares() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        
        // Schedule multiple tasks to accumulate fees
        for (uint i = 1; i <= 5; i++) {
            _scheduleTask(user, uint64(i), Size.Large, currentBlock + 2);
        }
        
        // Get schedule
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(5);
        
        // Verify pending shares are calculated
        assertTrue(schedule[2].pendingSharesPayable > 0, "Should have pending shares payable");
        assertEq(schedule[2].pendingLargeTasks, 5, "Should have 5 large tasks");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeAfterExecution() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        uint64 targetBlock = currentBlock + 2;
        
        // Schedule multiple tasks
        bytes32 taskId1 = _scheduleTask(user, 1, Size.Small, targetBlock);
        bytes32 taskId2 = _scheduleTask(user, 2, Size.Small, targetBlock);
        bytes32 taskId3 = _scheduleTask(user, 3, Size.Small, targetBlock);
        
        // Get initial schedule
        ScheduledTasks[] memory scheduleBefore = taskManager.getTaskScheduleInRange(5);
        assertEq(scheduleBefore[2].pendingSmallTasks, 3, "Should have 3 tasks before execution");
        
        // Execute tasks
        vm.roll(targetBlock + 1);
        taskManager.executeTasks(payout, 0);
        
        // Get schedule after execution
        ScheduledTasks[] memory scheduleAfter = taskManager.getTaskScheduleInRange(5);
        assertEq(scheduleAfter[2].pendingSmallTasks, 0, "Should have 0 tasks after execution");
        
        // Verify tasks were executed
        assertTrue(taskManager.isTaskExecuted(taskId1), "Task 1 should be executed");
        assertTrue(taskManager.isTaskExecuted(taskId2), "Task 2 should be executed");
        assertTrue(taskManager.isTaskExecuted(taskId3), "Task 3 should be executed");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeAfterCancellation() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        uint64 targetBlock = currentBlock + 2;
        
        // Schedule multiple tasks
        bytes32 taskId1 = _scheduleTask(user, 1, Size.Small, targetBlock);
        bytes32 taskId2 = _scheduleTask(user, 2, Size.Small, targetBlock);
        bytes32 taskId3 = _scheduleTask(user, 3, Size.Small, targetBlock);
        
        // Get initial schedule
        ScheduledTasks[] memory scheduleBefore = taskManager.getTaskScheduleInRange(5);
        assertEq(scheduleBefore[2].pendingSmallTasks, 3, "Should have 3 tasks before cancellation");
        
        // Cancel one task
        taskManager.cancelTask(taskId2);
        
        // Get schedule after cancellation
        ScheduledTasks[] memory scheduleAfter = taskManager.getTaskScheduleInRange(5);
        assertEq(scheduleAfter[2].pendingSmallTasks, 3, "Cancelled tasks still count as pending");
        
        // Execute remaining tasks
        vm.roll(targetBlock + 1);
        taskManager.executeTasks(payout, 0);
        
        // Verify execution status
        assertTrue(taskManager.isTaskExecuted(taskId1), "Task 1 should be executed");
        assertFalse(taskManager.isTaskExecuted(taskId2), "Task 2 should not be executed (cancelled)");
        assertTrue(taskManager.isTaskExecuted(taskId3), "Task 3 should be executed");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeLoadBalancerState() public {
        vm.startPrank(user);
        
        // Get initial load balancer state
        (uint64 initialSmall, uint64 initialMedium, uint64 initialLarge,,) = taskManager.S_loadBalancer();
        
        uint64 currentBlock = uint64(block.number);
        
        // Schedule tasks at different blocks for different sizes
        _scheduleTask(user, 1, Size.Small, currentBlock + 2);
        _scheduleTask(user, 2, Size.Medium, currentBlock + 5);
        _scheduleTask(user, 3, Size.Large, currentBlock + 8);
        
        // Get schedule - should start from lowest active block
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(10);
        
        // Verify schedule includes all tasks
        assertEq(schedule[2].pendingSmallTasks, 1, "Should find small task");
        assertEq(schedule[5].pendingMediumTasks, 1, "Should find medium task");
        assertEq(schedule[8].pendingLargeTasks, 1, "Should find large task");
        
        // Execute small tasks and verify load balancer updates
        vm.roll(currentBlock + 3);
        taskManager.executeTasks(payout, 0);
        
        (uint64 newSmall,,,,) = taskManager.S_loadBalancer();
        assertTrue(newSmall > initialSmall, "Small task pointer should advance");
        
        vm.stopPrank();
    }

    function testGetTaskScheduleInRangeGasOptimization() public {
        vm.startPrank(user);
        
        uint64 currentBlock = uint64(block.number);
        
        // Schedule many tasks across a wide range to test gas optimization
        for (uint i = 0; i < 50; i++) {
            uint64 targetBlock = currentBlock + 2 + uint64(i * 6); // Start at +2 and spread tasks every 6 blocks
            _scheduleTask(user, uint64(i + 1), Size.Small, targetBlock);
        }
        
        // Measure gas for large lookahead
        uint256 gasBefore = gasleft();
        ScheduledTasks[] memory schedule = taskManager.getTaskScheduleInRange(300);
        uint256 gasUsed = gasBefore - gasleft();
        
        // Verify function completed and found tasks
        assertEq(schedule.length, 301, "Should return full schedule");
        
        // Count non-empty blocks
        uint256 nonEmptyBlocks = 0;
        for (uint256 i = 0; i < schedule.length; i++) {
            if (schedule[i].pendingSmallTasks > 0) {
                nonEmptyBlocks++;
            }
        }
        
        // Should find approximately 50 blocks with tasks
        assertTrue(nonEmptyBlocks >= 45, "Should find most scheduled tasks");
        assertTrue(gasUsed < 5_000_000, "Should use reasonable amount of gas");
        
        vm.stopPrank();
    }
} 