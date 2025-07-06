//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAddressHub } from "../../IAddressHub.sol";
import { SessionKey, SessionKeyData, GasAbstractionTracker, CallerType } from "../types/GasRelayTypes.sol";
import { GasRelayErrors } from "./GasRelayErrors.sol";

/// @title ITaskManagerImmutables
/// @notice Interface for accessing immutable variables from the TaskManager contract
/// @dev Used to fetch the policy ID during construction
interface ITaskManagerImmutables {
    /// @notice Returns the policy ID used by the task manager
    /// @return uint64 The policy ID as a uint64
    function POLICY_ID() external view returns (uint64);
}

/// @title GasRelayConstants
/// @notice Core constants and configuration for the gas relay system
/// @dev Contains all constant values and storage layouts used across both upgradeable and non-upgradeable
/// implementations
abstract contract GasRelayConstants is GasRelayErrors {
    /// @notice Address of the task manager contract
    /// @dev Immutable contract reference for task management functionality
    address public immutable TASK_MANAGER;

    /// @notice Policy ID for the task manager
    /// @dev Immutable ID used for task management policies
    uint64 public immutable TASK_MANAGER_POLICY_ID;

    /// @notice Address of the ShMonad protocol
    /// @dev Immutable contract reference for ShMonad protocol interactions
    address public immutable SHMONAD;

    /// @notice Address of the Atlas protocol
    /// @dev Immutable contract reference for Atlas protocol interactions
    address public immutable ATLAS;

    /// @notice Minimum gas required for task execution
    /// @dev Base gas requirement to ensure task completion
    uint256 internal constant _MIN_TASK_EXECUTION_GAS = 120_000;

    /// @notice Buffer for task manager execution
    /// @dev Additional gas buffer to ensure safe task manager operations
    uint256 internal constant _TASK_MANAGER_EXECUTION_GAS_BUFFER = 31_000;

    /// @notice Minimum gas required for gas abstraction
    /// @dev Base requirement for gas abstraction operations
    uint256 internal constant _GAS_ABSTRACTION_MIN_REMAINDER_GAS = 65_000;

    /// @notice Buffer for minimum remainder gas
    /// @dev Safety buffer added to minimum gas requirements
    uint256 internal constant _MIN_REMAINDER_GAS_BUFFER = 31_000;

    /// @notice Base gas usage for a transaction
    /// @dev Standard gas cost for basic transaction execution
    uint256 internal constant _BASE_TX_GAS_USAGE = 21_000;

    /// @notice Maximum base fee increase factor (112.5%)
    /// @dev Used to calculate maximum allowed base fee increases
    uint256 internal constant _BASE_FEE_MAX_INCREASE = 1125;

    /// @notice Denominator for base fee calculations
    /// @dev Used in conjunction with _BASE_FEE_MAX_INCREASE for percentage calculations
    uint256 internal constant _BASE_FEE_DENOMINATOR = 1000;

    /// @notice Address of the FastLane address hub contract on Monad
    /// @dev Central registry for FastLane contract addresses
    address public constant ADDRESS_HUB = 0xC9f0cDE8316AbC5Efc8C3f5A6b571e815C021B51;

    /// @notice Transient storage bit for tracking usage lock
    /// @dev Bit mask used to mark storage as in use
    bytes32 internal constant _IN_USE_BIT = 0x0000000000000000000000020000000000000000000000000000000000000000;

    /// @notice Transient storage bit for modifying usage lock
    /// @dev Bit mask used to clear the in-use flag
    bytes32 internal constant _NOT_IN_USE_BITMASK = 0xfffffffffffffffffffffffdffffffffffffffffffffffffffffffffffffffff;

    /// @notice Transient storage bit for identifying session keys
    /// @dev Bit mask used to mark storage as a session key
    bytes32 internal constant _IS_SESSION_KEY_BIT = 0x0000000000000000000000040000000000000000000000000000000000000000;

    /// @notice Transient storage bit for identifying tasks
    /// @dev Bit mask used to mark storage as a task
    // 1<<163
    bytes32 internal constant _IS_TASK_BIT = 0x0000000000000000000000080000000000000000000000000000000000000000;

    /// @notice Combined bits for session key in use
    /// @dev Combined bit mask for session key usage tracking
    bytes32 internal constant _IN_USE_AS_SESSION_KEY_BITS =
        0x0000000000000000000000060000000000000000000000000000000000000000;

    /// @notice Combined bits for task in use
    /// @dev Combined bit mask for task usage tracking
    bytes32 internal constant _IN_USE_AS_TASK_BITS = 0x00000000000000000000000a0000000000000000000000000000000000000000;

    /// @notice Initializes the contract with required protocol addresses
    /// @dev Fetches addresses from the hub and initializes immutable variables
    constructor() {
        address _taskManager = IAddressHub(ADDRESS_HUB).taskManager();
        TASK_MANAGER = _taskManager;

        address _shMonad = IAddressHub(ADDRESS_HUB).shMonad();
        SHMONAD = _shMonad;

        address _atlas = IAddressHub(ADDRESS_HUB).atlas();
        ATLAS = _atlas;

        TASK_MANAGER_POLICY_ID = ITaskManagerImmutables(_taskManager).POLICY_ID();
    }

    /// @notice Returns the policy ID for the current implementation
    /// @return The policy ID as a uint64
    function POLICY_ID() public view virtual returns (uint64);

    /// @notice Returns the address of the policy wrapper contract
    /// @return The policy wrapper contract address
    function POLICY_WRAPPER() public view virtual returns (address);

    /// @notice Returns the maximum expected gas usage per transaction
    /// @return The maximum gas usage limit
    function _MAX_EXPECTED_GAS_USAGE_PER_TX() internal view virtual returns (uint256);

    /// @notice Returns the target balance multiplier
    /// @return The multiplier used for balance calculations
    function _TARGET_BALANCE_MULTIPLIER() internal view virtual returns (uint256);

    /// @notice Returns the gas usage and multiplier values
    /// @return A tuple containing the gas usage and multiplier values
    function _GAS_USAGE_AND_MULTIPLIER() internal view virtual returns (uint256, uint256);

    /// @notice Returns the namespace for session keys
    /// @return The session key namespace identifier
    function _SESSION_KEY_NAMESPACE() internal view virtual returns (bytes32);

    /// @notice Returns the namespace for key owners
    /// @return The key owner namespace identifier
    function _KEY_OWNER_NAMESPACE() internal view virtual returns (bytes32);

    /// @notice Returns the namespace for underlying callers
    /// @return The underlying caller namespace identifier
    function _UNDERLYING_CALLER_NAMESPACE() internal view virtual returns (bytes32);
}
