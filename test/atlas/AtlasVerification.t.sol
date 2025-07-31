// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { Atlas } from "../../src/atlas/core/Atlas.sol";
import { AtlasVerification, USER_TYPEHASH_DEFAULT, USER_TYPEHASH_TRUSTED } from "../../src/atlas/core/AtlasVerification.sol";
import { TestAtlasVerification } from "./helpers/TestAtlasVerification.sol";
import { DAppConfig, CallConfig } from "../../src/atlas/types/ConfigTypes.sol";
import "../../src/atlas/types/DAppOperation.sol";
import { UserOperation } from "../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../src/atlas/types/SolverOperation.sol";
import { ValidCallsResult } from "../../src/atlas/types/ValidCalls.sol";
import { AtlasErrors } from "../../src/atlas/types/AtlasErrors.sol";
import { DummyDAppControl } from "./helpers/DummyDAppControl.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import { CallVerification } from "../../src/atlas/libraries/CallVerification.sol";
import { CallBits } from "../../src/atlas/libraries/CallBits.sol";
import { SolverOutcome } from "../../src/atlas/types/EscrowTypes.sol";
import { DummyDAppControlBuilder } from "./helpers/DummyDAppControlBuilder.sol";
import { CallConfigBuilder } from "./helpers/CallConfigBuilder.sol";
import { UserOperationBuilder } from "./builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "./builders/SolverOperationBuilder.sol";
import { DAppOperationBuilder } from "./builders/DAppOperationBuilder.sol";

// TODO add tests for the gasLimitSum stuff

contract DummyNotSmartWallet {
}

contract DummySmartWallet {
    bytes4 constant internal EIP1271_MAGIC_VALUE = 0x1626ba7e;
    bool public isValidResult = true;

    function isValidSignature(
        bytes32,
        bytes memory
    ) public view returns (bytes4) {
        if (isValidResult) {
            return EIP1271_MAGIC_VALUE;
        } else {
            return 0;
        }
    }

    function setIsValidResult(bool data) external {
        isValidResult = data;
    }
}

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
        return new DummyDAppControlBuilder()
            .withEscrow(address(atlas))
            .withGovernance(governanceEOA)
            .withCallConfig(defaultCallConfig().build());
    }

    function validUserOperation() public returns (UserOperationBuilder) {
        return new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification), userEOA)
            .withDeadline(block.number + 2)
            .withControl(address(dAppControl))
            .withCallConfig(dAppControl.CALL_CONFIG())
            .withDAppGasLimit(dAppControl.getDAppGasLimit())
            .withSolverGasLimit(dAppControl.getSolverGasLimit())
            .withBundlerSurchargeRate(dAppControl.getBundlerSurchargeRate())
            .withSessionKey(address(0))
            .withData("")
            .sign(address(atlasVerification), userPK);
    }

    function validSolverOperation(UserOperation memory userOp) public returns (SolverOperationBuilder) {
        return new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withData("")
            .withUserOpHash(userOp)
            .sign(address(atlasVerification), solverOnePK);
    }

    function validSolverOperations(UserOperation memory userOp) public returns (SolverOperation[] memory) {
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = validSolverOperation(userOp).build();
        return solverOps;
    }

    function validDAppOperation(DAppConfig memory config, UserOperation memory userOp, SolverOperation[] memory solverOps) public returns (DAppOperationBuilder) {
        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        return new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(callChainHash)
            .sign(address(atlasVerification), governancePK);
    }

    function validDAppOperation(UserOperation memory userOp, SolverOperation[] memory solverOps) public returns (DAppOperationBuilder) {
        return new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK);
    }

    function doValidateCalls(ValidCallsCall memory call) public returns (
        uint256 allSolversGasLimit,
        uint256 allSolversCalldataGas,
        uint256 bidFindOverhead,
        ValidCallsResult result
    ) {
        DAppConfig memory config = dAppControl.getDAppConfig(call.userOp);

        // If 0, set to just under expected exec gas limit. Otherwise use the existing value.
        if(call.metacallGasLeft == 0)
            call.metacallGasLeft = _gasLim(call.userOp, call.solverOps) - 10_000; 

        vm.startPrank(address(atlas));
        (allSolversGasLimit,  allSolversCalldataGas, bidFindOverhead, result) = atlasVerification.validateCalls(
            config,
            call.userOp,
            call.solverOps,
            call.dAppOp,
            call.metacallGasLeft,
            call.msgValue,
            call.msgSender,
            call.isSimulation);
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
}

//
// ---- verifySolverOp() Tests ---- //
//

contract AtlasVerificationVerifySolverOpTest is AtlasVerificationBase {
    using CallVerification for UserOperation;

    function setUp() public override {
        BaseTest.setUp();
        dAppControl = defaultDAppControl().buildAndIntegrate(atlasVerification);
    }

    function test_verifySolverOp_InvalidSignature() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = userEOA;

        // Signed by wrong PK = SolverOutcome.InvalidSignature
        solverOps[0] = validSolverOperation(userOp).signAndBuild(address(atlasVerification), userPK);
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidSignature), "Expected InvalidSignature 1");

        // No signature = SolverOutcome.InvalidSignature
        solverOps[0].signature = "";
        result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidSignature), "Expected InvalidSignature 2");
    }

    function test_verifySolverOp_InvalidUserHash() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // userOpHash doesnt match = SolverOutcome.InvalidUserHash
        solverOps[0].userOpHash = keccak256(abi.encodePacked("Not the userOp"));
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidUserHash), "Expected InvalidUserHash");
    }

    function test_verifySolverOp_InvalidTo() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // solverOp.to != atlas = SolverOutcome.InvalidTo
        solverOps[0].to = address(0);
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidTo), "Expected InvalidTo");
    }

    function test_verifySolverOp_GasPriceOverCap() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // solverOp.maxFeePerGas < tx.gasprice = SolverOutcome.GasPriceOverCap
        vm.txGasPrice(solverOps[0].maxFeePerGas + 1); // Increase gas price above solver's max
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.GasPriceOverCap), "Expected GasPriceOverCap");
        vm.txGasPrice(tx.gasprice); // Reset gas price to expected level
    }

    function test_verifySolverOp_GasPriceBelowUsers() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // solverOp.maxFeePerGas < userOp.maxFeePerGas = SolverOutcome.GasPriceBelowUsers
        solverOps[0].maxFeePerGas = userOp.maxFeePerGas - 1;
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.GasPriceBelowUsers), "Expected GasPriceBelowUsers");
    }

    function test_verifySolverOp_InvalidSolver() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // solverOp.solver is atlas = SolverOutcome.InvalidSolver
        solverOps[0].solver = address(atlas);
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 1 << uint256(SolverOutcome.InvalidSolver), "Expected InvalidSolver");
    }

    function test_verifySolverOp_Valid() public {
        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        address bundler = solverOneEOA;

        // no sig, everything valid = Valid result
        solverOps[0].signature = "";
        vm.prank(solverOneEOA);
        uint256 result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 0, "Expected No Errors 1"); // 0 = No SolverOutcome errors

        // Valid solver sig, everything valid = Valid result
        solverOps = validSolverOperations(userOp);
        bundler = userEOA;
        result = atlasVerification.verifySolverOp(
            solverOps[0],
            atlasVerification.getUserOperationHash(userOp),
            userOp.maxFeePerGas,
            bundler,
            false
        );
        assertEq(result, 0, "Expected No Errors 2"); // 0 = No SolverOutcome errors
    }
}

//
// ---- VALID CALLS TESTS BEGIN HERE ---- //
//

contract AtlasVerificationValidCallsTest is AtlasVerificationBase {
    using CallVerification for UserOperation;

    // Default Everything Valid Test Case

    function test_DefaultEverything_Valid() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: 0, msgValue: 0, msgSender: solverOneEOA, isSimulation: false
        }), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is not signed properly
    // when validCalls is called and the bundler is not the user
    // then it should return InvalidSignature
    // because the user operation must be signed by the user unless the bundler is the user
    //
    function test_verifyUserOp_UserSignatureInvalid_WhenOpUnsignedIfNotUserBundler() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        userOp.signature = "";
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: 0, msgValue: 0, msgSender: solverOneEOA, isSimulation: false
        }), ValidCallsResult.UserSignatureInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is not signed properly
    // when validCalls is called and the bundler is the user
    // then it should return Valid
    // because the user operation doesn't need to be signed by the user if the bundler is the user
    //
    function test_verifyUserOp_Valid_WhenOpUnsignedIfUserBundler() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        userOp.signature = "";
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: 0, msgValue: 0, msgSender: userEOA, isSimulation: false
        }), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is not
    // when validCalls is called
    //   and the bundler is not the user
    //   and isSimulation = true
    // then it should return Valid
    // because the user operation doesn't need to be signed if it's a simulation
    //
    function test_verifyUserOp_Valid_WhenOpUnsignedIfIsSimulation() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation().build();
        userOp.signature = "";
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: 0, msgValue: 0, msgSender: solverOneEOA, isSimulation: true
        }), ValidCallsResult.Valid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation has a bad signature
    // when validCalls is called
    //   and the bundler is not the user
    //   and isSimulation = true
    // then it should return UserSignatureInvalid
    // because the user operation doesn't need to be signed if it's a simulation
    //
    function test_verifyUserOp_Valid_WhenOpHasBadSignatureIfIsSimulation() public {
        defaultAtlasEnvironment();

        UserOperation memory userOp = validUserOperation()
            .withSignature("bad signature")
            .build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: 0, msgValue: 0, msgSender: solverOneEOA, isSimulation: true
        }), ValidCallsResult.UserSignatureInvalid);
    }

    //
    // given a default atlas environment
    //   and otherwise valid user, solver and dapp operations
    // where the user operation is from a smart contract
    //   and the from address is Atlas, AtlasVerification or the dAppControl
    // when validCalls is called
    // then it should return UserFromInvalid
    // to prevent abusive behavior
    //
    function test_verifyUserOp_UserFromInvalid_WhenFromInvalidSmartContract() public {
        defaultAtlasEnvironment();

        address[] memory invalidFroms = new address[](2);
        invalidFroms[0] = address(atlas);
        invalidFroms[1] = address(atlasVerification);

        for (uint256 i = 0; i < invalidFroms.length; i++) {
            UserOperation memory userOp = validUserOperation()
                .withFrom(invalidFroms[i])
                .withSignature("")
                .build();

            SolverOperation[] memory solverOps = validSolverOperations(userOp);
            DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

            callAndAssert(ValidCallsCall({
                userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: 0, msgValue: 0, msgSender: solverOneEOA, isSimulation: false
            }), ValidCallsResult.UserFromInvalid);
        }
    }

    function test_validCalls_checkMetacallGasLimitEnabled_GasLimitTooLow() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withCheckMetacallGasLimit(true).build());
        uint256 gasLim = 300_000; // Should be too low to pass checks

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: gasLim, msgValue: 0, msgSender: userEOA, isSimulation: false
        }), ValidCallsResult.MetacallGasLimitTooLow);
    }

    function test_validCalls_checkMetacallGasLimitEnabled_GasLimitTooHigh() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withCheckMetacallGasLimit(true).build());
        uint256 gasLim = 50_000_000; // Should be too high to pass checks

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: gasLim, msgValue: 0, msgSender: userEOA, isSimulation: false
        }), ValidCallsResult.MetacallGasLimitTooHigh);
    }

    function test_validCalls_checkMetacallGasLimitDisabled_LowGasLimitValid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withCheckMetacallGasLimit(false).build());
        uint256 gasLim = 300_000; // Should be valid when checks are disabled

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: gasLim, msgValue: 0, msgSender: userEOA, isSimulation: false
        }), ValidCallsResult.Valid);
    }

    function test_validCalls_checkMetacallGasLimitDisabled_HighGasLimitValid() public {
        defaultAtlasWithCallConfig(defaultCallConfig().withCheckMetacallGasLimit(false).build());
        uint256 gasLim = 50_000_000; // Should be valid when checks are disabled

        UserOperation memory userOp = validUserOperation().build();
        SolverOperation[] memory solverOps = validSolverOperations(userOp);
        DAppOperation memory dappOp = validDAppOperation(userOp, solverOps).build();

        callAndAssert(ValidCallsCall({
            userOp: userOp, solverOps: solverOps, dAppOp: dappOp, metacallGasLeft: gasLim, msgValue: 0, msgSender: userEOA, isSimulation: false
        }), ValidCallsResult.Valid);
    }

    function testGetDomainSeparatorInAtlasVerification() public view {
        bytes32 hashedName = keccak256(bytes("AtlasVerification"));
        bytes32 hashedVersion = keccak256(bytes("1.6.3"));
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 predictedDomainSeparator = keccak256(abi.encode(typeHash, hashedName, hashedVersion, block.chainid, address(atlasVerification)));
        bytes32 domainSeparator = atlasVerification.getDomainSeparator();

        assertEq(predictedDomainSeparator, domainSeparator);
    }
}