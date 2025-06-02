// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Task, Size, TaskMetadata, LoadBalancer } from "../../src/task-manager/types/TaskTypes.sol";
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

    function testGetNextExecutionBlockInRange() public {
        // Setup - schedule tasks at different blocks
        vm.startPrank(user);
        
        // Get current block and use relative offsets
        uint64 currentBlock = uint64(block.number);
        
        
        // Schedule first task at currentBlock + 2
        Task memory task1 = _createTask(user, 1, Size.Small);
        // Get the cost estimate
        uint256 estimatedCost = taskManager.estimateCost(currentBlock + 2, _maxGasFromSize(task1.size));
        taskManager.scheduleTask{ value: estimatedCost }(task1.implementation, _maxGasFromSize(task1.size), currentBlock + 2, type(uint256).max / 2, task1.data);

        // Schedule second task at currentBlock + 5
        Task memory task2 = _createTask(user, 2, Size.Small);
        estimatedCost = taskManager.estimateCost(currentBlock + 5, _maxGasFromSize(task2.size));
        taskManager.scheduleTask{ value: estimatedCost }(task2.implementation, _maxGasFromSize(task2.size), currentBlock + 5, type(uint256).max / 2, task2.data);

        // Calculate expected block numbers - should return the exact block where tasks are scheduled
        uint64 firstTaskBlock = currentBlock + 2;  // first task block
        uint64 secondTaskBlock = currentBlock + 5; // second task block

        // Test cases
        // Case 1: Search with lookahead of 10 blocks, should return first task block
        uint64 block1 = taskManager.getNextExecutionBlockInRange(10);

        // Case 2: Search with lookahead of 10 blocks, should still return first task block
        uint64 block2 = taskManager.getNextExecutionBlockInRange(10);

        // Roll forward and execute tasks at firstTaskBlock
        vm.roll(firstTaskBlock + 1);
        taskManager.executeTasks(payout, 0);

        // Case 3: After executing first task, search with lookahead of 10 blocks, should return second task block
        uint64 block3 = taskManager.getNextExecutionBlockInRange(10);

        // Roll forward and execute tasks at secondTaskBlock
        vm.roll(secondTaskBlock + 1);
        taskManager.executeTasks(payout, 0);

        // Case 4: After executing all tasks, search with lookahead of 10 blocks, should return 0
        uint64 block4 = taskManager.getNextExecutionBlockInRange(10);

        // Edge cases
        // Case 5: Search with lookahead of 3 blocks, should return 0 (no tasks within lookahead)
        uint64 block5 = taskManager.getNextExecutionBlockInRange(3);

        // Case 6: Search with lookahead of 1 block, should return 0 (no tasks in immediate future)
        uint64 block6 = taskManager.getNextExecutionBlockInRange(1);

        assertEq(block1, firstTaskBlock, "Should return first task block for lookahead of 10");
        assertEq(block2, firstTaskBlock, "Should still return first task block for lookahead of 10");
        assertEq(block3, secondTaskBlock, "Should return second task block after executing first task");
        assertEq(block4, 0, "Should return 0 after executing all tasks");
        assertEq(block5, 0, "Should return 0 when no tasks within lookahead");
        assertEq(block6, 0, "Should return 0 for small lookahead");

        // Case 7: Test reversion when lookahead exceeds MAX_SCHEDULE_DISTANCE
        uint64 tooLargeLookahead = taskManager.MAX_SCHEDULE_DISTANCE() + 1;
        vm.expectRevert(abi.encodeWithSelector(
            TaskErrors.LookaheadExceedsMaxScheduleDistance.selector,
            tooLargeLookahead
        ));
        taskManager.getNextExecutionBlockInRange(tooLargeLookahead);

        // Case 8: Test reversion when lookahead would cause overflow
        uint64 maxLookahead = type(uint64).max - uint64(block.number) + 1;
        vm.expectRevert(abi.encodeWithSelector(
            TaskErrors.LookaheadExceedsMaxScheduleDistance.selector,
            maxLookahead
        ));
        taskManager.getNextExecutionBlockInRange(maxLookahead);

        vm.stopPrank();
    }

    function testGetNextExecutionBlockInRangeComprehensive() public {
        vm.startPrank(user);
        
        // Get current block and use relative offsets
        uint64 currentBlock = uint64(block.number);

        // Target blocks for tasks - use relative offsets
        uint64 block2 = currentBlock + 2;  // +2 blocks from current
        uint64 block5 = currentBlock + 5;  // +5 blocks from current
        uint64 block10 = currentBlock + 10; // +10 blocks from current
        uint64 block15 = currentBlock + 15; // +15 blocks from current

        // Schedule tasks in any order - should still always find earliest block
        _scheduleTask(user, 1, Size.Small, block2);
        _scheduleTask(user, 2, Size.Small, block5);
        _scheduleTask(user, 3, Size.Medium, block10);
        _scheduleTask(user, 4, Size.Large, block15);

        // Should always find block2 first as it's earliest, regardless of scheduling order
        assertEq(taskManager.getNextExecutionBlockInRange(20), block2, "Should find earliest task at block+2");
        assertEq(taskManager.getNextExecutionBlockInRange(20), block2, "Should still find block+2 when starting at block+2");
        assertEq(taskManager.getNextExecutionBlockInRange(20), block2, "Should still find block+2 when starting after it");

        // Roll forward relative to current block and execute tasks at block2
        vm.roll(block2 + 1);
        taskManager.executeTasks(payout, 0);

        // After executing block2, should now find block5
        assertEq(taskManager.getNextExecutionBlockInRange(20), block5, "Should find block+5 after executing block+2");
        assertEq(taskManager.getNextExecutionBlockInRange(20), block5, "Should find block+5 when starting between executed and next");
        assertEq(taskManager.getNextExecutionBlockInRange(20), block5, "Should find block+5 when starting at it");

        // Roll forward and execute tasks at block5
        vm.roll(block5 + 1);
        taskManager.executeTasks(payout, 0);

        // After executing block5, should now find block10
        assertEq(taskManager.getNextExecutionBlockInRange(20), block10, "Should find block+10 after executing block+5");
        assertEq(taskManager.getNextExecutionBlockInRange(20), block10, "Should find block+10 when starting between executed and next");

        // Roll forward and execute tasks at block10
        vm.roll(block10 + 1);
        taskManager.executeTasks(payout, 0);

        // After executing block10, should now find block15
        assertEq(taskManager.getNextExecutionBlockInRange(20), block15, "Should find block+15 after executing block+10");
        assertEq(taskManager.getNextExecutionBlockInRange(20), block15, "Should find block+15 when starting between executed and next");

        // Roll forward and execute tasks at block15
        vm.roll(block15 + 1);
        taskManager.executeTasks(payout, 0);

        // After executing all tasks, should find nothing
        assertEq(taskManager.getNextExecutionBlockInRange(20), 0, "Should find no tasks after executing all");

        // Edge cases remain valid
        assertEq(taskManager.getNextExecutionBlockInRange(10), 0, "Should find no tasks after all tasks");
        assertEq(taskManager.getNextExecutionBlockInRange(5), 0, "Should return 0 for small lookahead");
        assertEq(taskManager.getNextExecutionBlockInRange(10), 0, "Should return 0 for range with no tasks");

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
} 