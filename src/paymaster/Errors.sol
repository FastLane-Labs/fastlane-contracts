// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

abstract contract PaymasterErrors {
    error InvalidPaymasterConfigLength();
    error InvalidPayorAddress();
    error InvalidPaymasterAndDataLength();
    error InsufficientBalance();
    error InvalidMode();
    error InvalidTimestampRange();

    error InvalidPolicyId();
}
