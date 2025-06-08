// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title TaskTypes
/// @notice Core data structures for the task management system
/// @dev Contains all type definitions used across the task manager system

/// @notice The actual task to be executed (immutable)
/// @dev Once created, task properties cannot be modified except for cancellation
struct Task {
    /// @notice Address that created and owns the task
    address from;
    /// @notice Sequential identifier for tasks from the same owner
    uint64 nonce;
    /// @notice Gas consumption category (Small/Medium/Large)
    Size size;
    /// @notice Contract address that is delegatecalled
    address implementation;
    /// @notice Whether the task has been cancelled
    bool cancelled;
    /// @notice Encoded function call data for the task
    bytes data;
}

/// @notice Metadata for task ownership and status tracking
/// @dev Used for task management and access control
struct TaskMetadata {
    address owner; // Owner of the task
    uint64 nonce; // to track different tasks from same owner
    Size size; // small, medium, or large gas.
}

/// @notice Gas consumption categories for tasks
/// @dev Used for load balancing and fee calculation
enum Size {
    Small, // For lightweight operations
    Medium, // For moderate complexity operations
    Large // For complex operations

}

/// @notice Hierarchical depth levels for task organization
/// @dev Used in the load balancing system
enum Depth {
    A, // Individual task level
    B, // Block level (base unit, index 0)
    C, // Cohort level (128 blocks)
    D, // Division level (128 cohorts)
    E // Epoch level (128 divisions)

}

/// @notice Load balancing configuration for task scheduling
/// @dev Manages task distribution across blocks
struct LoadBalancer {
    /// @notice Current active block for small tasks
    uint64 activeBlockSmall;
    /// @notice Current active block for medium tasks
    uint64 activeBlockMedium;
    /// @notice Current active block for large tasks
    uint64 activeBlockLarge;
    /// @notice Target delay between task scheduling and execution
    uint32 targetDelay;
    /// @notice Rate at which delays should adjust
    uint32 targetGrowthRate;
}

/// @notice Tracks execution statistics at different depth levels
/// @dev Used for performance monitoring and fee adjustment
struct Tracker {
    /// @notice Total number of tasks (array length at depth B)
    uint32 totalTasks;
    /// @notice Number of executed tasks (array index at depth B)
    uint32 executedTasks;
    /// @notice Sum of execution delays
    uint32 cumulativeDelays;
    /// @notice Total fees collected (scaled by 10^9)
    uint64 cumulativeFeesCollected;
    /// @notice Total fees paid out (scaled by 10^9)
    uint64 cumulativeFeesPaid;
    /// @notice Bitmap tracking empty slots at depth C
    uint32 bitmap;
}

/// @notice In-memory structure for tracking state during execution
/// @dev Used to pass multiple trackers efficiently between functions
struct Trackers {
    /// @notice Target gas remainder at end
    uint256 targetGasReserve;
    /// @notice Current load balancer state
    LoadBalancer loadBalancer;
    /// @notice Whether to update load balancer
    bool updateLoadBalancer;
    /// @notice Whether to update all tracker levels
    bool updateAllTrackers;
    /// @notice Whether tasks are available for execution
    bool tasksAvailable;
    /// @notice Current task size
    Size size;
    /// @notice Current block number
    uint64 blockNumber;
    /// @notice Block-level tracker
    Tracker b;
    /// @notice Cohort-level tracker
    Tracker c;
    /// @notice Division-level tracker
    Tracker d;
}

struct ScheduledTasks {
    uint256 blockNumber;
    uint256 pendingSmallTasks;
    uint256 pendingMediumTasks;
    uint256 pendingLargeTasks;
    uint256 pendingSharesPayable; // NOTE: Fees collected (shares payable) > reward received by executor
}
