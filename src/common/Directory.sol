//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Pointers / Indices for common addresses.
library Directory {
    // WARNING: NEVER -EVER- CHANGE ONE OF THESE
    // DOING SO WILL BREAK BACKWARDS AND FORWARDS COMPATIBILITY

    // CONSIDER THIS LIST APPEND-ONLY.

    // 0 is null - leave unassigned
    uint256 internal constant _SHMONAD = 1;
    uint256 internal constant _VALIDATOR_AUCTION = 2;
    uint256 internal constant _ATLAS = 3;
    uint256 internal constant _CLEARING_HOUSE = 4;
    uint256 internal constant _TASK_MANAGER = 5;
    uint256 internal constant _CAPITAL_ALLOCATOR = 6;
    uint256 internal constant _STAKING_HUB = 7;
    uint256 internal constant _ENTRYPOINT_4337 = 8;
    uint256 internal constant _PAYMASTER_4337 = 9;
    uint256 internal constant _SPONSORED_EXECUTOR = 10;
    uint256 internal constant _RPC_POLICY = 11;
    // uint256 internal constant _THE_NEXT_ONE = 12;

    // CONSIDER THIS LIST APPEND-ONLY.
}
