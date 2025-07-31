// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { SafetyBits, SAFE_USER_TRANSFER, SAFE_DAPP_TRANSFER } from "../../../src/atlas/libraries/SafetyBits.sol";
import { Context, ExecutionPhase } from "../../../src/atlas/types/LockTypes.sol";

contract SafetyBitsTest is Test {
    using SafetyBits for Context;

    function test_constants() public pure {
        // SAFE_USER_TRANSFER should allow transfers in: PreOps, UserOperation, PreSolver, PostSolver
        // Binary: 00101110 (phases 1,2,3,5 are allowed)
        uint8 expectedUserTransfer = uint8(
            (1 << uint8(ExecutionPhase.PreOps)) |
            (1 << uint8(ExecutionPhase.UserOperation)) |
            (1 << uint8(ExecutionPhase.PreSolver)) |
            (1 << uint8(ExecutionPhase.PostSolver))
        );
        assertEq(SAFE_USER_TRANSFER, expectedUserTransfer);
        assertEq(SAFE_USER_TRANSFER, 0x2E); // Binary: 00101110

        // SAFE_DAPP_TRANSFER should allow transfers in: PreOps, PreSolver, PostSolver, AllocateValue
        // Binary: 01101010 (phases 1,3,5,6 are allowed)
        uint8 expectedDappTransfer = uint8(
            (1 << uint8(ExecutionPhase.PreOps)) |
            (1 << uint8(ExecutionPhase.PreSolver)) |
            (1 << uint8(ExecutionPhase.PostSolver)) |
            (1 << uint8(ExecutionPhase.AllocateValue))
        );
        assertEq(SAFE_DAPP_TRANSFER, expectedDappTransfer);
        assertEq(SAFE_DAPP_TRANSFER, 0x6A); // Binary: 01101010
    }

    function test_setAndPack_defaultContext() public pure {
        Context memory ctx;
        
        bytes memory packed = ctx.setAndPack(ExecutionPhase.PreOps);
        
        // Context should have phase set
        assertEq(ctx.phase, uint8(ExecutionPhase.PreOps));
        
        // Packed data should be correct length (20 + 1 + 1 + 1 + 1 + 3 + 1 + 1 + 1 = 30 bytes)
        assertEq(packed.length, 30);
        
        // Verify packed structure
        assertEq(address(bytes20(packed)), address(0)); // bundler
        assertEq(uint8(packed[20]), 0); // solverSuccessful
        assertEq(uint8(packed[21]), 0); // solverIndex
        assertEq(uint8(packed[22]), 0); // solverCount
        assertEq(uint8(packed[23]), uint8(ExecutionPhase.PreOps)); // phase
        // solverOutcome is uint24 (3 bytes)
        assertEq(uint8(packed[24]), 0); // solverOutcome byte 1
        assertEq(uint8(packed[25]), 0); // solverOutcome byte 2
        assertEq(uint8(packed[26]), 0); // solverOutcome byte 3
        assertEq(uint8(packed[27]), 0); // bidFind
        assertEq(uint8(packed[28]), 0); // isSimulation
        assertEq(uint8(packed[29]), 1); // callDepth (always 1)
    }

    function test_setAndPack_withValues() public pure {
        Context memory ctx = Context({
            userOpHash: bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222)),
            executionEnvironment: address(0x1111111111111111111111111111111111111111),
            solverOutcome: 42,
            solverIndex: 5,
            solverCount: 10,
            callDepth: 0, // This will be overridden to 1
            phase: uint8(ExecutionPhase.UserOperation),
            solverSuccessful: true,
            bidFind: true,
            isSimulation: true,
            bundler: address(0x3333333333333333333333333333333333333333),
            dappGasLeft: 100000
        });
        
        bytes memory packed = ctx.setAndPack(ExecutionPhase.PreSolver);
        
        // Context phase should be updated
        assertEq(ctx.phase, uint8(ExecutionPhase.PreSolver));
        
        // Verify packed structure
        assertEq(address(bytes20(packed)), address(0x3333333333333333333333333333333333333333)); // bundler
        assertEq(uint8(packed[20]), 1); // solverSuccessful (true)
        assertEq(uint8(packed[21]), 5); // solverIndex
        assertEq(uint8(packed[22]), 10); // solverCount
        assertEq(uint8(packed[23]), uint8(ExecutionPhase.PreSolver)); // phase (updated)
        // solverOutcome is uint24 (3 bytes) - value 42
        assertEq(uint8(packed[24]), 0); // solverOutcome byte 1 (MSB)
        assertEq(uint8(packed[25]), 0); // solverOutcome byte 2
        assertEq(uint8(packed[26]), 42); // solverOutcome byte 3 (LSB)
        assertEq(uint8(packed[27]), 1); // bidFind (true)
        assertEq(uint8(packed[28]), 1); // isSimulation (true)
        assertEq(uint8(packed[29]), 1); // callDepth (always 1)
    }

    function test_setAndPack_allPhases() public pure {
        Context memory ctx;
        
        // Test each phase
        ExecutionPhase[8] memory phases = [
            ExecutionPhase.Uninitialized,
            ExecutionPhase.PreOps,
            ExecutionPhase.UserOperation,
            ExecutionPhase.PreSolver,
            ExecutionPhase.SolverOperation,
            ExecutionPhase.PostSolver,
            ExecutionPhase.AllocateValue,
            ExecutionPhase.FullyLocked
        ];
        
        for (uint i = 0; i < phases.length; i++) {
            bytes memory packed = ctx.setAndPack(phases[i]);
            assertEq(ctx.phase, uint8(phases[i]));
            assertEq(uint8(packed[23]), uint8(phases[i]));
            assertEq(uint8(packed[29]), 1); // callDepth always 1
        }
    }

    function testFuzz_setAndPack(
        address bundler,
        bool solverSuccessful,
        uint8 solverIndex,
        uint8 solverCount,
        uint8 phase,
        uint24 solverOutcome,
        bool bidFind,
        bool isSimulation
    ) public pure {
        // Bound phase to valid ExecutionPhase values
        phase = uint8(bound(phase, 0, 7));
        
        Context memory ctx = Context({
            userOpHash: bytes32(0),
            executionEnvironment: address(0),
            solverOutcome: solverOutcome,
            solverIndex: solverIndex,
            solverCount: solverCount,
            callDepth: 0,
            phase: 0,
            solverSuccessful: solverSuccessful,
            bidFind: bidFind,
            isSimulation: isSimulation,
            bundler: bundler,
            dappGasLeft: 0
        });
        
        bytes memory packed = ctx.setAndPack(ExecutionPhase(phase));
        
        // Verify context was updated
        assertEq(ctx.phase, phase);
        
        // Verify packed data
        assertEq(address(bytes20(packed)), bundler);
        assertEq(uint8(packed[20]), solverSuccessful ? 1 : 0);
        assertEq(uint8(packed[21]), solverIndex);
        assertEq(uint8(packed[22]), solverCount);
        assertEq(uint8(packed[23]), phase);
        // solverOutcome is uint24 (3 bytes)
        assertEq(uint8(packed[24]), uint8(solverOutcome >> 16)); // MSB
        assertEq(uint8(packed[25]), uint8(solverOutcome >> 8)); // Middle byte
        assertEq(uint8(packed[26]), uint8(solverOutcome)); // LSB
        assertEq(uint8(packed[27]), bidFind ? 1 : 0);
        assertEq(uint8(packed[28]), isSimulation ? 1 : 0);
        assertEq(uint8(packed[29]), 1); // callDepth always 1
    }

    function test_phaseTransitions() public pure {
        Context memory ctx;
        
        // Simulate typical phase transitions
        bytes memory packed1 = ctx.setAndPack(ExecutionPhase.PreOps);
        assertEq(ctx.phase, uint8(ExecutionPhase.PreOps));
        
        bytes memory packed2 = ctx.setAndPack(ExecutionPhase.UserOperation);
        assertEq(ctx.phase, uint8(ExecutionPhase.UserOperation));
        
        bytes memory packed3 = ctx.setAndPack(ExecutionPhase.PreSolver);
        assertEq(ctx.phase, uint8(ExecutionPhase.PreSolver));
        
        bytes memory packed4 = ctx.setAndPack(ExecutionPhase.PostSolver);
        assertEq(ctx.phase, uint8(ExecutionPhase.PostSolver));
        
        bytes memory packed5 = ctx.setAndPack(ExecutionPhase.AllocateValue);
        assertEq(ctx.phase, uint8(ExecutionPhase.AllocateValue));
        
        bytes memory packed6 = ctx.setAndPack(ExecutionPhase.FullyLocked);
        assertEq(ctx.phase, uint8(ExecutionPhase.FullyLocked));
        
        // Each packed result should reflect the correct phase
        assertEq(uint8(packed1[23]), uint8(ExecutionPhase.PreOps));
        assertEq(uint8(packed2[23]), uint8(ExecutionPhase.UserOperation));
        assertEq(uint8(packed3[23]), uint8(ExecutionPhase.PreSolver));
        assertEq(uint8(packed4[23]), uint8(ExecutionPhase.PostSolver));
        assertEq(uint8(packed5[23]), uint8(ExecutionPhase.AllocateValue));
        assertEq(uint8(packed6[23]), uint8(ExecutionPhase.FullyLocked));
    }

    function test_safeTransferBitmasks() public pure {
        // Test user transfer safety for each phase
        assertTrue(_isPhaseAllowed(SAFE_USER_TRANSFER, ExecutionPhase.PreOps));
        assertTrue(_isPhaseAllowed(SAFE_USER_TRANSFER, ExecutionPhase.UserOperation));
        assertTrue(_isPhaseAllowed(SAFE_USER_TRANSFER, ExecutionPhase.PreSolver));
        assertTrue(_isPhaseAllowed(SAFE_USER_TRANSFER, ExecutionPhase.PostSolver));
        assertFalse(_isPhaseAllowed(SAFE_USER_TRANSFER, ExecutionPhase.AllocateValue));
        assertFalse(_isPhaseAllowed(SAFE_USER_TRANSFER, ExecutionPhase.SolverOperation));
        assertFalse(_isPhaseAllowed(SAFE_USER_TRANSFER, ExecutionPhase.FullyLocked));
        assertFalse(_isPhaseAllowed(SAFE_USER_TRANSFER, ExecutionPhase.Uninitialized));
        
        // Test dapp transfer safety for each phase
        assertTrue(_isPhaseAllowed(SAFE_DAPP_TRANSFER, ExecutionPhase.PreOps));
        assertFalse(_isPhaseAllowed(SAFE_DAPP_TRANSFER, ExecutionPhase.UserOperation));
        assertTrue(_isPhaseAllowed(SAFE_DAPP_TRANSFER, ExecutionPhase.PreSolver));
        assertFalse(_isPhaseAllowed(SAFE_DAPP_TRANSFER, ExecutionPhase.SolverOperation));
        assertTrue(_isPhaseAllowed(SAFE_DAPP_TRANSFER, ExecutionPhase.PostSolver));
        assertTrue(_isPhaseAllowed(SAFE_DAPP_TRANSFER, ExecutionPhase.AllocateValue));
        assertFalse(_isPhaseAllowed(SAFE_DAPP_TRANSFER, ExecutionPhase.FullyLocked));
        assertFalse(_isPhaseAllowed(SAFE_DAPP_TRANSFER, ExecutionPhase.Uninitialized));
    }

    function _isPhaseAllowed(uint8 bitmask, ExecutionPhase phase) private pure returns (bool) {
        return (bitmask & (1 << uint8(phase))) != 0;
    }
}