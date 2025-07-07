//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITaskManager } from "../../../task-manager/interfaces/ITaskManager.sol";
import { IShMonad } from "../../../shmonad/interfaces/IShMonad.sol";
import { SessionKey, SessionKeyData, GasAbstractionTracker, CallerType } from "../types/GasRelayTypes.sol";
import { GasRelayHelper } from "./GasRelayHelper.sol";
// import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GasRelayBase
/// @notice Core implementation of gas abstraction and session key management
/// @dev Provides the foundational logic for gas relaying, session key management, and transaction handling
abstract contract GasRelayBase is GasRelayHelper {
    uint256 private constant _NONZERO_CALLDATA_CHAR_COST = 16;
    /// @notice Retrieves current session key data for an owner
    /// @dev Returns a struct containing all relevant session key information including balances and expiration
    /// @param owner Address of the owner to query
    /// @return sessionKeyData Struct containing session key information, balances, and status

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

    /// @notice Creates or updates a session key with optional funding
    /// @dev Can deactivate a key by setting address to 0 or expiration to past block
    /// @param sessionKeyAddress Address of the session key to update
    /// @param expiration Block number when the session key expires
    function updateSessionKey(address sessionKeyAddress, uint256 expiration) external payable Locked {
        // Update session key mapping and metadata
        _updateSessionKey(sessionKeyAddress, false, msg.sender, expiration);

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

    /// @notice Adds funds to the caller's session key or bonds them if no active key exists
    /// @dev If caller has no active session key, the entire amount is bonded
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

    /// @notice Deactivates a session key and optionally bonds any provided funds
    /// @dev Can be called by either the owner or the session key itself
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

        _updateSessionKey(sessionKeyAddress, false, _owner, 0);
        if (msg.value > 0) {
            _depositMonAndBondForRecipient(_owner, msg.value);
        }
    }

    /// @notice Modifier that handles session key creation/update with funding
    /// @dev Manages the entire lifecycle of a session key operation including task execution
    /// @param sessionKeyAddress Address of the session key
    /// @param owner Address that will own the session key
    /// @param sessionKeyExpiration Block number when the session key expires
    /// @param depositValue Amount of MON to deposit for the session key
    modifier CreateOrUpdateSessionKey(
        address sessionKeyAddress,
        address owner,
        uint256 sessionKeyExpiration,
        uint256 depositValue
    ) {
        _checkForReentrancy();
        _lock();

        _createOrUpdateSessionKey(sessionKeyAddress, owner, sessionKeyExpiration, depositValue);

        // Execute the decorated function
        _;

        // Use remaining gas to execute pending tasks if sufficient gas remains
        _finishCreatingOrUpdatingSessionKey(owner);

        // Clean up the transaction context
        _unlock({ preserveUnderlyingCaller: false });
    }

    /// @notice Modifier that enables gas abstraction through session keys
    /// @dev Handles the complete gas abstraction flow including reimbursement and task execution
    modifier GasAbstracted() {
        // Initialize gas abstraction tracking and identify session key
        // NOTE: Locking and reentrancy checks are handled inside the _startShMonadGasAbstraction method.
        GasAbstractionTracker memory gasAbstractionTracker = _startShMonadGasAbstraction();

        // Execute the intended function
        _;

        // Clean up the transaction context
        _unlock({ preserveUnderlyingCaller: false });

        // Process unused gas through task manager if possible
        if (!gasAbstractionTracker.isTask) {
            gasAbstractionTracker = _handleUnusedGas(gasAbstractionTracker, _MIN_REMAINDER_GAS_BUFFER);
        }

        // Handle gas reimbursement for the transaction
        _finishShMonadGasAbstraction(gasAbstractionTracker);
    }

    /// @notice Modifier providing reentrancy protection using transient storage
    /// @dev Locks storage during execution and cleans up afterward
    modifier Locked() {
        _checkForReentrancy();
        _lock();

        _;

        _unlock(false);
    }

    /// @notice Returns the effective sender, resolving session keys to their owners
    /// @dev Uses transient storage to maintain sender context across try/catch blocks
    /// @return The resolved sender address (owner address for session keys, msg.sender otherwise)
    function _abstractedMsgSender() internal view virtual returns (address) {
        // NOTE: We use transient storage so that apps can access this value inside of a try/catch,
        // which is a useful pattern if they still want to handle the gas reimbursement of a gas abstracted
        // transaction in scenarios in which the users' call would revert.

        (address _underlyingMsgSender, bool _isCallerSessionKey, bool _isCallerTask, bool _inUse) =
            _loadUnderlyingMsgSenderData();

        if (!_inUse) {
            return msg.sender;
        }

        // If owner is calling as itself, pass it through the self.try/catch
        if (!_isCallerSessionKey && !_isCallerTask) {
            if (msg.sender == address(this) || msg.sender == _underlyingMsgSender) {
                return _underlyingMsgSender;
            }
        }

        if (msg.sender == address(this) || msg.sender == _underlyingMsgSender) {
            (address _owner, bool _valid) = _loadAbstractedMsgSenderData(_underlyingMsgSender);
            if (_valid) {
                return _owner;
            }
        }
        return msg.sender;
    }

    /// @notice Internal function to create or update a session key with funding
    /// @dev Handles validation, funding allocation, and context setup
    /// @param sessionKeyAddress Address of the session key
    /// @param owner Address that will own the session key
    /// @param sessionKeyExpiration Block number when the session key expires
    /// @param depositValue Amount of MON to deposit
    function _createOrUpdateSessionKey(
        address sessionKeyAddress,
        address owner,
        uint256 sessionKeyExpiration,
        uint256 depositValue
    )
        internal
    {
        // Validate session key parameters and update if valid
        bool _isSessionKeyValid = sessionKeyAddress != address(0) && sessionKeyExpiration > block.number
            && owner == msg.sender && sessionKeyAddress != owner;

        if (_isSessionKeyValid) {
            _updateSessionKey(sessionKeyAddress, false, owner, sessionKeyExpiration);

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
        _storeUnderlyingMsgSender(CallerType.Owner);
    }

    /// @notice Completes session key creation/update by executing pending tasks
    /// @dev Executes tasks if sufficient gas remains and credits rewards to the owner
    /// @param owner Address of the session key owner
    function _finishCreatingOrUpdatingSessionKey(address owner) internal {
        if (gasleft() > _MIN_TASK_EXECUTION_GAS + _TASK_MANAGER_EXECUTION_GAS_BUFFER + _MIN_REMAINDER_GAS_BUFFER) {
            uint256 _sharesEarned = ITaskManager(TASK_MANAGER).executeTasks(address(this), _MIN_REMAINDER_GAS_BUFFER);
            if (_sharesEarned > 0) {
                _creditToOwnerAndBond(owner, _sharesEarned);
            }
        }
    }

    /// @notice Returns minimum required bonded shares for an account
    /// @dev Can be overridden to implement custom bonding requirements
    /// @param account Address to check minimum bond requirement for
    /// @return shares Minimum required bonded shares in shMON
    function _minBondedShares(address account) internal view virtual returns (uint256 shares) {
        shares = 0;
    }

    /// @notice Checks if the current caller is a session key
    /// @dev Uses transient storage to determine caller type
    /// @return isSessionKey True if the caller is a session key
    function _isSessionKey() internal view returns (bool isSessionKey) {
        (, isSessionKey,,) = _loadUnderlyingMsgSenderData();
    }

    /// @notice Checks if the current caller is a task
    /// @dev Uses transient storage to determine caller type
    /// @return isTask True if the caller is a task
    function _isTask() internal view returns (bool isTask) {
        (,, isTask,) = _loadUnderlyingMsgSenderData();
    }

    /// @notice Processes unused gas by executing pending tasks
    /// @dev Executes tasks if sufficient gas remains and updates gas tracking
    /// @param gasAbstractionTracker Current gas tracking state
    /// @param minRemainderGas Minimum gas to reserve for transaction completion
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

    /// @notice Initializes gas abstraction for a transaction
    /// @dev Sets up tracking and context for gas abstraction handling
    /// @return gasAbstractionTracker Initial gas tracking state
    function _startShMonadGasAbstraction() internal returns (GasAbstractionTracker memory gasAbstractionTracker) {
        uint256 _startingGas = gasleft();
        if (_startingGas > _MAX_EXPECTED_GAS_USAGE_PER_TX()) {
            _startingGas = _MAX_EXPECTED_GAS_USAGE_PER_TX();
        } else {
            _startingGas += _BASE_TX_GAS_USAGE;
        }
        _startingGas += (msg.data.length * _NONZERO_CALLDATA_CHAR_COST);

        // Reentrancy check
        _checkForReentrancy();

        // NOTE: Assumes msg.sender is session key
        SessionKey memory _sessionKey = _loadSessionKey(msg.sender);

        // CASE: SessionKey is expired or invalid
        if (_sessionKey.owner == address(0) || uint64(block.number) >= _sessionKey.expiration) {
            if (_sessionKey.isTask) {
                revert TaskExpired(uint256(_sessionKey.expiration), block.number);
            }
            gasAbstractionTracker = GasAbstractionTracker({
                usingSessionKey: false,
                isTask: false,
                owner: msg.sender, // Beneficiary of any task execution credits
                key: address(0),
                expiration: 0,
                startingGasLeft: _startingGas,
                credits: 0
            });
            _storeUnderlyingMsgSender(CallerType.Owner);

            // CASE: SessionKey is a task
        } else if (_sessionKey.isTask) {
            gasAbstractionTracker = GasAbstractionTracker({
                usingSessionKey: true,
                isTask: true,
                owner: _sessionKey.owner,
                key: msg.sender,
                expiration: _sessionKey.expiration,
                startingGasLeft: _startingGas,
                credits: 0
            });
            _storeUnderlyingMsgSender(CallerType.Task);

            // CASE: Traditional SessionKey
        } else {
            gasAbstractionTracker = GasAbstractionTracker({
                usingSessionKey: true,
                isTask: false,
                owner: _sessionKey.owner,
                key: msg.sender,
                expiration: _sessionKey.expiration,
                startingGasLeft: _startingGas,
                credits: 0
            });
            _storeUnderlyingMsgSender(CallerType.SessionKey);
        }
        return gasAbstractionTracker;
    }

    /// @notice Completes gas abstraction by handling reimbursements
    /// @dev Manages credit distribution and session key refunding
    /// @param gasAbstractionTracker Final gas tracking state
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
        address _payee = gasAbstractionTracker.usingSessionKey ? gasAbstractionTracker.key : gasAbstractionTracker.owner;

        if (gasAbstractionTracker.usingSessionKey && !gasAbstractionTracker.isTask) {
            uint256 _gasPrice = tx.gasprice > block.basefee ? tx.gasprice : block.basefee;
            uint256 _replacementAmount = gasAbstractionTracker.startingGasLeft * _gasPrice;

            (uint256 _maxExpectedGasUsage, uint256 _targetBalanceMultipler) = _GAS_USAGE_AND_MULTIPLIER();
            uint256 _targetBalanceInGas = _maxExpectedGasUsage * _targetBalanceMultipler;
            uint256 _targetBalance = _targetBalanceInGas * _gasPrice;
            uint256 _actualBalance = address(gasAbstractionTracker.key).balance;

            if (_targetBalance < _actualBalance) {
                _sharesNeeded = _convertMonToWithdrawnShMon(_replacementAmount / _targetBalanceMultipler);
            } else if (_targetBalance < _actualBalance + _replacementAmount) {
                _sharesNeeded =
                    _convertMonToWithdrawnShMon(_replacementAmount * _BASE_FEE_MAX_DECREASE / _BASE_FEE_DENOMINATOR);
            } else if (_targetBalanceInGas * block.basefee < _actualBalance + _replacementAmount) {
                _sharesNeeded = _convertMonToWithdrawnShMon(_replacementAmount);
            } else {
                // CASE: _targetBalance > _actualBalance + _replacementAmount.
                uint256 _deficitWithPriority = _targetBalance - _actualBalance;
                _sharesNeeded = _convertMonToWithdrawnShMon(
                    ((_replacementAmount * _targetBalanceMultipler) + _deficitWithPriority)
                        / (_targetBalanceMultipler + 1)
                );
            }
        }

        // Exit early if credits exactly matched needed shares
        // NOTE: This will catch tasks too
        if (_credits == 0 && _sharesNeeded == 0) {
            return;
        }

        if (_credits > _sharesNeeded) {
            // Return excess credits to owner
            // NOTE: _sharesNeeded should be zero
            if (_sharesNeeded > 0) {
                IShMonad(SHMONAD).redeem(_sharesNeeded, _payee, address(this));
                _credits -= _sharesNeeded;
            }
            _creditToOwnerAndBond(gasAbstractionTracker.owner, _credits);
        } else {
            if (_credits > 0) {
                // TODO: This will need to be updated to use the ClearingHouse's atomic unstaking function
                IShMonad(SHMONAD).redeem(_credits, _payee, address(this));
                _sharesNeeded -= _credits;
            }

            if (_sharesNeeded > 0) {
                uint256 _sharesAvailable = _sharesBondedToThis(gasAbstractionTracker.owner);
                uint256 _minSharesRemaining = _minBondedShares(gasAbstractionTracker.owner);

                if (_sharesNeeded + _minSharesRemaining > _sharesAvailable) {
                    uint256 _topUpAvailable =
                        IShMonad(SHMONAD).topUpAvailable(POLICY_ID(), gasAbstractionTracker.owner, false);
                    _sharesAvailable += _topUpAvailable;
                }

                if (_sharesAvailable > _minSharesRemaining) {
                    _sharesAvailable -= _minSharesRemaining;
                } else {
                    _sharesAvailable = 0;
                }

                if (_sharesAvailable >= _sharesNeeded) {
                    IShMonad(SHMONAD).agentWithdrawFromBonded(
                        POLICY_ID(), gasAbstractionTracker.owner, gasAbstractionTracker.key, _sharesNeeded, 0, false
                    );
                } else if (_sharesAvailable > 0) {
                    IShMonad(SHMONAD).agentWithdrawFromBonded(
                        POLICY_ID(), gasAbstractionTracker.owner, gasAbstractionTracker.key, _sharesAvailable, 0, false
                    );
                }
            }
        }
    }

    /// @notice Manages session key funding from deposits and bonded tokens
    /// @dev Handles MON transfers and bonded token withdrawals
    /// @param owner Address of the session key owner
    /// @param sessionKeyAddress Address of the session key
    /// @param deposit Amount of MON being deposited
    /// @return remainder Unused portion of the deposit
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
                POLICY_ID(), owner, sessionKeyAddress, _remainingDeficit, 0, true
            ) {
                // Successfully withdrew from bonded tokens
            } catch {
                // Fall back to partial funding if full withdrawal fails
                uint256 _amountAvailable = _amountBondedToThis(owner);
                uint256 _amountToWithdraw = _amountAvailable > _remainingDeficit ? _remainingDeficit : _amountAvailable;
                if (_amountToWithdraw > 0) {
                    IShMonad(SHMONAD).agentWithdrawFromBonded(
                        POLICY_ID(), owner, sessionKeyAddress, _amountToWithdraw, 0, true
                    );
                }
            }
        }

        return remainder;
    }

    /// @notice Receive function to allow for ETH transfers to the contract
    /// @dev Allows for ETH transfers to the contract for gas funding
    /// @dev This is a virtual function to allow for overriding in derived contracts
    receive() external payable virtual { }
}
