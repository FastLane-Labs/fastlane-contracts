// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TaskFactory } from "src/task-manager/core/Factory.sol";
import { TaskExecutionEnvironment } from "src/task-manager/common/ExecutionEnvironment.sol";

contract TaskFactoryTest is TaskFactory, Test {
    address public owner;
    address public taskManager;
    address public defaultImplementation;

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        taskManager = makeAddr("taskManager");
        vm.deal(owner, 100 ether);

        // Deploy factory
        vm.prank(taskManager);
        defaultImplementation = this.EXECUTION_ENV_TEMPLATE();
    }

    function testGetEnvironmentAddress() public {
        bytes memory taskData = abi.encode("test data");

        // Get environment address with default implementation
        address env1 = _createEnvironment(owner, 1, address(0), taskData);
        assertTrue(env1 != address(0), "Environment address should not be zero");

        // Get environment address with custom implementation
        address customImpl = makeAddr("customImpl");
        address env2 = _createEnvironment(owner, 1, customImpl, taskData);
        assertTrue(env2 != address(0), "Environment address should not be zero");
        assertTrue(env1 != env2, "Different implementations should yield different addresses");

        address env3 = _createEnvironment(owner, 2, address(0), taskData);
        assertTrue(env3 != env1, "Different nonces should yield different addresses");
    }

    function test_CreateEnvironment() public {
        bytes memory taskData = abi.encode("test data");
        uint256 taskNonce = 100;

        // Create environment first to get the actual address
        address env = _createEnvironment(owner, taskNonce, address(0), taskData);
        assertTrue(env.code.length > 0, "Environment should have code");

        // Get the expected environment address
        address expectedEnv = _createEnvironment(owner, taskNonce, address(0), taskData);
        assertEq(env, expectedEnv, "Environment address mismatch");

        vm.stopPrank();
    }

    function test_CreateEnvironment_sameData() public {
        bytes memory taskData = abi.encode("test data");
        uint256 taskNonce = 100;

        // Get the expected environment address
        address expectedEnv = _createEnvironment(owner, taskNonce, address(0), taskData);

        // First call should create the environment
        address env = _createEnvironment(owner, taskNonce, address(0), taskData);
        assertTrue(env.code.length > 0, "Environment should have code");
        assertEq(env, expectedEnv, "Environment address mismatch");

        // Second call should return the same environment without creating it
        address env2 = _createEnvironment(owner, taskNonce, address(0), taskData);
        assertEq(env2, env, "Should return same environment");

        vm.stopPrank();
    }

    // function test_RevertIf_NotTaskManager() public {
    //     bytes memory taskData = abi.encode("test data");
        
    //     vm.expectRevert("Factory: only task manager");
    //     this.getOrCreateEnvironment(owner, 1, address(0), taskData);
    // }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_RevertIf_ZeroOwner() public {
        bytes memory taskData = abi.encode("test data");
        
        vm.prank(taskManager);
        vm.expectRevert("Factory: zero owner");
        _createEnvironment(address(0), 1, address(0), taskData);

    }

    function test_DifferentTaskNonces() public {
        bytes memory taskData = abi.encode("test data");
        
        vm.startPrank(taskManager);

        // Create environments with different nonces
        address env1 = _createEnvironment(owner, 1, address(0), taskData);
        address env2 = _createEnvironment(owner, 2, address(0), taskData);
        address env3 = _createEnvironment(owner, 3, address(0), taskData);

        assertTrue(env1 != env2 && env2 != env3 && env1 != env3, "All environments should be unique");
        assertTrue(env1.code.length > 0 && env2.code.length > 0 && env3.code.length > 0, "All environments should have code");

        vm.stopPrank();
    }
} 