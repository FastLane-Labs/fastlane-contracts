//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ISponsoredExecutor {
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
        returns (bool success, bytes memory returnData);
}
