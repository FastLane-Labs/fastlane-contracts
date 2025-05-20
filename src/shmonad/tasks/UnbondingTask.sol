//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IShMonad } from "../interfaces/IShMonad.sol";

// This is the implementation for an unbonding task run through the Taskmanager
contract UnbondingTask {
    address private immutable _SHMONAD;
    address private immutable _IMPLEMENTATION;

    // This is deployed by the ShMonad constructor
    constructor(address shMonad) {
        _SHMONAD = shMonad;
        _IMPLEMENTATION = address(this);
    }

    function claimAsTask(uint64 policyID, uint256 amount, address account) external {
        require(address(this) != _IMPLEMENTATION, "ERR-MustBeDelegated");
        IShMonad(_SHMONAD).claimAsTask(policyID, amount, account);
    }
}
