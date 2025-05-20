//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title TaskAccountingMath
/// @notice Library for task accounting calculations and constants
library TaskAccountingMath {
    // Protocol fee percentage (in basis points)
    uint256 internal constant PROTOCOL_FEE_BPS = 2500; // 25%
    uint256 internal constant VALIDATOR_FEE_BPS = 2600; // 26%

    // Scale for basis points calculations
    uint256 internal constant BPS_SCALE = 10_000;
}
