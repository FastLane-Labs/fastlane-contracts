// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymasterTestHelper } from "./helpers/PaymasterTestHelper.sol";
import { MockTarget } from "./helpers/MockTarget.sol";
import { IEntryPoint as EntryPointV7 } from "account-abstraction-v7/contracts/interfaces/IEntryPoint.sol";
import { IEntryPoint as EntryPointV8 } from "account-abstraction-v8/contracts/interfaces/IEntryPoint.sol";
import { SimpleAccountFactory as SimpleAccountFactoryV7 } from
    "account-abstraction-v7/contracts/samples/SimpleAccountFactory.sol";
import { SimpleAccountFactory as SimpleAccountFactoryV8 } from
    "account-abstraction-v8/contracts/accounts/SimpleAccountFactory.sol";
import { SimpleAccount as SimpleAccountV7 } from "account-abstraction-v7/contracts/samples/SimpleAccount.sol";
import { SimpleAccount as SimpleAccountV8 } from "account-abstraction-v8/contracts/accounts/SimpleAccount.sol";
import { PackedUserOperation } from "account-abstraction-v7/contracts/interfaces/PackedUserOperation.sol";
import { _parseValidationData, ValidationData } from "account-abstraction-v7/contracts/core/Helpers.sol";
import { IPaymaster } from "account-abstraction-v7/contracts/interfaces/IPaymaster.sol";
import { Policy } from "../../src/shmonad/Types.sol";

import "forge-std/console.sol";

contract PaymasterTest is PaymasterTestHelper {
    uint256 internal userBondedBalance;
    uint256 internal payorBondedBalance;
    uint256 internal sponsorBondedBalance;
    uint256 internal deployerBondedBalance;

    function setUp() public override {
        // Call parent setUp first to initialize all contracts
        super.setUp();

        // Deploy the SimpleAccountFactory
        accountFactoryV7 = new SimpleAccountFactoryV7(entryPointV7);
        accountFactoryV8 = new SimpleAccountFactoryV8(entryPointV8);

        // Setup smartwallet for testing
        __setupSmartWallet();

        // Setup test accounts
        (userEOA, userPK) = makeAddrAndKey("userEOA");
        (payor, payorPK) = makeAddrAndKey("payor");
        (sponsor, sponsorPK) = makeAddrAndKey("sponsor");

        // Fund accounts
        vm.deal(userEOA, 100 ether);
        vm.deal(payor, 100 ether);
        vm.deal(smartwalletV7, 100 ether);
        vm.deal(smartwalletV8, 100 ether);
        vm.deal(sponsor, 100 ether);
        vm.deal(deployer, 100 ether);

        // Deploy and setup Paymaster
        vm.startPrank(deployer);
        paymaster.deposit{ value: 9.9 ether }(address(entryPointV7));
        vm.stopPrank();

        // Bond tokens for test accounts
        vm.startPrank(userEOA);
        shMonad.depositAndBond{ value: 10 ether }(paymaster.POLICY_ID(), address(userEOA), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(payor);
        shMonad.depositAndBond{ value: 10 ether }(paymaster.POLICY_ID(), address(payor), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(smartwalletV7);
        shMonad.depositAndBond{ value: 10 ether }(paymaster.POLICY_ID(), address(smartwalletV7), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(smartwalletV8);
        shMonad.depositAndBond{ value: 10 ether }(paymaster.POLICY_ID(), address(smartwalletV8), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(sponsor);
        shMonad.depositAndBond{ value: 10 ether }(paymaster.POLICY_ID(), address(sponsor), type(uint256).max);
        vm.stopPrank();

        userBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(userEOA));
        payorBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(payor));
        sponsorBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(sponsor));
        deployerBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(deployer));
    }

    function testDeployment() external view {
        assertEq(address(paymaster.entryPointV7()), address(entryPointV7), "EntryPoint address mismatch");
        assertEq(address(paymaster.entryPointV8()), address(entryPointV8), "EntryPoint address mismatch");
        assertTrue(address(shMonad) != address(0), "ShMonad not deployed");
        assertTrue(address(paymaster) != address(0), "Paymaster not deployed");
        assertTrue(address(userEOA) != address(0), "UserEOA not set");
    }

    function testCreateAndVerifyAccountV7() external {
        testCreateAndVerifyAccount(true);
    }

    function testCreateAndVerifyAccountV8() external {
        testCreateAndVerifyAccount(false);
    }

    // Debug function to create and deploy a SimpleAccount to inspect issues
    function testCreateAndVerifyAccount(bool isV7) internal {
        // Create a new EOA for this test
        (address newOwner,) = makeAddrAndKey("testCreate");
        vm.deal(newOwner, 10 ether);

        uint256 saltNonce = 0;
        address predictedAddress =
            isV7 ? accountFactoryV7.getAddress(newOwner, saltNonce) : accountFactoryV8.getAddress(newOwner, saltNonce);

        if (isV7) {
            // Manually deploy the account via the factory
            vm.prank(newOwner);
            SimpleAccountV7 account = accountFactoryV7.createAccount(newOwner, saltNonce);

            // Verify the account was deployed correctly
            assertEq(address(account), predictedAddress, "Deployed address doesn't match predicted");
            assertEq(account.owner(), newOwner, "Owner not set correctly");

            // Test a direct execution through the wallet
            MockTarget target = new MockTarget();
            vm.prank(newOwner);
            account.execute(address(target), 0, abi.encodeCall(MockTarget.setValue, (999)));
            assertEq(target.value(), 999, "Direct execution failed");
        } else {
            // Manually deploy the account via the factory
            vm.prank(address(accountFactoryV8.senderCreator()));
            SimpleAccountV8 account = accountFactoryV8.createAccount(newOwner, saltNonce);

            // Verify the account was deployed correctly
            assertEq(address(account), predictedAddress, "Deployed address doesn't match predicted");
            assertEq(account.owner(), newOwner, "Owner not set correctly");

            // Test a direct execution through the wallet
            MockTarget target = new MockTarget();
            vm.prank(newOwner);
            account.execute(address(target), 0, abi.encodeCall(MockTarget.setValue, (999)));
            assertEq(target.value(), 999, "Direct execution failed");
        }
    }

    function testSmartAccountDeploymentV7() external {
        testSmartAccountDeployment(true);
    }

    function testSmartAccountDeploymentV8() external {
        testSmartAccountDeployment(false);
    }

    function testSmartAccountDeployment(bool isV7) internal {
        // Create a new EOA for this test
        (address newOwner, uint256 newOwnerPK) = makeAddrAndKey("newOwner");
        vm.deal(newOwner, 1 ether);

        // Generate init code for a new smart wallet and get the predicted address
        uint256 saltNonce = 0; // Use a unique salt for deterministic address generation
        (bytes memory initCode, address accountAddress) = generateInitCode(newOwner, saltNonce, isV7);

        // Fund the account address to pay for execution
        vm.deal(accountAddress, 1 ether);

        // Add stake to EntryPoint (may be required for validation)
        vm.deal(address(this), 10 ether);
        isV7
            ? entryPointV7.depositTo{ value: 1 ether }(accountAddress)
            : entryPointV8.depositTo{ value: 1 ether }(accountAddress);
        isV7 ? entryPointV7.addStake{ value: 1 ether }(1) : entryPointV8.addStake{ value: 1 ether }(1);

        // Create a UserOperation to deploy the smart wallet
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: accountAddress,
            nonce: 0, // First transaction from this account
            initCode: initCode,
            callData: new bytes(0), // No call data for deployment
            accountGasLimits: bytes32(abi.encodePacked(bytes16(uint128(2_000_000)), bytes16(uint128(500_000)))),
            preVerificationGas: 1_000_000,
            gasFees: bytes32(abi.encodePacked(bytes16(uint128(1_000_000_000)), bytes16(uint128(5_000_000_000)))),
            paymasterAndData: new bytes(0), // No paymaster for this test
            signature: new bytes(0) // Will add signature below
         });

        // Sign the UserOperation with the owner's private key
        userOp.signature =
            isV7 ? signUserOpV7(userOp, newOwnerPK) : signUserOpV8(toPackedUserOperationV8(userOp), newOwnerPK);

        // Pack the UserOperation for submission
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        // Make sure the EntryPoint has funds for gas refund
        address entryPoint = isV7 ? address(entryPointV7) : address(entryPointV8);
        vm.deal(entryPoint, 5 ether);

        // Try/catch to get a more detailed error if it fails
        if (isV7) {
            entryPointV7.handleOps(userOps, payable(address(this)));
        } else {
            entryPointV8.handleOps(toPackedUserOperationsV8(userOps), payable(address(this)));
        }
    }

    function testValidateUserOpV7() external {
        testValidateUserOp(true);
    }

    function testValidateUserOpV8() external {
        testValidateUserOp(false);
    }

    function testValidateUserOp(bool isV7) internal {
        PackedUserOperation memory userOp;
        if (isV7) {
            userOp = buildUserOpV7(entryPointV7, smartwalletV7);
        } else {
            userOp = toPackedUserOperationV7(buildUserOpV8(entryPointV8, smartwalletV8));
        }

        MockTarget target = new MockTarget();
        // Layer 1: Encode the actual function call
        bytes memory targetCalldata = abi.encodeCall(MockTarget.setValue, (42));

        // For SimpleAccount, we just call execute() directly
        bytes memory executeCalldata;
        executeCalldata = abi.encodeCall(SimpleAccountV7.execute, (address(target), 0, targetCalldata));
        userOp.callData = executeCalldata;

        bytes32 userOpHash = keccak256(abi.encode(userOp));
        uint256 maxCost = 1 ether;

        uint48 validAfter = uint48(0);
        uint48 validUntil = uint48(block.timestamp + 1_000_000);

        bytes memory payorSig;
        if (isV7) {
            payorSig = signPayorV7(userOp, sponsorPK, validUntil, validAfter);
        } else {
            payorSig = signPayorV8(toPackedUserOperationV8(userOp), sponsorPK, validUntil, validAfter);
        }

        userOp.paymasterAndData = abi.encodePacked(
            address(paymaster), uint128(500_000), uint128(500_000), hex"01", sponsor, validUntil, validAfter, payorSig
        );

        vm.startPrank(isV7 ? address(entryPointV7) : address(entryPointV8));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, userOpHash, maxCost);
        ValidationData memory validationResult = _parseValidationData(validationData);
        assertEq(validationResult.aggregator, address(0), "Validation data should be 0");
        vm.stopPrank();

        uint256 bondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), payor);
        assertEq(bondedBalance, payorBondedBalance, "Payor bonded balance should be unchanged");

        userOp.signature = isV7 ? signUserOpV7(userOp, userPK) : signUserOpV8(toPackedUserOperationV8(userOp), userPK);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        if (isV7) {
            entryPointV7.handleOps(userOps, payable(sponsor));
        } else {
            entryPointV8.handleOps(toPackedUserOperationsV8(userOps), payable(sponsor));
        }

        assertEq(target.value(), 42, "Target value should be 42");
    }

    function testPostOpV7() external {
        testPostOp(true);
    }

    function testPostOpV8() external {
        testPostOp(false);
    }

    function testPostOp(bool isV7) internal {
        IPaymaster.PostOpMode mode = IPaymaster.PostOpMode.opSucceeded;

        PackedUserOperation memory userOp;
        if (isV7) {
            userOp = buildUserOpV7(entryPointV7, smartwalletV7);
        } else {
            userOp = toPackedUserOperationV7(buildUserOpV8(entryPointV8, smartwalletV8));
        }

        bytes32 userOpHash = keccak256(abi.encode(userOp));
        uint256 maxCost = 1 ether;
        uint256 actualUserOpFeePerGas = 1 gwei;
        uint256 maxGasLimit = maxCost / 5_000_000_000; // HARDCODE BAD
        // uint256 gasCostWithMaxGasLimit = (maxGasLimit + 10_000) * actualUserOpFeePerGas;

        bytes memory context = abi.encodePacked(uint8(0), payor, maxCost, maxGasLimit, userOpHash);

        vm.startPrank(isV7 ? address(entryPointV7) : address(entryPointV8));
        paymaster.postOp(mode, context, maxCost, actualUserOpFeePerGas);
        vm.stopPrank();

        payorBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), payor);
        assertGt(payorBondedBalance, 9 ether);

        uint256 paymasterBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(paymaster));
        assertEq(paymasterBalance, 0);

        uint256 entryPointBalance = paymaster.getDeposit(isV7 ? address(entryPointV7) : address(entryPointV8));
        assertGe(entryPointBalance, 10 ether);
    }

    function testPostOpUserPaysForGasV7() external {
        testPostOpUserPaysForGas(true);
    }

    function testPostOpUserPaysForGasV8() external {
        testPostOpUserPaysForGas(false);
    }

    function testPostOpUserPaysForGas(bool isV7) internal {
        IPaymaster.PostOpMode mode = IPaymaster.PostOpMode.opReverted;

        PackedUserOperation memory userOp;
        if (isV7) {
            userOp = buildUserOpV7(entryPointV7, smartwalletV7);
        } else {
            userOp = toPackedUserOperationV7(buildUserOpV8(entryPointV8, smartwalletV8));
        }

        bytes32 userOpHash = keccak256(abi.encode(userOp));

        uint256 maxCost = 1 ether;
        uint256 actualUserOpFeePerGas = 1 gwei;
        uint256 maxGasLimit = maxCost / 5_000_000_000; // HARDCODE BAD
        // uint256 gasCostWithMaxGasLimit = (maxGasLimit + 10_000) * actualUserOpFeePerGas;

        bytes memory context = abi.encodePacked(uint8(1), userEOA, maxCost, maxGasLimit, userOpHash);

        vm.startPrank(isV7 ? address(entryPointV7) : address(entryPointV8));
        paymaster.postOp(mode, context, maxCost, actualUserOpFeePerGas);
        vm.stopPrank();

        userBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), userEOA);
        assertGt(userBondedBalance, 9 ether);

        uint256 paymasterBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(paymaster));
        assertEq(paymasterBalance, 0);

        uint256 entryPointBalance = paymaster.getDeposit(isV7 ? address(entryPointV7) : address(entryPointV8));
        assertGe(entryPointBalance, 10 ether);
    }

    function testPaymasterCallV7() external {
        testPaymasterCall(true);
    }

    function testPaymasterCallV8() external {
        testPaymasterCall(false);
    }

    function testPaymasterCall(bool isV7) internal {
        MockTarget target = new MockTarget();

        PackedUserOperation memory userOp;
        if (isV7) {
            userOp = buildUserOpV7(entryPointV7, smartwalletV7);
        } else {
            userOp = toPackedUserOperationV7(buildUserOpV8(entryPointV8, smartwalletV8));
        }

        bytes32 userOpHash = keccak256(abi.encode(userOp));
        uint256 maxCost = 1 ether;

        uint48 validAfter = uint48(0);
        uint48 validUntil = uint48(block.timestamp + 1_000_000);

        bytes memory payorSig;
        if (isV7) {
            payorSig = signPayorV7(userOp, sponsorPK, validUntil, validAfter);
        } else {
            payorSig = signPayorV8(toPackedUserOperationV8(userOp), sponsorPK, validUntil, validAfter);
        }

        // Layer 1: Encode the actual function call
        bytes memory targetCalldata = abi.encodeCall(MockTarget.setValue, (42));

        userOp.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(500_000),
            uint128(500_000),
            hex"02",
            address(sponsor),
            validUntil,
            validAfter,
            payorSig,
            uint256(0),
            uint256(300_000),
            address(target),
            targetCalldata
        );

        vm.startPrank(isV7 ? address(entryPointV7) : address(entryPointV8));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, userOpHash, maxCost);
        ValidationData memory validationResult = _parseValidationData(validationData);
        assertEq(validationResult.aggregator, address(0), "Validation data should be 0");
        vm.stopPrank();

        userOp.signature = isV7 ? signUserOpV7(userOp, userPK) : signUserOpV8(toPackedUserOperationV8(userOp), userPK);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        uint256 entrypointDepositBefore = paymaster.getDeposit(isV7 ? address(entryPointV7) : address(entryPointV8));

        if (isV7) {
            entryPointV7.handleOps(userOps, payable(sponsor));
        } else {
            entryPointV8.handleOps(toPackedUserOperationsV8(userOps), payable(sponsor));
        }

        uint256 entrypointDepositAfter = paymaster.getDeposit(isV7 ? address(entryPointV7) : address(entryPointV8));
        require(entrypointDepositAfter > entrypointDepositBefore, "Entrypoint deposit should increase");

        assertEq(target.value(), 42, "Target value should be 42");
    }

    function testUnbondShMonad() external {
        vm.deal(address(paymaster), 1 ether);
        // First bond some tokens to the paymaster
        vm.startPrank(address(paymaster));
        shMonad.depositAndBond{ value: 1 ether }(paymaster.POLICY_ID(), address(paymaster), type(uint256).max);

        // Get initial bond amount
        uint256 initialBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(paymaster));
        vm.stopPrank();

        // Unbond
        vm.startPrank(paymasterOwner);
        paymaster.unbondShMonad(0.5 ether, 0);
        vm.stopPrank();

        // Check final bond amount
        uint256 finalBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(paymaster));
        assertEq(finalBondedBalance, initialBondedBalance - 0.5 ether);
    }

    function testRedeemAndWithdrawToShMonad() external {
        Policy memory policy = shMonad.getPolicy(paymaster.POLICY_ID());
        vm.deal(address(paymaster), 1 ether);
        // First bond some tokens
        vm.startPrank(address(paymaster));
        shMonad.depositAndBond{ value: 1 ether }(paymaster.POLICY_ID(), address(paymaster), type(uint256).max);
        vm.stopPrank();

        // Get initial bond amount
        uint256 initialBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(paymaster));

        uint256 initialDepositBalance = address(paymasterOwner).balance;

        vm.startPrank(address(paymasterOwner));
        paymaster.unbondShMonad(0.5 ether, 0);

        vm.roll(block.number + policy.escrowDuration + 1);

        // Redeem
        paymaster.redeemAndWithdrawShMonad(0.5 ether);

        uint256 afterDepositBalance = address(paymasterOwner).balance;
        assertEq(afterDepositBalance, initialDepositBalance + 0.5 ether);

        // Check final amounts
        uint256 finalBondedBalance = shMonad.balanceOfBonded(paymaster.POLICY_ID(), address(paymaster));
        assertEq(finalBondedBalance, initialBondedBalance - 0.5 ether);
        vm.stopPrank();
    }

    function testOwnershipFunctions() external {
        Policy memory policy = shMonad.getPolicy(paymaster.POLICY_ID());
        // Test initial owner
        assertEq(paymaster.owner(), paymasterOwner, "Initial owner should be deployer");

        // Test ownership transfer
        address newOwner = makeAddr("newOwner");
        vm.prank(paymasterOwner);
        paymaster.transferOwnership(newOwner);
        assertEq(paymaster.owner(), newOwner, "Owner should be updated to newOwner");

        // Test onlyOwner functions with new owner
        vm.deal(newOwner, 1 ether);

        // First bond some tokens to the paymaster
        vm.deal(address(paymaster), 1 ether);
        vm.startPrank(address(paymaster));
        shMonad.depositAndBond{ value: 1 ether }(paymaster.POLICY_ID(), address(paymaster), type(uint256).max);
        vm.stopPrank();

        // Test unbondShMonad
        vm.startPrank(newOwner);
        paymaster.unbondShMonad(0.5 ether, 0);

        // Advance blocks to complete unbonding period
        vm.roll(block.number + policy.escrowDuration + 1);

        // Test redeemAndWithdrawShMonad
        paymaster.redeemAndWithdrawShMonad(0.1 ether);
        vm.stopPrank();

        // Test onlyOwner functions revert for non-owner
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", deployer));
        paymaster.unbondShMonad(0.5 ether, 0);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", deployer));
        paymaster.redeemAndWithdrawShMonad(0.1 ether);
        vm.stopPrank();
    }

    function testDeployAndExecuteV7() external {
        testDeployAndExecute(true);
    }

    function testDeployAndExecuteV8() external {
        testDeployAndExecute(false);
    }

    function testDeployAndExecute(bool isV7) internal {
        // Create a new EOA
        (address newOwner, uint256 newOwnerPK) = makeAddrAndKey("newDeployExecuteOwner");
        vm.deal(newOwner, 1 ether);

        // Create a target contract to interact with
        MockTarget target = new MockTarget();

        // Create a UserOperation that deploys the wallet and sets a value in one operation
        bytes memory targetCalldata = abi.encodeCall(MockTarget.setValue, (123));
        PackedUserOperation memory userOp;
        if (isV7) {
            userOp = buildDeployAndExecuteUserOpV7(
                newOwner,
                1, // Different salt from other test
                address(target),
                0, // No value sent
                targetCalldata
            );
        } else {
            userOp = toPackedUserOperationV7(
                buildDeployAndExecuteUserOpV8(
                    newOwner,
                    1, // Different salt from other test
                    address(target),
                    0, // No value sent
                    targetCalldata
                )
            );
        }

        // Get the account address
        address accountAddress = userOp.sender;
        vm.deal(accountAddress, 1 ether);

        // Sign the UserOperation
        userOp.signature =
            isV7 ? signUserOpV7(userOp, newOwnerPK) : signUserOpV8(toPackedUserOperationV8(userOp), newOwnerPK);

        // Pack the UserOperation for submission
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        // Submit the UserOperation
        // Calculate approximate required prefund manually
        // uint256 verificationGasLimit = uint256(uint128(bytes16(userOp.accountGasLimits)));
        // uint256 callGasLimit = uint256(uint128(bytes16(userOp.accountGasLimits >> 128)));
        // uint256 maxFeePerGas = uint256(uint128(bytes16(userOp.gasFees)));
        // uint256 requiredPrefund = (verificationGasLimit + callGasLimit + userOp.preVerificationGas) * maxFeePerGas;

        // Make sure the EntryPoint has funds for gas refund
        vm.deal(isV7 ? address(entryPointV7) : address(entryPointV8), 1 ether);

        if (isV7) {
            entryPointV7.handleOps(userOps, payable(address(this)));
        } else {
            entryPointV8.handleOps(toPackedUserOperationsV8(userOps), payable(address(this)));
        }

        // Verify the wallet was deployed
        uint256 codeSize;
        // @solhint-disable-next-line no-inline-assembly
        assembly {
            codeSize := extcodesize(accountAddress)
        }
        assertTrue(codeSize > 0, "Smart wallet was not deployed");

        // Verify the target function was called
        assertEq(target.value(), 123, "Target function was not called");
    }
}
