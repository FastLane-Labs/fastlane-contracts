// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Core types and functions are same for v7 and v8, we use v7 definitions for simplicity
import { PackedUserOperation } from "account-abstraction-v7/contracts/interfaces/PackedUserOperation.sol";
import { UserOperationLib } from "account-abstraction-v7/contracts/core/UserOperationLib.sol";
import { _packValidationData } from "account-abstraction-v7/contracts/core/Helpers.sol";

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";

import { IShMonad } from "../shmonad/interfaces/IShMonad.sol";
import { Directory } from "../common/Directory.sol";

import { BasePaymaster } from "./BasePaymaster.sol";
import { PaymasterEvents } from "./Events.sol";
import { PaymasterErrors } from "./Errors.sol";
import { ITaskManager } from "../task-manager/interfaces/ITaskManager.sol";

using UserOperationLib for PackedUserOperation;

contract Paymaster is BasePaymaster, PaymasterErrors, PaymasterEvents {
    uint256 public constant FEE_BASE = 10_000;

    // Immutable dependency addresses
    IShMonad public immutable shMonad;
    address public immutable taskManager;

    uint64 public immutable POLICY_ID;
    uint256 public immutable FEE;

    /// @notice Constructor that sets immutable variables
    /// @param _shMonad The shMonad address
    /// @param _taskManager The task manager address
    /// @param _entryPointV7 The entry point address for v7
    /// @param _entryPointV8 The entry point address for v8
    /// @param _fee The fee for the paymaster
    /// @param _policyId The policy id for the paymaster
    constructor(
        address _shMonad,
        address _taskManager,
        address _entryPointV7,
        address _entryPointV8,
        uint256 _fee,
        uint64 _policyId
    )
        BasePaymaster(_entryPointV7, _entryPointV8)
    {
        require(_shMonad != address(0), "Invalid shMonad address");
        require(_taskManager != address(0), "Invalid taskManager address");
        require(_entryPointV7 != address(0), "Invalid entryPointV7 address");
        require(_entryPointV8 != address(0), "Invalid entryPointV8 address");
        require(_policyId != 0, InvalidPolicyId());

        shMonad = IShMonad(_shMonad);
        taskManager = _taskManager;
        FEE = _fee;
        POLICY_ID = _policyId;
    }

    /// @notice Initialize the paymaster
    /// @param owner The owner of the paymaster
    function initialize(address owner) external reinitializer(5) {
        // initialize the base paymaster
        _initialize(owner);
    }

    // PRIVATE FUNCTIONS
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    )
        internal
        override
        returns (bytes memory context, uint256 validationData)
    {
        // parse the paymasterAndData
        (uint8 mode, bytes calldata paymasterConfig) = _parsePaymasterAndData(userOp.paymasterAndData);

        if (mode > 2) {
            // mode should be 0 or 1
            revert InvalidMode();
        }

        address payor = userOp.sender;
        bytes memory callData = bytes("");

        if (mode == 0) {
            // check length of paymasterConfig
            require(paymasterConfig.length == 0, InvalidPaymasterConfigLength());

            // user is payor so no signature is needed
            validationData = 0;
        } else if (mode == 1) {
            // check length of paymasterConfig
            require(paymasterConfig.length == 97, InvalidPaymasterConfigLength());

            // check if the paymasterConfig is a valid address
            payor = address(bytes20(paymasterConfig[0:20]));
            require(payor != address(0), InvalidPayorAddress());

            validationData = _validatePayorSignature(payor, userOp, paymasterConfig);
        } else if (mode == 2) {
            // check length of paymasterConfig
            require(paymasterConfig.length > 97, InvalidPaymasterConfigLength());

            // check if the paymasterConfig is a valid address
            payor = address(bytes20(paymasterConfig[0:20]));
            require(payor != address(0), InvalidPayorAddress());

            validationData = _validatePayorSignature(payor, userOp, paymasterConfig);
            callData = paymasterConfig[97:];
        }

        uint256 maxFeePerGas = UserOperationLib.unpackMaxFeePerGas(userOp);
        uint256 maxGasLimit = maxCost / maxFeePerGas;

        // check if the user has enough balance
        uint256 bondedBalance = shMonad.balanceOfBonded(POLICY_ID, payor);
        require(bondedBalance >= maxCost, InsufficientBalance());

        // hold the balance
        shMonad.hold(POLICY_ID, payor, maxCost);

        // Pack userOp.sender and maxCost into context
        context = abi.encodePacked(mode, payor, maxCost, maxGasLimit, userOpHash, callData);
        return (context, validationData);
    }

    function _postOp(
        address entryPoint,
        PostOpMode,
        bytes calldata context,
        uint256,
        uint256 actualUserOpFeePerGas
    )
        internal
        override
    {
        // unpack the context
        uint8 mode = uint8(context[0]);
        address payor = address(bytes20(context[1:21]));
        uint256 maxCost = uint256(bytes32(context[21:53]));
        uint256 maxGasLimit = uint256(bytes32(context[53:85]));
        bytes32 userOpHash = bytes32(context[85:117]);

        // calculate the gas cost with the max gas limit since bundler is paying the gas limit
        uint256 monGasCost = maxGasLimit * actualUserOpFeePerGas;

        // calculate the boost yield amount
        uint256 monBoostYield = (FEE * monGasCost) / FEE_BASE;

        if (mode == 2) {
            uint256 msgValue = uint256(bytes32(context[117:149]));
            uint256 gasLimit = uint256(bytes32(context[149:181]));
            address callTarget = address(bytes20(context[181:201]));
            bytes memory data = context[201:];

            shMonad.agentExecuteWithSponsor(POLICY_ID, payor, address(this), msgValue, gasLimit, callTarget, data);

            // calculate the boost yield amount
            monBoostYield += (FEE * (gasLimit * tx.gasprice)) / FEE_BASE;
        }

        // don't need to preview since its done inside the function
        shMonad.agentWithdrawFromBonded(POLICY_ID, payor, address(this), monGasCost + monBoostYield, maxCost, true);

        // transfer to address(shMonad)
        shMonad.boostYield{ value: monBoostYield }();

        // rebalance the entry point
        this.deposit{ value: address(this).balance }(entryPoint);

        // emit the event
        emit UserOperationSponsored(userOpHash, payor, monGasCost + monBoostYield, POLICY_ID);

        // Use any extra gas to execute other tasks
        (bool success,) =
            address(taskManager).call{ gas: gasleft() }(abi.encodeCall(ITaskManager.executeTasks, (msg.sender, 0)));
    }

    /// @notice Parses the paymasterAndData field of the user operation and returns the paymaster mode and data.
    /// @param _paymasterAndData The paymasterAndData field of the user operation.
    /// @return mode The paymaster mode.
    /// @return paymasterConfig The paymaster configuration data.
    function _parsePaymasterAndData(bytes calldata _paymasterAndData) internal pure returns (uint8, bytes calldata) {
        if (_paymasterAndData.length < 53) {
            return (0, msg.data[0:0]);
        }
        return (uint8(_paymasterAndData[52]), _paymasterAndData[53:]);
    }

    /// @notice Gets the hash of the user operation.
    /// @param userOp The user operation.
    /// @param validUntil The end timestamp of the user operation.
    /// @param validAfter The start timestamp of the user operation.
    /// @return The hash of the user operation.
    function getHash(
        PackedUserOperation calldata userOp,
        uint48 validUntil,
        uint48 validAfter
    )
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.gasFees,
                block.chainid,
                address(this),
                validUntil,
                validAfter
            )
        );
    }

    /// @notice Validates the payor signature and returns the validation data
    /// @param payor The payor address
    /// @param userOp The user operation
    /// @param paymasterConfig The paymaster configuration data
    /// @return validationData The packed validation data
    function _validatePayorSignature(
        address payor,
        PackedUserOperation calldata userOp,
        bytes calldata paymasterConfig
    )
        internal
        view
        returns (uint256 validationData)
    {
        // get deadlines
        uint48 validUntil = uint48(bytes6(paymasterConfig[20:26]));
        uint48 validAfter = uint48(bytes6(paymasterConfig[26:32]));

        // get the signature
        bytes memory payorSig = paymasterConfig[32:97];

        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(getHash(userOp, validUntil, validAfter));

        // Validate signature
        bool signatureValid = SignatureChecker.isValidSignatureNow(payor, hash, payorSig);

        validationData = _packValidationData(!signatureValid, validUntil, validAfter);
    }

    // SHMONAD FUNCTIONS
    function unbondShMonad(uint256 amount, uint256 newMinBalance) external onlyOwner {
        shMonad.unbond(POLICY_ID, amount, newMinBalance);
    }

    function redeemAndWithdrawShMonad(uint256 amount) external onlyOwner {
        shMonad.claimAndRedeem(POLICY_ID, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    receive() external payable { }
}
