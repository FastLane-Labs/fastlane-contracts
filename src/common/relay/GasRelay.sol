//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { GasRelayBase } from "./core/GasRelayBase.sol";
import { RelayNonUpgradeable } from "./core/RelayNonUpgradeable.sol";

/// @title GasRelay
/// @notice Core contract for gas abstraction and session key management
/// @dev Implements the main entry points and modifiers for gas abstraction. This is the non-upgradeable version of the
/// contract.
contract GasRelay is GasRelayBase, RelayNonUpgradeable {
    /// @notice Initializes the gas relay contract with specified parameters
    /// @param maxExpectedGasUsagePerTx Maximum gas expected to be used per transaction
    /// @param escrowDuration Number of blocks for which funds are held in escrow
    /// @param targetBalanceMultiplier Multiplier used to determine target balance for gas fees
    constructor(
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier
    )
        RelayNonUpgradeable(maxExpectedGasUsagePerTx, escrowDuration, targetBalanceMultiplier)
    { }
}
