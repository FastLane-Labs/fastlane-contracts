// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Task } from "./TaskTypes.sol";

/// @title TaskEvents
/// @notice Single source of truth for all task-related events
contract TaskEvents {
    // Task lifecycle events
    event TaskScheduled(bytes32 indexed taskId, address indexed owner, uint64 nextBlock);
    event TaskExecuted(bytes32 indexed taskId, address indexed executor, bool success, bytes returnData);
    event TaskCancelled(bytes32 indexed taskId, address indexed owner);
    event TaskInactiveDueToInsufficientBonds(bytes32 indexed taskId, address indexed owner, uint256 requiredBond);
    // Accounting events
    event ExecutorReimbursed(address indexed executor, uint256 amount);
    event ProtocolFeeCollected(uint256 amount);

    // Batch operation events
    event TasksExecuted(uint256 executed, uint256 failed);

    // Task canceller events
    event TaskCancellerAuthorized(bytes32 indexed taskId, address indexed owner, address indexed canceller);
    event TaskCancellerRevoked(bytes32 indexed taskId, address indexed owner, address indexed canceller);
    event TaskEnvironmentCancellerAuthorized(
        address indexed environment, address indexed owner, address indexed canceller
    );
    event TaskEnvironmentCancellerRevoked(
        address indexed environment, address indexed owner, address indexed canceller
    );
}
