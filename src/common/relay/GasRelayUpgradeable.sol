//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { GasRelayBase } from "./core/GasRelayBase.sol";
import { RelayUpgradeable } from "./core/RelayUpgradeable.sol";

/// @title GasRelayUpgradeable
/// @notice Core contract for gas abstraction and session key management
/// @dev Implements the main entry points and modifiers for gas abstraction. This is the upgradeable version of the
/// contract.
contract GasRelayUpgradeable is GasRelayBase, RelayUpgradeable {
    /// @notice Internal initialization function for the gas relay contract
    /// @dev This function can only be called once during contract initialization
    /// @param maxExpectedGasUsagePerTx Maximum gas expected to be used per transaction
    /// @param escrowDuration Number of blocks for which funds are held in escrow
    /// @param targetBalanceMultiplier Multiplier used to determine target balance for gas fees
    function _gasRelayInitialize(
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier
    )
        internal
    {
        super.__gasRelayInitialize(maxExpectedGasUsagePerTx, escrowDuration, targetBalanceMultiplier);
    }
}
