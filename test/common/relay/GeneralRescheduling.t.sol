// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { DummyApp } from "./DummyApp.sol";
import { BaseTest } from "test/base/BaseTest.t.sol";
import { ITaskManager } from "../../../src/task-manager/interfaces/ITaskManager.sol";

event MethodCalled(address caller, string method, uint256 value);
event CallbackScheduled();

contract GeneralReschedulingTest is BaseTest {
    DummyApp public dummyApp;
    ITaskManager public currentTaskManager;
    address public owner;
    address public sessionKey;
    address public executor;
    
    uint256 constant MAX_EXPECTED_GAS_USAGE_PER_TX = 200_000;
    
    event GasReimbursed(address indexed sessionKey, uint256 sharesNeeded, uint256 sharesEarned);
    
    function setUp() public override {
        super.setUp();
        
        owner = makeAddr("owner");
        sessionKey = makeAddr("sessionKey");
        executor = makeAddr("executor");
      
        // Deploy DummyGasRelay with real contracts
        dummyApp = new DummyApp();
        currentTaskManager = ITaskManager(address(addressHub.taskManager()));

        // Give ETH to owner for testing
        vm.deal(owner, 10 ether);
        vm.deal(sessionKey, 1 ether);
        vm.deal(executor, 10 ether);
    }
    
    function testTaskImplementationWithReschedule() public {
        vm.prank(owner);
        dummyApp.updateSessionKey{value: 2 ether}(sessionKey, block.number + 100);
        
        uint256 value = 123;

        vm.prank(sessionKey);
        vm.expectEmit(true, true, true, true);
        emit MethodCalled(owner, "begin", value);
        dummyApp.begin(value, true);

        vm.roll(block.number + 16);
        vm.prank(executor);
        vm.expectEmit(true, true, true, true);
        emit MethodCalled(owner, "followUp", value);
        currentTaskManager.executeTasks(executor, 0);

        vm.roll(block.number + 24);
        vm.prank(executor);
        vm.expectEmit(true, true, true, true);
        emit MethodCalled(owner, "followUp", value);
        currentTaskManager.executeTasks(executor, 0);
    }
} 