// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Size, Depth, LoadBalancer, Tracker, Trackers } from "../types/TaskTypes.sol";
import { TaskStorage } from "./Storage.sol";
import { TaskErrors } from "../types/TaskErrors.sol";

/// @title TaskLoadBalancer
/// @notice Handles task execution balancing and performance tracking
/// @dev Core component responsible for:
/// 1. Task Prioritization:
///    - Balances execution between Small, Medium, and Large tasks
///    - Prioritizes tasks with longest delays
///    - Ensures gas efficiency across different task sizes
///
/// 2. Block Management:
///    - Groups blocks for efficient searching (_GROUP_SIZE blocks per group)
///    - Uses bitmap for quick task presence checks
///    - Maintains metrics at multiple depths (block, group, supergroup)
///
/// 3. Performance Optimization:
///    - Adapts to network conditions via targetDelay and growthRate
///    - Prevents gas exhaustion with size-specific limits
///    - Enables efficient backlog processing
///
/// Storage Layout:
/// - Uses hierarchical tracking system (Depth.B -> block, Depth.C -> group, Depth.D -> supergroup)
/// - Maintains separate queues for each task size
/// - Stores execution metrics for performance analysis
///
/// TODO: Consider splitting bitmap management into a separate library
/// TODO: Add support for dynamic gas limits based on network conditions

abstract contract TaskLoadBalancer is TaskStorage {
    /**
     * @notice Constructor to set immutable variables
     * @param shMonad The address of the shMonad contract
     * @param policyId The policy ID for the task manager
     */
    constructor(address shMonad, uint64 policyId) TaskStorage(shMonad, policyId) { }

    /**
     * @notice Allocates load for task execution based on available gas and task metrics
     * @dev Determines which queue (Small, Medium, Large) to process based on:
     * 1. Available gas for execution
     * 2. Task availability in each queue
     * 3. Block progression and task metrics
     *
     * Gas Allocation Strategy:
     * - Large tasks: Requires > LARGE_GAS
     * - Medium tasks: Requires > MEDIUM_GAS
     * - Small tasks: Requires > SMALL_GAS
     *
     * Selection Priority:
     * 1. Large tasks with longest delay
     * 2. Medium tasks with longer delay than Small
     * 3. Small tasks if sufficient gas
     *
     * @param targetGasReserve Gas to reserve for post-execution operations
     * @return loadBalancer Current state of the load balancer
     * @return size Selected queue size for execution
     * @return blockNumber Target block for execution
     * @return tasksAvailable Whether tasks are available for execution
     */
    function _allocateLoad(uint256 targetGasReserve)
        internal
        view
        returns (LoadBalancer memory loadBalancer, Size size, uint64 blockNumber, bool tasksAvailable)
    {
        loadBalancer = S_loadBalancer;

        if (gasleft() < targetGasReserve + ITERATION_BUFFER + 5000) {
            return (loadBalancer, size, blockNumber, tasksAvailable);
        }

        uint256 _gasAvailable = gasleft() - targetGasReserve - ITERATION_BUFFER - 5000;

        // 1. Try Large queue if we have enough gas and it has longest delay
        if (
            _gasAvailable > LARGE_GAS && loadBalancer.activeBlockLarge < block.number
                && (loadBalancer.activeBlockLarge <= loadBalancer.activeBlockMedium)
                && (loadBalancer.activeBlockLarge <= loadBalancer.activeBlockSmall)
        ) {
            size = Size.Large;
            blockNumber = loadBalancer.activeBlockLarge;
            tasksAvailable = false;
            return (loadBalancer, size, blockNumber, tasksAvailable);
        }

        // 2. Try Medium queue if we have enough gas and it has longer delay than Small
        if (
            _gasAvailable > MEDIUM_GAS && loadBalancer.activeBlockMedium < block.number
                && (loadBalancer.activeBlockMedium <= loadBalancer.activeBlockSmall)
        ) {
            size = Size.Medium;
            blockNumber = loadBalancer.activeBlockMedium;
            tasksAvailable = false;
            return (loadBalancer, size, blockNumber, tasksAvailable);
        }

        // 3. Try Small queue if we have enough gas
        if (_gasAvailable > SMALL_GAS && loadBalancer.activeBlockSmall < block.number) {
            size = Size.Small;
            blockNumber = loadBalancer.activeBlockSmall;
            tasksAvailable = false;
            return (loadBalancer, size, blockNumber, tasksAvailable);
        }
    }

    /**
     * @notice Reallocates load when current queue is depleted or gas is insufficient
     * @dev Implements a fallback strategy for task execution:
     * 1. If Large queue depleted/insufficient gas -> try Medium
     * 2. If Medium queue depleted/insufficient gas -> try Small
     * 3. If no viable queues -> mark no tasks available
     *
     * Gas Requirements:
     * - Medium fallback: > MEDIUM_GAS + buffer
     * - Small fallback: > SMALL_GAS + buffer
     *
     * @param trackers Current execution metrics and state
     * @return Updated trackers with new allocation if available
     */
    function _reallocateLoad(Trackers memory trackers) internal view returns (Trackers memory) {
        // If we're doing a large queue and don't have enough gas left for another, try medium.
        LoadBalancer memory loadBalancer = trackers.loadBalancer;

        require(!trackers.updateAllTrackers, "ERR-Unreachable1");

        if (gasleft() < trackers.targetGasReserve + ITERATION_BUFFER + 5000) {
            trackers.tasksAvailable = false;
            return trackers;
        }
        uint256 _gasAvailable = gasleft() - trackers.targetGasReserve - ITERATION_BUFFER - 5000;

        // Try to reallocate to medium if currently on large or no size
        if (
            // all checks
            (trackers.size == Size.Large || trackers.size == Size(0)) && _gasAvailable > MEDIUM_GAS // Include buffer in
                && loadBalancer.activeBlockMedium < block.number
        ) {
            // Check if there are actually unexecuted tasks
            trackers.size = Size.Medium;
            trackers.blockNumber = loadBalancer.activeBlockMedium;
            trackers.tasksAvailable = false;

            // Try to reallocate to small if on medium/large or no size
        } else if (
            // all checks
            (trackers.size >= Size.Medium || trackers.size == Size(0)) && _gasAvailable > SMALL_GAS // Include buffer in
                && loadBalancer.activeBlockSmall < block.number
        ) {
            // Check if there are actually unexecuted tasks
            trackers.size = Size.Small;
            trackers.blockNumber = loadBalancer.activeBlockSmall;
            trackers.tasksAvailable = false;
        }

        trackers.b = _blankTracker();
        trackers.c = _blankTracker();
        trackers.d = _blankTracker();

        return trackers;
    }

    function _blankTracker() internal pure returns (Tracker memory tracker) {
        tracker = Tracker({
            totalTasks: 0,
            executedTasks: 0,
            cumulativeDelays: 0,
            cumulativeFeesCollected: 0,
            cumulativeFeesPaid: 0,
            bitmap: 0
        });
    }

    /// @notice Forecasts metrics for a future block to generate price quotes
    /// @dev Uses current load balancer state to predict execution metrics
    /// Loads metrics at all depths (block, group, supergroup) for the target block
    /// @param targetBlockNumber The future block to forecast metrics for
    /// @param size The size category of tasks to forecast
    /// @return trackers Predicted metrics for the target block
    function _forecastTrackers(uint64 targetBlockNumber, Size size) internal view returns (Trackers memory trackers) {
        // TODO: a custom loadAllTrackers function to get last completed groupings to compare.
        trackers.loadBalancer = S_loadBalancer;
        trackers.blockNumber = targetBlockNumber;
        trackers.size = size;

        return _loadAllTrackers(trackers);
    }

    function _swapInRescheduleTrackers(
        Trackers memory trackers,
        uint64 targetBlockNumber,
        Size size
    )
        internal
        view
        returns (Trackers memory rescheduleTrackers)
    {
        /*
       // NOTE: Currently, the size of a rescheduled task cannot change
        if (trackers.size != size) {
            return _loadAllTrackers(trackers);
        }
        */

        rescheduleTrackers.blockNumber = targetBlockNumber;
        rescheduleTrackers.size = size;

        // Load B level metrics (individual blocks)
        // NOTE: We can't reschedule a task in the same block it's executed in
        rescheduleTrackers.b = S_metrics[rescheduleTrackers.size][Depth.B][uint256(targetBlockNumber)];

        uint256 _rescheduleIndexC = rescheduleTrackers.blockNumber / _GROUP_SIZE;
        uint256 _originalIndexC = trackers.blockNumber / _GROUP_SIZE;
        if (_rescheduleIndexC == _originalIndexC) {
            rescheduleTrackers.c = trackers.c;
        } else {
            rescheduleTrackers.c = S_metrics[rescheduleTrackers.size][Depth.C][_rescheduleIndexC];
        }

        uint256 _rescheduleIndexD = rescheduleTrackers.blockNumber / (_GROUP_SIZE * _GROUP_SIZE);
        uint256 _originalIndexD = trackers.blockNumber / (_GROUP_SIZE * _GROUP_SIZE);
        if (_rescheduleIndexD == _originalIndexD) {
            rescheduleTrackers.d = trackers.d;
        } else {
            rescheduleTrackers.d = S_metrics[rescheduleTrackers.size][Depth.D][_rescheduleIndexD];
        }
    }

    function _swapOutRescheduleTrackers(
        Trackers memory rescheduleTrackers,
        Trackers memory trackers
    )
        internal
        returns (Trackers memory)
    {
        /*
        // NOTE: Currently, the size of a rescheduled task cannot change
        if (trackers.size != rescheduleTrackers.size) {
            _storeAllTrackers(rescheduleTrackers);
            return trackers;
        }
        */

        // Store B level metrics (individual blocks)
        S_metrics[rescheduleTrackers.size][Depth.B][uint256(rescheduleTrackers.blockNumber)] = rescheduleTrackers.b;

        uint256 _rescheduleIndexC = rescheduleTrackers.blockNumber / _GROUP_SIZE;
        uint256 _originalIndexC = trackers.blockNumber / _GROUP_SIZE;
        if (_rescheduleIndexC == _originalIndexC) {
            trackers.c = rescheduleTrackers.c;
        } else {
            S_metrics[rescheduleTrackers.size][Depth.C][_rescheduleIndexC] = rescheduleTrackers.c;
        }

        uint256 _rescheduleIndexD = rescheduleTrackers.blockNumber / (_GROUP_SIZE * _GROUP_SIZE);
        uint256 _originalIndexD = trackers.blockNumber / (_GROUP_SIZE * _GROUP_SIZE);
        if (_rescheduleIndexD == _originalIndexD) {
            trackers.d = rescheduleTrackers.d;
        } else {
            S_metrics[rescheduleTrackers.size][Depth.D][_rescheduleIndexD] = rescheduleTrackers.d;
        }

        return trackers;
    }

    /**
     * @notice Initializes tracking metrics for task execution
     * @dev Sets up initial state by:
     * 1. Getting load allocation based on current gas conditions
     * 2. Loading metrics at all depths for the allocated block
     * 3. Setting up gas reserves and availability flags
     *
     * @param targetGasReserve Gas to reserve for post-execution operations
     * @return trackers Initialized tracking metrics for execution
     */
    function _initTrackers(uint256 targetGasReserve) internal view returns (Trackers memory trackers) {
        // Get initial load allocation
        (LoadBalancer memory _loadBalancer, Size _size, uint64 _blockNumber, bool _tasksAvailable) =
            _allocateLoad(targetGasReserve);
        trackers.targetGasReserve = targetGasReserve;
        trackers.loadBalancer = _loadBalancer;
        trackers.blockNumber = _blockNumber;
        trackers.size = _size;
        trackers.tasksAvailable = _tasksAvailable;

        return trackers;
    }

    /**
     * @notice Loads metrics for all tracking depths (B, C, D)
     * @dev Retrieves and processes metrics at each depth level:
     * - B (Block): Individual block metrics
     * - C (Group): Group of blocks metrics (_GROUP_SIZE)
     * - D (Supergroup): Supergroup metrics (_GROUP_SIZE^2)
     *
     * Task Availability Logic:
     * - Only considers B-level (block) tasks for immediate execution
     * - Tasks are available if totalTasks > executedTasks
     *
     * @param trackers Current tracking state to load metrics into
     * @return Updated trackers with metrics loaded at all depths
     */
    function _loadAllTrackers(Trackers memory trackers) internal view returns (Trackers memory) {
        uint256 _index = trackers.blockNumber;
        Size _size = trackers.size;

        // Load B level metrics (individual blocks)
        trackers.b = S_metrics[_size][Depth.B][_index];

        // Load C level metrics (groups of blocks)
        _index = trackers.blockNumber / _GROUP_SIZE;
        trackers.c = S_metrics[_size][Depth.C][_index];

        // Load D level metrics (supergroups)
        _index = trackers.blockNumber / (_GROUP_SIZE * _GROUP_SIZE);
        trackers.d = S_metrics[_size][Depth.D][_index];

        // Only check B-level tasks since that's where execution happens
        // Tasks are only available if we have unexecuted tasks in the current block
        if (trackers.b.totalTasks > 0) {
            trackers.tasksAvailable = trackers.b.totalTasks > trackers.b.executedTasks;
        }

        return trackers;
    }

    /**
     * @notice Stores updated load balancer state
     * @dev Simple storage operation that:
     * 1. Updates all queue pointers
     * 2. Preserves task execution order
     * 3. Maintains block progression
     *
     * @param trackers Current tracking state with load balancer updates
     */
    function _storeLoadBalancer(Trackers memory trackers) internal {
        S_loadBalancer = trackers.loadBalancer;
    }

    /**
     * @notice Stores metrics for all tracking depths
     * @dev Comprehensive storage update:
     * 1. Updates B level if tasks exist
     * 2. Updates C level if group has tasks
     * 3. Updates D level if supergroup has tasks
     *
     * Storage Optimization:
     * - Only stores non-empty metrics
     * - Uses appropriate indexing for each depth
     * - Preserves task count integrity
     *
     * @param trackers Current execution metrics and state to store
     */
    function _storeAllTrackers(Trackers memory trackers) internal {
        // Store B level metrics (individual blocks)
        if (trackers.b.totalTasks > 0) {
            uint256 _indexB = trackers.blockNumber;
            S_metrics[trackers.size][Depth.B][_indexB] = trackers.b;
        }

        // Store C level metrics (groups of blocks)
        if (trackers.c.totalTasks > 0) {
            uint256 _indexC = trackers.blockNumber / _GROUP_SIZE;
            S_metrics[trackers.size][Depth.C][_indexC] = trackers.c;
        }

        // Store D level metrics (supergroups)
        if (trackers.d.totalTasks > 0) {
            uint256 _indexD = trackers.blockNumber / (_GROUP_SIZE * _GROUP_SIZE);
            S_metrics[trackers.size][Depth.D][_indexD] = trackers.d;
        }
    }

    /**
     * @notice Stores metrics for a specific tracking depth
     * @dev Updates storage for the specified depth level:
     * - B: Individual block metrics
     * - C: Group metrics (_GROUP_SIZE blocks)
     * - D: Supergroup metrics (_GROUP_SIZE^2 blocks)
     *
     * Index Calculation:
     * - B: Direct block number
     * - C: Block number / _GROUP_SIZE
     * - D: Block number / (_GROUP_SIZE^2)
     *
     * @param trackers Current tracking state
     * @param depth The depth level to store metrics for
     */
    function _storeSpecificTracker(Trackers memory trackers, Depth depth) internal {
        if (depth == Depth.B) {
            uint256 _index = trackers.blockNumber;
            S_metrics[trackers.size][Depth.B][_index] = trackers.b;
        } else if (depth == Depth.C) {
            uint256 _index = trackers.blockNumber / _GROUP_SIZE;
            S_metrics[trackers.size][Depth.C][_index] = trackers.c;
        } else if (depth == Depth.D) {
            uint256 _index = trackers.blockNumber / (_GROUP_SIZE ** 2);
            S_metrics[trackers.size][Depth.D][_index] = trackers.d;
        }
    }

    /**
     * @notice Loads metrics for a specific tracking depth
     * @dev Retrieves metrics for specified depth level:
     * - B: Individual block metrics
     * - C: Group metrics (_GROUP_SIZE blocks)
     * - D: Supergroup metrics (_GROUP_SIZE^2 blocks)
     *
     * Index Calculation:
     * - B: Direct block number
     * - C: Block number / _GROUP_SIZE
     * - D: Block number / (_GROUP_SIZE^2)
     *
     * @param trackers Current tracking state
     * @param depth The depth level to load metrics for
     * @return Updated trackers with loaded metrics
     */
    function _loadSpecificTracker(Trackers memory trackers, Depth depth) internal view returns (Trackers memory) {
        uint256 _index;
        if (depth == Depth.B) {
            _index = trackers.blockNumber;
            trackers.b = S_metrics[trackers.size][Depth.B][_index];
        } else if (depth == Depth.C) {
            _index = trackers.blockNumber / _GROUP_SIZE;
            trackers.c = S_metrics[trackers.size][Depth.C][_index];
        } else if (depth == Depth.D) {
            _index = trackers.blockNumber / (_GROUP_SIZE * _GROUP_SIZE);
            trackers.d = S_metrics[trackers.size][Depth.D][_index];
        }
        return trackers;
    }

    /**
     * @notice Checks if tasks are available at specified depth
     * @dev Compares executed tasks against total tasks:
     * - Available if executedTasks < totalTasks
     * - Checks appropriate counter for depth level
     *
     * @param trackers Current tracking state
     * @param depth Depth level to check
     * @return tasksAvailable True if unexecuted tasks exist
     */
    function _taskAvailableAtDepth(Trackers memory trackers, Depth depth) internal pure returns (bool tasksAvailable) {
        if (depth == Depth.B) {
            tasksAvailable = trackers.b.executedTasks < trackers.b.totalTasks;
        } else if (depth == Depth.C) {
            tasksAvailable = trackers.c.executedTasks < trackers.c.totalTasks;
        } else if (depth == Depth.D) {
            tasksAvailable = trackers.d.executedTasks < trackers.d.totalTasks;
        }
    }

    /**
     * @notice Verifies if tasks existed at specified depth
     * @dev Checks total task counter:
     * - True if totalTasks > 0
     * - Checks appropriate counter for depth level
     *
     * @param trackers Current tracking state
     * @param depth Depth level to check
     * @return tasksExisted True if tasks were present
     */
    function _taskExistedAtDepth(Trackers memory trackers, Depth depth) internal pure returns (bool tasksExisted) {
        if (depth == Depth.B) {
            tasksExisted = trackers.b.totalTasks > 0;
        } else if (depth == Depth.C) {
            tasksExisted = trackers.c.totalTasks > 0;
        } else if (depth == Depth.D) {
            tasksExisted = trackers.d.totalTasks > 0;
        }
    }

    /**
     * @notice Checks if tasks are completed at specified depth
     * @dev Verifies completion status:
     * - True if totalTasks > 0 && totalTasks == executedTasks
     * - Checks appropriate counters for depth level
     * - Used for progression tracking
     *
     * @param trackers Current tracking state
     * @param depth Depth level to check
     * @return tasksCompleted True if all tasks are executed
     */
    function _taskCompletedAtDepth(Trackers memory trackers, Depth depth) internal pure returns (bool tasksCompleted) {
        if (depth == Depth.B) {
            tasksCompleted = trackers.b.totalTasks > 0 && trackers.b.totalTasks == trackers.b.executedTasks;
        } else if (depth == Depth.C) {
            tasksCompleted = trackers.c.totalTasks > 0 && trackers.c.totalTasks == trackers.c.executedTasks;
        } else if (depth == Depth.D) {
            tasksCompleted = trackers.d.totalTasks > 0 && trackers.d.totalTasks == trackers.d.executedTasks;
        }
    }

    /**
     * @notice Stores completion status for tasks at and below depth
     * @dev Updates completion metrics hierarchically:
     * 1. Stores B level if completed
     * 2. Stores C level if in scope
     * 3. Stores D level if in scope
     *
     * Completion Logic:
     * - Higher level completion implies lower level completion
     * - Only stores if metrics were fully loaded
     * - Updates all relevant depth levels
     *
     * @param trackers Current tracking state
     * @param depth Highest depth level to store
     */
    function _storeCompletedTasksAtAndBelowDepth(Trackers memory trackers, Depth depth) internal {
        // NOTE: if a higher-level tracker is complete, all lower levels should also
        // be complete as long as they were fully loaded.
        uint256 _index;
        if (depth == Depth.B) {
            _index = trackers.blockNumber;
            S_metrics[trackers.size][Depth.B][_index] = trackers.b;
        } else if (depth == Depth.C) {
            if (trackers.b.totalTasks > 0 && trackers.b.totalTasks == trackers.b.executedTasks) {
                _index = trackers.blockNumber;
                S_metrics[trackers.size][Depth.B][_index] = trackers.b;
            }
            _index = trackers.blockNumber / _GROUP_SIZE;
            S_metrics[trackers.size][Depth.C][_index] = trackers.c;
        } else if (depth == Depth.D) {
            if (trackers.b.totalTasks > 0 && trackers.b.totalTasks == trackers.b.executedTasks) {
                _index = trackers.blockNumber;
                S_metrics[trackers.size][Depth.B][_index] = trackers.b;
            }
            if (trackers.c.totalTasks > 0 && trackers.c.totalTasks == trackers.c.executedTasks) {
                _index = trackers.blockNumber / _GROUP_SIZE;
                S_metrics[trackers.size][Depth.C][_index] = trackers.c;
            }
            _index = trackers.blockNumber / (_GROUP_SIZE * _GROUP_SIZE);
            S_metrics[trackers.size][Depth.D][_index] = trackers.d;
        }
    }

    /**
     * @notice Clears tracker data at and below specified depth
     * @dev Hierarchical cleanup operation:
     * - B: Clears only block level
     * - C: Clears block and group levels
     * - D: Clears all levels
     *
     * Used for:
     * - Resetting metrics after completion
     * - Preparing for new task allocation
     * - Cleaning up after iterations
     *
     * @param trackers Current tracking state
     * @param depth Highest depth level to clear
     * @return Updated trackers with cleared metrics
     */
    function _clearTrackerAtAndBelowDepth(
        Trackers memory trackers,
        Depth depth
    )
        internal
        pure
        returns (Trackers memory)
    {
        if (depth == Depth.B) {
            trackers.b = _blankTracker();
        } else if (depth == Depth.C) {
            trackers.b = _blankTracker();
            trackers.c = _blankTracker();
        } else if (depth == Depth.D) {
            trackers.b = _blankTracker();
            trackers.c = _blankTracker();
            trackers.d = _blankTracker();
        }
        return trackers;
    }

    /**
     * @notice Retrieves bitmap for specified depth level
     * @dev Returns appropriate bitmap based on depth:
     * - B: Uses C level bitmap
     * - C: Uses D level bitmap
     * - D: Returns full bitmap (0xffffffff)
     *
     * Used for:
     * - Task presence checking
     * - Block navigation
     * - Iteration optimization
     *
     * @param trackers Current tracking state
     * @param depth Depth level to get bitmap for
     * @return bitmap Bitmap for specified depth
     */
    function _bitmapForDepth(Trackers memory trackers, Depth depth) internal pure returns (uint256 bitmap) {
        if (depth == Depth.B) {
            bitmap = uint256(trackers.c.bitmap);
        } else if (depth == Depth.C) {
            bitmap = uint256(trackers.d.bitmap);
        } else if (depth == Depth.D) {
            bitmap = uint256(uint32(0xffffffff));
        }
    }

    /**
     * @notice Records a new task being scheduled
     * @dev Updates metrics at all tracking depths:
     * 1. Sets bitmap bits for task presence tracking
     * 2. Increments task counters at all levels
     * 3. Updates cumulative fee metrics
     *
     * Bitmap Updates:
     * - C level: Tracks 4-block groups within current group
     * - D level: Tracks groups within supergroup
     *
     * @param trackers Current tracking state
     * @param unadjFeeCollected Raw fee amount collected for task
     * @return Updated trackers and task's position in block
     * @return taskIndexInBlock Index assigned to task in current block
     */
    function _markTaskScheduled(
        Trackers memory trackers,
        uint256 unadjFeeCollected
    )
        internal
        pure
        returns (Trackers memory, uint16 taskIndexInBlock)
    {
        trackers.updateAllTrackers = true;
        // For C bitmap: track 4-block groups within the current group
        uint256 _groupBit = (trackers.blockNumber % _GROUP_SIZE) / _BITMAP_SPECIFICITY;
        // Set the bit for this sub-chunk
        trackers.c.bitmap |= uint32(1 << _groupBit);

        // For D bitmap: set bit 0 to indicate tasks exist in this supergroup
        _groupBit = (trackers.blockNumber % (_GROUP_SIZE ** 2)) / (_BITMAP_SPECIFICITY * _GROUP_SIZE);
        trackers.d.bitmap |= uint32(1 << _groupBit);

        // Always use the next available index in the block
        taskIndexInBlock = uint16(trackers.b.totalTasks);

        // Increment task counters
        trackers.b.totalTasks++;
        trackers.c.totalTasks++;
        trackers.d.totalTasks++;

        // Add fee to cumulative fees
        trackers.b.cumulativeFeesCollected += uint64(unadjFeeCollected);
        trackers.c.cumulativeFeesCollected += uint64(unadjFeeCollected);
        trackers.d.cumulativeFeesCollected += uint64(unadjFeeCollected);

        return (trackers, taskIndexInBlock);
    }

    /**
     * @notice Records task completion and updates execution metrics
     * @dev Updates metrics at all tracking depths:
     * 1. Increments executed task counters
     * 2. Updates cumulative fees paid
     * 3. Records execution delays
     *
     * Delay Calculation:
     * - Measures blocks between scheduling and execution
     * - Updates delay metrics at all levels
     *
     * @param trackers Current tracking state
     * @param adjFeePaid Adjusted fee amount paid for execution
     * @return Updated trackers with completion metrics
     */
    function _markTaskComplete(Trackers memory trackers, uint256 adjFeePaid) internal view returns (Trackers memory) {
        trackers.updateAllTrackers = true;

        ++trackers.b.executedTasks;
        ++trackers.c.executedTasks;
        ++trackers.d.executedTasks;

        // Add fee to cumulative fees paid
        trackers.b.cumulativeFeesPaid += uint64(adjFeePaid);
        trackers.c.cumulativeFeesPaid += uint64(adjFeePaid);
        trackers.d.cumulativeFeesPaid += uint64(adjFeePaid);

        uint32 _delay = uint32(uint64(block.number) - trackers.blockNumber);

        trackers.b.cumulativeDelays += _delay;
        trackers.c.cumulativeDelays += _delay;
        trackers.d.cumulativeDelays += _delay;

        return trackers;
    }

    /**
     * @notice Updates load balancer pointers in memory
     * @dev Updates active block pointers based on task size:
     * - Small tasks: Updates activeBlockSmall
     * - Medium tasks: Updates activeBlockMedium
     * - Large tasks: Updates activeBlockLarge
     *
     * Sets updateLoadBalancer flag when pointers change
     *
     * @param trackers Current tracking state
     * @return Updated trackers with new load balancer state
     */
    function _updateLoadBalancerInMemory(Trackers memory trackers) internal pure returns (Trackers memory) {
        if (trackers.size == Size.Small) {
            if (trackers.loadBalancer.activeBlockSmall < trackers.blockNumber) {
                trackers.loadBalancer.activeBlockSmall = trackers.blockNumber;
                trackers.updateLoadBalancer = true; // flag for future storage update
            }
        } else if (trackers.size == Size.Medium) {
            if (trackers.loadBalancer.activeBlockMedium < trackers.blockNumber) {
                trackers.loadBalancer.activeBlockMedium = trackers.blockNumber;
                trackers.updateLoadBalancer = true; // flag for future storage update
            }
        } else if (trackers.size == Size.Large) {
            if (trackers.loadBalancer.activeBlockLarge < trackers.blockNumber) {
                trackers.loadBalancer.activeBlockLarge = trackers.blockNumber;
                trackers.updateLoadBalancer = true; // flag for future storage update
            }
        }

        return trackers;
    }

    /**
     * @notice Iterates through blocks to find available tasks
     * @dev Implements an optimized block traversal algorithm:
     * 1. Uses bitmap to quickly identify blocks with tasks
     * 2. Traverses through depth levels (D -> C -> B)
     * 3. Skips empty blocks/groups efficiently
     *
     * Gas Management:
     * - Checks remaining gas against targetGasReserve
     * - Exits iteration if gas drops below threshold
     *
     * Block Navigation:
     * - Uses bitmap to identify task presence
     * - Skips empty block groups efficiently
     * - Updates load balancer state during traversal
     *
     * @param trackers Current tracking state
     * @param targetGasReserve Minimum gas to maintain
     * @param upperBoundBlockNumber Maximum block to consider (inclusive)
     * @return Updated trackers after iteration
     */
    function _iterate(
        Trackers memory trackers,
        uint256 targetGasReserve,
        uint64 upperBoundBlockNumber
    )
        internal
        returns (Trackers memory)
    {
        // Define starting variables
        Depth _depth = Depth.D;
        uint256 _groupFactorUpper = _GROUP_SIZE ** (uint256(uint8(_depth)));
        uint256 _groupFactorLower = _GROUP_SIZE ** (uint256(uint8(_depth)) - 1);
        trackers.tasksAvailable = false;

        // Start off with a full bitmap (assume if we had an E level its bitmap of D would always be full)
        uint256 _bitmap = uint256(uint32(0xffffffff));

        // Assume we start with a valid gas check in the calling function, so begin with do-while loop
        do {
            uint256 _blockGroupBit = uint256(uint256(trackers.blockNumber) % _groupFactorUpper);

            // CASE: There is a match - return the block number
            if ((1 << (_blockGroupBit / (_BITMAP_SPECIFICITY * _groupFactorLower))) & _bitmap != 0) {
                // CASE: Tasks are completed.
                // Store any completed tasks that we already loaded, then iterate to the next available slot
                if (_taskCompletedAtDepth(trackers, _depth)) {
                    // NOTE: if a higher-level tracker is complete, all lower levels will be too
                    _storeCompletedTasksAtAndBelowDepth(trackers, _depth);

                    // CASE: Tasks either haven't been loaded or are incomplete
                } else {
                    // Load this level's tracker if we haven't already
                    if (!_taskExistedAtDepth(trackers, _depth)) {
                        trackers = _loadSpecificTracker(trackers, _depth);
                    }

                    // CASE: totalTasks > tasksExecuted
                    if (_taskAvailableAtDepth(trackers, _depth)) {
                        // CASE: Bottom level - tasks are available, return
                        if (_depth == Depth.B) {
                            trackers.tasksAvailable = true;
                            // trackers = _updateLoadBalancerInMemory(trackers);
                            break;

                            // CASE: Go into deeper level
                        } else {
                            _depth = Depth(uint8(_depth) - 1);
                            _groupFactorUpper = _groupFactorLower;
                            _groupFactorLower = _GROUP_SIZE ** (uint256(uint8(_depth)) - 1);
                            _bitmap = _bitmapForDepth(trackers, _depth);
                            continue;
                        }
                    }
                }

                // Clear the previous trackers
                trackers = _clearTrackerAtAndBelowDepth(trackers, _depth);

                // CASE There's a task in this byte, just not in this group, so we go to next group in the byte.
                uint64 _bitSkip = uint64(_groupFactorLower - (uint256(trackers.blockNumber) % _groupFactorLower));
                trackers.blockNumber += uint64(_bitSkip);
            } else {
                // CASE None of this group of 4 has a task
                // Skip ahead 1-3 blocks (to the next group of four)
                // NOTE: _BITMAP_SPECIFICITY (4) is a factor of _GROUP_SIZE (128)
                // This means we don't have to worry about skipping a C or D-level reload

                // First move to end of this group
                uint64 _bitSkip = uint64(_groupFactorLower - (uint256(trackers.blockNumber) % _groupFactorLower));

                // Then skip ahead to beginning of next group
                uint256 _bitGroupRemainder = (_blockGroupBit / _groupFactorLower) % _BITMAP_SPECIFICITY;
                uint64 _bitGroupSkip = uint64((_BITMAP_SPECIFICITY - _bitGroupRemainder - 1) * _groupFactorLower);
                _bitSkip += _bitGroupSkip;
                trackers.blockNumber += _bitSkip;
            }

            // We don't allow tasks to schedule and execute in the same block, so
            // stop at the block before this one.
            if (trackers.blockNumber > upperBoundBlockNumber) {
                trackers.blockNumber = upperBoundBlockNumber;
                trackers = _updateLoadBalancerInMemory(trackers);
                break;
            }

            // If we reach this point it means we successfully looped through an entire set of four.
            // Turn on the 'store on no-find iteration' flag so that we'll save progress
            // and avoid this loop in the future
            // storeNoFindIteration = true;
            trackers = _updateLoadBalancerInMemory(trackers);
        } while (gasleft() > targetGasReserve);
        return trackers;
    }

    /**
     * @notice Simulates a view-only search in a given task queue.
     * @dev Initializes trackers for a given task size and starting block, then runs _iterateView.
     * @param targetGasReserve The gas reserve to maintain.
     * @return trackers The updated trackers after iteration.
     */
    function _searchInQueue(
        Trackers memory trackers,
        uint256 targetGasReserve,
        uint64 upperBoundBlockNumber
    )
        internal
        returns (Trackers memory)
    {
        // if there are no tasks available, iterate to find the next available task
        if (trackers.b.executedTasks >= trackers.b.totalTasks) {
            trackers = _iterate(trackers, targetGasReserve, upperBoundBlockNumber);
        }

        return trackers;
    }

    /**
     * @notice Calculates group factor for a given depth level
     * @dev Returns the block grouping factor for each depth:
     * - B (Block): 1 (individual blocks)
     * - C (Group): _GROUP_SIZE (e.g., 128)
     * - D (Supergroup): _GROUP_SIZE^2 (e.g., 16384)
     *
     * Used for:
     * - Block number calculations
     * - Bitmap indexing
     * - Metric aggregation
     *
     * @param depth The depth level to calculate factor for
     * @return groupFactor Number of blocks in group at specified depth
     */
    function _groupFactorForDepth(Depth depth) internal pure returns (uint256 groupFactor) {
        if (depth == Depth.B) {
            groupFactor = 1;
        } else if (depth == Depth.C) {
            groupFactor = _GROUP_SIZE; // e.g. 128
        } else if (depth == Depth.D) {
            groupFactor = _GROUP_SIZE * _GROUP_SIZE; // e.g. 16384
        } else {
            revert("Invalid depth");
        }
    }

    /**
     * @notice Determines maximum gas limit for a task size
     * @dev Maps task sizes to their corresponding gas limits:
     * - Small: SMALL_GAS
     * - Medium: MEDIUM_GAS
     * - Large: LARGE_GAS
     *
     * Used for:
     * - Task scheduling validation
     * - Execution gas requirement checks
     * - Queue allocation decisions
     *
     * @param size The size category to get gas limit for
     * @return maxGas Maximum gas limit for the specified size
     */
    function _maxGasFromSize(Size size) internal pure returns (uint256 maxGas) {
        if (size == Size.Medium) {
            return MEDIUM_GAS;
        } else if (size == Size.Small) {
            return SMALL_GAS;
        }
        return LARGE_GAS;
    }

    /**
     * @notice Handles revert data from a static call
     * @dev Extracts the uint64 block number from the revert data
     * @param reason The revert data from the static call
     * @return blockNumber The extracted block number
     */
    function _handleRevertData(bytes memory reason) internal pure returns (uint64 blockNumber) {
        // For custom errors, we need at least 4 bytes (selector) + 32 bytes (value)
        if (reason.length < 36) {
            // 4 bytes selector + 32 bytes value
            return 0;
        }

        // Check if the first 4 bytes match our expected selector
        bytes4 selector = bytes4(reason);

        if (selector == TaskErrors.NextExecutionBlock.selector) {
            // Extract the uint64 blockNumber from the error data - simplest approach
            uint64 extractedValue;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                // Load the full 32-byte word that follows the selector (starts at byte 4)
                extractedValue := mload(add(add(reason, 0x20), 4))
            }

            blockNumber = extractedValue;
        }

        return blockNumber;
    }
}
