//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IShMonad } from "../../../shmonad/interfaces/IShMonad.sol";
import { SessionKey, CallerType } from "../types/GasRelayTypes.sol";
import { GasRelayConstants } from "./GasRelayConstants.sol";

/// @title GasRelayHelper
/// @notice Helper functions for session key and ShMONAD interactions
/// @dev Contains utility functions for the gas relay system
abstract contract GasRelayHelper is GasRelayConstants {
    /// @notice Emitted when a session key is removed
    /// @param sessionKeyAddress Address of the removed session key
    /// @param owner Address of the owner
    /// @param applicationEntrypoint Address of the application entrypoint
    /// @param remainingBalance Remaining balance in the session key
    event SessionKeyRemoved(
        address sessionKeyAddress,
        address indexed owner,
        address indexed applicationEntrypoint,
        uint256 remainingBalance
    );

    /// @notice Get the abstracted msg.sender and contextual data
    /// @dev Returns the original owner address when called by a session key
    /// @return Address of the abstracted msg.sender
    /// @return expiration Block number that session key expires
    /// @return isSessionKey bool indicating that the abstracted msg.sender is a session key
    /// @return isTask bool indicating that the abstracted msg.sender is a task
    function _abstractedMsgSenderWithContext()
        internal
        view
        virtual
        returns (address, uint256, bool isSessionKey, bool isTask)
    {
        // NOTE: We use transient storage so that apps can access this value inside of a try/catch,
        // which is a useful pattern if they still want to handle the gas reimbursement of a gas abstracted
        // transaction in scenarios in which the users' call would revert.

        (address _underlyingMsgSender, bool _isCallerSessionKey, bool _isCallerTask, bool _isInUse) =
            _loadUnderlyingMsgSenderData();

        if (!_isInUse) {
            return (msg.sender, 0, false, false);
        }

        // If owner is calling as itself, treat expiration as infinite
        if (!_isCallerSessionKey && !_isCallerTask) {
            return (msg.sender, type(uint64).max, false, false);
        }

        if (msg.sender == address(this) || msg.sender == _underlyingMsgSender) {
            (address _owner, uint256 _expiration) = _loadAbstractedMsgSenderWithExpiration(_underlyingMsgSender);
            if (_owner != address(0) && _expiration > block.number) {
                return (_owner, _expiration, _isCallerSessionKey, _isCallerTask);
            }
        }
        return (msg.sender, 0, false, false);
    }

    /// @notice Calculate the deficit between current and target balance for a session key
    /// @param account Address of the session key
    /// @return deficit Amount needed to reach target balance
    function _sessionKeyBalanceDeficit(address account) internal view returns (uint256 deficit) {
        if (account == address(0)) {
            return 0;
        }
        uint256 _targetBalance = _targetSessionKeyBalance();
        uint256 _currentBalance = address(account).balance;
        if (_targetBalance > _currentBalance) {
            return _targetBalance - _currentBalance;
        }
        return 0;
    }

    /// @notice Calculate the target balance for session keys
    /// @return targetBalance Target balance in wei
    function _targetSessionKeyBalance() internal view returns (uint256 targetBalance) {
        uint256 _gasRate = tx.gasprice > block.basefee ? tx.gasprice : block.basefee;
        _gasRate = _gasRate * _BASE_FEE_MAX_INCREASE / _BASE_FEE_DENOMINATOR;
        // Use direct multiplication instead of bit shifting
        (uint256 _maxExpectedGasUsage, uint256 _targetBalanceMultipler) = _GAS_USAGE_AND_MULTIPLIER();
        targetBalance = (_maxExpectedGasUsage * _gasRate) * _targetBalanceMultipler;
    }

    /// @notice Check if the contract is currently in use (reentrancy check)
    /// @return inUse True if the contract is in use
    function _inUse() internal view returns (bool inUse) {
        // Check if the transient storage has the IN_USE_BIT set
        bytes32 _underlyingCallerTransientSlot = _UNDERLYING_CALLER_NAMESPACE();
        bytes32 _packedUnderlyingCaller;
        assembly {
            _packedUnderlyingCaller := tload(_underlyingCallerTransientSlot)
        }
        inUse = _packedUnderlyingCaller & _IN_USE_BIT != 0;
    }

    /// @notice Check for reentrancy and revert if detected
    function _checkForReentrancy() internal view {
        // Revert if we detect reentrancy
        if (_inUse()) {
            revert Reentrancy();
        }
    }

    /// @notice Lock the contract against reentrancy
    function _lock() internal {
        bytes32 _underlyingCallerTransientSlot = _UNDERLYING_CALLER_NAMESPACE();
        assembly {
            tstore(_underlyingCallerTransientSlot, _IN_USE_BIT)
        }
    }

    /// @notice Lock the contract against reentrancy
    /// @param preserveUnderlyingCaller bool that determines whether the packed caller data is preserved when unlocking
    /// @dev Set preserveUnderlyingCaller to false unless you are 100% confident that you need to access the data again
    /// later
    // and you either dont need reentrancy protection or you are using another mechanism that protects from reentrancy.
    function _unlock(bool preserveUnderlyingCaller) internal {
        bytes32 _underlyingCallerTransientSlot = _UNDERLYING_CALLER_NAMESPACE();
        if (!preserveUnderlyingCaller) {
            assembly {
                tstore(
                    _underlyingCallerTransientSlot, 0x0000000000000000000000000000000000000000000000000000000000000000
                )
            }
        } else {
            assembly {
                let _packedUnderlyingCaller := tload(_underlyingCallerTransientSlot)
                tstore(_underlyingCallerTransientSlot, and(_packedUnderlyingCaller, _NOT_IN_USE_BITMASK))
            }
        }
    }

    /// @notice Load abstracted msg sender data from transient storage
    /// @param underlyingMsgSender Address of the underlying msg sender
    /// @return abstractedMsgSender Address of the session key or task's owner
    /// @return valid Bool indicating if the session key is valid
    function _loadAbstractedMsgSenderData(address underlyingMsgSender)
        internal
        view
        returns (address abstractedMsgSender, bool valid)
    {
        if (underlyingMsgSender == address(0) || underlyingMsgSender == address(this)) {
            return (address(0), false);
        }
        SessionKey memory _sessionKey = _loadSessionKey(underlyingMsgSender);
        abstractedMsgSender = _sessionKey.owner;
        valid = abstractedMsgSender != address(0) && uint256(_sessionKey.expiration) > block.number;
    }

    /// @notice Load abstracted msg sender and expiration from transient storage
    /// @param underlyingMsgSender Address of the underlying msg sender
    /// @return abstractedMsgSender Address of the session key or task's owner
    /// @return expiration Block number that session key expires
    function _loadAbstractedMsgSenderWithExpiration(address underlyingMsgSender)
        internal
        view
        returns (address abstractedMsgSender, uint256 expiration)
    {
        if (underlyingMsgSender == address(0) || underlyingMsgSender == address(this)) {
            return (address(0), uint256(0));
        }
        SessionKey memory _sessionKey = _loadSessionKey(underlyingMsgSender);
        abstractedMsgSender = _sessionKey.owner;
        expiration = uint256(_sessionKey.expiration);
    }

    /// @notice Store underlying msg sender in transient storage
    function _storeUnderlyingMsgSender(CallerType callerType) internal {
        // NOTE: Apps wishing to update the underlying msg sender multiple times in the same
        // tx should use the _unlock(false) command first.
        if (msg.sender == address(this)) return;

        // NOTE: We do not let smart contracts use session keys. EIP-7702-enabled wallets
        // should already benefit from "session key" usage and will get treated as a
        // default owner, which results in the same UX. The exception is if it's a task.
        if (address(msg.sender).code.length != 0 && callerType != CallerType.Task) return;

        bytes32 _packedUnderlyingCaller;

        if (callerType == CallerType.Owner) {
            _packedUnderlyingCaller = bytes32(uint256(uint160(address(msg.sender)))) | _IN_USE_BIT;
        } else if (callerType == CallerType.SessionKey) {
            _packedUnderlyingCaller = bytes32(uint256(uint160(address(msg.sender)))) | _IN_USE_AS_SESSION_KEY_BITS;
        } else if (callerType == CallerType.Task) {
            _packedUnderlyingCaller = bytes32(uint256(uint160(address(msg.sender)))) | _IN_USE_AS_TASK_BITS;
        } else {
            revert UnknownMsgSenderType();
        }
        bytes32 _underlyingCallerTransientSlot = _UNDERLYING_CALLER_NAMESPACE();
        assembly {
            tstore(_underlyingCallerTransientSlot, _packedUnderlyingCaller)
        }
    }

    /// @notice Load underlying msg sender data from transient storage
    /// @return underlyingMsgSender Address of the underlying msg sender (embedded wallet / bundler)
    /// @return isSessionKey Whether the caller is using a session key
    /// @return isTask Whether the caller is a task
    /// @return inUse Whether the contract is in use
    function _loadUnderlyingMsgSenderData()
        internal
        view
        returns (address underlyingMsgSender, bool isSessionKey, bool isTask, bool inUse)
    {
        bytes32 _underlyingCallerTransientSlot = _UNDERLYING_CALLER_NAMESPACE();
        bytes32 _packedUnderlyingCaller;
        assembly {
            _packedUnderlyingCaller := tload(_underlyingCallerTransientSlot)
            underlyingMsgSender :=
                and(_packedUnderlyingCaller, 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff)
        }
        isSessionKey = _packedUnderlyingCaller & _IS_SESSION_KEY_BIT != 0;
        isTask = _packedUnderlyingCaller & _IS_TASK_BIT != 0;
        inUse = _packedUnderlyingCaller & _IN_USE_BIT != 0;
    }

    /// @notice Update a session key's data
    /// @param sessionKeyAddress Address of the session key
    /// @param isTask Bool indicating if this is a task
    /// @param owner Address of the owner
    /// @param expiration Block number when the session key expires
    function _updateSessionKey(address sessionKeyAddress, bool isTask, address owner, uint256 expiration) internal {
        if (sessionKeyAddress == owner) {
            revert SessionKeyCantOwnSelf();
        }
        if (expiration > type(uint64).max) {
            revert SessionKeyExpirationInvalid(expiration);
        }

        if (!isTask) {
            address _existingSessionKeyAddress;
            bytes32 _keyOwnerStorageSlot = keccak256(abi.encodePacked(owner, _KEY_OWNER_NAMESPACE()));
            assembly {
                _existingSessionKeyAddress := sload(_keyOwnerStorageSlot)
            }

            if (sessionKeyAddress != _existingSessionKeyAddress) {
                if (_existingSessionKeyAddress != address(0)) {
                    _deactivateSessionKey(_existingSessionKeyAddress);
                }
                assembly {
                    sstore(_keyOwnerStorageSlot, sessionKeyAddress)
                }
            }
        }

        if (sessionKeyAddress != address(0)) {
            bytes32 _sessionKeyStorageSlot = keccak256(abi.encodePacked(sessionKeyAddress, _SESSION_KEY_NAMESPACE()));
            if (isTask) {
                assembly {
                    // Pack the owner and expiration, clear the expiredNotified flag
                    let _packedTaskSessionKey := or(or(owner, shl(192, expiration)), _IS_TASK_BIT)
                    sstore(_sessionKeyStorageSlot, _packedTaskSessionKey)
                }
            } else {
                assembly {
                    // Pack the owner and expiration, clear the expiredNotified flag
                    let _packedSessionKey := or(owner, shl(192, expiration))
                    sstore(_sessionKeyStorageSlot, _packedSessionKey)
                }
            }
        }
    }

    /// @notice Deactivate a session key
    /// @param sessionKeyAddress Address of the session key to deactivate
    function _deactivateSessionKey(address sessionKeyAddress) internal {
        bytes32 _sessionKeyStorageSlot = keccak256(abi.encodePacked(sessionKeyAddress, _SESSION_KEY_NAMESPACE()));
        uint256 _expiration;
        bytes32 _packedSessionKey;
        assembly {
            _packedSessionKey := sload(_sessionKeyStorageSlot)
            _expiration :=
                and(shr(192, _packedSessionKey), 0x000000000000000000000000000000000000000000000000ffffffffffffffff)
        }
        if (_expiration > 0) {
            address _owner;
            assembly {
                sstore(
                    _sessionKeyStorageSlot,
                    and(_packedSessionKey, 0x0000000000000000ffffffffffffffffffffffffffffffffffffffffffffffff)
                )
                _owner := and(_packedSessionKey, 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff)
            }
            emit SessionKeyRemoved(sessionKeyAddress, _owner, address(this), address(sessionKeyAddress).balance);
        }
    }

    /// @notice Get session key address for an owner
    /// @param ownerAddress Address of the owner
    /// @return sessionKeyAddress Address of the session key
    function _getSessionKeyAddress(address ownerAddress) internal view returns (address sessionKeyAddress) {
        bytes32 _keyOwnerStorageSlot = keccak256(abi.encodePacked(ownerAddress, _KEY_OWNER_NAMESPACE()));
        assembly {
            sessionKeyAddress := sload(_keyOwnerStorageSlot)
        }
    }

    /// @notice Load session key data
    /// @param sessionKeyAddress Address of the session key
    /// @return sessionKey Session key data
    function _loadSessionKey(address sessionKeyAddress) internal view returns (SessionKey memory sessionKey) {
        bytes32 _sessionKeyStorageSlot = keccak256(abi.encodePacked(sessionKeyAddress, _SESSION_KEY_NAMESPACE()));
        address _owner;
        uint256 _expiration;
        bool _isTask;
        assembly {
            let _packedSessionKey := sload(_sessionKeyStorageSlot)
            _owner := and(_packedSessionKey, 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff)
            _expiration :=
                and(shr(192, _packedSessionKey), 0x000000000000000000000000000000000000000000000000ffffffffffffffff)
            _isTask := gt(and(_packedSessionKey, _IS_TASK_BIT), 0)
        }
        sessionKey.owner = _owner;
        sessionKey.expiration = uint64(_expiration);
        sessionKey.isTask = _isTask;
    }

    /// @notice Load session key from owner address
    /// @param ownerAddress Address of the owner
    /// @return sessionKey Session key data
    function _loadSessionKeyFromOwner(address ownerAddress) internal view returns (SessionKey memory sessionKey) {
        address _sessionKeyAddress = _getSessionKeyAddress(ownerAddress);
        if (_sessionKeyAddress != address(0)) {
            sessionKey = _loadSessionKey(_sessionKeyAddress);
        }
        // NOTE: To save gas costs, task-based session keys cannot currently be loaded by owner.
        // If you need this functionality, please let us know.
    }

    /// @notice Credit shares to owner and bond to policy
    /// @param owner Address of the owner
    /// @param shares Number of shares to credit
    function _creditToOwnerAndBond(address owner, uint256 shares) internal {
        IShMonad(SHMONAD).bond(POLICY_ID(), owner, shares);
    }

    /// @notice Take shares from owner's bonded balance
    /// @param owner Address of the owner
    /// @param shares Number of shares to take
    function _takeFromOwnerBondedShares(address owner, uint256 shares) internal {
        IShMonad(SHMONAD).agentTransferToUnbonded(POLICY_ID(), owner, address(this), shares, 0, false);
    }

    /// @notice Take amount from owner's bonded balance
    /// @param owner Address of the owner
    /// @param amount Amount to take
    function _takeFromOwnerBondedAmount(address owner, uint256 amount) internal {
        IShMonad(SHMONAD).agentTransferToUnbonded(POLICY_ID(), owner, address(this), amount, 0, true);
    }

    /// @notice Take amount in underlying tokens from owner's bonded balance
    /// @param owner Address of the owner
    /// @param amount Amount to take
    function _takeFromOwnerBondedAmountInUnderlying(address owner, uint256 amount) internal {
        IShMonad(SHMONAD).agentWithdrawFromBonded(POLICY_ID(), owner, address(this), amount, 0, true);
    }

    /// @notice Get shares bonded to this contract for an owner
    /// @param owner Address of the owner
    /// @return shares Number of shares bonded
    function _sharesBondedToThis(address owner) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).balanceOfBonded(POLICY_ID(), owner);
    }

    /// @notice Get amount bonded to this contract for an owner
    /// @param owner Address of the owner
    /// @return amount Amount bonded
    function _amountBondedToThis(address owner) internal view returns (uint256 amount) {
        amount = _convertWithdrawnShMonToMon(IShMonad(SHMONAD).balanceOfBonded(POLICY_ID(), owner));
    }

    /// @notice Get shares unbonding from this contract for an owner
    /// @param owner Address of the owner
    /// @return shares Number of shares unbonding
    function _sharesUnbondingFromThis(address owner) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).balanceOfUnbonding(POLICY_ID(), owner);
    }

    /// @notice Boost yield with shares
    /// @param shares Number of shares for yield boost
    function _boostYieldShares(uint256 shares) internal {
        IShMonad(SHMONAD).boostYield(shares, address(this));
    }

    /// @notice Boost yield with MON
    /// @param amount Amount of MON for yield boost
    function _boostYieldAmount(uint256 amount) internal {
        IShMonad(SHMONAD).boostYield{ value: amount }();
    }

    /// @dev Returns the number of shMON shares you need to withdraw to receive input MON amount.
    /// @notice Convert MON to ShMON
    /// @param amount Amount of MON to convert
    /// @return shares Equivalent amount in ShMON shares
    function _convertMonToWithdrawnShMon(uint256 amount) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).previewWithdraw(amount);
    }

    /// @dev Returns the MON amount you'll receive if you withdraw the input shMON shares.
    /// @notice Convert ShMON to MON
    /// @param shares Number of ShMON shares to convert
    /// @return amount Equivalent amount in MON
    function _convertWithdrawnShMonToMon(uint256 shares) internal view returns (uint256 amount) {
        amount = IShMonad(SHMONAD).previewRedeem(shares);
    }

    /// @dev Returns the number of shMON shares you'll receive if you deposit the input MON amount.
    /// @notice Convert MON to ShMON
    /// @param amount Amount of MON to convert
    /// @return shares Equivalent amount in ShMON shares
    function _convertDepositedMonToShMon(uint256 amount) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).previewDeposit(amount);
    }

    /// @dev Returns the MON amount you'll need to deposit to receive the input shMON shares.
    /// @notice Convert ShMON to MON
    /// @param shares Number of ShMON shares to convert
    /// @return amount Equivalent amount in MON
    function _convertShMonToDepositedMon(uint256 shares) internal view returns (uint256 amount) {
        amount = IShMonad(SHMONAD).previewMint(shares);
    }

    /// @notice Deposit MON and bond for a recipient
    /// @param bondRecipient Address of the bond recipient
    /// @param amount Amount to deposit and bond
    function _depositMonAndBondForRecipient(address bondRecipient, uint256 amount) internal {
        IShMonad(SHMONAD).depositAndBond{ value: amount }(POLICY_ID(), bondRecipient, type(uint256).max);
    }
}
