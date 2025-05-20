// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

abstract contract PaymasterEvents {
    event UserOperationSponsored(
        bytes32 indexed userOpHash, address indexed payor, uint256 actualGasCost, uint64 policyID
    );
}
