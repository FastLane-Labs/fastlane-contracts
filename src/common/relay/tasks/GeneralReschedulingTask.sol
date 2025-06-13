//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITaskManager } from "../../../task-manager/interfaces/ITaskManager.sol";
import { IShMonad } from "../../../shmonad/interfaces/IShMonad.sol";

/*
    THIS TASK IS UNSAFE FOR ANY CONTRACTS THAT ALLOW ARBITRARY CALLS TO ARBITRARY TARGETS!
    AN ATTACKER CAN CALL THE RESCHEDULING IMPLEMENTATION PRETENDING TO BE YOUR CONTRACT
    AND RESCHEDULE A TASK THAT WASNT INTENDED TO BE RESCHEDULED.

    PLEASE USE THIS TASK ONLY WHEN YOU EITHER:
        - Do not allow arbitrary calls to arbitrary targets from arbitrary sources
        - Screen call targets against this task's implementation address
        - Use an "airlock" pattern when making / forwarding arbitrary calls
*/

/// @title GeneralReschedulingTask
/// @notice Implementation of task rescheduling functionality for the FastLane relay system
/// @dev Handles task execution, rescheduling, and data storage using transient storage
/// @dev This contract uses a delegation pattern where most functions must be called through a proxy
contract GeneralReschedulingTask {
    /// @notice Error thrown when a function must be called through delegation
    error MustBeDelegated();
    /// @notice Error thrown when a function cannot be called through delegation
    error CantBeDelegated();
    /// @notice Error thrown when caller must be the currently active task
    error CallerMustBeActiveTask();
    /// @notice Error thrown when caller must be either the active task or target
    error CallerMustBeActiveTaskOrTarget();
    /// @notice Error thrown when task address doesn't match stored task
    /// @param task Provided task address
    /// @param storedTask Expected task address from storage
    error InvalidTaskMatch(address task, address storedTask);
    /// @notice Error thrown when non-target attempts to set rescheduling
    error OnlyTargetCanSetReschedule();
    /// @notice Error thrown when task balance is insufficient for rescheduling
    /// @param balance Current balance
    /// @param cost Required cost
    error CantAffordReschedule(uint256 balance, uint256 cost);
    /// @notice Error thrown when rescheduling cost exceeds maximum
    /// @param cost Provided cost
    error RescheduleCostTooHigh(uint256 cost);
    /// @notice Error thrown when target block is too high
    /// @param targetBlock Provided block number
    error TargetBlockTooHigh(uint256 targetBlock);
    /// @notice Error thrown when task execution fails
    error ExecutionFailed();
    /// @notice Error thrown when task rescheduling fails
    error ReschedulingFailed();

    /// @notice Address of the implementation contract
    /// @dev Used for delegation checks
    address private immutable _IMPLEMENTATION;
    /// @notice Address of the task manager contract
    address private immutable _TASK_MANAGER;
    /// @notice Address of the ShMonad protocol
    address private immutable _SHMONAD;

    /// @notice Minimum gas required for rescheduling operations
    /// @dev Ensures sufficient gas for rescheduling logic
    uint256 private constant _MIN_RESCHEDULE_GAS = 45_500;

    /// @notice Namespace for target address transient storage
    bytes32 private immutable _TARGET_NAMESPACE;
    /// @notice Namespace for rescheduling data transient storage
    bytes32 private immutable _RESCHEDULE_NAMESPACE;
    /// @notice Namespace for caller address transient storage
    bytes32 private immutable _CALLER_NAMESPACE;
    /// @notice Namespace for calldata hash transient storage
    bytes32 private immutable _CALLDATA_NAMESPACE;
    /// @notice Bit flag indicating rescheduling is enabled
    uint256 private constant _RESCHEDULE_BIT = 0x0000000000000002000000000000000000000000000000000000000000000000;

    /// @notice Initializes the contract with required protocol addresses
    /// @dev Sets up namespaces for transient storage and initializes immutable variables
    /// @param taskManager Address of the task manager contract
    /// @param shMonad Address of the ShMonad protocol
    constructor(address taskManager, address shMonad) {
        _IMPLEMENTATION = address(this);
        _TASK_MANAGER = taskManager;
        _SHMONAD = shMonad;

        _TARGET_NAMESPACE = keccak256(
            abi.encode(
                "General Rescheduling Task 1.0", "Target Namespace", shMonad, taskManager, address(this), block.chainid
            )
        );

        _CALLER_NAMESPACE = keccak256(
            abi.encode(
                "General Rescheduling Task 1.0", "Caller Namespace", shMonad, taskManager, address(this), block.chainid
            )
        );

        _RESCHEDULE_NAMESPACE = keccak256(
            abi.encode(
                "General Rescheduling Task 1.0",
                "Rescheduling Namespace",
                shMonad,
                taskManager,
                address(this),
                block.chainid
            )
        );

        _CALLDATA_NAMESPACE = keccak256(
            abi.encode(
                "General Rescheduling Task 1.0",
                "Calldata Hash Namespace",
                shMonad,
                taskManager,
                address(this),
                block.chainid
            )
        );
    }

    /// @notice Executes a task and handles potential rescheduling
    /// @dev Includes gas management and failure handling
    /// @dev Must be called through delegation (not directly on implementation)
    /// @param target Address of the contract to execute the task on
    /// @param data Calldata to execute on the target contract
    function execute(address target, bytes calldata data) external {
        if (address(this) == _IMPLEMENTATION) {
            revert MustBeDelegated();
        }

        GeneralReschedulingTask(_IMPLEMENTATION).markTarget(target, data);

        // Leave enough room for rescheduling
        // NOTE: Some functions inside processTurn will iterate until gasleft() is low
        uint256 gasLimit = gasleft() > _MIN_RESCHEDULE_GAS ? gasleft() - _MIN_RESCHEDULE_GAS : gasleft();

        // Process the turn
        (bool success,) = target.call{ gas: gasLimit * 63 / 64 }(data);

        if (!success) {
            revert ExecutionFailed();
        }

        (uint256 maxCost, uint256 targetBlock, bool reschedule) =
            GeneralReschedulingTask(_IMPLEMENTATION).returnAndClearRescheduleData(target);

        // Check for value - could be sent from battlenads or just leftover
        uint256 value = address(this).balance;
        if (!reschedule) {
            if (value > 0 && gasleft() > 25_000) {
                IShMonad(_SHMONAD).boostYield{ value: value }();
            }
            return;
        }

        // Recommend checking this prior to rescheduling
        if (value < maxCost) {
            revert CantAffordReschedule(value, maxCost);
        }

        // Reschedule the task
        (reschedule,,) = ITaskManager(msg.sender).rescheduleTask{ value: maxCost }(uint64(targetBlock), maxCost);

        if (!reschedule) {
            revert ReschedulingFailed();
        }
    }

    /// @notice Marks a target for task execution and stores its data
    /// @dev Must be called directly on implementation by active task
    /// @param target Address of the target contract
    /// @param data Calldata to be executed
    function markTarget(address target, bytes calldata data) external {
        if (address(this) != _IMPLEMENTATION) {
            revert CantBeDelegated();
        }
        if (msg.sender != _activeTask()) {
            revert CallerMustBeActiveTask();
        }
        bytes32 _calldataHash = keccak256(data);

        _storeTarget(target);
        _storeCaller(msg.sender);
        _storeCalldataHash(_calldataHash);
    }

    /// @notice Retrieves the stored target, task, and calldata hash
    /// @dev Must be called directly on implementation
    /// @return target Address of the target contract
    /// @return task Address of the task contract
    /// @return calldataHash Hash of the stored calldata
    function getTargetTaskCalldataHash() external view returns (address target, address task, bytes32 calldataHash) {
        if (address(this) != _IMPLEMENTATION) {
            revert CantBeDelegated();
        }

        target = _loadTarget();
        task = _loadCaller();
        calldataHash = _loadCalldataHash();
    }

    /// @notice Validates if provided target and data match stored values
    /// @dev Must be called directly on implementation
    /// @param target Address to validate against stored target
    /// @param data Calldata to validate against stored hash
    /// @return validMatch True if target and data match stored values
    function matchCalldataHash(address target, bytes calldata data) public view returns (bool validMatch) {
        if (address(this) != _IMPLEMENTATION) {
            revert CantBeDelegated();
        }
        bytes32 _expectedCalldataHash = keccak256(data);
        bytes32 _actualCalldataHash = _loadCalldataHash();
        validMatch = _expectedCalldataHash == _actualCalldataHash && target == _loadTarget();
    }

    /// @notice Sets rescheduling parameters for a task
    /// @dev Must be called directly on implementation by target contract
    /// @param task Address of the task to reschedule
    /// @param maxCost Maximum cost allowed for rescheduling
    /// @param targetBlock Target block for rescheduling
    /// @param reschedule Whether to enable rescheduling
    function setRescheduleData(address task, uint256 maxCost, uint256 targetBlock, bool reschedule) external {
        if (address(this) != _IMPLEMENTATION) {
            revert CantBeDelegated();
        }
        if (msg.sender != _loadTarget()) {
            revert OnlyTargetCanSetReschedule();
        }
        if (task != _loadCaller()) {
            revert InvalidTaskMatch(task, _loadCaller());
        }

        _storeRescheduleData(maxCost, targetBlock, reschedule);
    }

    /// @notice Sets rescheduling data if target and data match stored values
    /// @dev Must be called directly on implementation by target contract
    /// @param target Address to validate against stored target
    /// @param data Calldata to validate against stored hash
    /// @param task Address of the task to reschedule
    /// @param maxCost Maximum cost allowed for rescheduling
    /// @param targetBlock Target block for rescheduling
    /// @param reschedule Whether to enable rescheduling
    /// @return valid True if data was set successfully
    function setRescheduleDataIfMatch(
        address target,
        bytes calldata data,
        address task,
        uint256 maxCost,
        uint256 targetBlock,
        bool reschedule
    )
        external
        returns (bool valid)
    {
        if (address(this) != _IMPLEMENTATION) {
            revert CantBeDelegated();
        }
        if (msg.sender != _loadTarget()) {
            revert OnlyTargetCanSetReschedule();
        }
        if (task != _loadCaller()) {
            revert InvalidTaskMatch(task, _loadCaller());
        }

        if (matchCalldataHash(target, data)) {
            _storeRescheduleData(maxCost, targetBlock, reschedule);
            valid = true;
        }
    }

    /// @notice Retrieves stored rescheduling data
    /// @dev Must be called directly on implementation by active task
    /// @param target Address of the target contract
    /// @return maxCost Maximum cost allowed for rescheduling
    /// @return targetBlock Target block for rescheduling
    /// @return reschedule Whether rescheduling is enabled
    function returnRescheduleData(address target)
        external
        returns (uint256 maxCost, uint256 targetBlock, bool reschedule)
    {
        if (address(this) != _IMPLEMENTATION) {
            revert CantBeDelegated();
        }
        if (msg.sender != _loadCaller()) {
            revert CallerMustBeActiveTask();
        }
        if (target != _loadTarget()) {
            revert OnlyTargetCanSetReschedule();
        }

        (maxCost, targetBlock, reschedule) = _loadRescheduleData();
    }

    /// @notice Retrieves and clears stored rescheduling data
    /// @dev Must be called directly on implementation by active task
    /// @param target Address of the target contract
    /// @return maxCost Maximum cost allowed for rescheduling
    /// @return targetBlock Target block for rescheduling
    /// @return reschedule Whether rescheduling is enabled
    function returnAndClearRescheduleData(address target)
        external
        returns (uint256 maxCost, uint256 targetBlock, bool reschedule)
    {
        if (address(this) != _IMPLEMENTATION) {
            revert CantBeDelegated();
        }
        if (msg.sender != _loadCaller()) {
            revert CallerMustBeActiveTask();
        }
        if (target != _loadTarget()) {
            revert OnlyTargetCanSetReschedule();
        }

        (maxCost, targetBlock, reschedule) = _loadRescheduleData();

        _storeTarget(address(0));
        _storeCaller(address(0));
        _storeCalldataHash(bytes32(0));
        _storeRescheduleData(0, 0, false);
    }

    /// @notice Clears all stored rescheduling data
    /// @dev Must be called directly on implementation by active task or target
    function clearRescheduleData() external {
        if (address(this) != _IMPLEMENTATION) {
            revert CantBeDelegated();
        }
        if (msg.sender != _loadCaller() && msg.sender != _loadTarget()) {
            revert CallerMustBeActiveTaskOrTarget();
        }

        _storeTarget(address(0));
        _storeCaller(address(0));
        _storeCalldataHash(bytes32(0));
        _storeRescheduleData(0, 0, false);
    }

    /// @notice Gets the currently active task from the task manager
    /// @return activeTask Address of the currently active task
    function _activeTask() internal view returns (address activeTask) {
        activeTask = ITaskManager(_TASK_MANAGER).getCurrentTask();
    }

    /// @notice Stores target address in transient storage
    /// @param target Address to store
    function _storeTarget(address target) internal {
        bytes32 _targetTransientSlot = _TARGET_NAMESPACE;
        assembly {
            tstore(_targetTransientSlot, target)
        }
    }

    /// @notice Loads target address from transient storage
    /// @return target Stored target address
    function _loadTarget() internal view returns (address target) {
        bytes32 _targetTransientSlot = _TARGET_NAMESPACE;
        assembly {
            target := tload(_targetTransientSlot)
        }
    }

    /// @notice Stores calldata hash in transient storage
    /// @param calldataHash Hash to store
    function _storeCalldataHash(bytes32 calldataHash) internal {
        bytes32 _calldataTransientSlot = _CALLDATA_NAMESPACE;
        assembly {
            tstore(_calldataTransientSlot, calldataHash)
        }
    }

    /// @notice Loads calldata hash from transient storage
    /// @return calldataHash Stored calldata hash
    function _loadCalldataHash() internal view returns (bytes32 calldataHash) {
        bytes32 _calldataTransientSlot = _CALLDATA_NAMESPACE;
        assembly {
            calldataHash := tload(_calldataTransientSlot)
        }
    }

    /// @notice Stores caller address in transient storage
    /// @param expectedCaller Address to store
    function _storeCaller(address expectedCaller) internal {
        bytes32 _callerTransientSlot = _CALLER_NAMESPACE;
        assembly {
            tstore(_callerTransientSlot, expectedCaller)
        }
    }

    /// @notice Loads caller address from transient storage
    /// @return expectedCaller Stored caller address
    function _loadCaller() internal view returns (address expectedCaller) {
        bytes32 _callerTransientSlot = _CALLER_NAMESPACE;
        assembly {
            expectedCaller := tload(_callerTransientSlot)
        }
    }

    /// @notice Stores rescheduling data in transient storage
    /// @dev Packs the data into a single storage slot
    /// @param maxCost Maximum cost allowed for rescheduling
    /// @param targetBlock Target block for rescheduling
    /// @param reschedule Whether to enable rescheduling
    function _storeRescheduleData(uint256 maxCost, uint256 targetBlock, bool reschedule) internal {
        uint256 _packedRescheduleData = _packRescheduleData(maxCost, targetBlock, reschedule);

        bytes32 _rescheduleDataTransientSlot = _RESCHEDULE_NAMESPACE;
        assembly {
            tstore(_rescheduleDataTransientSlot, _packedRescheduleData)
        }
    }

    /// @notice Loads and unpacks rescheduling data from transient storage
    /// @return maxCost Maximum cost allowed for rescheduling
    /// @return targetBlock Target block for rescheduling
    /// @return reschedule Whether rescheduling is enabled
    function _loadRescheduleData() internal view returns (uint256 maxCost, uint256 targetBlock, bool reschedule) {
        bytes32 _rescheduleDataTransientSlot = _RESCHEDULE_NAMESPACE;
        uint256 _packedRescheduleData;
        assembly {
            _packedRescheduleData := tload(_rescheduleDataTransientSlot)
        }
        return _unpackRescheduleData(_packedRescheduleData);
    }

    /// @notice Packs rescheduling data into a single uint256
    /// @dev Combines maxCost (128 bits), targetBlock (64 bits), and reschedule flag (1 bit)
    /// @param maxCost Maximum cost allowed for rescheduling
    /// @param targetBlock Target block for rescheduling
    /// @param reschedule Whether to enable rescheduling
    /// @return packed Packed data as a single uint256
    function _packRescheduleData(
        uint256 maxCost,
        uint256 targetBlock,
        bool reschedule
    )
        internal
        pure
        returns (uint256 packed)
    {
        if (maxCost > type(uint128).max) revert RescheduleCostTooHigh(maxCost);
        if (targetBlock > type(uint64).max) revert TargetBlockTooHigh(targetBlock);
        if (reschedule) {
            packed = maxCost | (targetBlock << 128) | _RESCHEDULE_BIT;
        }
    }

    /// @notice Unpacks rescheduling data from a single uint256
    /// @dev Extracts maxCost (128 bits), targetBlock (64 bits), and reschedule flag (1 bit)
    /// @param packed Packed data as a single uint256
    /// @return maxCost Maximum cost allowed for rescheduling
    /// @return targetBlock Target block for rescheduling
    /// @return reschedule Whether rescheduling is enabled
    function _unpackRescheduleData(uint256 packed)
        internal
        pure
        returns (uint256 maxCost, uint256 targetBlock, bool reschedule)
    {
        reschedule = packed & _RESCHEDULE_BIT != 0;
        if (reschedule) {
            maxCost = packed & 0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff;
            targetBlock = (packed >> 128) & 0x000000000000000000000000000000000000000000000000ffffffffffffffff;
        }
    }
}
