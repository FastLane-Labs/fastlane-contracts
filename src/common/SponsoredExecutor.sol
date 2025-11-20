//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Linked } from "./Linked.sol";
import { Directory } from "./Directory.sol";
import { IAddressHub } from "./IAddressHub.sol";

contract SponsoredExecutor is Linked {
    error Reentry();
    error InsufficientValue(uint256 expectedValue, uint256 actualValue);
    error InsufficientGas(uint256 expectedGas, uint256 actualGas);
    error InvalidCaller();
    error InvalidCallTarget();

    // TODO: Make transient
    uint64 public T_policyID;
    /*
    address public T_payor;
    address public T_recipient;
    uint256 public T_msgValue;
    uint256 public T_gasLimit;
    address public T_callTarget;
    bytes32 public T_callDataHash;
    */

    // SponsoredExecutor is deployed by AddressHub
    constructor() Linked(msg.sender) { }

    function agentExecuteWithSponsor(
        uint64 policyID,
        address payor,
        address recipient,
        uint256 msgValue,
        uint256 gasLimit,
        address callTarget,
        bytes calldata callData
    )
        external
        payable
        returns (bool success, bytes memory returnData)
    {
        // Verify the caller
        if (_fastLaneAddress(Directory._SHMONAD) != msg.sender) revert InvalidCaller();

        // Verify call target is valid
        if (_isFastLane(callTarget)) revert InvalidCallTarget();

        // Verify no reentry
        if (T_policyID != uint64(0)) revert Reentry();

        // Update the data (so callee can verify if needed)
        T_policyID = policyID;
        /*
        T_payor = payor;
        T_recipient = recipient;
        T_msgValue = msgValue;
        T_gasLimit = gasLimit;
        T_callTarget = callTarget;
        T_callDataHash = keccak256(callData);
        */

        // Verify params
        if (gasLimit + 2500 > gasleft()) revert InsufficientGas(gasLimit, gasleft() - 2500);
        if (msg.value != msgValue) revert InsufficientValue(msgValue, msg.value);

        // Handle call
        (success, returnData) = callTarget.call{ value: msgValue, gas: gasLimit }(callData);

        // Release the lock and return
        T_policyID = 0;

        return (success, returnData);
    }

    fallback() external { }
    receive() external payable { }
}
