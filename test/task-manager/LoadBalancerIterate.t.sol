// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { Size, Depth, LoadBalancer, Tracker, Trackers } from "src/task-manager/types/TaskTypes.sol";
import { TaskLoadBalancer } from "src/task-manager/core/LoadBalancer.sol";

contract TestLoadBalancerIterate is TaskLoadBalancer {
    constructor(address shMonad, uint64 policyId) TaskLoadBalancer(shMonad, policyId) {}
    // Expose internal functions for testing
    function iterate(Trackers memory trackers, uint256 targetGasReserve) public returns (Trackers memory) {
        return _iterate(trackers, targetGasReserve, uint64(block.number - 1));
    }

    function markTaskScheduled(Trackers memory trackers, uint256 unadjFeeCollected) 
        public 
        pure 
        returns (Trackers memory, uint16) 
    {
        return _markTaskScheduled(trackers, unadjFeeCollected);
    }

    function loadAllTrackers(Trackers memory trackers) public view returns (Trackers memory) {
        return _loadAllTrackers(trackers);
    }

    function storeAllTrackers(Trackers memory trackers) public {
        _storeAllTrackers(trackers);
    }

    // Helper to initialize trackers for testing
    function initializeTrackers(uint64 blockNumber, Size size) public view returns (Trackers memory) {
        Trackers memory trackers;
        trackers.blockNumber = blockNumber;
        trackers.size = size;
        trackers.targetGasReserve = 100000;
        trackers.loadBalancer = S_loadBalancer;
        return _loadAllTrackers(trackers);
    }
}

contract LoadBalancerIterateTest is Test {
    TestLoadBalancerIterate loadBalancer;
    uint256 constant TARGET_GAS_RESERVE = 100000;

    function setUp() public {
        loadBalancer = new TestLoadBalancerIterate(address(this), 1);
        vm.roll(1000); // Set a reasonable block number for testing
    }

    // Helper to schedule tasks in a block
    function scheduleTasksInBlock(uint64 blockNumber, Size size, uint256 numTasks) internal returns (Trackers memory) {
        // First load trackers for the target block
        Trackers memory trackers = loadBalancer.initializeTrackers(blockNumber, size);
        
        // Schedule the tasks
        for (uint256 i = 0; i < numTasks; i++) {
            (trackers, ) = loadBalancer.markTaskScheduled(trackers, 1 ether); // Use 1 ether as dummy fee
        }
        
        // Store all metrics for this block
        loadBalancer.storeAllTrackers(trackers);
        
        // Return the updated trackers
        return trackers;
    }

    function test_Iterate_SingleBlockWithTasks() public {
        // Schedule 3 tasks in block 100
        uint64 startBlock = 100;
        Trackers memory trackers = scheduleTasksInBlock(startBlock, Size.Small, 3);
        
        // Verify initial state
        assertEq(trackers.b.totalTasks, 3, "Should have 3 tasks scheduled");
        assertEq(trackers.b.executedTasks, 0, "Should have 0 tasks executed");
        
        // Run iteration
        trackers = loadBalancer.iterate(trackers, TARGET_GAS_RESERVE);
        
        // Verify we stay on the same block since it has unexecuted tasks
        assertEq(trackers.blockNumber, startBlock, "Should stay on same block with unexecuted tasks");
        assertTrue(trackers.tasksAvailable, "Should indicate tasks are available");
    }

    function test_Iterate_EmptyBlockSkipping() public {
        // Start at block 100, but schedule tasks in block 120
        uint64 startBlock = 100;
        uint64 taskBlock = 120;
        
        // Schedule tasks in block 120 first
        scheduleTasksInBlock(taskBlock, Size.Small, 2);
        
        // Then initialize trackers at start block and verify iteration
        Trackers memory trackers = loadBalancer.initializeTrackers(startBlock, Size.Small);
        
        // Run iteration
        trackers = loadBalancer.iterate(trackers, TARGET_GAS_RESERVE);
        
        // We should have moved forward to the block containing tasks
        assertEq(
            trackers.blockNumber,
            taskBlock,
            "Should have moved to the block containing tasks"
        );
        assertTrue(trackers.tasksAvailable, "Should indicate tasks are available");
    }

    function test_Iterate_CrossingGroupBoundary() public {
        // Schedule tasks in blocks that cross a group boundary
        uint64 groupSize = 128; // _GROUP_SIZE
        uint64 startBlock = groupSize - 2; // Near end of first group
        uint64 taskBlock = groupSize + 2; // Start of next group
        
        // Initialize and schedule tasks
        scheduleTasksInBlock(taskBlock, Size.Small, 2);
        Trackers memory trackers = loadBalancer.initializeTrackers(startBlock, Size.Small);
        
        // Run iteration
        trackers = loadBalancer.iterate(trackers, TARGET_GAS_RESERVE);
        
        // Should have moved to the block containing tasks
        assertEq(
            trackers.blockNumber,
            taskBlock,
            "Should have moved to the block containing tasks"
        );
        assertTrue(trackers.tasksAvailable, "Should indicate tasks are available");
    }

    function test_Iterate_ReachingChainTip() public {
        uint64 startBlock = uint64(block.number) - 10;
        
        // Initialize trackers near chain tip
        Trackers memory trackers = loadBalancer.initializeTrackers(startBlock, Size.Small);
        
        // Run iteration
        trackers = loadBalancer.iterate(trackers, TARGET_GAS_RESERVE);
        
        // Should stop at block.number - 1
        assertEq(
            trackers.blockNumber,
            uint64(block.number - 1),
            "Should stop at block.number - 1 to prevent same-block execution"
        );
        assertFalse(trackers.tasksAvailable, "Should indicate no tasks available at chain tip");
    }

    function test_Iterate_MultipleGroupsWithTasks() public {
        uint64 groupSize = 128; // _GROUP_SIZE
        uint64 startBlock = 100;
        
        // Schedule tasks in multiple groups
        scheduleTasksInBlock(startBlock, Size.Small, 2); // First group
        scheduleTasksInBlock(startBlock + groupSize, Size.Small, 2); // Second group
        scheduleTasksInBlock(startBlock + (2 * groupSize), Size.Small, 2); // Third group
        
        Trackers memory trackers = loadBalancer.initializeTrackers(startBlock, Size.Small);
        
        // Run iteration
        trackers = loadBalancer.iterate(trackers, TARGET_GAS_RESERVE);
        
        // Should find tasks in the first group
        assertEq(trackers.blockNumber, startBlock, "Should find tasks in first group");
        assertTrue(trackers.tasksAvailable, "Should indicate tasks are available");
    }

    function test_Iterate_LowGasScenario() public {
        uint64 startBlock = 100;
        
        // Schedule some tasks
        scheduleTasksInBlock(startBlock + 50, Size.Small, 2);
        
        Trackers memory trackers = loadBalancer.initializeTrackers(startBlock, Size.Small);
        
        // Set very high gas reserve to simulate low gas scenario
        uint256 highGasReserve = gasleft() - 50000; // Leave only 50k gas
        
        // Run iteration
        trackers = loadBalancer.iterate(trackers, highGasReserve);
        
        // Should not have processed much due to gas constraints
        assertTrue(
            trackers.blockNumber >= startBlock && trackers.blockNumber < startBlock + 50,
            "Should have limited progress due to gas"
        );
    }
} 