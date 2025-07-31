// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { SafetyLocks } from "../../src/atlas/core/SafetyLocks.sol";
import { AtlasEvents } from "../../src/atlas/types/AtlasEvents.sol";
import { AtlasErrors } from "../../src/atlas/types/AtlasErrors.sol";
import { DAppConfig } from "../../src/atlas/types/ConfigTypes.sol";
import { Context, ExecutionPhase } from "../../src/atlas/types/LockTypes.sol";

contract MockSafetyLocks is SafetyLocks {
    constructor() SafetyLocks(
        1_000_000, // atlasSurchargeRate
        address(0), // verification
        address(0), // simulator
        address(0), // initialSurchargeRecipient
        address(0), // l2GasCalculator
        address(0), // taskManager
        address(0), // shMonad
        0 // shMonadPolicyID
    ) { }

    function initializeLock(address executionEnvironment, uint256 gasMarker, uint256 userOpValue) external payable {
        DAppConfig memory dConfig;
        _setEnvironmentLock(dConfig, executionEnvironment);
        // Note: _initializeAccountingValues was removed in newer version
    }

    function buildContext(
        bytes32 userOpHash,
        address executionEnvironment,
        address bundler,
        uint32 dappGasLimit,
        uint8 solverOpCount,
        bool isSimulation
    )
        external
        pure
        returns (Context memory ctx)
    {
        return _buildContext(userOpHash, executionEnvironment, bundler, dappGasLimit, solverOpCount, isSimulation);
    }

    function setLock(address _activeEnvironment) external {
        _setLock({
            activeEnvironment: _activeEnvironment,
            callConfig: uint32(0),
            phase: uint8(ExecutionPhase.Uninitialized)
        });
    }

    function releaseLock() external {
        _releaseLock();
    }

    function setLockPhase(uint8 newPhase) external {
        _setLockPhase(newPhase);
    }

    function setSolverLock(uint256 newSolverLock) public {
        t_solverLock = newSolverLock;
    }

    function setSolverTo(address newSolverTo) public {
        t_solverTo = newSolverTo;
    }

    function solverTo() external view returns (address) {
        return t_solverTo;
    }
}

contract SafetyLocksTest is Test {
    MockSafetyLocks public safetyLocks;
    address executionEnvironment = makeAddr("executionEnvironment");

    function setUp() public {
        safetyLocks = new MockSafetyLocks();
    }

    function test_setEnvironmentLock() public {
        uint256 gasMarker = 222;
        uint256 userOpValue = 333;
        uint256 msgValue = 444;

        safetyLocks.setLock(address(2));
        vm.expectRevert(AtlasErrors.AlreadyInitialized.selector);
        safetyLocks.initializeLock{ value: msgValue }(executionEnvironment, gasMarker, userOpValue);

        safetyLocks.releaseLock(); // Reset to UNLOCKED
        safetyLocks.initializeLock{ value: msgValue }(executionEnvironment, gasMarker, userOpValue);

        (address activeEnv, uint32 callConfig, uint8 phase) = safetyLocks.lock();

        assertEq(activeEnv, executionEnvironment);
        assertEq(phase, uint8(ExecutionPhase.PreOps));
        assertEq(callConfig, uint32(0));
    }

    function test_buildContext() public {
        safetyLocks.initializeLock(executionEnvironment, 0, 0);
        Context memory ctx = safetyLocks.buildContext({ 
            userOpHash: bytes32(uint256(1)),
            executionEnvironment: executionEnvironment,
            bundler: address(2),
            dappGasLimit: 3,
            solverOpCount: 4,
            isSimulation: true
        });
        assertEq(executionEnvironment, ctx.executionEnvironment);
        assertEq(bytes32(uint256(1)), ctx.userOpHash);
        assertEq(address(2), ctx.bundler);
        assertEq(3, ctx.dappGasLeft);
        assertEq(4, ctx.solverCount);
        assertEq(true, ctx.isSimulation);
    }

    function test_setLockPhase() public {
        uint8 newPhase = uint8(ExecutionPhase.SolverOperation);

        safetyLocks.setLockPhase(newPhase);

        (,, uint8 phase) = safetyLocks.lock();
        assertEq(phase, newPhase);
    }

    function test_isUnlocked() public {
        safetyLocks.setLock(address(2));
        assertEq(safetyLocks.isUnlocked(), false);
        safetyLocks.releaseLock();
        assertEq(safetyLocks.isUnlocked(), true);
    }

    function test_combinedOperations() public {
        address ee = makeAddr("anotherExecutionEnvironment");
        uint256 gasMarker = 222;
        uint256 userOpValue = 333;
        uint256 msgValue = 444;

        safetyLocks.setLock(address(2));
        assertEq(safetyLocks.isUnlocked(), false);
        vm.expectRevert(AtlasErrors.AlreadyInitialized.selector);
        safetyLocks.initializeLock{ value: msgValue }(ee, gasMarker, userOpValue);
        safetyLocks.releaseLock();
        assertEq(safetyLocks.isUnlocked(), true);
        safetyLocks.initializeLock{ value: msgValue }(ee, gasMarker, userOpValue);
        safetyLocks.setLockPhase(uint8(ExecutionPhase.SolverOperation));
        safetyLocks.setSolverLock(0x456);

        (address activeEnv, uint32 callConfig, uint8 phase) = safetyLocks.lock();
        (address solverTo,,) = safetyLocks.solverLockData();

        assertEq(safetyLocks.isUnlocked(), false);
        assertEq(activeEnv, ee);
        assertEq(phase, uint8(ExecutionPhase.SolverOperation));
        assertEq(callConfig, uint32(0));
        assertEq(solverTo, address(0x456));
    }
}