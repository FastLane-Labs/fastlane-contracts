//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ITaskManager } from "../../task-manager/interfaces/ITaskManager.sol";
import { IShMonad } from "../../shmonad/interfaces/IShMonad.sol";
import { SessionKey, SessionKeyData, GasAbstractionTracker } from "./GasRelayTypes.sol";
import { GasRelayErrors } from "./GasRelayErrors.sol";

/// @title ITaskManagerImmutables
/// @notice Interface for accessing TaskManager immutable variables
interface ITaskManagerImmutables {
    function POLICY_ID() external view returns (uint64);
}

/// @title GasRelayHelper
/// @notice Helper functions for session key and ShMONAD interactions
/// @dev Contains utility functions for the gas relay system
contract GasRelayHelper is GasRelayErrors {
    /// @notice Address of the task manager contract
    address public immutable TASK_MANAGER;

    /// @notice Policy ID for the task manager
    uint64 public immutable TASK_MANAGER_POLICY_ID;

    /// @notice Address of the ShMonad protocol
    address public immutable SHMONAD;

    /// @notice Policy ID for this contract
    uint64 public immutable POLICY_ID;

    /// @notice Policy wrapper ERC20 token address
    address public immutable POLICY_WRAPPER;

    /// @notice Maximum expected gas usage per transaction
    uint256 internal immutable _MAX_EXPECTED_GAS_USAGE_PER_TX;

    /// @notice Multiplier for target balance (1=1x, 2=2x, 4=4x)
    uint256 private immutable _targetBalanceMultiplier;

    /// @notice Namespace for session key storage
    bytes32 private immutable SESSION_KEY_NAMESPACE;

    /// @notice Namespace for key owner storage
    bytes32 private immutable KEY_OWNER_NAMESPACE;

    /// @notice Namespace for abstracted caller transient storage
    bytes32 private immutable ABSTRACTED_CALLER_NAMESPACE;

    /// @notice Minimum gas required for task execution
    uint256 internal constant _MIN_TASK_EXECUTION_GAS = 110_000;

    /// @notice Buffer for task manager execution
    uint256 internal constant _TASK_MANAGER_EXECUTION_GAS_BUFFER = 31_000;

    /// @notice Minimum gas required for gas abstraction
    uint256 internal constant _GAS_ABSTRACTION_MIN_REMAINDER_GAS = 65_000;

    /// @notice Buffer for minimum remainder gas
    uint256 internal constant _MIN_REMAINDER_GAS_BUFFER = 31_000;

    /// @notice Base gas usage for a transaction
    uint256 internal constant _BASE_TX_GAS_USAGE = 21_000;

    /// @notice Maximum base fee increase factor (112.5%)
    uint256 internal constant _BASE_FEE_MAX_INCREASE = 1125;

    /// @notice Denominator for base fee calculations
    uint256 internal constant _BASE_FEE_DENOMINATOR = 1000;

    /// @notice Transient storage bit for tracking usage lock
    bytes32 private constant _IN_USE_BIT = 0x0000000000000000000000020000000000000000000000000000000000000000;

    /// @notice Transient storage bit for identifying session keys
    bytes32 private constant _IS_SESSION_KEY_BIT = 0x0000000000000000000000040000000000000000000000000000000000000000;

    /// @notice Combined bits for session key in use
    bytes32 private constant _IN_USE_AS_SESSION_KEY_BITS =
        0x0000000000000000000000060000000000000000000000000000000000000000;

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

    /// @notice Constructor for GasRelayHelper
    /// @param taskManager Address of the task manager contract
    /// @param shMonad Address of the ShMonad protocol
    /// @param maxExpectedGasUsagePerTx Maximum expected gas per transaction
    /// @param escrowDuration Duration of escrow in blocks
    /// @param targetBalanceMultiplier Multiplier for target balance calculation (1=1x, 2=2x, etc.)
    constructor(
        address taskManager,
        address shMonad,
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier
    ) {
        TASK_MANAGER = taskManager;
        SHMONAD = shMonad;

        // Using the reinstated interface here
        TASK_MANAGER_POLICY_ID = ITaskManagerImmutables(taskManager).POLICY_ID();

        // Create ShMONAD commitment policy for this app
        (uint64 policyIDLocal, address policyERC20WrapperLocal) = IShMonad(shMonad).createPolicy(escrowDuration);
        POLICY_ID = policyIDLocal;
        POLICY_WRAPPER = policyERC20WrapperLocal;

        _MAX_EXPECTED_GAS_USAGE_PER_TX = maxExpectedGasUsagePerTx;
        _targetBalanceMultiplier = targetBalanceMultiplier;

        // Create storage namespaces
        SESSION_KEY_NAMESPACE = keccak256(
            abi.encode(
                "ShMonad GasRelayHelper 1.0",
                "Session Key Namespace",
                taskManager,
                shMonad,
                policyIDLocal,
                address(this),
                block.chainid
            )
        );
        KEY_OWNER_NAMESPACE = keccak256(
            abi.encode(
                "ShMonad GasRelayHelper 1.0",
                "Key Owner Namespace",
                taskManager,
                shMonad,
                policyIDLocal,
                address(this),
                block.chainid
            )
        );
        ABSTRACTED_CALLER_NAMESPACE = keccak256(
            abi.encode(
                "ShMonad GasRelayHelper 1.0",
                "Abstracted Caller Transient Namespace",
                taskManager,
                shMonad,
                policyIDLocal,
                address(this),
                block.chainid
            )
        );
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
        targetBalance = (_MAX_EXPECTED_GAS_USAGE_PER_TX * _gasRate) * _targetBalanceMultiplier;
    }

    /// @notice Check if the contract is currently in use (reentrancy check)
    /// @return inUse True if the contract is in use
    function _inUse() internal view returns (bool inUse) {
        // Check if the transient storage has the IN_USE_BIT set
        bytes32 _abstractedCallerTransientSlot = ABSTRACTED_CALLER_NAMESPACE;
        bytes32 _packedAbstractedCaller;
        assembly {
            _packedAbstractedCaller := tload(_abstractedCallerTransientSlot)
        }
        inUse = _packedAbstractedCaller & _IN_USE_BIT != 0;
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
        bytes32 _abstractedCallerTransientSlot = ABSTRACTED_CALLER_NAMESPACE;
        assembly {
            tstore(_abstractedCallerTransientSlot, _IN_USE_BIT)
        }
    }

    /// @notice Load abstracted msg sender data from transient storage
    /// @return abstractedMsgSender Address of the abstracted msg sender
    /// @return isSessionKey Whether the caller is a session key
    /// @return inUse Whether the contract is in use
    function _loadAbstractedMsgSenderData()
        internal
        view
        returns (address abstractedMsgSender, bool isSessionKey, bool inUse)
    {
        bytes32 _abstractedCallerTransientSlot = ABSTRACTED_CALLER_NAMESPACE;
        bytes32 _packedAbstractedCaller;
        assembly {
            _packedAbstractedCaller := tload(_abstractedCallerTransientSlot)
            abstractedMsgSender :=
                and(_packedAbstractedCaller, 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff)
        }
        isSessionKey = _packedAbstractedCaller & _IS_SESSION_KEY_BIT != 0;
        inUse = _packedAbstractedCaller & _IN_USE_BIT != 0;
    }

    /// @notice Store abstracted msg sender in transient storage
    /// @param abstractedMsgSender Address of the abstracted msg sender
    /// @param isSessionKey Whether the caller is a session key
    function _storeAbstractedMsgSender(address abstractedMsgSender, bool isSessionKey) internal {
        bytes32 _abstractedCallerTransientSlot = ABSTRACTED_CALLER_NAMESPACE;
        bytes32 _packedAbstractedCaller = isSessionKey ? _IN_USE_AS_SESSION_KEY_BITS : _IN_USE_BIT;
        assembly {
            tstore(_abstractedCallerTransientSlot, or(_packedAbstractedCaller, abstractedMsgSender))
        }
    }

    /// @notice Clear abstracted msg sender from transient storage
    function _clearAbstractedMsgSender() internal {
        bytes32 _abstractedCallerTransientSlot = ABSTRACTED_CALLER_NAMESPACE;
        assembly {
            tstore(_abstractedCallerTransientSlot, 0x0000000000000000000000000000000000000000000000000000000000000000)
        }
    }

    /// @notice Update a session key's data
    /// @param sessionKeyAddress Address of the session key
    /// @param owner Address of the owner
    /// @param expiration Block number when the session key expires
    function _updateSessionKey(address sessionKeyAddress, address owner, uint256 expiration) internal {
        if (sessionKeyAddress == owner) {
            revert SessionKeyCantOwnSelf();
        }
        if (expiration > type(uint64).max) {
            revert SessionKeyExpirationInvalid(expiration);
        }

        address _existingSessionKeyAddress;
        bytes32 _keyOwnerStorageSlot = keccak256(abi.encodePacked(owner, KEY_OWNER_NAMESPACE));
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

        if (sessionKeyAddress != address(0)) {
            bytes32 _sessionKeyStorageSlot = keccak256(abi.encodePacked(sessionKeyAddress, SESSION_KEY_NAMESPACE));
            assembly {
                // Pack the owner and expiration, clear the expiredNotified flag
                let _packedSessionKey := or(owner, shl(192, expiration))
                sstore(_sessionKeyStorageSlot, _packedSessionKey)
            }
        }
    }

    /// @notice Deactivate a session key
    /// @param sessionKeyAddress Address of the session key to deactivate
    function _deactivateSessionKey(address sessionKeyAddress) internal {
        bytes32 _sessionKeyStorageSlot = keccak256(abi.encodePacked(sessionKeyAddress, SESSION_KEY_NAMESPACE));
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
        bytes32 _keyOwnerStorageSlot = keccak256(abi.encodePacked(ownerAddress, KEY_OWNER_NAMESPACE));
        assembly {
            sessionKeyAddress := sload(_keyOwnerStorageSlot)
        }
    }

    /// @notice Load session key data
    /// @param sessionKeyAddress Address of the session key
    /// @return sessionKey Session key data
    function _loadSessionKey(address sessionKeyAddress) internal view returns (SessionKey memory sessionKey) {
        bytes32 _sessionKeyStorageSlot = keccak256(abi.encodePacked(sessionKeyAddress, SESSION_KEY_NAMESPACE));
        address _owner;
        uint256 _expiration;
        assembly {
            let _packedSessionKey := sload(_sessionKeyStorageSlot)
            _owner := and(_packedSessionKey, 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff)
            _expiration :=
                and(shr(192, _packedSessionKey), 0x000000000000000000000000000000000000000000000000ffffffffffffffff)
        }
        sessionKey.owner = _owner;
        sessionKey.expiration = uint64(_expiration);
    }

    /// @notice Load session key from owner address
    /// @param ownerAddress Address of the owner
    /// @return sessionKey Session key data
    function _loadSessionKeyFromOwner(address ownerAddress) internal view returns (SessionKey memory sessionKey) {
        address _sessionKeyAddress = _getSessionKeyAddress(ownerAddress);
        if (_sessionKeyAddress != address(0)) {
            sessionKey = _loadSessionKey(_sessionKeyAddress);
        }
    }

    /// @notice Credit shares to owner and bond to policy
    /// @param owner Address of the owner
    /// @param shares Number of shares to credit
    function _creditToOwnerAndBond(address owner, uint256 shares) internal {
        IShMonad(SHMONAD).bond(POLICY_ID, owner, shares);
    }

    /// @notice Take shares from owner's bonded balance
    /// @param owner Address of the owner
    /// @param shares Number of shares to take
    function _takeFromOwnerBondedShares(address owner, uint256 shares) internal {
        IShMonad(SHMONAD).agentTransferToUnbonded(POLICY_ID, owner, address(this), shares, 0, false);
    }

    /// @notice Take amount from owner's bonded balance
    /// @param owner Address of the owner
    /// @param amount Amount to take
    function _takeFromOwnerBondedAmount(address owner, uint256 amount) internal {
        IShMonad(SHMONAD).agentTransferToUnbonded(POLICY_ID, owner, address(this), amount, 0, true);
    }

    /// @notice Take amount in underlying tokens from owner's bonded balance
    /// @param owner Address of the owner
    /// @param amount Amount to take
    function _takeFromOwnerBondedAmountInUnderlying(address owner, uint256 amount) internal {
        IShMonad(SHMONAD).agentWithdrawFromBonded(POLICY_ID, owner, address(this), amount, 0, true);
    }

    /// @notice Bond shares to task manager
    /// @param shares Number of shares to bond
    function _bondSharesToTaskManager(uint256 shares) internal {
        IShMonad(SHMONAD).bond(TASK_MANAGER_POLICY_ID, address(this), shares);
    }

    /// @notice Bond amount to task manager
    /// @param amount Amount to bond
    function _bondAmountToTaskManager(uint256 amount) internal {
        IShMonad(SHMONAD).depositAndBond{ value: amount }(TASK_MANAGER_POLICY_ID, address(this), type(uint256).max);
    }

    /// @notice Begin unbonding from task manager
    /// @param shares Number of shares to unbond
    function _beginUnbondFromTaskManager(uint256 shares) internal {
        IShMonad(SHMONAD).unbond(TASK_MANAGER_POLICY_ID, shares, 0);
    }

    /// @notice Get block when unbonding from task manager completes
    /// @return blockNumber Block number when unbonding completes
    function _taskManagerUnbondingBlock() internal view returns (uint256 blockNumber) {
        blockNumber = IShMonad(SHMONAD).unbondingCompleteBlock(TASK_MANAGER_POLICY_ID, address(this));
    }

    /// @notice Complete unbonding from task manager
    /// @param shares Number of shares to claim
    function _completeUnbondFromTaskManager(uint256 shares) internal {
        IShMonad(SHMONAD).claim(TASK_MANAGER_POLICY_ID, shares);
    }

    /// @notice Get shares bonded to task manager for an owner
    /// @param owner Address of the owner
    /// @return shares Number of shares bonded
    function _sharesBondedToTaskManager(address owner) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).balanceOfBonded(TASK_MANAGER_POLICY_ID, owner);
    }

    /// @notice Get shares unbonding from task manager for an owner
    /// @param owner Address of the owner
    /// @return shares Number of shares unbonding
    function _sharesUnbondingFromTaskManager(address owner) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).balanceOfUnbonding(TASK_MANAGER_POLICY_ID, owner);
    }

    /// @notice Get shares bonded to this contract for an owner
    /// @param owner Address of the owner
    /// @return shares Number of shares bonded
    function _sharesBondedToThis(address owner) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).balanceOfBonded(POLICY_ID, owner);
    }

    /// @notice Get amount bonded to this contract for an owner
    /// @param owner Address of the owner
    /// @return amount Amount bonded
    function _amountBondedToThis(address owner) internal view returns (uint256 amount) {
        amount = _convertWithdrawnShMonToMon(IShMonad(SHMONAD).balanceOfBonded(POLICY_ID, owner));
    }

    /// @notice Get shares unbonding from this contract for an owner
    /// @param owner Address of the owner
    /// @return shares Number of shares unbonding
    function _sharesUnbondingFromThis(address owner) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).balanceOfUnbonding(POLICY_ID, owner);
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
        IShMonad(SHMONAD).depositAndBond{ value: amount }(POLICY_ID, bondRecipient, type(uint256).max);
    }

    /// @notice Estimate cost for task execution
    /// @param targetBlock Target block for execution
    /// @param maxTaskGas Maximum gas for task execution
    /// @return cost Estimated cost
    function _estimateTaskCost(uint256 targetBlock, uint256 maxTaskGas) internal view returns (uint256 cost) {
        cost = ITaskManager(TASK_MANAGER).estimateCost(uint64(targetBlock), maxTaskGas);
    }
}
