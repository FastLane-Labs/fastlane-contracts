// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23 <0.9.0;

type ExecMode is bytes32;

interface IKernel {
    function execute(ExecMode execMode, bytes calldata executionCalldata) external payable;
}
