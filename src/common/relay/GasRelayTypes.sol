//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SessionKey
/// @notice Data structure for session key information
/// @dev Stores the owner and expiration time of a session key
struct SessionKey {
    /// @notice Address of the owner of this session key
    address owner;
    /// @notice Block number when this session key expires
    uint64 expiration; // block number
}

/// @title SessionKeyData
/// @notice Extended data structure for session key information with balance data
/// @dev Used for returning comprehensive session key information
struct SessionKeyData {
    /// @notice Address of the owner of this session key
    address owner;
    /// @notice Address of the session key
    address key;
    /// @notice Current balance of the session key in MON
    uint256 balance; // In MON
    /// @notice Target balance for the session key in MON
    uint256 targetBalance; // In MON
    /// @notice Amount committed by the owner in MON
    uint256 ownerCommittedAmount; // In MON
    /// @notice Shares committed by the owner in shMON
    uint256 ownerCommittedShares; // In shMON
    /// @notice Block number when this session key expires
    uint64 expiration; // block number
}

/// @title GasAbstractionTracker
/// @notice Tracks gas abstraction state during a transaction
/// @dev Used to manage gas reimbursement and session key information
struct GasAbstractionTracker {
    /// @notice Whether a session key is being used for this transaction
    bool usingSessionKey;
    /// @notice Address of the owner (original sender)
    address owner;
    /// @notice Address of the session key
    address key;
    /// @notice Block number when the session key expires
    uint64 expiration; // block number
    /// @notice Gas remaining at the start of the transaction
    uint256 startingGasLeft;
    /// @notice Credit accumulated in shMON
    uint256 credits; // in shMON
}
