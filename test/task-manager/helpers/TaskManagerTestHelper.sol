//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "../../base/BaseTest.t.sol";
import { Task, Size } from "../../../src/task-manager/types/TaskTypes.sol";
import { ITaskExecutionEnvironment } from "../../../src/task-manager/interfaces/IExecutionEnvironment.sol";
import { TaskExecutionEnvironment } from "../../../src/task-manager/common/ExecutionEnvironment.sol";
import { ShMonad } from "../../../src/shmonad/ShMonad.sol";
import { AddressHub } from "../../../src/common/AddressHub.sol";

contract MockTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }
}

contract TaskManagerTestHelper is BaseTest {
    /// @notice Gas limits for different queue categories
    uint64 public constant SMALL_GAS = 100_000;
    uint64 public constant MEDIUM_GAS = 300_000;
    uint64 public constant LARGE_GAS = 750_000;
    uint64 public constant _BLOCK_GROUP_SIZE = 4;

    // Contracts
    MockTarget public target;
    TaskExecutionEnvironment public executionEnvironment;

    // Test accounts
    address public owner;
    address public payout;

    // Task data setup
    bytes internal defaultCalldata;
    Task internal defaultTask;

    function setUp() public virtual override {
        // Call parent setUp first to initialize all contracts
        super.setUp();

        // Setup test accounts
        owner = makeAddr("taskOwner");
        payout = makeAddr("taskPayout");

        // Deploy MockTarget and ExecutionEnvironment
        target = new MockTarget();
        executionEnvironment = new TaskExecutionEnvironment(address(taskManager));

        // Layer 1: Encode the actual function call
        bytes memory targetCalldata = abi.encodeCall(MockTarget.setValue, (42));

        // Layer 2: Pack target and calldata
        bytes memory packedData = abi.encode(address(target), targetCalldata);

        // Layer 3: Encode the executeTask call
        defaultCalldata = abi.encodeWithSelector(ITaskExecutionEnvironment.executeTask.selector, packedData);

        defaultTask = Task({
            from: owner, // Use our test owner instead of deployer
            nonce: 1,
            size: Size.Small,
            implementation: address(executionEnvironment),
            cancelled: false,
            data: defaultCalldata
        });
    }

    function _bondWithTaskManager(address account, uint256 amount) internal {
        vm.startPrank(account);
        // First deposit ETH to get shMONAD tokens
        uint256 shares = shMonad.deposit{ value: amount }(amount, account);
        // Then bond to the task manager's policy ID
        uint64 policyID = taskManager.POLICY_ID();
        shMonad.bond(policyID, account, shares);
        vm.stopPrank();
    }

    function _depositAndApprove(address account, uint256 amount) internal {
        vm.startPrank(account);
        // First deposit ETH to get shMONAD tokens
        uint256 shares = shMonad.deposit{ value: amount }(amount, account);
        // Approve TaskManager to spend shMONAD
        shMonad.approve(address(taskManager), shares);
        vm.stopPrank();
    }

    function _createTask(address _from, uint64 _nonce, Size _size) internal view returns (Task memory) {
        return Task({
            from: _from,
            nonce: _nonce,
            size: _size,
            implementation: address(executionEnvironment),
            cancelled: false,
            data: defaultCalldata
        });
    }

    // Helper function to schedule a task with direct ETH payment required prior prank
    function _scheduleTask(address from, uint64 nonce, Size size, uint64 targetBlock) internal returns (bytes32) {
        Task memory task = _createTask(from, nonce, size);

        // Get the cost estimate
        uint256 estimatedCost = taskManager.estimateCost(targetBlock, _maxGasFromSize(task.size));

        assertGt(estimatedCost, 0, "Estimated cost should be greater than 0");

        // Call with the appropriate ETH value
        (bool scheduled, uint256 executionCost, bytes32 taskId) = taskManager.scheduleTask{ value: estimatedCost }(
            task.implementation, _maxGasFromSize(task.size), targetBlock, type(uint256).max / 2, task.data
        );
        assertEq(scheduled, true, "Task should be scheduled");
        assertEq(executionCost, estimatedCost, "Execution cost should match estimated cost");
        return taskId;
    }

    // Alternative helper that uses scheduleWithBond instead of direct ETH payment
    function _scheduleTaskWithBond(
        address from,
        uint64 nonce,
        Size size,
        uint64 targetBlock
    )
        internal
        returns (bytes32)
    {
        Task memory task = _createTask(from, nonce, size);
        // Not using vm.prank here since the caller might be using vm.startPrank
        (bool scheduled, uint256 executionCost, bytes32 taskId) = taskManager.scheduleWithBond(
            task.implementation, _maxGasFromSize(task.size), targetBlock, type(uint256).max / 2, task.data
        );
        assertEq(scheduled, true, "Task should be scheduled");
        assertGt(executionCost, 0, "Execution cost should be greater than 0");
        return taskId;
    }

    function _scheduleTaskWithQuote(
        address from,
        uint64 nonce,
        Size size,
        uint64 targetBlock,
        uint256 maxPayment
    )
        internal
        returns (bool scheduled, uint256 executionCost, bytes32 taskHash)
    {
        Task memory task = _createTask(from, nonce, size);

        // Get the cost estimate
        executionCost = taskManager.estimateCost(targetBlock, _maxGasFromSize(task.size));

        // Call with the appropriate ETH value
        vm.prank(from);
        return taskManager.scheduleTask{ value: executionCost }(
            task.implementation, _maxGasFromSize(task.size), targetBlock, maxPayment, task.data
        );
    }

    function _maxGasFromSize(Size size) internal pure returns (uint256 maxGas) {
        if (size == Size.Medium) {
            return MEDIUM_GAS;
        } else if (size == Size.Small) {
            return SMALL_GAS;
        }
        return LARGE_GAS;
    }
}
