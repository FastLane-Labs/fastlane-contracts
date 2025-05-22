// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TaskLoadBalancer } from "../../src/task-manager/core/LoadBalancer.sol";
import { Task, Size, Depth, LoadBalancer as LoadBalancerType, Tracker, Trackers } from "../../src/task-manager/types/TaskTypes.sol";

contract TaskLoadBalancerTest is TaskLoadBalancer, Test {

    constructor() TaskLoadBalancer(address(this), 1) {}

    /// @notice Sets up the test environment
    /// @dev Initializes all load balancer pointers to block 99 (one before initial block 100)
    /// This ensures proper task execution flow in tests by having all pointers start at the same block
    function setUp() public {
        vm.roll(100); // Start at block 100
        
        // Initialize active blocks to block 100
        S_loadBalancer.activeBlockSmall = 100;
        S_loadBalancer.activeBlockMedium = 100;
        S_loadBalancer.activeBlockLarge = 100;
    }

    // -----------------------------------------
    // INTERNAL HELPER
    // -----------------------------------------
    /// @notice Mocks a task for testing purposes
    /// @dev Uses _markTaskScheduled to properly update metrics and load balancer state
    /// @param blockNumber The block number to mock the task at
    /// @param size The size of the task to mock
    function _mockTask(uint64 blockNumber, Size size) internal {
        // Initialize trackers for the target block
        Trackers memory trackers;
        trackers.blockNumber = blockNumber;
        trackers.size = size;
        trackers.loadBalancer = S_loadBalancer;

        // Update load balancer pointers to track the latest block for each size
        if (size == Size.Small) {
            if (blockNumber > trackers.loadBalancer.activeBlockSmall) {
                trackers.loadBalancer.activeBlockSmall = blockNumber;
                trackers.updateLoadBalancer = true;
            }
        } else if (size == Size.Medium) {
            if (blockNumber > trackers.loadBalancer.activeBlockMedium) {
                trackers.loadBalancer.activeBlockMedium = blockNumber;
                trackers.updateLoadBalancer = true;
            }
        } else if (size == Size.Large) {
            if (blockNumber > trackers.loadBalancer.activeBlockLarge) {
                trackers.loadBalancer.activeBlockLarge = blockNumber;
                trackers.updateLoadBalancer = true;
            }
        }

        // Load existing metrics for this block
        trackers = _loadAllTrackers(trackers);

        // Mark task as scheduled
        uint16 taskIndexInBlock;
        (trackers, taskIndexInBlock) = _markTaskScheduled(trackers, 1000);

        // Store the updated trackers
        _storeAllTrackers(trackers);

        // Store updated load balancer if needed
        if (trackers.updateLoadBalancer) {
            _storeLoadBalancer(trackers);
        }
    }

    // -----------------------------------------
    // CORE FUNCTIONALITY TESTS
    // -----------------------------------------
    
    function testActiveBlockInitialization() public {
        // Mock tasks in different blocks
        _mockTask(102, Size.Small);
        _mockTask(103, Size.Medium);
        _mockTask(104, Size.Large);

        // Advance to block 104 so Small tasks are available (need to be at least 1 block old)
        vm.roll(104);

        // Set high gas to allow any allocation
        vm.mockCall(
            address(0),
            abi.encodeWithSignature("gasleft()"),
            abi.encode(LARGE_GAS + ITERATION_BUFFER + 5000)
        );

        // Check initial load allocation
        (
            LoadBalancerType memory loadBalancer, 
            Size size, 
            uint64 blockNumber, 
            bool tasksAvailable
        ) = _allocateLoad(0);

        // Should pick the earliest block (102) with Small task
        assertEq(uint8(size), uint8(Size.Small), "Should select Small size");
        assertEq(blockNumber, 102, "Should select block 102");
        // tasksAvailable should not be set since we haven't checked for tasks available yet
        assertFalse(tasksAvailable, "tasksAvailable should not be set");
        assertEq(loadBalancer.activeBlockSmall, 102, "Small block should be 102");
    }

    function testLoadBalancerTaskExecution() public {
        // Mock multiple tasks in same block
        S_loadBalancer.activeBlockSmall = 102;
        S_loadBalancer.activeBlockMedium = 103;
        S_loadBalancer.activeBlockLarge = 104;
        _mockTask(102, Size.Small);
        _mockTask(102, Size.Small);

        // Advance to block 104 so tasks are available (need to be at least 1 block old)
        vm.roll(104);

        // Set high gas for execution
        vm.mockCall(
            address(0),
            abi.encodeWithSignature("gasleft()"),
            abi.encode(LARGE_GAS + ITERATION_BUFFER + 5000)
        );

        // Initialize trackers
        Trackers memory trackers = _initTrackers(0);

        // Load specific tracker to get updated metrics
        trackers = _loadSpecificTracker(trackers, Depth.B);

        // Verify trackers state
        assertEq(trackers.blockNumber, 102, "Block number should be 102");
        assertEq(uint8(trackers.size), uint8(Size.Small), "Size should be Small");
        assertEq(trackers.b.totalTasks, 2, "Should have 2 total tasks");
        assertEq(trackers.b.executedTasks, 0, "Should have 0 executed tasks");
    }

    function testLoadBalancerReallocation() public {
        // Mock tasks of different sizes in same block
        _mockTask(102, Size.Large);
        _mockTask(102, Size.Medium);
        _mockTask(102, Size.Small);

        // Advance to block 104 so tasks are available (need to be at least 1 block old)
        vm.roll(104);

        // First set high gas to get initial allocation
        vm.mockCall(
            address(0),
            abi.encodeWithSignature("gasleft()"),
            abi.encode(LARGE_GAS + ITERATION_BUFFER + 5000)
        );

        // Initialize trackers starting with Large
        Trackers memory trackers = _initTrackers(0);
        
        // Then set medium gas to force reallocation
        vm.mockCall(
            address(0),
            abi.encodeWithSignature("gasleft()"),
            abi.encode(MEDIUM_GAS + ITERATION_BUFFER + 1000)
        );

        // Reallocate load
        trackers = _reallocateLoad(trackers);

        // Should reallocate to Medium
        assertEq(uint8(trackers.size), uint8(Size.Medium), "Should reallocate to Medium");
        // tasksAvailable should not be set since we haven't checked for tasks available yet
        assertFalse(trackers.tasksAvailable, "tasksAvailable should not be set");
    }

    function testLoadBalancerGasLimits() public {
        // Mock a large task at block 102
        _mockTask(102, Size.Large);

        // We haven't rolled to 102, but let's see if code tries to pick it up anyway
        // Set gas too low for any tasks
        vm.mockCall(
            address(0),
            abi.encodeWithSignature("gasleft()"),
            abi.encode(SMALL_GAS)
        );

        uint256 initialGas = gasleft();

        // Try to allocate load
        (, Size size, uint64 blockNumber, bool tasksAvailable) = _allocateLoad(initialGas);
        
        // Should not allocate any task due to low gas
        assertFalse(tasksAvailable, "Tasks should not be available with low gas");
        assertEq(uint8(size), uint8(Size.Small), "Size should default to Small");
        assertEq(blockNumber, 0, "Block number should be 0 when no allocation");
    }

    function testLoadBalancerMetricsTracking() public {
        // Mock a task
        _mockTask(102, Size.Small);

        // Advance to block 102
        vm.roll(102);

        // Set high gas for execution
        vm.mockCall(
            address(0),
            abi.encodeWithSignature("gasleft()"),
            abi.encode(LARGE_GAS + ITERATION_BUFFER + 5000)
        );
        uint256 initialGas = gasleft() - LARGE_GAS + ITERATION_BUFFER + 5000;
        // Get initial metrics
        Trackers memory trackers = _initTrackers(initialGas);
        uint256 initialTotal = trackers.b.totalTasks;
        uint256 initialExecuted = trackers.b.executedTasks;

        // Mark task as complete
        trackers = _markTaskComplete(trackers, 1000); // 1000 as example fee paid

        // Verify metrics updated
        assertEq(trackers.b.totalTasks, initialTotal, "Total tasks should remain same");
        assertEq(trackers.b.executedTasks, initialExecuted + 1, "Executed tasks should increment");
        assertEq(trackers.b.cumulativeFeesPaid, 1000, "Fees paid should be recorded");

        // Store the updated metrics
        _storeAllTrackers(trackers);
    }

    // -----------------------------------------
    // EDGE CASE TESTS
    // -----------------------------------------


    /**
     * @dev Tests scheduling tasks at blocks beyond our typical horizon.
     */
    function testEdgeCaseBlockMaximum() public {
        // Suppose we allow scheduling up to currentBlock + _GROUP_SIZE = 100 + 128 = 228
        // We'll schedule at exactly 228
        uint64 farBlock = 100 + uint64(_GROUP_SIZE); // or 228

        S_loadBalancer.activeBlockSmall = farBlock;  // We'll pretend there's something at 228
        S_loadBalancer.activeBlockMedium = farBlock;  // We'll pretend there's something at 228
        S_loadBalancer.activeBlockLarge = farBlock;  // We'll pretend there's something at 228
        _mockTask(farBlock, Size.Large);

        // Advance chain to farBlock + 2 so tasks are available (need to be at least 1 block old)
        vm.roll(farBlock + 2);

        // Gas is sufficient
        vm.mockCall(
            address(0),
            abi.encodeWithSignature("gasleft()"),
            abi.encode(LARGE_GAS + ITERATION_BUFFER + 5000)
        );

        // Should pick up the task now
        (,, uint64 blockNumber, bool tasksAvailable) = _allocateLoad(0);
        // tasksAvailable should not be set since we haven't checked for tasks available yet
        assertFalse(tasksAvailable, "tasksAvailable should not be set");
        assertEq(blockNumber, farBlock, "Should allocate tasks at block 228");
    }

    /**
     * @dev Tests partial completion of tasks in a single block.
     */
    function testPartialCompletionInBlock() public {
        // Mock 3 tasks in block 102
        _mockTask(100, Size.Small);
        _mockTask(100, Size.Small);
        _mockTask(100, Size.Small);

        // Advance to block 104 so tasks are available
        vm.roll(104);

        // High gas for initialization
        vm.mockCall(
            address(0),
            abi.encodeWithSignature("gasleft()"),
            abi.encode(MEDIUM_GAS)
        );

        // Initialize and load trackers
        Trackers memory trackers = _initTrackers(0);
        trackers.size = Size.Small;
        trackers = _loadAllTrackers(trackers);

        // Verify initial state
        assertTrue(trackers.tasksAvailable, "Tasks exist");
        assertEq(trackers.b.totalTasks, 3, "3 tasks total");
        assertEq(trackers.b.executedTasks, 0, "0 tasks executed initially");

        // Mark 2 tasks as completed
        trackers = _markTaskComplete(trackers, 500); // First task
        trackers = _markTaskComplete(trackers, 500); // Second task
        _storeAllTrackers(trackers);

        // Reload trackers to verify state
        trackers = _loadAllTrackers(trackers);
        assertEq(trackers.b.totalTasks, 3, "Total remains 3");
        assertEq(trackers.b.executedTasks, 2, "Should have 1 left unexecuted");
        assertEq(trackers.b.cumulativeFeesPaid, 1000, "Should record fees for 2 tasks");
        assertTrue(trackers.tasksAvailable, "Should still have tasks available");
    }
} 