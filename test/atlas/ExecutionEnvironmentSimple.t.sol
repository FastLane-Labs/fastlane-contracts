// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { AtlasBaseTest } from "./base/AtlasBaseTest.t.sol";

import { ExecutionEnvironment } from "../../src/atlas/common/ExecutionEnvironment.sol";
import { DAppControl } from "../../src/atlas/dapp/DAppControl.sol";
import { IAtlas } from "../../src/atlas/interfaces/IAtlas.sol";
import { CallBits } from "../../src/atlas/libraries/CallBits.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtlasErrors } from "../../src/atlas/types/AtlasErrors.sol";

import "../../src/atlas/types/ConfigTypes.sol";
import "../../src/atlas/types/UserOperation.sol";
import "../../src/atlas/types/SolverOperation.sol";

/// @notice Simplified ExecutionEnvironment tests that work with the Mimic proxy
contract ExecutionEnvironmentSimpleTest is AtlasBaseTest {
    using CallBits for uint32;

    ExecutionEnvironment public executionEnvironment;
    MockDAppControl public dAppControl;

    address public testUser = makeAddr("testUser");
    
    // Test token - WMON (Wrapped MON) on Monad
    address public constant WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
    IERC20 public constant WMON = IERC20(WMON_ADDRESS);

    CallConfig private callConfig;

    function setUp() public override {
        super.setUp();
        
        // Default setting for tests is all callConfig flags set to false.
        setupDAppControl(callConfig);
    }

    function setupDAppControl(CallConfig memory customCallConfig) internal {
        vm.startPrank(governanceEOA);
        dAppControl = new MockDAppControl(address(atlas), governanceEOA, customCallConfig);
        atlasVerification.initializeGovernance(address(dAppControl));
        vm.stopPrank();

        vm.prank(testUser);
        executionEnvironment =
            ExecutionEnvironment(payable(IAtlas(address(atlas)).createExecutionEnvironment(testUser, address(dAppControl))));
    }

    // Test view functions that should work through the Mimic proxy
    function test_getUser() public {
        assertEq(executionEnvironment.getUser(), testUser);
    }

    function test_getControl() public {
        assertEq(executionEnvironment.getControl(), address(dAppControl));
    }

    function test_getConfig() public {
        assertEq(executionEnvironment.getConfig(), CallBits.encodeCallConfig(callConfig));
    }

    function test_getEscrow() public {
        assertEq(executionEnvironment.getEscrow(), address(atlas));
    }

    // Test withdraw functions
    function test_withdrawERC20() public {
        // Give EE some WETH
        deal(WMON_ADDRESS, address(executionEnvironment), 2e18);
        assertEq(WMON.balanceOf(address(executionEnvironment)), 2e18);
        assertEq(WMON.balanceOf(testUser), 0);
        
        // Withdraw as the user
        vm.prank(testUser);
        executionEnvironment.withdrawERC20(WMON_ADDRESS, 2e18);
        
        assertEq(WMON.balanceOf(address(executionEnvironment)), 0);
        assertEq(WMON.balanceOf(testUser), 2e18);
    }

    function test_withdrawERC20_NotOwner() public {
        deal(WMON_ADDRESS, address(executionEnvironment), 2e18);
        
        vm.prank(address(0xBEEF)); // Different user
        vm.expectRevert(AtlasErrors.NotEnvironmentOwner.selector);
        executionEnvironment.withdrawERC20(WMON_ADDRESS, 2e18);
    }

    function test_withdrawERC20_InsufficientBalance() public {
        vm.prank(testUser);
        vm.expectRevert(AtlasErrors.ExecutionEnvironmentBalanceTooLow.selector);
        executionEnvironment.withdrawERC20(WMON_ADDRESS, 1e18);
    }

    function test_withdrawEther() public {
        // Give EE some ETH
        deal(address(executionEnvironment), 2e18);
        assertEq(address(executionEnvironment).balance, 2e18);
        uint256 initialUserBalance = testUser.balance;
        
        // Withdraw as the user
        vm.prank(testUser);
        executionEnvironment.withdrawEther(2e18);
        
        assertEq(address(executionEnvironment).balance, 0);
        assertEq(testUser.balance, initialUserBalance + 2e18);
    }

    function test_withdrawEther_NotOwner() public {
        deal(address(executionEnvironment), 2e18);
        
        vm.prank(address(0xBEEF)); // Different user
        vm.expectRevert(AtlasErrors.NotEnvironmentOwner.selector);
        executionEnvironment.withdrawEther(2e18);
    }

    function test_withdrawEther_InsufficientBalance() public {
        vm.prank(testUser);
        vm.expectRevert(AtlasErrors.ExecutionEnvironmentBalanceTooLow.selector);
        executionEnvironment.withdrawEther(1e18);
    }
}

contract MockDAppControl is DAppControl {
    constructor(
        address _atlas,
        address _governance,
        CallConfig memory _callConfig
    )
        DAppControl(_atlas, _governance, _callConfig)
    { }

    function _checkUserOperation(UserOperation memory) internal pure override { }

    function _preOpsCall(UserOperation calldata) internal override returns (bytes memory) {
        return "";
    }

    function _preSolverCall(SolverOperation calldata, bytes calldata) internal pure override { }

    function _postSolverCall(SolverOperation calldata, bytes calldata) internal pure override { }

    function _allocateValueCall(bool, address, uint256, bytes calldata) internal virtual override { }

    function getBidFormat(UserOperation calldata) public view virtual override returns (address) { }
    
    function getBidValue(SolverOperation calldata) public view virtual override returns (uint256) { }
}