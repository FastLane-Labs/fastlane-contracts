//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title GasRelayErrors
/// @notice Custom errors used throughout the GasRelay system
/// @dev Abstract contract containing all custom error definitions for the gas relay functionality
abstract contract GasRelayErrors {
    /// @notice Error thrown when an operation is attempted by an invalid session key owner
    error InvalidSessionKeyOwner();

    /// @notice Error thrown when an operation is attempted by an invalid task owner
    error InvalidTaskOwner();

    /// @notice Error thrown when attempting to set a session key as its own owner
    error SessionKeyCantOwnSelf();

    /// @notice Error thrown when setting an invalid session key expiration
    /// @param expiration The invalid expiration block number
    error SessionKeyExpirationInvalid(uint256 expiration);

    /// @notice Error thrown when setting an invalid task deadline
    /// @param deadline The invalid deadline block number
    error TaskDeadlineInvalid(uint256 deadline);

    /// @notice Error thrown when attempting to execute an expired task
    /// @param expiration The block number when the task expired
    /// @param currentBlock The current block number
    error TaskExpired(uint256 expiration, uint256 currentBlock);

    /// @notice Error thrown when a transaction requires ETH value but none was sent
    error MustHaveMsgValue();

    /// @notice Error thrown when detecting a potential reentrancy attack
    error Reentrancy();

    /// @notice Error thrown when the message sender type is not recognized
    error UnknownMsgSenderType();

    /// @notice Error thrown when MON token transfer to a session key fails
    /// @param sessionKeyAddress The address of the session key that failed to receive MON
    error SessionKeyMonTransferFailed(address sessionKeyAddress);
}
