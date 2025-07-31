//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../src/atlas/core/Atlas.sol";

/// @title TestAtlas
/// @notice A test version of the Atlas contract that exposes internal functions for testing
contract TestAtlas is Atlas {
    constructor(
        uint256 atlasSurchargeRate,
        address verification,
        address simulator,
        address initialSurchargeRecipient,
        address l2GasCalculator,
        address factoryLib,
        address taskManager,
        address shMonad,
        uint64 shMonadPolicyID
    )
        Atlas(
            atlasSurchargeRate,
            verification,
            simulator,
            initialSurchargeRecipient,
            l2GasCalculator,
            factoryLib,
            taskManager,
            shMonad,
            shMonadPolicyID
        )
    { }

    // Public functions to expose internal transient helpers for testing

    function clearTransientStorage() public {
        _setLock(address(0), 0, 0);
        _releaseLock();
        t_solverLock = 0;
        t_solverTo = address(0);
    }

    // Transient Setters

    function setLock(address activeEnvironment, uint32 callConfig, uint8 phase) public {
        _setLock(activeEnvironment, callConfig, phase);
    }

    function setLockPhase(ExecutionPhase newPhase) public {
        _setLockPhase(uint8(newPhase));
    }

    function setSolverLock(uint256 newSolverLock) public {
        t_solverLock = newSolverLock;
    }
}
