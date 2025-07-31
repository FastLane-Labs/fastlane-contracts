// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { CallVerification } from "../../../src/atlas/libraries/CallVerification.sol";
import { UserOperation } from "../../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../../src/atlas/types/SolverOperation.sol";

contract CallVerificationTest is Test {
    function test_getCallChainHash_emptyOperations() public pure {
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](0);
        
        bytes32 hash = CallVerification.getCallChainHash(userOp, solverOps);
        
        // Verify we get a consistent hash for empty operations
        bytes memory expectedCallSequence = abi.encodePacked(
            abi.encode(userOp),
            abi.encode(solverOps)
        );
        bytes32 expectedHash = keccak256(expectedCallSequence);
        
        assertEq(hash, expectedHash);
    }

    function test_getCallChainHash_withUserOp() public view {
        UserOperation memory userOp = UserOperation({
            from: address(0x1111111111111111111111111111111111111111),
            to: address(0x2222222222222222222222222222222222222222),
            value: 1 ether,
            gas: 200000,
            maxFeePerGas: 20 gwei,
            nonce: 1,
            deadline: 1000,
            dapp: address(0x3333333333333333333333333333333333333333),
            control: address(0x4444444444444444444444444444444444444444),
            callConfig: 0,
            dappGasLimit: 100000,
            solverGasLimit: 200000,
            bundlerSurchargeRate: 100,
            sessionKey: address(0),
            data: hex"deadbeef",
            signature: hex""
        });
        
        SolverOperation[] memory solverOps = new SolverOperation[](0);
        
        bytes32 hash = CallVerification.getCallChainHash(userOp, solverOps);
        
        // Verify the hash is deterministic
        bytes32 hash2 = CallVerification.getCallChainHash(userOp, solverOps);
        assertEq(hash, hash2, "Hash should be deterministic");
        
        // Verify it's different from empty operations
        UserOperation memory emptyUserOp;
        bytes32 emptyHash = CallVerification.getCallChainHash(emptyUserOp, solverOps);
        assertNotEq(hash, emptyHash, "Hash should be different for different user ops");
    }

    function test_getCallChainHash_withSolverOps() public view {
        UserOperation memory userOp = UserOperation({
            from: address(0x1111111111111111111111111111111111111111),
            to: address(0x2222222222222222222222222222222222222222),
            value: 1 ether,
            gas: 200000,
            maxFeePerGas: 20 gwei,
            nonce: 1,
            deadline: 1000,
            dapp: address(0x3333333333333333333333333333333333333333),
            control: address(0x4444444444444444444444444444444444444444),
            callConfig: 0,
            dappGasLimit: 100000,
            solverGasLimit: 200000,
            bundlerSurchargeRate: 100,
            sessionKey: address(0),
            data: hex"deadbeef",
            signature: hex""
        });
        
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        
        SolverOperation[] memory solverOps = new SolverOperation[](2);
        solverOps[0] = SolverOperation({
            from: address(0x5555555555555555555555555555555555555555),
            to: address(0x6666666666666666666666666666666666666666),
            value: 0.5 ether,
            gas: 50000,
            maxFeePerGas: 20 gwei,
            deadline: 1000,
            solver: address(0x7777777777777777777777777777777777777777),
            control: address(0x4444444444444444444444444444444444444444),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: 0.1 ether,
            data: hex"cafebabe",
            signature: hex"00"
        });
        
        solverOps[1] = SolverOperation({
            from: address(0x8888888888888888888888888888888888888888),
            to: address(0x9999999999999999999999999999999999999999),
            value: 0.3 ether,
            gas: 40000,
            maxFeePerGas: 15 gwei,
            deadline: 2000,
            solver: address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa),
            control: address(0x4444444444444444444444444444444444444444),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: 0.2 ether,
            data: hex"baddcafe",
            signature: hex"01"
        });
        
        bytes32 hash = CallVerification.getCallChainHash(userOp, solverOps);
        
        // Verify the hash changes with different solver ops
        SolverOperation[] memory differentSolverOps = new SolverOperation[](1);
        differentSolverOps[0] = solverOps[0];
        
        bytes32 differentHash = CallVerification.getCallChainHash(userOp, differentSolverOps);
        assertNotEq(hash, differentHash, "Hash should be different with different solver ops");
    }

    function test_getCallChainHash_orderMatters() public pure {
        UserOperation memory userOp;
        
        SolverOperation[] memory solverOps = new SolverOperation[](2);
        solverOps[0] = SolverOperation({
            from: address(0x1111),
            to: address(0x2222),
            value: 1 ether,
            gas: 100000,
            maxFeePerGas: 10 gwei,
            deadline: 1000,
            solver: address(0x3333),
            control: address(0x4444),
            userOpHash: bytes32(0),
            bidToken: address(0),
            bidAmount: 0.1 ether,
            data: hex"01",
            signature: hex""
        });
        
        solverOps[1] = SolverOperation({
            from: address(0x5555),
            to: address(0x6666),
            value: 2 ether,
            gas: 200000,
            maxFeePerGas: 20 gwei,
            deadline: 2000,
            solver: address(0x7777),
            control: address(0x8888),
            userOpHash: bytes32(0),
            bidToken: address(0),
            bidAmount: 0.2 ether,
            data: hex"02",
            signature: hex""
        });
        
        bytes32 hash1 = CallVerification.getCallChainHash(userOp, solverOps);
        
        // Swap the order
        SolverOperation memory temp = solverOps[0];
        solverOps[0] = solverOps[1];
        solverOps[1] = temp;
        
        bytes32 hash2 = CallVerification.getCallChainHash(userOp, solverOps);
        
        assertNotEq(hash1, hash2, "Hash should be different when solver ops order changes");
    }

    function testFuzz_getCallChainHash(
        address userFrom,
        address userTo,
        uint256 userValue,
        bytes calldata userData,
        uint8 solverCount
    ) public view {
        // Bound solver count to reasonable range
        solverCount = uint8(bound(solverCount, 0, 10));
        
        UserOperation memory userOp = UserOperation({
            from: userFrom,
            to: userTo,
            value: userValue,
            gas: 200000,
            maxFeePerGas: 20 gwei,
            nonce: 1,
            deadline: 1000,
            dapp: address(0x1234),
            control: address(0x5678),
            callConfig: 0,
            dappGasLimit: 100000,
            solverGasLimit: 200000,
            bundlerSurchargeRate: 100,
            sessionKey: address(0),
            data: userData,
            signature: hex""
        });
        
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        
        SolverOperation[] memory solverOps = new SolverOperation[](solverCount);
        for (uint i = 0; i < solverCount; i++) {
            solverOps[i] = SolverOperation({
                from: address(uint160(uint256(keccak256(abi.encode("solver", i))))),
                to: address(uint160(uint256(keccak256(abi.encode("solverTo", i))))),
                value: i * 1 ether,
                gas: 50000 + i * 10000,
                maxFeePerGas: 10 gwei + i * 1 gwei,
                deadline: 1000 + i * 3600,
                solver: address(uint160(uint256(keccak256(abi.encode("solverAddr", i))))),
                control: address(0x5678),
                userOpHash: userOpHash,
                bidToken: address(0),
                bidAmount: i * 0.01 ether,
                data: abi.encode("solver", i),
                signature: abi.encode("sig", i)
            });
        }
        
        bytes32 hash1 = CallVerification.getCallChainHash(userOp, solverOps);
        bytes32 hash2 = CallVerification.getCallChainHash(userOp, solverOps);
        
        // Hash should be deterministic
        assertEq(hash1, hash2, "Hash should be deterministic for same inputs");
        
        // Verify hash calculation matches expected
        bytes memory callSequence = abi.encodePacked(
            abi.encode(userOp),
            abi.encode(solverOps)
        );
        bytes32 expectedHash = keccak256(callSequence);
        assertEq(hash1, expectedHash, "Hash should match manual calculation");
    }

    function test_getCallChainHash_gasEfficiency() public {
        UserOperation memory userOp = UserOperation({
            from: address(0x1111),
            to: address(0x2222),
            value: 1 ether,
            gas: 200000,
            maxFeePerGas: 20 gwei,
            nonce: 1,
            deadline: 1000,
            dapp: address(0x3333),
            control: address(0x4444),
            callConfig: 0,
            dappGasLimit: 100000,
            solverGasLimit: 200000,
            bundlerSurchargeRate: 100,
            sessionKey: address(0),
            data: hex"deadbeef",
            signature: hex""
        });
        
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        
        // Test with various solver operation counts
        for (uint i = 0; i <= 5; i++) {
            SolverOperation[] memory solverOps = new SolverOperation[](i);
            
            for (uint j = 0; j < i; j++) {
                solverOps[j] = SolverOperation({
                    from: address(uint160(j + 1)),
                    to: address(uint160(j + 1000)),
                    value: j * 1 ether,
                    gas: 50000,
                    maxFeePerGas: 10 gwei,
                    deadline: 1000,
                    solver: address(uint160(j + 2000)),
                    control: address(0x5555),
                    userOpHash: userOpHash,
                    bidToken: address(0),
                    bidAmount: j * 0.1 ether,
                    data: abi.encode(j),
                    signature: hex""
                });
            }
            
            uint256 gasBefore = gasleft();
            bytes32 hash = CallVerification.getCallChainHash(userOp, solverOps);
            uint256 gasUsed = gasBefore - gasleft();
            
            // Just verify we get a hash - gas measurement is informational
            assertTrue(hash != bytes32(0), "Should produce non-zero hash");
        }
    }

    function test_getCallChainHash_edgeCases() public pure {
        // Test with maximum size data
        UserOperation memory userOp = UserOperation({
            from: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            to: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            value: type(uint256).max,
            gas: type(uint32).max,
            maxFeePerGas: type(uint256).max,
            nonce: type(uint256).max,
            deadline: type(uint256).max,
            dapp: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            control: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            callConfig: type(uint32).max,
            dappGasLimit: type(uint32).max,
            solverGasLimit: type(uint32).max,
            bundlerSurchargeRate: type(uint24).max,
            sessionKey: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            data: hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            signature: hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        });
        
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = SolverOperation({
            from: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            to: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            value: type(uint256).max,
            gas: type(uint32).max,
            maxFeePerGas: type(uint256).max,
            deadline: type(uint256).max,
            solver: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            control: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            userOpHash: bytes32(type(uint256).max),
            bidToken: address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF),
            bidAmount: type(uint256).max,
            data: hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            signature: hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        });
        
        bytes32 hash = CallVerification.getCallChainHash(userOp, solverOps);
        assertTrue(hash != bytes32(0), "Should handle maximum values");
        
        // Test with all zero addresses and values
        UserOperation memory zeroUserOp;
        SolverOperation[] memory zeroSolverOps = new SolverOperation[](1);
        
        bytes32 zeroHash = CallVerification.getCallChainHash(zeroUserOp, zeroSolverOps);
        assertTrue(zeroHash != bytes32(0), "Should handle zero values");
        assertNotEq(hash, zeroHash, "Max and zero hashes should differ");
    }
}