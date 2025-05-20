// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IShMonad } from "../../shmonad/interfaces/IShMonad.sol";
import { TaskBits } from "../libraries/TaskBits.sol";
import { Size, Depth, Task, LoadBalancer, Tracker, TaskMetadata } from "../types/TaskTypes.sol";
import { TaskEvents } from "../types/TaskEvents.sol";
import { TaskErrors } from "../types/TaskErrors.sol";

/// @title TaskStorage
/// @notice Core storage contract for task management system
abstract contract TaskStorage is TaskEvents, TaskErrors {
    using TaskBits for bytes32;

    address public immutable SHMONAD;

    uint256 internal constant _FEE_SIG_FIG = 1e9;
    uint256 internal constant _MIN_FEE_RATE = 10; // This is multiplied by gas and then _FEE_SIG_FIG
    uint256 internal constant _GROUP_SIZE = 128;
    uint256 internal constant _MAX_GROUP_DEPTH = 3;
    uint256 internal constant _BITMAP_SPECIFICITY = 4;
    uint256 internal constant _MIN_ITERATION_GAS_REMAINER = 25_000;

    /// @notice Maximum distance (in blocks) that a task can be scheduled ahead (~3 weeks)
    uint64 public constant MAX_SCHEDULE_DISTANCE = uint64(_GROUP_SIZE) ** uint64(_MAX_GROUP_DEPTH);

    /// @notice Gas limits for different queue categories
    uint64 public constant SMALL_GAS = 100_000;
    uint64 public constant MEDIUM_GAS = 250_000;
    uint64 public constant LARGE_GAS = 750_000;
    uint64 public constant ITERATION_BUFFER = 32_000;

    // These need to be removed when the real fee formula is added
    uint256 internal constant _CONGESTION_GROWTH_RATE = 101_000_000;
    uint256 internal constant _FORECAST_GROWTH_RATE = 25_000; // per 128 blocks, linear
    uint256 internal constant _BASE_RATE = 100_000_000; // 0.1 gwei

    /// @notice The shMONAD policy ID for this task manager
    uint64 public immutable POLICY_ID;

    mapping(address => TaskMetadata) public S_taskData;
    mapping(Size => mapping(uint64 => bytes32[])) public S_taskIdQueue;
    mapping(Size => mapping(Depth => mapping(uint256 => Tracker))) public S_metrics;

    // Mapping for storing task cancellation authorities
    // For task-specific authorities (one-time use)
    mapping(bytes32 => mapping(address => bool)) internal s_taskSpecificCanceller;
    // For execution environment authorities (persistent across task reschedules)
    mapping(address => mapping(address => bool)) internal s_taskEnvironmentCanceller;

    // Structured state
    LoadBalancer public S_loadBalancer;

    //  variables
    bytes32 public transient T_currentTaskId;
    uint256 internal transient t_executionFee;

    constructor(address shMonad, uint64 policyId) {
        require(shMonad != address(0), InvalidShMonadAddress());
        require(policyId != 0, InvalidPolicyId());
        SHMONAD = shMonad;
        POLICY_ID = policyId;
    }

    modifier withLock() {
        bytes32 _taskId = T_currentTaskId;
        if (_taskId != bytes32(0)) {
            revert TaskManagerLocked();
        }
        _;
        T_currentTaskId = bytes32(0);
    }

    /// @notice Modifier to check if caller is the task owner
    /// @param taskId The task ID to check ownership for
    modifier onlyTaskOwner(bytes32 taskId) {
        (address _environment,,,,) = taskId.unpack();
        TaskMetadata memory _taskData = S_taskData[_environment];
        if (msg.sender != _taskData.owner) {
            revert Unauthorized(msg.sender, _taskData.owner);
        }
        _;
    }

    /// @notice Modifier to check if caller has authority to cancel a task
    /// @param taskId The task ID to check authority for
    modifier onlyCancelAuthority(bytes32 taskId) {
        (address _environment,,,,) = taskId.unpack();
        TaskMetadata memory _taskData = S_taskData[_environment];
        // Check if caller is owner, has task-specific authority, or environment-wide authority
        if (
            msg.sender != _taskData.owner && !s_taskSpecificCanceller[taskId][msg.sender]
                && !s_taskEnvironmentCanceller[_environment][msg.sender]
        ) {
            revert Unauthorized(msg.sender, _taskData.owner);
        }
        _;
    }

    /// @notice Get task metadata for a given environment address
    /// @param environment The environment address to get metadata for
    /// @return The task metadata
    function getTaskMetadata(address environment) external view returns (TaskMetadata memory) {
        return S_taskData[environment];
    }
}
