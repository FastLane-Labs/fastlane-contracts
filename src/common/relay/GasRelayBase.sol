//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITaskManager } from "../../task-manager/interfaces/ITaskManager.sol";
import { IShMonad } from "../../shmonad/interfaces/IShMonad.sol";
import { SessionKey, SessionKeyData, GasAbstractionTracker } from "./GasRelayTypes.sol";
import { GasRelayHelper } from "./GasRelayHelper.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GasRelayBase
/// @notice Core contract for gas abstraction and session key management
/// @dev Implements the main entry points and modifiers for gas abstraction
contract GasRelayBase is GasRelayHelper {
    /// @notice Constructor for GasRelayBase
    /// @param taskManager Address of the task manager contract
    /// @param shMonad Address of the ShMonad protocol
    /// @param maxExpectedGasUsagePerTx Maximum gas expected to be used per transaction
    /// @param escrowDuration Duration in blocks for ShMonad policy escrow
    /// @param targetBalanceMultiplier Multiplier for target balance calculation (1=1x, 2=2x, etc.)
    constructor(
        address taskManager,
        address shMonad,
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier
    )
        GasRelayHelper(taskManager, shMonad, maxExpectedGasUsagePerTx, escrowDuration, targetBalanceMultiplier)
    { }

    /// @notice Get current session key data for an owner
    /// @param owner Address of the owner
    /// @return sessionKeyData Struct containing all session key information
    function getCurrentSessionKeyData(address owner) public view returns (SessionKeyData memory sessionKeyData) {
        if (owner == address(0)) {
            return sessionKeyData;
        }

        sessionKeyData.owner = owner;
        sessionKeyData.ownerCommittedShares = _sharesBondedToThis(owner);
        sessionKeyData.ownerCommittedAmount = _convertWithdrawnShMonToMon(sessionKeyData.ownerCommittedShares);
        if (sessionKeyData.ownerCommittedAmount > 0) --sessionKeyData.ownerCommittedAmount; // Rounding

        address key = _getSessionKeyAddress(sessionKeyData.owner);
        sessionKeyData.targetBalance = _targetSessionKeyBalance();

        if (key == address(0)) {
            return sessionKeyData;
        }

        sessionKeyData.key = key;
        sessionKeyData.balance = address(key).balance;
        sessionKeyData.expiration = _loadSessionKey(key).expiration;

        return sessionKeyData;
    }

    /// @notice Create or update a session key
    /// @dev Set sessionKeyAddress to address(0) or expiration to 0 will deactivate a session key
    /// @dev Must be called by owner
    /// @param sessionKeyAddress Address of the session key to update
    /// @param expiration Block number when the session key expires
    function updateSessionKey(address sessionKeyAddress, uint256 expiration) external payable Locked {
        // Update session key mapping and metadata
        _updateSessionKey(sessionKeyAddress, msg.sender, expiration);

        // No further action needed if deactivating key or no funds provided
        if (msg.value == 0 || sessionKeyAddress == address(0) || expiration <= block.number) {
            return;
        }

        // Calculate funding requirements for the session key
        uint256 _deficit = _sessionKeyBalanceDeficit(sessionKeyAddress);
        uint256 _fundingAmount = msg.value >= _deficit ? _deficit : msg.value;
        uint256 _surplusAmount = msg.value - _fundingAmount;

        // Transfer MON to session key first to prevent reentracy risks
        if (_fundingAmount > 0) {
            (bool success,) = sessionKeyAddress.call{ value: _fundingAmount }("");
            if (!success) {
                revert SessionKeyMonTransferFailed(sessionKeyAddress);
            }
        }

        // Bond any surplus after MON transfer is complete
        if (_surplusAmount > 0) {
            _depositMonAndBondForRecipient(msg.sender, _surplusAmount);
        }
    }

    /// @notice Replenish the gas balance of the caller's session key
    /// @dev If caller doesn't have an active session key, bonds the entire amount
    function replenishGasBalance() external payable Locked {
        if (msg.value == 0) {
            revert MustHaveMsgValue();
        }

        address _sessionKeyAddress = _getSessionKeyAddress(msg.sender);
        // If no active session key, bond the entire amount
        if (_sessionKeyAddress == address(0) || _loadSessionKey(_sessionKeyAddress).expiration <= block.number) {
            _depositMonAndBondForRecipient(msg.sender, msg.value);
            return;
        }

        // Calculate how much MON the session key needs
        uint256 _deficit = _sessionKeyBalanceDeficit(_sessionKeyAddress);
        uint256 _fundingAmount = msg.value >= _deficit ? _deficit : msg.value;
        uint256 _surplusAmount = msg.value - _fundingAmount;

        // Transfer MON to session key first to prevent reentracy risks
        if (_fundingAmount > 0) {
            (bool _success,) = _sessionKeyAddress.call{ value: _fundingAmount }("");
            if (!_success) {
                revert SessionKeyMonTransferFailed(_sessionKeyAddress);
            }
        }

        // Bond any surplus after MON transfer is complete
        if (_surplusAmount > 0) {
            _depositMonAndBondForRecipient(msg.sender, _surplusAmount);
        }
    }

    /// @notice Deactivate a session key
    /// @dev Can be called by either owner or the session key itself
    /// @dev A session key can't renew or extend itself
    /// @param sessionKeyAddress Address of the session key to deactivate
    function deactivateSessionKey(address sessionKeyAddress) external payable Locked {
        // Validate caller
        address _owner;
        if (sessionKeyAddress == msg.sender) {
            _owner = _loadSessionKey(sessionKeyAddress).owner;
        } else if (sessionKeyAddress == _getSessionKeyAddress(msg.sender)) {
            _owner = msg.sender;
        } else {
            revert InvalidSessionKeyOwner();
        }

        _updateSessionKey(sessionKeyAddress, _owner, 0);
        if (msg.value > 0) {
            _depositMonAndBondForRecipient(_owner, msg.value);
        }
    }

    /// @notice Modifier to create or update a session key with funding
    /// @dev msg.sender should be the address that owns the sessionKeyAddress, NOT the sessionKeyAddress itself
    /// @param sessionKeyAddress Address of the session key
    /// @param owner Address of the owner
    /// @param sessionKeyExpiration Block number when the session key expires
    /// @param depositValue Amount of MON to deposit
    modifier CreateOrUpdateSessionKey(
        address sessionKeyAddress,
        address owner,
        uint256 sessionKeyExpiration,
        uint256 depositValue
    ) {
        _checkForReentrancy();
        _lock();

        // Validate session key parameters and update if valid
        bool _isSessionKeyValid = sessionKeyAddress != address(0) && sessionKeyExpiration > block.number
            && owner == msg.sender && sessionKeyAddress != owner;

        if (_isSessionKeyValid) {
            _updateSessionKey(sessionKeyAddress, owner, sessionKeyExpiration);

            // Fund session key with required balance
            uint256 _deficit = _sessionKeyBalanceDeficit(sessionKeyAddress);
            uint256 _fundingAmount = depositValue >= _deficit ? _deficit : depositValue;
            uint256 _minSharesNeeded = _minBondedShares(owner);

            if (_fundingAmount > 0 && _minSharesNeeded > 0) {
                uint256 _sharesAvailable = _sharesBondedToThis(owner);
                if (_minSharesNeeded > _sharesAvailable) {
                    uint256 _reservedBondedAmount = _convertWithdrawnShMonToMon(_minSharesNeeded - _sharesAvailable);
                    if (_fundingAmount > _reservedBondedAmount) {
                        _fundingAmount -= _reservedBondedAmount;
                    } else {
                        _fundingAmount = 0;
                    }
                }
            }
            uint256 _surplusAmount = depositValue - _fundingAmount;

            // Transfer MON to session key first
            if (_fundingAmount > 0) {
                (bool success,) = sessionKeyAddress.call{ value: _fundingAmount }("");
                if (!success) {
                    revert SessionKeyMonTransferFailed(sessionKeyAddress);
                }
                depositValue = _surplusAmount; // Update depositValue to remaining amount
            }
        }

        // Bond any surplus after session key is funded
        if (depositValue > 0) {
            _depositMonAndBondForRecipient(owner, depositValue);
        }

        // Set the transaction sender context
        _storeUnderlyingMsgSender(false);

        // Execute the decorated function
        _;

        // Use remaining gas to execute pending tasks if sufficient gas remains
        if (gasleft() > _MIN_TASK_EXECUTION_GAS + _TASK_MANAGER_EXECUTION_GAS_BUFFER + _MIN_REMAINDER_GAS_BUFFER) {
            uint256 _sharesEarned = ITaskManager(TASK_MANAGER).executeTasks(address(this), _MIN_REMAINDER_GAS_BUFFER);
            if (_sharesEarned > 0) {
                _creditToOwnerAndBond(owner, _sharesEarned);
            }
        }

        // Clean up the transaction context
        _unlock(false);
    }

    /// @notice Modifier for gas abstraction via session keys
    /// @dev Handles detection of session keys, gas reimbursement, and task execution
    modifier GasAbstracted() {
        _checkForReentrancy();
        // NOTE: Locking is handled inside the _startShMonadGasAbstraction method.

        // Initialize gas abstraction tracking and identify session key
        GasAbstractionTracker memory gasAbstractionTracker = _startShMonadGasAbstraction(msg.sender);

        // Execute the intended function
        _;

        // Process unused gas through task manager if possible
        gasAbstractionTracker = _handleUnusedGas(gasAbstractionTracker, _MIN_REMAINDER_GAS_BUFFER);

        // Handle gas reimbursement for the transaction
        _finishShMonadGasAbstraction(gasAbstractionTracker);

        // Clean up the transaction context
        _unlock(false);
    }

    /// @notice Modifier that provides reentrancy protection
    /// @dev Locks transient storage during execution and clears it after
    modifier Locked() {
        _checkForReentrancy();
        _lock();

        _;

        _unlock(false);
    }

    /// @notice Get the abstracted msg.sender
    /// @dev Returns the original owner address when called by a session key
    /// @return Address of the abstracted msg.sender
    function _abstractedMsgSender() internal view virtual returns (address) {
        // NOTE: We use transient storage so that apps can access this value inside of a try/catch,
        // which is a useful pattern if they still want to handle the gas reimbursement of a gas abstracted
        // transaction in scenarios in which the users' call would revert.

        (address _underlyingMsgSender, bool _isCallerSessionKey, bool _inUse) = _loadUnderlyingMsgSenderData();

        if (!_isCallerSessionKey || !_inUse) {
            return msg.sender;
        }

        if (msg.sender == address(this) || msg.sender == _underlyingMsgSender) {
            (address _owner, bool _valid) = _loadAbstractedMsgSenderData(_underlyingMsgSender);
            if (_valid) {
                return _owner;
            }
        }
        return msg.sender;
    }

    /// @notice Get the min bonded shares that an account must have. Allocating
    /// gas to the session key will not drop the bonded shares below this value.
    /// This function is designed to be overriden based on app-specific commitment needs.
    /// @dev Returns the minimum bonded balance
    /// @return shares in shMON that the bonded balance cannot drop below while replenishing
    /// session key gas.
    function _minBondedShares(address account) internal view virtual returns (uint256 shares) {
        shares = 0;
    }

    /// @notice Check if the current caller is a session key
    /// @return isSessionKey True if the caller is a session key
    function _isSessionKey() internal view returns (bool isSessionKey) {
        (, isSessionKey,) = _loadUnderlyingMsgSenderData();
    }

    /// @notice Handles unused gas by executing tasks
    /// @param gasAbstractionTracker The gas abstraction tracker
    /// @param minRemainderGas Minimum gas to leave for the remainder of the transaction
    /// @return Updated gas abstraction tracker
    function _handleUnusedGas(
        GasAbstractionTracker memory gasAbstractionTracker,
        uint256 minRemainderGas
    )
        internal
        returns (GasAbstractionTracker memory)
    {
        uint256 _gasTarget = gasleft();
        // Make sure we have enough gas remaining for the app to finish its call
        if (_gasTarget < minRemainderGas + _MIN_REMAINDER_GAS_BUFFER) {
            return gasAbstractionTracker;
        }
        _gasTarget -= minRemainderGas + _MIN_REMAINDER_GAS_BUFFER;

        // Make sure the gasTarget is large enough to execute a small task
        if (_gasTarget < _MIN_TASK_EXECUTION_GAS + _TASK_MANAGER_EXECUTION_GAS_BUFFER) {
            return gasAbstractionTracker;
        }

        // Call task manager to execute tasks and get reimbursed for unused gas
        if (gasAbstractionTracker.usingSessionKey) {
            gasAbstractionTracker.credits +=
                ITaskManager(TASK_MANAGER).executeTasks{ gas: _gasTarget }(address(this), minRemainderGas);
        } else {
            ITaskManager(TASK_MANAGER).executeTasks{ gas: _gasTarget }(msg.sender, minRemainderGas);
        }
        return gasAbstractionTracker;
    }

    /// @notice Start the ShMonad gas abstraction process
    /// @param caller Address of the caller (potential session key)
    /// @return gasAbstractionTracker The gas abstraction tracker with initial data
    function _startShMonadGasAbstraction(address caller)
        internal
        returns (GasAbstractionTracker memory gasAbstractionTracker)
    {
        // NOTE: Assumes msg.sender is session key
        SessionKey memory _sessionKey = _loadSessionKey(caller);
        if (_sessionKey.owner != address(0) && uint64(block.number) < _sessionKey.expiration) {
            gasAbstractionTracker = GasAbstractionTracker({
                usingSessionKey: true,
                owner: _sessionKey.owner,
                key: caller,
                expiration: _sessionKey.expiration,
                startingGasLeft: gasleft() + _BASE_TX_GAS_USAGE + (msg.data.length * 16),
                credits: 0
            });
            _storeUnderlyingMsgSender(true);
        } else {
            gasAbstractionTracker = GasAbstractionTracker({
                usingSessionKey: false,
                owner: caller, // Beneficiary of any task execution credits
                key: address(0),
                expiration: 0,
                startingGasLeft: gasleft() + _BASE_TX_GAS_USAGE + (msg.data.length * 16),
                credits: 0
            });
            _storeUnderlyingMsgSender(false);
        }
        return gasAbstractionTracker;
    }

    /// @notice Finish ShMonad gas abstraction by handling reimbursements
    /// @param gasAbstractionTracker The gas abstraction tracker with usage data
    function _finishShMonadGasAbstraction(GasAbstractionTracker memory gasAbstractionTracker) internal {
        // Players gas abstract themselves with shMON - partial reimbursement is OK.
        // Don't do gas reimbursement if owner is caller
        // NOTE: Apps wishing to monetize shMON can easily build their own markup into these calculations,
        // ShMonad is permissionless.

        // Withdraw ShMON from owner's bonded and transfer MON to msg.sender to reimburse for gas
        // NOTE: Credits typically come from executor fees from task manager crank
        uint256 _credits = gasAbstractionTracker.credits;

        // We pay the full gas limit regardless of usage since execution is asynchronous
        uint256 _sharesNeeded = 0;

        if (gasAbstractionTracker.usingSessionKey) {
            uint256 _replacementGas = gasAbstractionTracker.startingGasLeft > _MAX_EXPECTED_GAS_USAGE_PER_TX
                ? _MAX_EXPECTED_GAS_USAGE_PER_TX
                : gasAbstractionTracker.startingGasLeft;
            uint256 _replacementAmount = Math.mulDiv(_replacementGas, tx.gasprice, 1);
            uint256 _deficitAmount = _sessionKeyBalanceDeficit(gasAbstractionTracker.key);

            if (_deficitAmount == 0) {
                _sharesNeeded = 0;
            } else if (_deficitAmount > _replacementAmount * _BASE_FEE_MAX_INCREASE / _BASE_FEE_DENOMINATOR) {
                // TODO: This needs more bespoke handling of base fee increases - will update once
                // Monad TX fee mechanism is published.
                _sharesNeeded =
                    _convertMonToWithdrawnShMon(_replacementAmount * _BASE_FEE_MAX_INCREASE / _BASE_FEE_DENOMINATOR);
            } else {
                _sharesNeeded = _convertMonToWithdrawnShMon(_deficitAmount);
            }
        }

        // Handle reimbursement scenarios based on available credits
        if (_credits >= _sharesNeeded) {
            // When credits are sufficient, refill the session key
            if (_sharesNeeded > 0) {
                // TODO: This will need to be updated to use the ClearingHouse's atomic unstaking function
                IShMonad(SHMONAD).redeem(_sharesNeeded, gasAbstractionTracker.key, address(this));
                _credits -= _sharesNeeded;
                _sharesNeeded = 0;
            }
        } else if (_sharesNeeded > _credits) {
            // When credits only cover part of the needed shares
            if (_credits > 0) {
                // TODO: This will need to be updated to use the ClearingHouse's atomic unstaking function
                IShMonad(SHMONAD).redeem(_credits, gasAbstractionTracker.key, address(this));
                _sharesNeeded -= _credits;
                _credits = 0;
            }
        }

        // Exit early if credits exactly matched needed shares
        if (_credits == _sharesNeeded) {
            return;
        } else if (_credits > _sharesNeeded) {
            // Return excess credits to owner
            // NOTE: _sharesNeeded should be zero
            _creditToOwnerAndBond(gasAbstractionTracker.owner, _credits);
        } else {
            uint256 _sharesAvailable = _sharesBondedToThis(gasAbstractionTracker.owner);
            uint256 _minSharesRemaining = _minBondedShares(gasAbstractionTracker.owner);
            if (_sharesAvailable > _minSharesRemaining) {
                _sharesAvailable -= _minSharesRemaining;

                if (_sharesNeeded > _sharesAvailable) {
                    _sharesNeeded = _sharesAvailable;
                }

                IShMonad(SHMONAD).agentWithdrawFromBonded(
                    POLICY_ID, gasAbstractionTracker.owner, gasAbstractionTracker.key, _sharesNeeded, 0, false
                );
            }
        }
    }

    /// @notice Handle session key funding from deposit and bonded tokens
    /// @param owner Address of the owner
    /// @param sessionKeyAddress Address of the session key
    /// @param deposit Amount of MON to deposit
    /// @return remainder Remaining MON after funding
    function _handleSessionKeyFunding(
        address owner,
        address sessionKeyAddress,
        uint256 deposit
    )
        internal
        returns (uint256 remainder)
    {
        uint256 _deficit = _sessionKeyBalanceDeficit(sessionKeyAddress);

        if (_deficit == 0) {
            return deposit;
        }

        // Determine funding allocation from deposit vs bonded tokens
        uint256 _amountFromDeposit = 0;
        uint256 _remainingDeficit = 0;

        if (deposit >= _deficit) {
            _amountFromDeposit = _deficit;
            remainder = deposit - _deficit;
        } else {
            _amountFromDeposit = deposit;
            _remainingDeficit = _deficit - deposit;
            remainder = 0;
        }

        // Transfer MON from deposit first
        if (_amountFromDeposit > 0) {
            (bool _success,) = sessionKeyAddress.call{ value: _amountFromDeposit }("");
            if (!_success) {
                revert SessionKeyMonTransferFailed(sessionKeyAddress);
            }
        }

        // Cover any remaining deficit from owner's bonded tokens
        if (_remainingDeficit > 0) {
            try IShMonad(SHMONAD).agentWithdrawFromBonded(
                POLICY_ID, owner, sessionKeyAddress, _remainingDeficit, 0, true
            ) {
                // Successfully withdrew from bonded tokens
            } catch {
                // Fall back to partial funding if full withdrawal fails
                uint256 _amountAvailable = _amountBondedToThis(owner);
                uint256 _amountToWithdraw = _amountAvailable > _remainingDeficit ? _remainingDeficit : _amountAvailable;
                if (_amountToWithdraw > 0) {
                    IShMonad(SHMONAD).agentWithdrawFromBonded(
                        POLICY_ID, owner, sessionKeyAddress, _amountToWithdraw, 0, true
                    );
                }
            }
        }

        return remainder;
    }

    /// @notice Find the next affordable block for task execution
    /// @param maxPayment Maximum payment available
    /// @param targetBlock Target block to start searching from
    /// @param highestAcceptableBlock Highest acceptable block
    /// @param maxTaskGas Maximum gas for task execution
    /// @param maxSearchGas Maximum gas to use for the search
    /// @return amountEstimated Estimated cost for the block
    /// @return Next affordable block number or 0 if none found
    function _getNextAffordableBlock(
        uint256 maxPayment,
        uint256 targetBlock,
        uint256 highestAcceptableBlock,
        uint256 maxTaskGas,
        uint256 maxSearchGas
    )
        internal
        view
        returns (uint256 amountEstimated, uint256)
    {
        uint256 _targetGasLeft = gasleft();

        // NOTE: This is an internal function and has no concept of how much gas
        // its caller needs to finish the call. If 'targetGasLeft' is set to zero and no profitable block is found prior
        // to running out
        // of gas, then this function will simply cause an EVM 'out of gas' error. The purpose of
        // the check below is to prevent an integer underflow, *not* to prevent an out of gas revert.
        if (_targetGasLeft < maxSearchGas) {
            _targetGasLeft = 0;
        } else {
            _targetGasLeft -= maxSearchGas;
        }

        uint256 i = 1;
        while (gasleft() > _targetGasLeft) {
            amountEstimated = _estimateTaskCost(targetBlock, maxTaskGas) + 1;

            if (targetBlock > highestAcceptableBlock) {
                return (0, 0);
            }

            // If block is too expensive, try jumping forwards
            if (amountEstimated > maxPayment) {
                // Distance between blocks increases incrementally as i increases.
                i += (i / 4 + 1);
                targetBlock += i;
            } else {
                return (amountEstimated, targetBlock);
            }
        }
        return (0, 0);
    }
}
