// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";

import { ITaskManager } from "../interfaces/ITaskManager.sol";
import { TaskScheduler } from "./Scheduler.sol";
import { TaskBits } from "../libraries/TaskBits.sol";
import { TaskMetadata, Size, Trackers, Tracker, ScheduledTasks, Depth, LoadBalancer } from "../types/TaskTypes.sol";

/// @title TaskManagerEntrypoint
/// @notice Public interface for task management
contract TaskManagerEntrypoint is TaskScheduler, ITaskManager, OwnableUpgradeable {
    using TaskBits for bytes32;
    using SafeTransferLib for address;

    /// @notice Constructor to set immutable variables
    /// @param shMonad The address of the shMonad contract
    /// @param policyId The policy ID for the task manager
    constructor(address shMonad, uint64 policyId) TaskScheduler(shMonad, policyId) { }

    /// @notice Initialize the contract
    /// @param deployer The deployer of the contract
    function initialize(address deployer) public reinitializer(6) {
        __Ownable_init(deployer);

        // Initialize LoadBalancer with current block number
        uint64 currentBlock = uint64(block.number) - 1;
        S_loadBalancer.activeBlockSmall = currentBlock;
        S_loadBalancer.activeBlockMedium = currentBlock;
        S_loadBalancer.activeBlockLarge = currentBlock;
        S_loadBalancer.targetDelay = uint32(3);
    }

    /// @notice Process task scheduling with validation, payment, and queueing
    /// @param implementation The contract address that is delegatecalled
    /// @param taskGasLimit The gas limit of the task's execution
    /// @param targetBlock The desired block number when the task should execute
    /// @param maxPayment Maximum payment willing to pay for execution
    /// @param taskCallData The encoded function call data for the task
    /// @param payWithMON If true, uses MON, otherwise uses bonded shMONAD
    /// @return scheduled Bool for whether or not the task was scheduled
    /// @return executionCost The estimated cost of the task
    /// @return taskId Unique identifier for tracking the scheduled task
    function _processTaskScheduling(
        address implementation,
        uint256 taskGasLimit,
        uint64 targetBlock,
        uint256 maxPayment,
        bytes calldata taskCallData,
        bool payWithMON
    )
        internal
        returns (bool scheduled, uint256 executionCost, bytes32 taskId)
    {
        // Validate task parameters
        _validateImplementation(implementation);

        // Get task metadata
        TaskMetadata memory _taskMetaData = _buildTaskMetadata(taskGasLimit, msg.sender);

        // Get quote for task
        (Trackers memory _trackers, uint256 _executionCostUnadj) = _getTaskQuote(_taskMetaData.size, targetBlock);

        // Adjust for _FEE_SIG_FIG
        uint256 executionCostInShMon = _executionCostUnadj * _FEE_SIG_FIG;
        // Convert the cost to MON and revert if it exceeds max payment
        executionCost = _convertShMonToDepositedMon(executionCostInShMon);
        if (executionCost > maxPayment) revert TaskCostAboveMax(executionCost, maxPayment);

        // Handle payment
        if (payWithMON) {
            _takeMonad(_taskMetaData.owner, executionCost);
        } else {
            _takeBondedShmonad(_taskMetaData.owner, executionCostInShMon);
        }

        // Deploy the execution environment
        address _environment =
            _createEnvironment(_taskMetaData.owner, _taskMetaData.nonce, implementation, taskCallData);

        // Update trackers and load balancer
        uint16 _taskIndexInBlock;
        (_trackers, _taskIndexInBlock) = _markTaskScheduled(_trackers, _executionCostUnadj);

        // Pack the environment address and task size into taskId
        taskId = TaskBits.pack(_environment, targetBlock, _taskIndexInBlock, _taskMetaData.size, false);

        // Push task to the end of the queue
        _addTaskId(taskId, _taskMetaData.size, targetBlock, _taskIndexInBlock);

        // Store the trackers and metadata
        _storeAllTrackers(_trackers);
        S_taskData[_environment] = _taskMetaData;

        // Emit event
        emit TaskScheduled(taskId, _taskMetaData.owner, targetBlock);

        return (true, executionCost, taskId);
    }

    /// @notice Schedule a task using native MON
    function scheduleTask(
        address implementation,
        uint256 taskGasLimit,
        uint64 targetBlock,
        uint256 maxPayment,
        bytes calldata taskCallData
    )
        external
        payable
        withLock
        returns (bool scheduled, uint256 executionCost, bytes32 taskId)
    {
        return _processTaskScheduling(
            implementation,
            taskGasLimit,
            targetBlock,
            maxPayment,
            taskCallData,
            true // use MON
        );
    }

    /// @notice Schedule a task using bonded shMONAD
    /// @dev Withdraws bonded shMONAD directly to task manager
    function scheduleWithBond(
        address implementation,
        uint256 taskGasLimit,
        uint64 targetBlock,
        uint256 maxPayment,
        bytes calldata taskCallData
    )
        external
        withLock
        returns (bool scheduled, uint256 executionCost, bytes32 taskId)
    {
        return _processTaskScheduling(
            implementation,
            taskGasLimit,
            targetBlock,
            maxPayment,
            taskCallData,
            false // use bonded shMONAD
        );
    }

    /// @notice Cancel a task
    /// @param taskHash The hash of the task to cancel
    function cancelTask(bytes32 taskHash) external withLock {
        _cancelTask(taskHash);
    }

    /// @notice Reschedules the currently executing task using transient storage for state management
    /// @dev Uses transient storage to set a flag indicating state needs to be reloaded after rescheduling
    ///      This prevents a task from spawning multiple iterations by maintaining execution context
    ///      State is reloaded after rescheduling instead of marking the task as scheduled
    /// @param targetBlock The block to reschedule the task to
    /// @param maxPayment Maximum payment the caller is willing to pay for execution
    /// @return rescheduled Whether the task was successfully rescheduled
    /// @return executionCost The cost of executing the rescheduled task
    /// @return taskId The ID of the rescheduled task
    function rescheduleTask(
        uint64 targetBlock,
        uint256 maxPayment
    )
        external
        payable
        returns (bool rescheduled, uint256 executionCost, bytes32 taskId)
    {
        // Get the id from transient storage only available during execution
        taskId = T_currentTaskId;

        (address _environment, uint64 _initBlock,, Size _size,) = taskId.unpack();

        if (taskId == bytes32(0)) {
            revert NoActiveTask();
        }

        // Make sure the task is rescheduling itself
        if (msg.sender != _environment) {
            revert TaskMustRescheduleSelf();
        }

        // Make sure the task hasn't already been rescheduled (task can't spawn multiples)
        // NOTE: The target block for a future task must be greater than current block,
        // while the executed block for a task must be less than or equal to current block
        if (uint256(_initBlock) > block.number) {
            revert TaskAlreadyRescheduled(taskId);
        }

        // Validate task parameters and get quote
        (Trackers memory _trackers, uint256 _executionCostUnadj) = _getTaskQuote(_size, targetBlock);

        // Adjust for _FEE_SIG_FIG and revert if cost exceeds max payment
        uint256 executionCostInShMon = _executionCostUnadj * _FEE_SIG_FIG;
        executionCost = _convertShMonToDepositedMon(executionCostInShMon);
        if (executionCost > maxPayment) revert TaskCostAboveMax(executionCost, maxPayment);

        // Load the metadata
        TaskMetadata memory _taskMetaData = S_taskData[_environment];

        // Handle payment
        if (msg.value < executionCost) {
            // TODO: Evaluate bonding any spare msg.value - it's skipped here because of the extra gas overhead
            if (msg.value > 0) {
                address(msg.sender).safeTransferETH(msg.value);
            }
            _takeBondedShmonad(_taskMetaData.owner, executionCostInShMon);
        } else {
            // Refund any msg.value back to task
            _takeMonad(_environment, executionCost);
        }

        // Schedule the task with tracking updates
        taskId = TaskBits.pack(_environment, targetBlock, uint16(_trackers.b.totalTasks), _size, false);

        // Store the new taskId in the lock to prevent a task spawning multiple iterations
        T_currentTaskId = taskId;
        t_executionFee = _executionCostUnadj;

        return (true, executionCost, taskId);
    }

    /// @inheritdoc ITaskManager
    /// @param payoutAddress The beneficiary of any payouts
    /// @param targetGasReserve Amount of gas to reserve for after execution
    /// @return feesEarned Amount of fees earned from execution
    function executeTasks(
        address payoutAddress,
        uint256 targetGasReserve
    )
        external
        withLock
        returns (uint256 feesEarned)
    {
        // Validate payout address is not zero
        if (payoutAddress == address(0)) {
            revert InvalidPayoutAddress(payoutAddress);
        }

        // Loop through available tasks
        return _execute(payoutAddress, targetGasReserve);
    }

    // HELPERS

    /// @inheritdoc ITaskManager
    /// @notice Get the address of the currently-executing task
    /// @return currentTask The address of the currently-executing task
    function getCurrentTask() external view returns (address currentTask) {
        // Get the id from transient storage only available during execution
        bytes32 _taskId = T_currentTaskId;
        (currentTask,,,,) = _taskId.unpack();
    }

    /// @inheritdoc ITaskManager
    /// @notice Alerts whether or not a task is cancelled
    /// @param taskId The id of the task to cancel
    /// @return cancelled Bool for whether or not the task was cancelled
    function isTaskCancelled(bytes32 taskId) external view returns (bool cancelled) {
        // Unpack the ID
        (, uint64 _initBlock, uint16 _initIndex, Size _size,) = taskId.unpack();

        // Pull up the task
        bytes32 _currentTaskId = _loadTaskId(_size, _initBlock, _initIndex);
        if (_currentTaskId == bytes32(0)) {
            revert TaskNotFound(taskId);
        }

        // Get the most recent info
        (,,,, cancelled) = _currentTaskId.unpack();
    }

    /// @inheritdoc ITaskManager
    /// @notice Alerts whether or not a task has been executed
    /// @param taskId The id of the task to check
    /// @return executed Bool for whether or not the task was executed
    function isTaskExecuted(bytes32 taskId) external view returns (bool executed) {
        // Unpack the ID
        (, uint64 _initBlock, uint16 _initIndex, Size _size,) = taskId.unpack();

        // Pull up the task
        bytes32 _currentTaskId = _loadTaskId(_size, _initBlock, _initIndex);
        if (_currentTaskId == bytes32(0)) {
            revert TaskNotFound(taskId);
        }

        // Get the most recent info, return false if it's cancelled
        (,,,, bool _cancelled) = _currentTaskId.unpack();
        if (_cancelled) return false;

        return _isTaskExecuted(_initBlock, _initIndex, _size);
    }

    /// @inheritdoc ITaskManager
    /// @notice Estimate the required bond for a task
    /// @param targetBlock The block to schedule the task for
    /// @param taskGasLimit The gas limit of the task's execution
    /// @return cost The estimated cost of the task
    function estimateCost(uint64 targetBlock, uint256 taskGasLimit) external view override returns (uint256 cost) {
        // Validate task parameters
        _validateBlock(targetBlock);

        if (taskGasLimit > LARGE_GAS) revert TaskGasTooLarge(taskGasLimit);
        Size _size = _sizeFromGasLimit(taskGasLimit);

        // Get quote for task based on size and target block
        (, uint256 _costUnadj) = _getTaskQuote(_size, targetBlock);

        // Convert for sig fig
        cost = _costUnadj * _FEE_SIG_FIG;

        // Convert to MON and add 1 to account for rounding on shMonad
        cost = _convertShMonToDepositedMon(cost);
    }

    /// @inheritdoc ITaskManager
    /// @notice Get the earliest block number with scheduled tasks within the lookahead range
    /// @param lookahead Number of blocks to look ahead from current block
    /// @return schedule An array of the tasks scheduled for each block requested
    function getTaskScheduleInRange(uint64 lookahead) external view returns (ScheduledTasks[] memory schedule) {
        // First check against MAX_SCHEDULE_DISTANCE
        if (lookahead > MAX_SCHEDULE_DISTANCE) {
            revert LookaheadExceedsMaxScheduleDistance(lookahead);
        }

        // Get the load balancer and determine most recently completed blocks
        LoadBalancer memory _loadBalancer = S_loadBalancer;
        uint256[] memory _sizeStartBlocks = new uint256[](_TOTAL_QUEUES);
        _sizeStartBlocks[0] = uint256(_loadBalancer.activeBlockSmall);
        _sizeStartBlocks[1] = uint256(_loadBalancer.activeBlockMedium);
        _sizeStartBlocks[2] = uint256(_loadBalancer.activeBlockLarge);

        // Sanity check the start blocks
        for (uint256 s; s < _TOTAL_QUEUES; s++) {
            if (_sizeStartBlocks[s] + MAX_SCHEDULE_DISTANCE < block.number) {
                _sizeStartBlocks[s] = block.number - MAX_SCHEDULE_DISTANCE;
            }
        }

        // Get the lowest block
        uint256 blockNumber = uint256(
            _sizeStartBlocks[0] < _sizeStartBlocks[1]
                ? (_sizeStartBlocks[0] < _sizeStartBlocks[2] ? _sizeStartBlocks[0] : _sizeStartBlocks[2])
                : (_sizeStartBlocks[1] < _sizeStartBlocks[2] ? _sizeStartBlocks[1] : _sizeStartBlocks[2])
        );

        // Init a tracker
        Tracker memory _tracker;

        {
            // Some custom gas logic for rare init / cold start issues to prevent a hang due to gas limit
            // CASE - check to see if we need to jump forwards
            while (gasleft() / 25_000 < block.number + uint256(lookahead) - blockNumber) {
                // Iterate through sizes
                for (uint256 s; s < _TOTAL_QUEUES; s++) {
                    // _TOTAL_QUEUES = 3 // small, medium, large task sizes
                    uint256 d = 1; // 1=b
                    bool _pinpointing = false;
                    uint256 _bitmap;

                    // loop through depths (3 = max depth levels)
                    while (d < 3 && d > 0) {
                        _tracker = S_metrics[Size(s)][Depth(d)][_sizeStartBlocks[s] / (_GROUP_SIZE ** (d - 1))];

                        // CASE: Task available - zoom in
                        if (_tracker.totalTasks > _tracker.executedTasks) {
                            --d;
                            _pinpointing = true;
                            _bitmap = uint256(_tracker.bitmap);
                            continue;
                        }

                        // CASE: No task available and not pinpointing (no bitmap available) so we zoom out
                        if (!_pinpointing) {
                            // Increment the starting block
                            _sizeStartBlocks[s] +=
                                (_GROUP_SIZE ** (d - 1) - (_sizeStartBlocks[s] % _GROUP_SIZE ** (d - 1)));
                            ++d;

                            // CASE: Tasks are available in higher group - use bitmap to skip ahead
                        } else {
                            _sizeStartBlocks[s] +=
                                (_GROUP_SIZE ** (d - 1) - (_sizeStartBlocks[s] % _GROUP_SIZE ** (d - 1)));

                            uint256 _blockGroupBit = (_sizeStartBlocks[s] % (_GROUP_SIZE ** (d)))
                                / (_BITMAP_SPECIFICITY * (_GROUP_SIZE ** (d - 1)));
                            if (_bitmap & (1 << _blockGroupBit) == 0) {
                                _sizeStartBlocks[s] += (
                                    _BITMAP_SPECIFICITY
                                        - ((_blockGroupBit / _GROUP_SIZE ** (d - 1)) % _BITMAP_SPECIFICITY) - 1
                                ) * (_GROUP_SIZE ** (d - 1));
                            }
                        }

                        if (_sizeStartBlocks[s] > block.number) {
                            _sizeStartBlocks[s] = block.number;
                            break;
                        }
                    }

                    blockNumber = uint256(
                        _sizeStartBlocks[0] < _sizeStartBlocks[1]
                            ? (_sizeStartBlocks[0] < _sizeStartBlocks[2] ? _sizeStartBlocks[0] : _sizeStartBlocks[2])
                            : (_sizeStartBlocks[1] < _sizeStartBlocks[2] ? _sizeStartBlocks[1] : _sizeStartBlocks[2])
                    );
                }
            }
        }

        // Build memory array for returndata
        // NOTE: Blocks prior to current block are merged
        schedule = new ScheduledTasks[](uint256(lookahead) + 1);
        uint256 i;

        // Iterate through blocks
        while (blockNumber < block.number + lookahead) {
            // Iterate through sizes
            for (uint256 s; s < _TOTAL_QUEUES; s++) {
                // _TOTAL_QUEUES = 3 // small, medium, large task sizes
                // Skip if this size is already past the block number;
                if (_sizeStartBlocks[s] > blockNumber) continue;

                _tracker = S_metrics[Size(s)][Depth.B][blockNumber];

                // Skip if there are no unexecuted tasks
                if (_tracker.totalTasks == _tracker.executedTasks) continue;

                unchecked {
                    // Add any unpaid shares
                    schedule[i].pendingSharesPayable +=
                        uint256(_tracker.cumulativeFeesCollected - _tracker.cumulativeFeesPaid) * _FEE_SIG_FIG;

                    // Add the unexecuted tasks to the count
                    if (s == 0) {
                        schedule[i].pendingSmallTasks += uint256(_tracker.totalTasks - _tracker.executedTasks);
                    } else if (s == 1) {
                        schedule[i].pendingMediumTasks += uint256(_tracker.totalTasks - _tracker.executedTasks);
                    } else {
                        // if (s == 2) {
                        schedule[i].pendingLargeTasks += uint256(_tracker.totalTasks - _tracker.executedTasks);
                    }
                }
            }

            // Store and increment block number
            unchecked {
                if (blockNumber > block.number) {
                    schedule[i++].blockNumber = blockNumber++;
                } else if (blockNumber < block.number) {
                    // If we haven't reached current block, don't store the 'past due' block number
                    ++blockNumber;
                } else {
                    // if (blockNumber == block.number) {
                    // Store 'past due' block as "1"
                    schedule[i++].blockNumber = 1;
                    ++blockNumber;
                }
            }
        }

        return schedule;
    }

    /// @inheritdoc ITaskManager
    function getTaskMetadata(bytes32 taskId) external view returns (TaskMetadata memory) {
        address _envAddress = TaskBits.getMimicAddress(taskId);
        return S_taskData[_envAddress];
    }

    /// @notice Add an address as a canceller authorized to cancel a specific task
    /// @param taskId The task ID to add the canceller for
    /// @param canceller The address to authorize as task canceller
    function addTaskCanceller(bytes32 taskId, address canceller) external onlyTaskOwner(taskId) {
        (address _environment,,,,) = taskId.unpack();
        _registerCancelPermission(taskId, _environment, canceller, false);
    }

    /// @notice Add an address as a canceller authorized to cancel all tasks for an environment
    /// @param taskId The task ID used to verify ownership and get environment
    /// @param canceller The address to authorize as environment canceller
    function addEnvironmentCanceller(bytes32 taskId, address canceller) external onlyTaskOwner(taskId) {
        (address _environment,,,,) = taskId.unpack();
        _registerCancelPermission(taskId, _environment, canceller, true);
    }

    /// @notice Internal function to register a canceller permission with appropriate authority
    /// @param taskId The task ID for task-specific authority
    /// @param environment The environment address for environment-wide authority
    /// @param canceller The address to authorize
    /// @param isEnvironment If true, grants environment-wide authority
    function _registerCancelPermission(
        bytes32 taskId,
        address environment,
        address canceller,
        bool isEnvironment
    )
        internal
    {
        // Validate canceller address
        if (canceller == address(0) || canceller == msg.sender) {
            revert InvalidCancellerAddress();
        }

        // Set appropriate authority
        if (isEnvironment) {
            s_taskEnvironmentCanceller[environment][canceller] = true;
            emit TaskEnvironmentCancellerAuthorized(environment, msg.sender, canceller);
        } else {
            s_taskSpecificCanceller[taskId][canceller] = true;
            emit TaskCancellerAuthorized(taskId, msg.sender, canceller);
        }
    }

    /// @notice Remove an address as a task-specific canceller
    /// @param taskId The task ID to remove the canceller from
    /// @param canceller The address to deauthorize
    function removeTaskCanceller(bytes32 taskId, address canceller) external onlyTaskOwner(taskId) {
        (address _environment,,,,) = taskId.unpack();
        _revokeCancelPermission(taskId, _environment, canceller, false);
    }

    /// @notice Remove an address as an environment-wide canceller
    /// @param taskId The task ID used to verify ownership and get environment
    /// @param canceller The address to deauthorize
    function removeEnvironmentCanceller(bytes32 taskId, address canceller) external onlyTaskOwner(taskId) {
        (address _environment,,,,) = taskId.unpack();
        _revokeCancelPermission(taskId, _environment, canceller, true);
    }

    /// @notice Internal function to revoke a canceller's permission
    /// @param taskId The task ID for task-specific authority
    /// @param environment The environment address for environment-wide authority
    /// @param canceller The address to deauthorize
    /// @param isEnvironment If true, removes environment-wide authority
    function _revokeCancelPermission(
        bytes32 taskId,
        address environment,
        address canceller,
        bool isEnvironment
    )
        internal
    {
        // Remove appropriate authority
        if (isEnvironment) {
            s_taskEnvironmentCanceller[environment][canceller] = false;
            emit TaskEnvironmentCancellerRevoked(environment, msg.sender, canceller);
        } else {
            s_taskSpecificCanceller[taskId][canceller] = false;
            emit TaskCancellerRevoked(taskId, msg.sender, canceller);
        }
    }

    /// @notice Returns the environment address for the given owner, nonce, implementation, and task data.
    ///         Does not attempt to create the environment – if it isn't deployed, returns address(0).
    /// @param owner The owner of the environment.
    /// @param taskNonce The task nonce for this environment.
    /// @param implementation Optional custom implementation (use address(0) for default).
    /// @param taskData The task data embedded in code.
    /// @return environment The deployed environment address or address(0) if not deployed.
    function getEnvironment(
        address owner,
        uint256 taskNonce,
        address implementation,
        bytes memory taskData
    )
        external
        view
        returns (address environment)
    {
        return _getEnvironment(owner, taskNonce, implementation, taskData);
    }

    receive() external payable { }
}
