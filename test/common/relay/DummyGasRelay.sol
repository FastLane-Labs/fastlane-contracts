// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { GasRelayBase } from "../../../src/common/relay/GasRelayBase.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

// A simple relay contract for testing
contract DummyGasRelay is GasRelayBase {
    constructor(
        address taskManager,
        address shMonad,
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier
    )
        GasRelayBase(taskManager, shMonad, maxExpectedGasUsagePerTx, escrowDuration, targetBalanceMultiplier)
    { }

    event MethodCalled(address caller, string method, uint256 value);

    // Standard function with GasAbstracted modifier
    function standardMethod(uint256 value) external GasAbstracted {
        emit MethodCalled(_abstractedMsgSender(), "standardMethod", value);
    }

    // Function with Locked modifier
    function lockedMethod(uint256 value) external Locked {
        emit MethodCalled(msg.sender, "lockedMethod", value);
    }

    // Function with CreateOrUpdateSessionKey modifier
    function createOrUpdateMethod(
        address sessionKeyAddress,
        uint256 expiration,
        uint256 value
    )
        external
        payable
        CreateOrUpdateSessionKey(sessionKeyAddress, msg.sender, expiration, msg.value)
    {
        emit MethodCalled(_abstractedMsgSender(), "createOrUpdateMethod", value);
    }

    // Helper function to check if the caller is a session key
    function checkIsSessionKey() external view returns (bool) {
        return _isSessionKey();
    }

    // Helper function to get the abstracted msg sender
    function getAbstractedMsgSender() external view returns (address) {
        return _abstractedMsgSender();
    }

    // Helper function to test Math.mulDiv for overflow protection (H-3 fix)
    function testMathMulDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.mulDiv(a, b, 1);
    }

    // Function with GasAbstracted modifier for our tests
    function gasAbstractedMethod(uint256 value) external GasAbstracted {
        emit MethodCalled(_abstractedMsgSender(), "gasAbstractedMethod", value);
    }

    // Function that reverts after using GasAbstracted modifier to test transient storage clearing
    function gasAbstractedRevertingMethod() external GasAbstracted {
        emit MethodCalled(_abstractedMsgSender(), "gasAbstractedRevertingMethod", 0);
        revert("Intentional revert for testing");
    }

    // Expose the target session key balance calculation for testing
    function exposed_targetSessionKeyBalance() external view returns (uint256) {
        return _targetSessionKeyBalance();
    }

    // Expose the session key balance deficit calculation for testing
    function exposed_sessionKeyBalanceDeficit(address sessionKey) external view returns (uint256) {
        return _sessionKeyBalanceDeficit(sessionKey);
    }

    // Expose the _getNextAffordableBlock function for testing
    function exposed_getNextAffordableBlock(
        uint256 maxPayment,
        uint256 maxSearchGas
    )
        external
        view
        returns (uint256 nextBlock, uint256 gasLimit)
    {
        // Need to provide all the required parameters
        uint256 amountEstimated;
        (amountEstimated, nextBlock) = _getNextAffordableBlock(
            maxPayment,
            block.number, // targetBlock
            block.number + 100, // highestAcceptableBlock
            _MAX_EXPECTED_GAS_USAGE_PER_TX, // maxTaskGas
            maxSearchGas
        );
        gasLimit = nextBlock > 0 ? _MAX_EXPECTED_GAS_USAGE_PER_TX : 0;
        return (nextBlock, gasLimit);
    }
}
