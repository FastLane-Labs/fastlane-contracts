// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { BaseTest } from "../../base/BaseTest.t.sol";
import { DummyDAppControl } from "../helpers/DummyDAppControl.sol";
import { DummyDAppControlBuilder } from "../helpers/DummyDAppControlBuilder.sol";
import { CallConfigBuilder } from "../helpers/CallConfigBuilder.sol";
import { UserOperationBuilder } from "../builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "../builders/SolverOperationBuilder.sol";
import { DAppOperationBuilder } from "../builders/DAppOperationBuilder.sol";
import { CallVerification } from "../../../src/atlas/libraries/CallVerification.sol";
import { UserOperation } from "../../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../../src/atlas/types/SolverOperation.sol";
import { DAppOperation } from "../../../src/atlas/types/DAppOperation.sol";
import { DAppConfig, CallConfig } from "../../../src/atlas/types/ConfigTypes.sol";
import { ValidCallsResult } from "../../../src/atlas/types/ValidCalls.sol";

contract AtlasVerificationBase is BaseTest {
    DummyDAppControl dAppControl;

    struct ValidCallsCall {
        UserOperation userOp;
        SolverOperation[] solverOps;
        DAppOperation dAppOp;
        uint256 metacallGasLeft;
        uint256 msgValue;
        address msgSender;
        bool isSimulation;
    }

    function defaultCallConfig() public returns (CallConfigBuilder) {
        return new CallConfigBuilder();
    }

    function defaultDAppControl() public returns (DummyDAppControlBuilder) {
        return new DummyDAppControlBuilder().withEscrow(address(atlas)).withGovernance(governanceEOA).withCallConfig(
            defaultCallConfig().build()
        );
    }

    function validUserOperation() public returns (UserOperationBuilder) {
        return new UserOperationBuilder().withFrom(userEOA).withTo(address(atlas)).withValue(0).withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1).withNonce(address(atlasVerification), userEOA).withDeadline(block.number + 2)
            .withControl(address(dAppControl)).withCallConfig(dAppControl.CALL_CONFIG()).withDAppGasLimit(
            dAppControl.getDAppGasLimit()
        ).withSolverGasLimit(dAppControl.getSolverGasLimit()).withBundlerSurchargeRate(
            dAppControl.getBundlerSurchargeRate()
        ).withSessionKey(address(0)).withData("").sign(address(atlasVerification), userPK);
    }

    function validSolverOperation(UserOperation memory userOp) public returns (SolverOperationBuilder) {
        return new SolverOperationBuilder().withFrom(solverOneEOA).withTo(address(atlas)).withValue(0).withGas(
            1_000_000
        ).withMaxFeePerGas(userOp.maxFeePerGas).withDeadline(userOp.deadline).withControl(userOp.control).withData("")
            .withUserOpHash(userOp).sign(address(atlasVerification), solverOnePK);
    }

    function validSolverOperations(UserOperation memory userOp) public returns (SolverOperation[] memory) {
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp).build();
        return solverOps;
    }

    function validDAppOperation(
        DAppConfig memory config,
        UserOperation memory userOp,
        SolverOperation[] memory solverOps
    )
        public
        returns (DAppOperationBuilder)
    {
        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        return new DAppOperationBuilder().withFrom(governanceEOA).withTo(address(atlas)).withNonce(
            address(atlasVerification), governanceEOA
        ).withDeadline(userOp.deadline).withControl(userOp.control).withBundler(address(0)).withUserOpHash(userOp)
            .withCallChainHash(callChainHash).sign(address(atlasVerification), governancePK);
    }

    function validDAppOperation(
        UserOperation memory userOp,
        SolverOperation[] memory solverOps
    )
        public
        returns (DAppOperationBuilder)
    {
        return new DAppOperationBuilder().withFrom(governanceEOA).withTo(address(atlas)).withNonce(
            address(atlasVerification), governanceEOA
        ).withDeadline(userOp.deadline).withControl(userOp.control).withBundler(address(0)).withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps).sign(address(atlasVerification), governancePK);
    }

    function doValidateCalls(ValidCallsCall memory call)
        public
        returns (
            uint256 allSolversGasLimit,
            uint256 allSolversCalldataGas,
            uint256 bidFindOverhead,
            ValidCallsResult result
        )
    {
        DAppConfig memory config = dAppControl.getDAppConfig(call.userOp);

        // If 0, set to just under expected exec gas limit. Otherwise use the existing value.
        if (call.metacallGasLeft == 0) {
            call.metacallGasLeft = _gasLim(call.userOp, call.solverOps) - 10_000;
        }

        vm.startPrank(address(atlas));
        (allSolversGasLimit, allSolversCalldataGas, bidFindOverhead, result) = atlasVerification.validateCalls(
            config,
            call.userOp,
            call.solverOps,
            call.dAppOp,
            call.metacallGasLeft,
            call.msgValue,
            call.msgSender,
            call.isSimulation
        );
        vm.stopPrank();
    }

    function assertValidCallsResult(ValidCallsResult actual, ValidCallsResult expected) public pure {
        assertTrue(actual == expected, "validCallsResult different to expected");
    }

    function callAndAssert(ValidCallsCall memory call, ValidCallsResult expected) public {
        ValidCallsResult result;
        (,,, result) = doValidateCalls(call);
        assertValidCallsResult(result, expected);
    }

    function callAndExpectRevert(ValidCallsCall memory call, bytes4 selector) public {
        vm.expectRevert(selector);
        doValidateCalls(call);
    }

    function defaultAtlasEnvironment() public {
        BaseTest.setUp();
        dAppControl = defaultDAppControl().buildAndIntegrate(atlasVerification);
    }

    function defaultAtlasWithCallConfig(CallConfig memory callConfig) public {
        BaseTest.setUp();
        dAppControl = defaultDAppControl().withCallConfig(callConfig).buildAndIntegrate(atlasVerification);
    }

    function _calculateGasLimit(
        UserOperation memory userOp,
        SolverOperation[] memory solverOps
    )
        internal
        pure
        returns (uint256)
    {
        uint256 totalGas = userOp.gas;
        for (uint256 i = 0; i < solverOps.length; i++) {
            totalGas += solverOps[i].gas;
        }
        return totalGas;
    }
}
