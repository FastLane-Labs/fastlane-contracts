//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RelayTaskScheduler } from "./core/RelayTaskScheduler.sol";
import { RelayUpgradeable } from "./core/RelayUpgradeable.sol";

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

/// @title GasRelayWithSchedulingUpgradeable
/// @notice Upgradeable contract for gas abstraction, session key management, and callback scheduling
/// @dev Extends the base gas relay functionality with task scheduling capabilities in an upgradeable format
contract GasRelayWithSchedulingUpgradeable is RelayTaskScheduler, RelayUpgradeable {
    /// @notice Internal initialization function for the gas relay contract with scheduling
    /// @dev This function can only be called once during contract initialization
    /// @param maxExpectedGasUsagePerTx Maximum gas expected to be used per transaction
    /// @param escrowDuration Number of blocks for which funds are held in escrow
    /// @param targetBalanceMultiplier Multiplier used to determine target balance for gas fees
    function _gasRelayWithSchedulingInitialize(
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier
    )
        internal
        onlyInitializing
    {
        super.__gasRelayInitialize(maxExpectedGasUsagePerTx, escrowDuration, targetBalanceMultiplier);
    }

    /// @notice Returns the maximum gas allowed for searching for an affordable block
    /// @dev This is hardcoded to a safe value to optimize gas costs
    /// @return maxGasUsage The maximum gas that can be used for block search
    function _maxSearchGas() internal view override returns (uint256 maxGasUsage) {
        maxGasUsage = 50_000;
    }

    /// @notice Returns the minimum gas that must remain after scheduling a task
    /// @dev This is hardcoded to a safe value to optimize gas costs
    /// @return minRemainingGasUsage The minimum gas that must be available after scheduling
    function _minExecutionGasRemaining() internal view override returns (uint256 minRemainingGasUsage) {
        minRemainingGasUsage = 50_000;
    }
}
