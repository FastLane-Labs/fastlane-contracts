// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { AtlasBaseTest } from "./base/AtlasBaseTest.t.sol";
import { TestAtlas } from "./helpers/TestAtlas.sol";

import { ExecutionEnvironment } from "../../src/atlas/common/ExecutionEnvironment.sol";
import { DAppControl } from "../../src/atlas/dapp/DAppControl.sol";
import { IAtlas } from "../../src/atlas/interfaces/IAtlas.sol";
import { SafetyBits } from "../../src/atlas/libraries/SafetyBits.sol";
import { CallBits } from "../../src/atlas/libraries/CallBits.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AtlasErrors } from "../../src/atlas/types/AtlasErrors.sol";

import "../../src/atlas/types/ConfigTypes.sol";
import "../../src/atlas/types/UserOperation.sol";
import "../../src/atlas/types/SolverOperation.sol";
import "../../src/atlas/types/LockTypes.sol";
import "../../src/atlas/types/EscrowTypes.sol";

/// @notice ExecutionEnvironmentTest tests deploy ExecutionEnvironment contracts through the factory. Because all calls
/// are delegated through the mimic contract, the reported coverage is at 0%, but the actual coverage is close to 100%.
contract ExecutionEnvironmentTest is AtlasBaseTest {
    using stdStorage for StdStorage;
    using SafetyBits for Context;
    using CallBits for uint32;

    ExecutionEnvironment public executionEnvironment;
    MockDAppControl public dAppControl;

    Context public ctx;

    address public testUser = makeAddr("testUser");
    address public testSolver = makeAddr("testSolver");
    address public invalid = makeAddr("invalid");

    // Test token - WMON (Wrapped MON) on Monad
    address public constant WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
    IERC20 public WMON = IERC20(WMON_ADDRESS);

    CallConfig private callConfig;

    function setUp() public override {
        super.setUp();


        // Default setting for tests is all callConfig flags set to false.
        // For custom scenarios, set the needed flags and call setupDAppControl.
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

    function test_modifier_validUser_SkipCoverage() public {
        UserOperation memory userOp;
        bytes memory preOpsData;
        bool status;

        TestAtlas(payable(address(atlas))).setLockPhase(ExecutionPhase.PreOps);

        // Valid
        userOp.from = testUser;
        userOp.to = address(atlas);
        preOpsData = abi.encodeWithSelector(executionEnvironment.preOpsWrapper.selector, userOp);
        preOpsData = abi.encodePacked(preOpsData, ctx.setAndPack(ExecutionPhase.PreOps));
        vm.prank(address(atlas));
        (status,) = address(executionEnvironment).call(preOpsData);
        assertTrue(status);

        // InvalidTo
        userOp.from = testUser;
        userOp.to = invalid; // Invalid to
        preOpsData = abi.encodeWithSelector(executionEnvironment.preOpsWrapper.selector, userOp);
        preOpsData = abi.encodePacked(preOpsData, ctx.setAndPack(ExecutionPhase.PreOps));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.InvalidTo.selector);
        address(executionEnvironment).call(preOpsData);
    }

    function test_modifier_onlyAtlasEnvironment_SkipCoverage() public {
        UserOperation memory userOp;
        bytes memory preOpsData;
        bool status;

        userOp.from = testUser;
        userOp.to = address(atlas);

        TestAtlas(payable(address(atlas))).setLockPhase(ExecutionPhase.PreOps);

        // Valid
        preOpsData = abi.encodeWithSelector(executionEnvironment.preOpsWrapper.selector, userOp);
        preOpsData = abi.encodePacked(preOpsData, ctx.setAndPack(ExecutionPhase.PreOps));
        vm.prank(address(atlas));
        (status,) = address(executionEnvironment).call(preOpsData);
        assertTrue(status);

        // InvalidSender
        preOpsData = abi.encodeWithSelector(executionEnvironment.preOpsWrapper.selector, userOp);
        preOpsData = abi.encodePacked(preOpsData, ctx.setAndPack(ExecutionPhase.PreOps));
        vm.prank(address(0)); // Invalid sender
        vm.expectRevert(AtlasErrors.OnlyAtlas.selector);
        address(executionEnvironment).call(preOpsData);
    }

    function test_modifier_validControlHash_SkipCoverage() public {
        UserOperation memory userOp;
        bytes memory userData;
        bool status;

        userOp.from = testUser;
        userOp.to = address(atlas);

        // Valid
        userData = abi.encodeWithSelector(executionEnvironment.userWrapper.selector, userOp);
        userData = abi.encodePacked(userData, ctx.setAndPack(ExecutionPhase.UserOperation));
        vm.prank(address(atlas));
        (status,) = address(executionEnvironment).call(userData);
        assertTrue(status);
    }

    function test_preOpsWrapper_SkipCoverage() public {
        UserOperation memory userOp;
        bytes memory preOpsData;
        bool status;
        bytes memory data;

        userOp.from = testUser;
        userOp.to = address(atlas);
        userOp.dapp = address(dAppControl);

        TestAtlas(payable(address(atlas))).setLockPhase(ExecutionPhase.PreOps);

        // Valid
        uint256 expectedReturnValue = 123;
        userOp.data = abi.encodeWithSelector(dAppControl.mockOperation.selector, false, expectedReturnValue);
        preOpsData = abi.encodeWithSelector(executionEnvironment.preOpsWrapper.selector, userOp);
        preOpsData = abi.encodePacked(preOpsData, ctx.setAndPack(ExecutionPhase.PreOps));
        vm.prank(address(atlas));
        (status, data) = address(executionEnvironment).call(preOpsData);
        assertTrue(status);
        assertEq(abi.decode(abi.decode(data, (bytes)), (uint256)), expectedReturnValue);

        // DelegateRevert
        userOp.data = abi.encodeWithSelector(dAppControl.mockOperation.selector, true, uint256(0));
        preOpsData = abi.encodeWithSelector(executionEnvironment.preOpsWrapper.selector, userOp);
        preOpsData = abi.encodePacked(preOpsData, ctx.setAndPack(ExecutionPhase.PreOps));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.PreOpsDelegatecallFail.selector);
        address(executionEnvironment).call(preOpsData);
    }

    function test_userWrapper_SkipCoverage() public {
        UserOperation memory userOp;
        bytes memory userData;
        bool status;
        bytes memory data;
        uint256 expectedReturnValue;

        userOp.from = testUser;
        userOp.to = address(atlas);
        userOp.dapp = address(dAppControl);

        // ValueExceedsBalance
        userOp.value = 1; // Positive value but EE has no balance
        userData = abi.encodeWithSelector(executionEnvironment.userWrapper.selector, userOp);
        userData = abi.encodePacked(userData, ctx.setAndPack(ExecutionPhase.UserOperation));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.UserOpValueExceedsBalance.selector);
        (status,) = address(executionEnvironment).call(userData);
        userOp.value = 0;

        // Valid (needsDelegateUser=false)
        expectedReturnValue = 987;
        userOp.data = abi.encodeWithSelector(dAppControl.mockOperation.selector, false, expectedReturnValue);
        userData = abi.encodeWithSelector(executionEnvironment.userWrapper.selector, userOp);
        userData = abi.encodePacked(userData, ctx.setAndPack(ExecutionPhase.UserOperation));
        vm.prank(address(atlas));
        (status, data) = address(executionEnvironment).call(userData);
        assertTrue(status);
        assertEq(abi.decode(abi.decode(data, (bytes)), (uint256)), expectedReturnValue);

        // CallRevert (needsDelegateUser=false)
        userOp.data = abi.encodeWithSelector(dAppControl.mockOperation.selector, true, 0);
        userData = abi.encodeWithSelector(executionEnvironment.userWrapper.selector, userOp);
        userData = abi.encodePacked(userData, ctx.setAndPack(ExecutionPhase.UserOperation));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.UserWrapperCallFail.selector);
        (status,) = address(executionEnvironment).call(userData);

        // Change of config
        callConfig.delegateUser = true;
        setupDAppControl(callConfig);
        userOp.dapp = address(dAppControl);

        // Valid (needsDelegateUser=true)
        expectedReturnValue = 277;
        userOp.data = abi.encodeWithSelector(dAppControl.mockOperation.selector, false, expectedReturnValue);
        userData = abi.encodeWithSelector(executionEnvironment.userWrapper.selector, userOp);
        userData = abi.encodePacked(userData, ctx.setAndPack(ExecutionPhase.UserOperation));
        vm.prank(address(atlas));
        (status, data) = address(executionEnvironment).call(userData);
        assertTrue(status);
        assertEq(abi.decode(abi.decode(data, (bytes)), (uint256)), expectedReturnValue);

        // DelegateRevert (needsDelegateUser=true)
        userOp.data = abi.encodeWithSelector(dAppControl.mockOperation.selector, true, 0);
        userData = abi.encodeWithSelector(executionEnvironment.userWrapper.selector, userOp);
        userData = abi.encodePacked(userData, ctx.setAndPack(ExecutionPhase.UserOperation));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.UserWrapperDelegatecallFail.selector);
        (status,) = address(executionEnvironment).call(userData);
    }

    function test_solverPreTryCatch_SkipCoverage() public {
        bytes memory preTryCatchMetaData;
        bool revertsAsExpected;

        vm.prank(testSolver);
        MockSolverContract solverContract = new MockSolverContract(WMON_ADDRESS, address(atlas));

        SolverOperation memory solverOp;
        solverOp.from = testSolver;
        solverOp.control = address(dAppControl);
        solverOp.solver = address(solverContract);

        // Valid
        preTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPreTryCatch.selector, solverOp.bidAmount, solverOp, new bytes(0)
        );
        preTryCatchMetaData = abi.encodePacked(preTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PreSolver));
        vm.prank(address(atlas));
        (bool status,) = address(executionEnvironment).call(preTryCatchMetaData);
        assertTrue(status, "solverPreTryCatch failed");

        // InvalidSolver
        solverOp.solver = address(executionEnvironment); // Invalid solver
        preTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPreTryCatch.selector, solverOp.bidAmount, solverOp, new bytes(0)
        );
        preTryCatchMetaData = abi.encodePacked(preTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PreSolver));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.InvalidSolver.selector);
        (revertsAsExpected,) = address(executionEnvironment).call(preTryCatchMetaData);

        // AlteredControl
        solverOp.solver = address(solverContract);
        solverOp.control = invalid; // Invalid control
        preTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPreTryCatch.selector, solverOp.bidAmount, solverOp, new bytes(0)
        );
        preTryCatchMetaData = abi.encodePacked(preTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PreSolver));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.AlteredControl.selector);
        (revertsAsExpected,) = address(executionEnvironment).call(preTryCatchMetaData);

        // Change of config
        callConfig.requirePreSolver = true;
        setupDAppControl(callConfig);
        solverOp.control = address(dAppControl);

        // PreSolverFailed
        bytes memory returnData = abi.encode(true, true);
        preTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPreTryCatch.selector, solverOp.bidAmount, solverOp, returnData
        );
        preTryCatchMetaData = abi.encodePacked(preTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PreSolver));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.PreSolverFailed.selector);
        (revertsAsExpected,) = address(executionEnvironment).call(preTryCatchMetaData);
    }

    function test_solverPostTryCatch_SkipCoverage() public {
        bytes memory postTryCatchMetaData;
        bool revertsAsExpected;

        vm.prank(testSolver);
        MockSolverContract solverContract = new MockSolverContract(WMON_ADDRESS, address(atlas));

        SolverTracker memory solverTracker;
        solverTracker.etherIsBidToken = true;

        SolverOperation memory solverOp;
        solverOp.from = testSolver;
        solverOp.control = address(dAppControl);
        solverOp.solver = address(solverContract);

        // Valid
        postTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPostTryCatch.selector, solverOp, new bytes(0), solverTracker
        );
        postTryCatchMetaData = abi.encodePacked(postTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PostSolver));
        vm.prank(address(atlas));
        (bool status,) = address(executionEnvironment).call(postTryCatchMetaData);
        assertTrue(status, "solverPostTryCatch failed");

        // BidNotPaid (floor > ceiling)
        solverTracker.floor = 1;
        postTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPostTryCatch.selector, solverOp, new bytes(0), solverTracker
        );
        postTryCatchMetaData = abi.encodePacked(postTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PreSolver));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.BidNotPaid.selector);
        (revertsAsExpected,) = address(executionEnvironment).call(postTryCatchMetaData);

        // BidNotPaid (!invertsBidValue && netBid < bidAmount)
        solverTracker.floor = 0;
        solverTracker.bidAmount = 1;
        postTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPostTryCatch.selector, solverOp, new bytes(0), solverTracker
        );
        postTryCatchMetaData = abi.encodePacked(postTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PreSolver));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.BidNotPaid.selector);
        (revertsAsExpected,) = address(executionEnvironment).call(postTryCatchMetaData);

        // BidNotPaid (invertsBidValue && netBid > bidAmount)
        solverTracker.invertsBidValue = true;
        solverTracker.bidAmount = 0;
        solverTracker.ceiling = 1;
        postTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPostTryCatch.selector, solverOp, new bytes(0), solverTracker
        );
        postTryCatchMetaData = abi.encodePacked(postTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PreSolver));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.BidNotPaid.selector);
        (revertsAsExpected,) = address(executionEnvironment).call(postTryCatchMetaData);

        // Change of config
        callConfig.requirePostSolver = true;
        setupDAppControl(callConfig);
        solverOp.control = address(dAppControl);

        // PostSolverFailed
        bytes memory returnData = abi.encode(true, true);
        postTryCatchMetaData = abi.encodeWithSelector(
            executionEnvironment.solverPostTryCatch.selector, solverOp, returnData, solverTracker
        );
        postTryCatchMetaData = abi.encodePacked(postTryCatchMetaData, ctx.setAndPack(ExecutionPhase.PreSolver));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.PostSolverFailed.selector);
        (revertsAsExpected,) = address(executionEnvironment).call(postTryCatchMetaData);
    }
    
    function test_allocateValue_SkipCoverage() public {
        bytes memory allocateData;
        bool status;

        TestAtlas(payable(address(atlas))).setLockPhase(ExecutionPhase.AllocateValue);

        // Valid
        allocateData = abi.encodeCall(
            executionEnvironment.allocateValue, (false, address(0), uint256(0), abi.encode(false))
        );
        allocateData = abi.encodePacked(allocateData, ctx.setAndPack(ExecutionPhase.AllocateValue));
        vm.prank(address(atlas));
        (status,) = address(executionEnvironment).call(allocateData);
        assertTrue(status);

        // DelegateRevert
        allocateData = abi.encodeCall(
            executionEnvironment.allocateValue, (false, address(0), uint256(0), abi.encode(true))
        );
        allocateData = abi.encodePacked(allocateData, ctx.setAndPack(ExecutionPhase.AllocateValue));
        vm.prank(address(atlas));
        vm.expectRevert(AtlasErrors.AllocateValueDelegatecallFail.selector);
        (status,) = address(executionEnvironment).call(allocateData);
    }

    function test_withdrawERC20_SkipCoverage() public {
        // Valid
        deal(WMON_ADDRESS, address(executionEnvironment), 2e18);
        assertEq(WMON.balanceOf(address(executionEnvironment)), 2e18);
        assertEq(WMON.balanceOf(testUser), 0);
        vm.prank(testUser);
        executionEnvironment.withdrawERC20(WMON_ADDRESS, 2e18);
        assertEq(WMON.balanceOf(address(executionEnvironment)), 0);
        assertEq(WMON.balanceOf(testUser), 2e18);

        // NotEnvironmentOwner
        vm.prank(invalid); // Invalid caller
        vm.expectRevert(AtlasErrors.NotEnvironmentOwner.selector);
        executionEnvironment.withdrawERC20(WMON_ADDRESS, 2e18);

        // BalanceTooLow
        vm.prank(testUser);
        vm.expectRevert(AtlasErrors.ExecutionEnvironmentBalanceTooLow.selector);
        executionEnvironment.withdrawERC20(WMON_ADDRESS, 2e18);

        // Note: AtlasLockActive test removed as it requires internal Atlas state manipulation
    }

    function test_withdrawEther_SkipCoverage() public {
        // Valid
        deal(address(executionEnvironment), 2e18);
        assertEq(address(executionEnvironment).balance, 2e18);
        assertEq(testUser.balance, 0);
        vm.prank(testUser);
        executionEnvironment.withdrawEther(2e18);
        assertEq(address(executionEnvironment).balance, 0);
        assertEq(testUser.balance, 2e18);

        // NotEnvironmentOwner
        vm.prank(address(0)); // Invalid caller
        vm.expectRevert(AtlasErrors.NotEnvironmentOwner.selector);
        executionEnvironment.withdrawEther(2e18);

        // BalanceTooLow
        vm.prank(testUser);
        vm.expectRevert(AtlasErrors.ExecutionEnvironmentBalanceTooLow.selector);
        executionEnvironment.withdrawEther(2e18);

        // Note: AtlasLockActive test removed as it requires internal Atlas state manipulation
    }

    function test_getUser_SkipCoverage() public view {
        assertEq(executionEnvironment.getUser(), testUser);
    }

    function test_getControl_SkipCoverage() public view {
        assertEq(executionEnvironment.getControl(), address(dAppControl));
    }

    function test_getConfig_SkipCoverage() public view {
        assertEq(executionEnvironment.getConfig(), CallBits.encodeCallConfig(callConfig));
    }

    function test_getEscrow_SkipCoverage() public view {
        assertEq(executionEnvironment.getEscrow(), address(atlas));
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

    /*//////////////////////////////////////////////////////////////
                        ATLAS OVERRIDE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _checkUserOperation(UserOperation memory) internal pure override { }

    function _preOpsCall(UserOperation calldata userOp) internal override returns (bytes memory) {
        if (userOp.data.length > 0) {
            (bool success, bytes memory data) = address(userOp.dapp).call(userOp.data);
            require(success, "_preOpsCall reverted");
            return data;
        }
        return new bytes(0);
    }

    function _preSolverCall(
        SolverOperation calldata,
        bytes calldata returnData
    )
        internal
        pure
        override
    {
        (bool shouldRevert, bool returnValue) = abi.decode(returnData, (bool, bool));
        require(!shouldRevert, "_preSolverCall revert requested");
        if (!returnValue) revert("_preSolverCall returned false");
    }

    function _postSolverCall(
        SolverOperation calldata,
        bytes calldata returnData
    )
        internal
        pure
        override
    {
        (bool shouldRevert, bool returnValue) = abi.decode(returnData, (bool, bool));
        require(!shouldRevert, "_postSolverCall revert requested");
        if (!returnValue) revert("_postSolverCall returned false");
    }

    function _allocateValueCall(bool solved, address, uint256, bytes calldata data) internal virtual override {
        (bool shouldRevert) = abi.decode(data, (bool));
        require(!shouldRevert, "_allocateValueCall revert requested");
    }

    function getBidFormat(UserOperation calldata) public view virtual override returns (address) { }
    function getBidValue(SolverOperation calldata) public view virtual override returns (uint256) { }

    /*//////////////////////////////////////////////////////////////
                            CUSTOM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function mockOperation(bool shouldRevert, uint256 returnValue) public pure returns (uint256) {
        require(!shouldRevert, "mockOperation revert requested");
        return returnValue;
    }
}

contract MockSolverContract {
    address public immutable WETH_ADDRESS;
    address private immutable _atlas;
    bool public shouldReconcile = true;

    constructor(address weth, address atlas) {
        WETH_ADDRESS = weth;
        _atlas = atlas;
    }

    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address,
        uint256,
        bytes calldata solverOpData,
        bytes calldata
    )
        external
        payable
        returns (bool success, bytes memory data)
    {
        (success, data) = address(this).call{ value: msg.value }(solverOpData);
        require(success, "atlasSolverCall call reverted");
        if (shouldReconcile) {
            IAtlas(_atlas).reconcile(type(uint256).max);
        }
    }

    function solverMockOperation(bool shouldRevert) public pure {
        require(!shouldRevert, "solverMockOperation revert requested");
    }

    function setReconcile(bool _shouldReconcile) external {
        shouldReconcile = _shouldReconcile;
    }
}

