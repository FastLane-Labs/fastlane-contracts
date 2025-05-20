// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "../../base/BaseTest.t.sol";
import { IEntryPoint as IEntryPointV7 } from "account-abstraction-v7/contracts/interfaces/IEntryPoint.sol";
import { IEntryPoint as IEntryPointV8 } from "account-abstraction-v8/contracts/interfaces/IEntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PackedUserOperation as PackedUserOperationV7 } from
    "account-abstraction-v7/contracts/interfaces/PackedUserOperation.sol";
import { PackedUserOperation as PackedUserOperationV8 } from
    "account-abstraction-v8/contracts/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "account-abstraction-v7/contracts/core/UserOperationLib.sol";
import { SimpleAccount as SimpleAccountV7 } from "account-abstraction-v7/contracts/samples/SimpleAccount.sol";
import { SimpleAccount as SimpleAccountV8 } from "account-abstraction-v8/contracts/accounts/SimpleAccount.sol";
import { SimpleAccountFactory as SimpleAccountFactoryV7 } from
    "account-abstraction-v7/contracts/samples/SimpleAccountFactory.sol";
import { SimpleAccountFactory as SimpleAccountFactoryV8 } from
    "account-abstraction-v8/contracts/accounts/SimpleAccountFactory.sol";

contract PaymasterTestHelper is BaseTest {
    using UserOperationLib for PackedUserOperationV7;

    address public payor;
    uint256 public payorPK;
    address public smartwalletV7;
    address public smartwalletV8;
    address public sponsor;
    uint256 public sponsorPK;
    uint256 public deployerPrivateKey;
    SimpleAccountFactoryV7 public accountFactoryV7;
    SimpleAccountFactoryV8 public accountFactoryV8;

    // This function is needed to receive ETH refunds from the EntryPoint
    receive() external payable { }

    function __setupSmartWallet() internal {
        // Use counterfactual address calculation to predict the wallet address
        uint256 saltNonce = 0; // Use a unique salt for deterministic address generation
        smartwalletV7 = getSmartAccountAddress(userEOA, saltNonce, true);
        smartwalletV8 = getSmartAccountAddress(userEOA, saltNonce, false);
    }

    // Helper function to generate ERC4337 init code for a new smart wallet
    function generateInitCode(
        address owner,
        uint256 saltNonce,
        bool isV7
    )
        internal
        view
        returns (bytes memory initCode, address accountAddress)
    {
        // Create the initCode - this needs to call the factory's createAccount method
        initCode = isV7
            ? abi.encodePacked(
                address(accountFactoryV7), abi.encodeCall(SimpleAccountFactoryV7.createAccount, (owner, saltNonce))
            )
            : abi.encodePacked(
                address(accountFactoryV8), abi.encodeCall(SimpleAccountFactoryV8.createAccount, (owner, saltNonce))
            );

        // Calculate the counterfactual address
        accountAddress =
            isV7 ? accountFactoryV7.getAddress(owner, saltNonce) : accountFactoryV8.getAddress(owner, saltNonce);
    }

    // Helper function to directly calculate the predicted smart account address
    function getSmartAccountAddress(address owner, uint256 saltNonce, bool isV7) public view returns (address) {
        return isV7 ? accountFactoryV7.getAddress(owner, saltNonce) : accountFactoryV8.getAddress(owner, saltNonce);
    }

    function buildUserOpV7(
        IEntryPointV7 _entryPoint,
        address _userEOA
    )
        internal
        view
        returns (PackedUserOperationV7 memory)
    {
        return buildUserOp(address(_entryPoint), _userEOA, smartwalletV7, true);
    }

    function buildUserOpV8(
        IEntryPointV8 _entryPoint,
        address _userEOA
    )
        internal
        view
        returns (PackedUserOperationV8 memory)
    {
        return toPackedUserOperationV8(buildUserOp(address(_entryPoint), _userEOA, smartwalletV8, false));
    }

    // Returns a v7 userOp no matter what, convert to v8 if needed
    function buildUserOp(
        address _entryPoint,
        address _userEOA,
        address _smartWallet,
        bool isV7
    )
        internal
        view
        returns (PackedUserOperationV7 memory)
    {
        address sender = _userEOA;
        bytes memory initCode;

        if (sender == _smartWallet) {
            // For the smartwallet, we know the owner is userEOA
            uint256 saltNonce = 0;
            address accountAddress;

            // Generate the initCode for the smart account
            (initCode, accountAddress) = generateInitCode(userEOA, saltNonce, isV7);

            // Verify the calculated address matches the sender
            require(accountAddress == _smartWallet, "Calculated address doesn't match smartwallet");
        } else {
            // We don't know the owner for other addresses, so we can't generate correct initCode
            // In a real-world scenario, we'd need to know the owner for each address
            initCode = new bytes(0);
        }

        return PackedUserOperationV7({
            sender: sender,
            nonce: isV7 ? IEntryPointV7(_entryPoint).getNonce(sender, 0) : IEntryPointV8(_entryPoint).getNonce(sender, 0),
            initCode: initCode,
            callData: new bytes(0),
            // Use higher gas limits needed for account creation
            accountGasLimits: bytes32(abi.encodePacked(bytes16(uint128(2_000_000)), bytes16(uint128(500_000)))),
            preVerificationGas: 1_000_000,
            gasFees: bytes32(abi.encodePacked(bytes16(uint128(1_000_000_000)), bytes16(uint128(5_000_000_000)))),
            paymasterAndData: new bytes(0),
            signature: new bytes(0)
        });
    }

    function buildDeployAndExecuteUserOpV7(
        address owner,
        uint256 saltNonce,
        address target,
        uint256 value,
        bytes memory callData
    )
        internal
        view
        returns (PackedUserOperationV7 memory)
    {
        return buildDeployAndExecuteUserOp(owner, saltNonce, target, value, callData, true);
    }

    function buildDeployAndExecuteUserOpV8(
        address owner,
        uint256 saltNonce,
        address target,
        uint256 value,
        bytes memory callData
    )
        internal
        view
        returns (PackedUserOperationV8 memory)
    {
        return toPackedUserOperationV8(buildDeployAndExecuteUserOp(owner, saltNonce, target, value, callData, false));
    }

    // Helper function to create a UserOperation that deploys and executes in one operation.
    // Returns a v7 userOp no matter what, convert to v8 if needed
    function buildDeployAndExecuteUserOp(
        address owner,
        uint256 saltNonce,
        address target,
        uint256 value,
        bytes memory callData,
        bool isV7
    )
        internal
        view
        returns (PackedUserOperationV7 memory)
    {
        // Generate init code and get the account address
        (bytes memory initCode, address accountAddress) = generateInitCode(owner, saltNonce, isV7);

        // Encode the execution call - for SimpleAccount we use execute method
        bytes memory executeCalldata =
        // abi.encodeCall(isV7 ? SimpleAccountV7.execute : SimpleAccountV8.execute, (target, value, callData));
         abi.encodeCall(SimpleAccountV7.execute, (target, value, callData));

        // Create the UserOperation
        PackedUserOperationV7 memory userOp = PackedUserOperationV7({
            sender: accountAddress,
            nonce: 0, // First transaction
            initCode: initCode,
            callData: executeCalldata,
            accountGasLimits: bytes32(abi.encodePacked(bytes16(uint128(2_000_000)), bytes16(uint128(500_000)))),
            preVerificationGas: 1_000_000,
            gasFees: bytes32(abi.encodePacked(bytes16(uint128(1_000_000_000)), bytes16(uint128(5_000_000_000)))),
            paymasterAndData: new bytes(0),
            signature: new bytes(0)
        });

        return userOp;
    }

    function signUserOpV7(PackedUserOperationV7 memory op, uint256 _key) public view returns (bytes memory signature) {
        bytes32 hash = entryPointV7.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, MessageHashUtils.toEthSignedMessageHash(hash));
        signature = abi.encodePacked(r, s, v);
    }

    function signUserOpV8(PackedUserOperationV8 memory op, uint256 _key) public view returns (bytes memory signature) {
        bytes32 hash = entryPointV8.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, hash);
        signature = abi.encodePacked(r, s, v);
    }

    function signPayorV7(
        PackedUserOperationV7 memory op,
        uint256 _key,
        uint48 validUntil,
        uint48 validAfter
    )
        public
        view
        returns (bytes memory payorSig)
    {
        bytes32 hash = paymaster.getHash(op, validUntil, validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, MessageHashUtils.toEthSignedMessageHash(hash));
        payorSig = abi.encodePacked(r, s, v);
    }

    function signPayorV8(
        PackedUserOperationV8 memory op,
        uint256 _key,
        uint48 validUntil,
        uint48 validAfter
    )
        public
        view
        returns (bytes memory payorSig)
    {
        bytes32 hash = paymaster.getHash(toPackedUserOperationV7(op), validUntil, validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, MessageHashUtils.toEthSignedMessageHash(hash));
        payorSig = abi.encodePacked(r, s, v);
    }

    // balanceOf helper that supports ERC20 and native token
    function _balanceOf(address token, address account) internal view returns (uint256) {
        if (token == address(0)) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }

    function toPackedUserOperationV8(PackedUserOperationV7 memory op)
        internal
        pure
        returns (PackedUserOperationV8 memory)
    {
        return PackedUserOperationV8({
            sender: op.sender,
            nonce: op.nonce,
            initCode: op.initCode,
            callData: op.callData,
            accountGasLimits: op.accountGasLimits,
            preVerificationGas: op.preVerificationGas,
            gasFees: op.gasFees,
            paymasterAndData: op.paymasterAndData,
            signature: op.signature
        });
    }

    function toPackedUserOperationV7(PackedUserOperationV8 memory op)
        internal
        pure
        returns (PackedUserOperationV7 memory)
    {
        return PackedUserOperationV7({
            sender: op.sender,
            nonce: op.nonce,
            initCode: op.initCode,
            callData: op.callData,
            accountGasLimits: op.accountGasLimits,
            preVerificationGas: op.preVerificationGas,
            gasFees: op.gasFees,
            paymasterAndData: op.paymasterAndData,
            signature: op.signature
        });
    }

    function toPackedUserOperationsV8(PackedUserOperationV7[] memory ops)
        internal
        pure
        returns (PackedUserOperationV8[] memory)
    {
        PackedUserOperationV8[] memory opsV8 = new PackedUserOperationV8[](ops.length);
        for (uint256 i = 0; i < ops.length; i++) {
            opsV8[i] = toPackedUserOperationV8(ops[i]);
        }
        return opsV8;
    }

    function toPackedUserOperationsV7(PackedUserOperationV8[] memory ops)
        internal
        pure
        returns (PackedUserOperationV7[] memory)
    {
        PackedUserOperationV7[] memory opsV7 = new PackedUserOperationV7[](ops.length);
        for (uint256 i = 0; i < ops.length; i++) {
            opsV7[i] = toPackedUserOperationV7(ops[i]);
        }
        return opsV7;
    }
}
