// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TaskFactory } from "src/task-manager/core/Factory.sol";
import { ITaskExecutionEnvironment } from "src/task-manager/interfaces/IExecutionEnvironment.sol";

/**
 * @title TaskExecutionEnvironment Tests
 * @notice Test suite for the TaskExecutionEnvironment contract
 * @dev Tests use a 3-layer encoding pattern:
 *      1. Encode the actual function call (e.g., setValue(42))
 *      2. Pack target and calldata together
 *      3. Encode the executeTask call with the packed data
 *      The resulting taskData is embedded in the mimic contract's code
 */

contract MockTarget {
    uint256 public value;
    uint256 public gasUsed;
    
    function setValue(uint256 newValue) external returns (uint256) {
        value = newValue;
        gasUsed = gasleft();
        return newValue;
    }
    
    function revertWithMessage() external pure {
        revert("MockTarget: expected revert");
    }

    function useGas(uint256 iterations) external {
        uint256 initialGas = gasleft();
        uint256 sum;
        for(uint256 i; i < iterations; i++) {
            sum += i;
        }
        gasUsed = initialGas - gasleft();
        value = sum;
    }
}

contract TaskExecutionEnvironmentTest is TaskFactory, Test {
    MockTarget public target;
    address public owner;
    address public taskManager;

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        taskManager = makeAddr("taskManager");
        
        // Deploy contracts
        target = new MockTarget();

        // Fund owner
        vm.deal(owner, 100 ether);

    }

    function test_ExecuteTask() public {
        // Layer 1: Encode the actual function call
        bytes memory targetCalldata = abi.encodeCall(MockTarget.setValue, (42));
        
        // Layer 2: Pack target and calldata
        bytes memory packedData = abi.encode(address(target), targetCalldata);
        
        // Layer 3: Encode the executeTask call
        bytes memory taskData = abi.encodeWithSelector(ITaskExecutionEnvironment.executeTask.selector, packedData);
        
        address env = _createEnvironment(owner, 1, address(0), taskData);
        
        // Execute task
        (bool success,) = env.call("a");

        assertTrue(success, "Task execution failed");
        assertEq(target.value(), 42, "Target state not updated");
    }

    function test_ExecuteTask_Revert() public {
        // Layer 1: Encode the actual function call
        bytes memory targetCalldata = abi.encodeCall(MockTarget.revertWithMessage, ());
        
        // Layer 2: Pack target and calldata
        bytes memory packedData = abi.encode(address(target), targetCalldata);
        
        // Layer 3: Encode the executeTask call
        bytes memory taskData = abi.encodeWithSelector(ITaskExecutionEnvironment.executeTask.selector, packedData);
        
        address env = _createEnvironment(owner, 2, address(0), taskData);

        (bool success,) = env.call("a");

        // The mimic call succeeds but returns false
        assertTrue(success, "Mimic call failed");
        
        // Check that the target state didn't change
        assertEq(target.value(), 0, "Target state should not have changed");
    }

    function test_RevertIf_NotTaskManager() public {
        // Layer 1: Encode the actual function call
        bytes memory targetCalldata = abi.encodeCall(MockTarget.setValue, (42));
        
        // Layer 2: Pack target and calldata
        bytes memory packedData = abi.encode(address(target), targetCalldata);
        
        // Create environment
        address env = _createEnvironment(
            owner,
            1,
            address(0), // Use default implementation
            packedData
        );

        vm.prank(makeAddr("attacker"));
        (bool success,) = env.call("a");
        assertTrue(!success, "Task execution should have failed");
    }

    function test_GasUsage() public {
        // Layer 1: Encode the actual function call
        bytes memory targetCalldata = abi.encodeCall(MockTarget.useGas, (1000));
        
        // Layer 2: Pack target and calldata
        bytes memory packedData = abi.encode(address(target), targetCalldata);
        
        // Layer 3: Encode the executeTask call
        bytes memory taskData = abi.encodeWithSelector(ITaskExecutionEnvironment.executeTask.selector, packedData);
        
        // Create environment
        address env = _createEnvironment(owner, 4, address(0), taskData);
        
        // Execute task
        (bool success,) = env.call("a");

        assertTrue(success, "Task execution failed");
        assertTrue(target.gasUsed() > 0, "Target didn't use gas");
    }
} 