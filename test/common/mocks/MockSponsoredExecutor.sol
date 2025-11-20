//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { ISponsoredExecutor } from "../../../src/common/ISponsoredExecutor.sol";

/**
 * @title MockSponsoredExecutor
 * @notice Mock implementation of ISponsoredExecutor for testing
 * @dev Used to avoid complex AddressHub dependencies in timelock tests
 */
contract MockSponsoredExecutor is ISponsoredExecutor {
    function agentExecuteWithSponsor(
        uint64, // policyID
        address, // payor
        address, // recipient
        uint256, // msgValue
        uint256, // gasLimit
        address, // callTarget
        bytes calldata // callData
    )
        external
        payable
        override
        returns (bool success, bytes memory returnData)
    {
        // Mock implementation - always succeeds
        return (true, "");
    }
}
