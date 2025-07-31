// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AtlasBaseTest } from "./base/AtlasBaseTest.t.sol";
import { Simulator } from "../../src/atlas/helpers/Simulator.sol";
import { Result } from "../../src/atlas/interfaces/ISimulator.sol";
import { UserOperation } from "../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../src/atlas/types/SolverOperation.sol";
import { DAppOperation } from "../../src/atlas/types/DAppOperation.sol";
import { DAppConfig, CallConfig } from "../../src/atlas/types/ConfigTypes.sol";
import { ValidCallsResult } from "../../src/atlas/types/ValidCalls.sol";
import { DummyDAppControl } from "./helpers/DummyDAppControl.sol";
import { DummyDAppControlBuilder } from "./helpers/DummyDAppControlBuilder.sol";

contract SimulatorTest is AtlasBaseTest {
    
    uint256 constant USER_GAS = 200_000;
    uint256 constant SOLVER_GAS = 100_000;
    DummyDAppControl dappControl;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy a mock DApp control
        CallConfig memory callConfig = CallConfig({
            userNoncesSequential: false,
            dappNoncesSequential: false,
            requirePreOps: false,
            trackPreOpsReturnData: false,
            trackUserReturnData: false,
            delegateUser: false,
            requirePreSolver: false,
            requirePostSolver: false,
            zeroSolvers: false,
            reuseUserOp: false,
            userAuctioneer: true,
            solverAuctioneer: false,
            verifyCallChainHash: true,
            unknownAuctioneer: false,
            forwardReturnData: false,
            requireFulfillment: false,
            trustedOpHash: false,
            invertBidValue: false,
            exPostBids: false,
            multipleSuccessfulSolvers: false,
            checkMetacallGasLimit: false
        });
        
        dappControl = new DummyDAppControlBuilder()
            .withEscrow(address(atlas))
            .withGovernance(governanceEOA)
            .withCallConfig(callConfig)
            .buildAndIntegrate(atlasVerification);
    }
    
    function test_estimateMetacallGasLimit() public view {
        UserOperation memory userOp = _createUserOp(userEOA);
        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        
        SolverOperation[] memory solverOps = new SolverOperation[](2);
        solverOps[0] = _createSolverOp(solverOneEOA, userOpHash, 1 ether);
        solverOps[1] = _createSolverOp(solverTwoEOA, userOpHash, 2 ether);
        
        uint256 gasLimit = simulator.estimateMetacallGasLimit(userOp, solverOps);
        
        // Gas limit should include user gas, solver gas, and overhead
        assertTrue(gasLimit > userOp.gas, "Gas limit should be greater than user gas");
        assertTrue(gasLimit > userOp.gas + solverOps[0].gas + solverOps[1].gas, "Should include all solver gas");
    }
    
    function test_estimateMaxSolverWinGasCharge() public view {
        UserOperation memory userOp = _createUserOp(userEOA);
        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        
        SolverOperation memory solverOp = _createSolverOp(solverOneEOA, userOpHash, 1 ether);
        
        uint256 gasCharge = simulator.estimateMaxSolverWinGasCharge(userOp, solverOp);
        
        // Gas charge should be non-zero
        assertTrue(gasCharge > 0, "Gas charge should be positive");
        
        // Gas charge should scale with maxFeePerGas
        solverOp.maxFeePerGas = 20 gwei;
        uint256 higherGasCharge = simulator.estimateMaxSolverWinGasCharge(userOp, solverOp);
        assertTrue(higherGasCharge > gasCharge, "Higher fee should result in higher charge");
    }
    
    function testFuzz_estimateMetacallGasLimit(
        uint32 userGas,
        uint32 solverGas,
        uint8 solverCount
    ) public view {
        // Bound inputs
        userGas = uint32(bound(userGas, 50_000, 1_000_000));
        solverGas = uint32(bound(solverGas, 20_000, 500_000));
        solverCount = uint8(bound(solverCount, 0, 10));
        
        UserOperation memory userOp = _createUserOp(userEOA);
        userOp.gas = userGas;
        
        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        
        SolverOperation[] memory solverOps = new SolverOperation[](solverCount);
        for (uint i = 0; i < solverCount; i++) {
            solverOps[i] = _createSolverOp(address(uint160(i + 1000)), userOpHash, 1 ether);
            solverOps[i].gas = solverGas;
        }
        
        uint256 gasLimit = simulator.estimateMetacallGasLimit(userOp, solverOps);
        
        // Verify gas limit is reasonable
        assertTrue(gasLimit >= userGas, "Gas limit should at least include user gas");
        if (solverCount > 0) {
            assertTrue(gasLimit >= userGas + solverGas, "Should include at least one solver's gas");
        }
        assertTrue(gasLimit < type(uint32).max, "Gas limit should be reasonable");
    }
    
    function test_setAtlas() public {
        // Test that only deployer can set atlas
        address newAtlas = address(0x1234);
        
        vm.expectRevert();
        simulator.setAtlas(newAtlas);
        
        // Deployer should be able to set it
        vm.prank(simulator.deployer());
        simulator.setAtlas(newAtlas);
        assertEq(simulator.atlas(), newAtlas, "Atlas should be updated");
    }
    
    function test_withdrawETH() public {
        // Send some ETH to simulator
        deal(address(simulator), 10 ether);
        
        // The simulator was deployed by the deployer address in SetupAtlas
        address simulatorDeployer = simulator.deployer();
        uint256 balanceBefore = simulatorDeployer.balance;
        
        // Deployer should be able to withdraw
        vm.prank(simulatorDeployer);
        simulator.withdrawETH(simulatorDeployer);
        
        assertEq(simulatorDeployer.balance, balanceBefore + 10 ether, "ETH should be withdrawn");
        assertEq(address(simulator).balance, 0, "Simulator should have no balance");
    }
    
    function test_withdrawETH_unauthorized() public {
        // Send some ETH to simulator
        deal(address(simulator), 10 ether);
        
        // Non-deployer should not be able to withdraw
        vm.prank(address(0x9999));
        vm.expectRevert();
        simulator.withdrawETH(address(0x9999));
    }
    
    // Helper functions
    function _createUserOp(address from) internal view returns (UserOperation memory) {
        return UserOperation({
            from: from,
            to: address(atlas),
            value: 0,
            gas: USER_GAS,
            maxFeePerGas: 10 gwei,
            nonce: 1,
            deadline: block.number + 100,
            dapp: address(dappControl),
            control: address(dappControl),
            callConfig: 0,
            dappGasLimit: 50_000,
            solverGasLimit: uint32(SOLVER_GAS),
            bundlerSurchargeRate: 100,
            sessionKey: address(0),
            data: "",
            signature: ""
        });
    }
    
    function _createSolverOp(
        address from,
        bytes32 userOpHash,
        uint256 bidAmount
    ) internal view returns (SolverOperation memory) {
        return SolverOperation({
            from: from,
            to: address(atlas),
            value: 0,
            gas: SOLVER_GAS,
            maxFeePerGas: 10 gwei,
            deadline: block.number + 100,
            solver: address(0x9999),
            control: address(dappControl),
            userOpHash: userOpHash,
            bidToken: address(0), // Native ETH
            bidAmount: bidAmount,
            data: "",
            signature: ""
        });
    }
}