//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RelayTaskScheduler } from "./core/RelayTaskScheduler.sol";
import { RelayNonUpgradeable } from "./core/RelayNonUpgradeable.sol";

/*
    THIS TASK IS UNSAFE FOR ANY CONTRACTS THAT ALLOW ARBITRARY CALLS TO ARBITRARY TARGETS!
    AN ATTACKER CAN CALL THE RESCHEDULING IMPLEMENTATION PRETENDING TO BE YOUR CONTRACT
    AND RESCHEDULE A TASK THAT WASNT INTENDED TO BE RESCHEDULED.

    PLEASE USE THIS TASK ONLY WHEN YOU EITHER:
        - Do not allow arbitrary calls to arbitrary targets from arbitrary sources
        - Screen call targets against this task's implementation address
        - Use an "airlock" pattern when making / forwarding arbitrary calls
    A "SAFE" VERSION FOR CALL FORWARDING CONTRACTS WILL BE AVAILABLE IN A FUTURE
    RELEASE.
*/

/// @title GasRelayWithScheduling
/// @notice Non-Upgradeable contract for gas abstraction, session key management, and callback scheduling
/// @dev Extends the base gas relay functionality with task scheduling capabilities
contract GasRelayWithScheduling is RelayTaskScheduler, RelayNonUpgradeable {
    /// @notice Maximum gas allowed for searching scheduled tasks
    uint256 private immutable _MAX_SEARCH_GAS;
    /// @notice Minimum gas that must remain after scheduling a task
    uint256 private immutable _MIN_EXECUTION_GAS_REMAINING;

    /// @notice Initializes the contract with gas relay and scheduling parameters
    /// @param maxExpectedGasUsagePerTx Maximum gas expected to be used per transaction
    /// @param escrowDuration Number of blocks for which funds are held in escrow
    /// @param targetBalanceMultiplier Multiplier used to determine target balance for gas fees
    /// @param maxSearchGas Maximum gas allowed for searching for an affordable block to schedule a task
    /// @param minExecutionGasRemaining Minimum gas that must remain after scheduling a task for the function to
    /// complete
    constructor(
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier,
        uint256 maxSearchGas,
        uint256 minExecutionGasRemaining
    )
        RelayNonUpgradeable(maxExpectedGasUsagePerTx, escrowDuration, targetBalanceMultiplier)
    {
        _MAX_SEARCH_GAS = maxSearchGas;
        _MIN_EXECUTION_GAS_REMAINING = minExecutionGasRemaining;
    }

    /// @notice Returns the maximum gas allowed for searching for an affordable block
    /// @return maxGasUsage The maximum gas that can be used for block search
    function _maxSearchGas() internal view override returns (uint256 maxGasUsage) {
        maxGasUsage = _MAX_SEARCH_GAS;
    }

    /// @notice Returns the minimum gas that must remain after scheduling a task
    /// @return minRemainingGasUsage The minimum gas that must be available after scheduling
    function _minExecutionGasRemaining() internal view override returns (uint256 minRemainingGasUsage) {
        minRemainingGasUsage = _MIN_EXECUTION_GAS_REMAINING;
    }
}
