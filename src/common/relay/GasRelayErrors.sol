//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title GasRelayErrors
/// @notice Errors for the GasRelay system
abstract contract GasRelayErrors {
    // Errors from original CashierErrors.sol
    error TaskNotScheduled();
    error InvalidTaskCostEstimate(uint256 amountEstimated, uint256 executionCost);

    // Errors from original CashierHelper.sol
    error InvalidSessionKeyOwner();
    error SessionKeyCantOwnSelf();
    error SessionKeyExpirationInvalid(uint256 expiration);
    error SessionKeyExpired(uint256 expiration, uint256 currentBlock);
    error MustHaveMsgValue();
    error Reentrancy();
    error UnknownMsgSender();

    // New error for when MON transfer to session key fails
    error SessionKeyMonTransferFailed(address sessionKeyAddress);
}
