//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

// import { TestnetHarness } from "./testnet/TestnetHarness.sol";
import { FastLaneERC4626 } from "./FLERC4626.sol";
import { Coinbase } from "./Coinbase.sol";
import { STAKING_GAS_BUFFER, STAKING_GAS_GET_VALIDATOR } from "./Constants.sol";
import {
    Epoch,
    PendingBoost,
    CashFlows,
    ValidatorStats,
    StakingEscrow,
    ValidatorData,
    ValidatorDataStorage
} from "./Types.sol";
import { StorageLib } from "./libraries/StorageLib.sol";
import { IMonadStaking } from "./interfaces/IMonadStaking.sol";
import {
    SCALE,
    STAKING,
    SHMONAD_VALIDATOR_DEACTIVATION_PERIOD,
    BPS_SCALE,
    EPOCHS_TRACKED,
    UNKNOWN_VAL_ID,
    UNKNOWN_VAL_ADDRESS,
    LAST_VAL_ID,
    FIRST_VAL_ID,
    COINBASE_SALT
} from "./Constants.sol";

/*
WARNING: Validator ID vs. `block.coinbase` Addresses on Monad

- Block Author Address (block.coinbase): On Monad this is NOT a unique identifier
  for a validator. Multiple validator IDs can share the same block.coinbase address.
  As a result, ShMonad MUST NOT infer validator identity from block.coinbase.

- Registry Mappings in this file:
  - s_valCoinbases[valId] -> coinbaseContractAddress
  - s_valIdByCoinbase[coinbaseContractAddress] -> valId
  These mappings are ONLY for the per‑validator Coinbase contract, NOT the
  network’s block.coinbase author address.

- Primary Key is Validator ID: All runtime logic, cranking, accounting, and
  precompile calls must key off validator IDs. PrecompileHelpers obtains the
  current proposer via STAKING.getProposerValId() and never relies on
  block.coinbase. When ShMonad needs a coinbase address (for events or to call
  ICoinbase.process), it derives it from the validator ID via _validatorCoinbase.

- Where this matters:
  - Events that include a "coinbase" field reference the per‑validator Coinbase
    contract address for operator visibility.
  - Crank ordering uses a linked list indexed by validator IDs (FIRST_VAL_ID /
    LAST_VAL_ID sentinels). No address‑based sentinels remain.
  - Do not attempt to map block.coinbase -> validator ID in this contract; use
    the precompile (getProposerValId) or the stored valId -> coinbase mapping.
*/

abstract contract ValidatorRegistry is FastLaneERC4626 {
    using Math for uint256;
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using StorageLib for CashFlows;
    using StorageLib for StakingEscrow;
    using StorageLib for PendingBoost;

    // ================================================== //
    //                    Admin Functions                 //
    // ================================================== //

    // Queue up a deactivation
    // NOTE: Takes 5 epochs to complete
    // NOTE: Deactivation immediately flags the validator as inactive for reward settlement, so any unpaid
    // rewards (including those earned earlier in the current epoch) are redirected to shMON yield.
    /// @custom:selector 0x8f289544
    function deactivateValidator(uint64 validatorId) external virtual onlyOwner {
        _beginDeactivatingValidator(validatorId);
    }

    /// @notice Adds a validator and primes its epoch windows without affecting ordering.
    /// @dev Validates existence via precompile (except UNKNOWN placeholder during init).
    /// Inserts at tail of the crank linked list; enforces one id ↔ one coinbase mapping.
    /// Reverts if attempting to reuse sentinel addresses or if validator not fully removed.
    /// @custom:selector 0xb5965470
    function addValidator(uint64 validatorId, address coinbase) external virtual onlyOwner {
        require(validatorId != UNKNOWN_VAL_ID, InvalidValidatorId(validatorId));

        // NOTE: We want to avoid scenarios where a validator has their own custom smart contract
        // as the coinbase with unknown code being run when 'process()' is called. We can check
        // at crank time that the bytecode isn't 7702-enabled, it must be manually verified offchain
        // that the coinbase is a wallet with a known private key and not an undeployed create2
        // smart contract.
        require(coinbase.code.length == 0, CustomCoinbaseCantBeContract(validatorId));
        _addValidator(validatorId, coinbase);
    }

    /// @custom:selector 0xb5965470
    function addValidator(uint64 validatorId) external virtual onlyOwner returns (address coinbase) {
        require(validatorId != UNKNOWN_VAL_ID, InvalidValidatorId(validatorId));
        coinbase = _deployOrGetCoinbaseContractAddress(validatorId);
        _addValidator(validatorId, coinbase);
    }

    /// @notice Deploys and links a fresh Coinbase contract for an existing validator.
    /// @dev `nonReentrant` prevents the previous coinbase's `process()` callback from reentering
    /// while registry links are being migrated.
    /// @custom:selector 0x0c017712
    function updateCoinbaseForExistingValidator(uint64 validatorId)
        external
        virtual
        nonReentrant
        onlyOwner
        returns (address newCoinbase)
    {
        require(validatorId != UNKNOWN_VAL_ID, InvalidValidatorId(validatorId));
        address _previousCoinbase = s_valCoinbases[validatorId];

        // Get the new coinbase address
        newCoinbase = _deployOrGetCoinbaseContractAddress(validatorId);

        // Verify this is a net new deployment
        require(_previousCoinbase != newCoinbase, CoinbaseAlreadyDeployed(validatorId, newCoinbase));
        require(newCoinbase != address(0), ZeroAddress());

        // Clear out any pending balances / rewards on the old contract, if it exists
        if (_previousCoinbase.code.length > 0 && _previousCoinbase.balance > 0) {
            _settleCoinbaseContract(validatorId, _previousCoinbase);
        }

        // Unlink the previous coinbase address if it exists and then link the new one
        _unlinkValidatorCoinbase(validatorId);
        _linkValidatorCoinbase(validatorId, newCoinbase);

        emit CoinbaseContractUpdated(validatorId, _previousCoinbase, newCoinbase);
    }

    /// @custom:selector 0x9e6cb0bf
    function updateStakingCommission(uint16 feeInBps) external virtual onlyOwner {
        require(feeInBps < BPS_SCALE, CommissionMustBeBelow100Percent());
        s_admin.stakingCommission = feeInBps;
    }

    /// @custom:selector 0x01b3bfa4
    function updateBoostCommission(uint16 feeInBps) external virtual onlyOwner {
        require(feeInBps < BPS_SCALE, CommissionMustBeBelow100Percent());
        s_admin.boostCommissionRate = feeInBps;
    }

    /// @custom:selector 0x071c3626
    function updateIncentiveAlignmentPercentage(uint16 percentageInBps) external virtual onlyOwner {
        require(percentageInBps < BPS_SCALE, PercentageMustBeBelow100Percent());
        s_admin.incentiveAlignmentPercentage = percentageInBps;
    }

    /// @custom:selector 0x84aae4c9
    function setFrozenStatus(bool isFrozen) external virtual onlyOwner {
        globalEpochPtr_N(0).frozen = isFrozen;
    }

    /// @custom:selector 0xc2006eaa
    function setClosedStatus(bool isClosed) external virtual onlyOwner {
        globalEpochPtr_N(0).closed = isClosed;
    }

    // ================================================== //
    //            Coinbase Auth Functions                //
    // ================================================== //

    /// @notice Allows a validator's auth address or the ShMonad owner to process its Coinbase contract via ShMonad.
    /// @dev Uses the same settlement path as cranking to account for donations as revenue. `nonReentrant`
    /// blocks coinbase callbacks from reentering and mutating balances mid-settlement.
    /// @custom:selector 0xa1b6d59b
    function processCoinbaseByAuth(uint64 validatorId) external notWhenFrozen nonReentrant {
        require(validatorId != 0 && validatorId != UNKNOWN_VAL_ID, InvalidValidatorId(validatorId));

        address coinbase = s_valCoinbases[validatorId];
        require(coinbase != address(0), InvalidValidatorId(validatorId));
        require(coinbase.code.length > 0, InvalidValidatorAddress(coinbase));

        address authAddress = Coinbase(payable(coinbase)).AUTH_ADDRESS();
        require(msg.sender == authAddress || msg.sender == owner(), OnlyCoinbaseAuth(validatorId, msg.sender));

        _settleCoinbaseContract(validatorId, coinbase);
    }

    /// @notice Allows the ShMonad owner to process a Coinbase contract via its address.
    /// @dev Supports coinbases no longer registered in ShMonad. Restricted to `onlyOwner` to prevent unauthorized
    /// processing of arbitrary coinbase addresses. `nonReentrant` blocks coinbase callbacks from reentering and
    /// mutating balances mid-settlement.
    /// @param coinbase The address of the Coinbase contract to process.
    /// @custom:selector 0x41638da9
    function processCoinbaseByAuth(address coinbase) external onlyOwner notWhenFrozen nonReentrant {
        require(coinbase != address(0), InvalidValidatorAddress(coinbase));
        require(coinbase.code.length > 0, InvalidValidatorAddress(coinbase));

        uint64 valId;
        try Coinbase(payable(coinbase)).VAL_ID() returns (uint64 _valId) {
            valId = _valId;
            require(valId != 0 && valId != UNKNOWN_VAL_ID, InvalidValidatorId(valId));
        } catch {
            revert InvalidValidatorAddress(coinbase);
        }

        try Coinbase(payable(coinbase)).SHMONAD() returns (address shmonad) {
            require(shmonad == address(this), InvalidValidatorAddress(coinbase));
        } catch {
            revert InvalidValidatorAddress(coinbase);
        }

        _settleCoinbaseContract(valId, coinbase);
    }

    function _addValidator(uint64 validatorId, address coinbase) internal {
        require(validatorId != 0, InvalidValidatorId(validatorId));
        // Prevent registering sentinel IDs which would break the linked list
        require(validatorId != FIRST_VAL_ID && validatorId != LAST_VAL_ID, InvalidValidatorId(validatorId));
        require(coinbase != address(0), ZeroAddress());
        require(
            !s_validatorIsActive[UNKNOWN_VAL_ID] || coinbase != UNKNOWN_VAL_ADDRESS, InvalidValidatorAddress(coinbase)
        );

        // Verify validator exists in precompile (unless it's the UNKNOWN_VAL_ID placeholder used during init)
        // Public entry points explicitly reject UNKNOWN_VAL_ID, so it can only reach here during initialization
        if (validatorId != UNKNOWN_VAL_ID) {
            // Note: Real precompile returns zeros for missing, mock reverts with UnknownValidator()
            try STAKING.getValidator{ gas: STAKING_GAS_GET_VALIDATOR + STAKING_GAS_BUFFER }(validatorId) returns (
                address authAddress,
                uint64,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                bytes memory,
                bytes memory
            ) {
                require(authAddress != address(0), ValidatorNotFoundInPrecompile(validatorId));
            } catch {
                revert ValidatorNotFoundInPrecompile(validatorId);
            }
        }

        // Disallow re-adding an active validator
        if (s_validatorIsActive[validatorId]) revert ValidatorAlreadyAdded();

        // If the coinbase is already linked:
        // - to a different validatorId: treat as already added
        // - to the same validatorId: treat as not fully removed
        uint64 _existingForCoinbase = s_valIdByCoinbase[coinbase];
        if (_existingForCoinbase != 0) {
            if (_existingForCoinbase == validatorId) revert ValidatorNotFullyRemoved();
            revert ValidatorAlreadyAdded();
        }

        ++s_activeValidatorCount;

        // Validator must be fully removed (which takes a min of SHMONAD_VALIDATOR_DEACTIVATION_PERIOD from when
        // deactivation is initiated) before they can be added again.
        for (uint256 i; i < EPOCHS_TRACKED; i++) {
            if (s_validatorEpoch[validatorId][i].epoch != 0) revert ValidatorNotFullyRemoved();
        }

        s_validatorIsActive[validatorId] = true;
        s_validatorData[validatorId].isActive = true;
        // Initialize the in-active-set flag based on the precompile's current view
        s_validatorData[validatorId].inActiveSet_Current = _isValidatorInActiveSet(validatorId);
        _linkValidatorCoinbase(validatorId, coinbase);

        uint64 _currentEpoch = s_admin.internalEpoch;

        // Initialize s_validatorEpoch for the new validator
        _setEpochStorage(
            validatorEpochPtr_N(1, validatorId),
            Epoch({
                epoch: _currentEpoch + 1,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: false,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        _setEpochStorage(
            validatorEpochPtr_N(0, validatorId),
            Epoch({
                epoch: _currentEpoch,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: true,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        if (_currentEpoch > 0) --_currentEpoch;

        _setEpochStorage(
            validatorEpochPtr_N(-1, validatorId),
            Epoch({
                epoch: _currentEpoch,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: true,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        if (_currentEpoch > 0) --_currentEpoch;

        _setEpochStorage(
            validatorEpochPtr_N(-2, validatorId),
            Epoch({
                epoch: _currentEpoch,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: true,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        if (_currentEpoch > 0) --_currentEpoch;

        _setEpochStorage(
            validatorEpochPtr_N(-3, validatorId),
            Epoch({
                epoch: _currentEpoch,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: true,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        validatorRewardsPtr_N(0, validatorId).clear();
        validatorRewardsPtr_N(1, validatorId).clear();

        validatorPendingPtr_N(0, validatorId).clear();
        validatorPendingPtr_N(1, validatorId).clear();

        // Update the link pointers
        _addValidatorToCrankSequence(validatorId);

        emit ValidatorAdded(validatorId, coinbase);
    }

    /// @notice Checks if a validator is in the active set and caches the result in transient storage.
    function _isValidatorInActiveSetTransient(uint64 valId) internal returns (bool) {
        if (valId == UNKNOWN_VAL_ID) {
            // Placeholder validator represents unregistered-flow accounting and must always stay "active".
            return true;
        }
        if (t_validatorActiveSetCheckValId != valId) {
            bool _isActive = _isValidatorInActiveSet(valId);
            t_validatorActiveSetCheckValId = valId;
            t_validatorActiveSetCheckValIdState = _isActive;
            return _isActive;
        }
        return t_validatorActiveSetCheckValIdState;
    }

    /// @notice Marks a validator as not in the active set and clears the transient cache.
    function _markValidatorNotInActiveSet(uint64 valId, uint256 detectionIndex) internal {
        bool _stillActive = s_validatorData[valId].inActiveSet_Current && _isValidatorInActiveSetTransient(valId);
        if (_stillActive) return;

        if (s_validatorData[valId].inActiveSet_Current) s_validatorData[valId].inActiveSet_Current = false;

        emit ValidatorNotFoundInActiveSet(valId, s_valCoinbases[valId], globalEpochPtr_N(0).epoch, detectionIndex);
    }

    function _beginDeactivatingValidator(uint64 validatorId) internal {
        address _coinbase = s_valCoinbases[validatorId];
        require(s_validatorData[validatorId].isActive, ValidatorAlreadyDeactivated());

        --s_activeValidatorCount;
        s_validatorData[validatorId].isActive = false;
        s_validatorData[validatorId].epoch = s_admin.internalEpoch;
        emit ValidatorMarkedInactive(validatorId, _coinbase, s_admin.internalEpoch);
    }

    function _completeDeactivatingValidator(uint64 validatorId) internal virtual {
        require(s_validatorIsActive[validatorId], ValidatorAlreadyDeactivated());

        // validator deactivation queue takes 7 epochs
        require(!s_validatorData[validatorId].isActive, ValidatorDeactivationNotQueued());
        require(
            s_admin.internalEpoch >= s_validatorData[validatorId].epoch + SHMONAD_VALIDATOR_DEACTIVATION_PERIOD,
            ValidatorDeactivationQueuedIncomplete()
        );

        delete s_validatorIsActive[validatorId];
        _unlinkValidatorCoinbase(validatorId);
        delete s_validatorData[validatorId];

        // Remove this validator from the link and connect together the validators on either end
        _removeValidatorFromCrankSequence(validatorId);

        for (uint256 i; i < EPOCHS_TRACKED; i++) {
            delete s_validatorEpoch[validatorId][i];
            delete s_validatorRewards[validatorId][i];
            delete s_validatorPending[validatorId][i];
        }

        emit ValidatorDeactivated(validatorId);
    }

    function _removeValidatorFromCrankSequence(uint64 validatorId) internal {
        uint64 _nextValidator = s_valLinkNext[validatorId];
        uint64 _previousValidator = s_valLinkPrevious[validatorId];

        s_valLinkNext[_previousValidator] = _nextValidator;
        s_valLinkPrevious[_nextValidator] = _previousValidator;
    }

    function _addValidatorToCrankSequence(uint64 validatorId) internal {
        uint64 _previousTailValidator = s_valLinkPrevious[LAST_VAL_ID];
        s_valLinkNext[_previousTailValidator] = validatorId;
        s_valLinkPrevious[validatorId] = _previousTailValidator;
        s_valLinkNext[validatorId] = LAST_VAL_ID;
        s_valLinkPrevious[LAST_VAL_ID] = validatorId;
    }

    // ================================================== //
    //          validatorId <-> block.coinbase map        //
    // ================================================== //

    /// @dev Establishes 1:1 link between `valId` and `coinbase`. Reverts if either already linked.
    /// Invariant after success: `s_valCoinbases[valId] == coinbase` and `s_validatorData[coinbase].id == valId`.
    function _linkValidatorCoinbase(uint64 valId, address coinbase) internal {
        if (coinbase == address(0)) revert ZeroAddress();
        if (s_valCoinbases[valId] != address(0) || s_valIdByCoinbase[coinbase] > 0) revert ValidatorAlreadyAdded();

        s_valCoinbases[valId] = coinbase;
        s_valIdByCoinbase[coinbase] = valId;
    }

    /// @dev Clears 1:1 link between `valId` and its existing `coinbase`, if any.
    /// Invariant after success: `s_valCoinbases[valId] == address(0)` and `s_validatorData[coinbase].id == 0`.
    function _unlinkValidatorCoinbase(uint64 valId) internal {
        address _coinbase = s_valCoinbases[valId];
        if (_coinbase != address(0)) {
            delete s_valIdByCoinbase[_coinbase];
            delete s_valCoinbases[valId];
        }
    }

    function _validatorCoinbase(uint64 valId) internal view returns (address) {
        return s_valCoinbases[valId];
    }

    function _getValidatorData(uint64 valId) internal view returns (ValidatorData memory) {
        ValidatorDataStorage memory _validatorData = s_validatorData[valId];
        address coinbase = s_valCoinbases[valId];
        return ValidatorData({
            epoch: _validatorData.epoch,
            id: valId,
            isPlaceholder: valId == UNKNOWN_VAL_ID,
            isActive: _validatorData.isActive,
            inActiveSet_Current: _validatorData.inActiveSet_Current,
            inActiveSet_Last: _validatorData.inActiveSet_Last,
            coinbase: coinbase
        });
    }

    // ================================================== //
    //             Coinbase Deployment Helpers            //
    // ================================================== //

    function _coinbaseSalt(uint64 validatorId) internal pure returns (bytes32) {
        // Domain-separated salt for safety across potential future CREATE2 usages.
        return keccak256(abi.encodePacked(COINBASE_SALT, validatorId));
    }

    function _predictCreate2Address(bytes32 salt, bytes32 initCodeHash) internal view returns (address predicted) {
        // address = keccak256(0xff ++ deployer ++ salt ++ keccak256(init_code))[12:]
        predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _coinbaseInitCode(uint64 validatorId) internal pure returns (bytes memory) {
        return abi.encodePacked(type(Coinbase).creationCode, abi.encode(validatorId));
    }

    function _coinbaseInitCodeHash(uint64 validatorId) internal pure returns (bytes32) {
        return keccak256(_coinbaseInitCode(validatorId));
    }

    function _predictCoinbaseAddress(uint64 validatorId) internal view returns (address) {
        return _predictCreate2Address(_coinbaseSalt(validatorId), _coinbaseInitCodeHash(validatorId));
    }

    function _deployOrGetCoinbaseContractAddress(uint64 validatorId) internal returns (address coinbase) {
        bytes32 salt = _coinbaseSalt(validatorId);
        bytes memory creationCode = _coinbaseInitCode(validatorId);
        address predicted = _predictCoinbaseAddress(validatorId);
        if (predicted.code.length == 0) {
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            }
            coinbase = deployed;
            require(coinbase != address(0), Create2Failed());
        } else {
            coinbase = predicted;
        }
    }

    // ================================================== //
    //                   View Functions                   //
    // ================================================== //

    /// @notice Returns the deterministic Coinbase address for a validator without deploying it.
    /// @dev Reverts for invalid placeholders to mirror addValidator checks.
    /// @custom:selector 0xa60232ad
    function previewCoinbaseAddress(uint64 validatorId) external view returns (address predicted) {
        require(validatorId != 0 && validatorId != UNKNOWN_VAL_ID, InvalidValidatorId(validatorId));
        predicted = _predictCoinbaseAddress(validatorId);
    }

    /// @custom:selector 0xd3b9fd72
    function getValidatorStats(uint64 validatorId) external view returns (ValidatorStats memory stats) {
        address coinbase = s_valCoinbases[validatorId];
        stats.isActive = s_validatorData[validatorId].isActive;
        require(stats.isActive || coinbase != address(0), InvalidValidatorId(validatorId));

        Epoch memory _validatorEpoch = validatorEpochPtr_N(-1, validatorId);
        PendingBoost memory _rewardsLast = validatorRewardsPtr_N(-1, validatorId);
        PendingBoost memory _rewardsCurrent = validatorRewardsPtr_N(0, validatorId);

        stats.coinbase = coinbase;
        stats.lastEpoch = _validatorEpoch.epoch;
        stats.targetStakeAmount = _validatorEpoch.targetStakeAmount;
        stats.rewardsPayableLast = _rewardsLast.rewardsPayable;
        stats.earnedRevenueLast = _rewardsLast.earnedRevenue;
        stats.rewardsPayableCurrent = _rewardsCurrent.rewardsPayable;
        stats.earnedRevenueCurrent = _rewardsCurrent.earnedRevenue;
    }

    /// @custom:selector 0x0e1e8f7d
    function isValidatorActive(uint64 validatorId) external view returns (bool) {
        return s_validatorIsActive[validatorId];
    }

    /// @notice Mirrors precompile epoch; startBlock not provided by precompile → returns 0.
    /// @custom:selector 0xa9fd1a8f
    function getEpochInfo() external returns (uint256 epochNumber, uint256 epochStartBlock) {
        (uint64 e,) = STAKING.getEpoch();
        return (uint256(e), 0);
    }

    /// @custom:selector 0x3bbc81d1
    function getValidatorCoinbase(uint256 validatorId) external view returns (address) {
        return _validatorCoinbase(validatorId.toUint64());
    }

    /// @custom:selector 0xc84fef9f
    function getValidatorIdForCoinbase(address coinbase) external view returns (uint256) {
        return s_valIdByCoinbase[coinbase];
    }

    function _validatorIdForCoinbase(address coinbase) internal view override returns (uint64) {
        return s_valIdByCoinbase[coinbase];
    }

    /// @notice Returns detailed validator data (no structs) for a validatorId.
    /// @custom:selector 0x6c91b101
    function getValidatorData(uint64 validatorId)
        external
        view
        returns (
            uint64 epoch,
            uint64 id,
            bool isPlaceholder,
            bool isActive,
            bool inActiveSet_Current,
            bool inActiveSet_Last,
            address coinbase
        )
    {
        ValidatorData memory _validatorData = _getValidatorData(validatorId);
        return (
            _validatorData.epoch,
            _validatorData.id,
            _validatorData.isPlaceholder,
            _validatorData.isActive,
            _validatorData.inActiveSet_Current,
            _validatorData.inActiveSet_Last,
            _validatorData.coinbase
        );
    }

    /// @notice Returns the active validator set as parallel arrays of ids and coinbases.
    /// @custom:selector 0xd5dc7f75
    function listActiveValidators() external view returns (uint64[] memory validatorIds, address[] memory coinbases) {
        uint256 count = s_activeValidatorCount;
        validatorIds = new uint64[](count);
        coinbases = new address[](count);
        uint64 cursorId = s_valLinkNext[FIRST_VAL_ID];
        uint256 i;
        while (cursorId != LAST_VAL_ID && i < count) {
            if (cursorId != UNKNOWN_VAL_ID) {
                uint64 valId = cursorId;
                if (valId != 0 && s_validatorData[valId].isActive) {
                    validatorIds[i] = valId;
                    coinbases[i] = s_valCoinbases[valId];
                    unchecked {
                        ++i;
                    }
                }
            }
            cursorId = s_valLinkNext[cursorId];
        }
    }

    /// @notice Returns last and current epoch values for a validator.
    /// @custom:selector 0xaeefe59d
    function getValidatorEpochs(uint64 validatorId)
        external
        view
        returns (uint64 lastEpoch, uint128 lastTargetStakeAmount, uint64 currentEpoch, uint128 currentTargetStakeAmount)
    {
        Epoch memory _last = validatorEpochPtr_N(-1, validatorId);
        Epoch memory _current = validatorEpochPtr_N(0, validatorId);
        return (_last.epoch, _last.targetStakeAmount, _current.epoch, _current.targetStakeAmount);
    }

    /// @notice Returns last and current pending escrow values for a validator.
    /// @custom:selector 0x00601aaf
    function getValidatorPendingEscrow(uint64 validatorId)
        external
        view
        returns (
            uint120 lastPendingStaking,
            uint120 lastPendingUnstaking,
            uint120 currentPendingStaking,
            uint120 currentPendingUnstaking
        )
    {
        StakingEscrow memory _last = validatorPendingPtr_N(-1, validatorId);
        StakingEscrow memory _current = validatorPendingPtr_N(0, validatorId);
        return (_last.pendingStaking, _last.pendingUnstaking, _current.pendingStaking, _current.pendingUnstaking);
    }

    /// @notice Returns last and current rewards tracking for a validator.
    /// @custom:selector 0x0b4c7141
    function getValidatorRewards(uint64 validatorId)
        external
        view
        returns (
            uint120 lastRewardsPayable,
            uint120 lastEarnedRevenue,
            uint120 currentRewardsPayable,
            uint120 currentEarnedRevenue
        )
    {
        PendingBoost memory _last = validatorRewardsPtr_N(-1, validatorId);
        PendingBoost memory _current = validatorRewardsPtr_N(0, validatorId);
        return (_last.rewardsPayable, _last.earnedRevenue, _current.rewardsPayable, _current.earnedRevenue);
    }

    /// @notice Returns crank linked-list neighbors for a validator (previous, next).
    /// @custom:selector 0x29067fef
    function getValidatorNeighbors(uint64 validatorId) external view returns (address previous, address next) {
        uint64 prevId = s_valLinkPrevious[validatorId];
        uint64 nextId = s_valLinkNext[validatorId];
        previous = (prevId == FIRST_VAL_ID || prevId == LAST_VAL_ID) ? address(0) : s_valCoinbases[prevId];
        next = (nextId == FIRST_VAL_ID || nextId == LAST_VAL_ID) ? address(0) : s_valCoinbases[nextId];
    }

    /// @notice Returns active validator count.
    /// @custom:selector 0x37deea70
    function getActiveValidatorCount() external view returns (uint256) {
        return s_activeValidatorCount;
    }

    /// @notice Returns next validator scheduled to crank.
    /// @custom:selector 0x44390e2f
    function getNextValidatorToCrank() external view returns (address) {
        // Start from the current cursor. If we're at the FIRST sentinel,
        // peek the first node after it (which may be UNKNOWN_VAL_ID).
        uint64 id = s_nextValidatorToCrank;
        if (id == FIRST_VAL_ID) id = s_valLinkNext[FIRST_VAL_ID];

        // By construction, UNKNOWN_VAL_ID is always immediately after FIRST_VAL_ID
        // and never appears elsewhere in the list. Skip it if encountered.
        if (id == UNKNOWN_VAL_ID) id = s_valLinkNext[UNKNOWN_VAL_ID];

        if (id == LAST_VAL_ID) return address(0);
        return s_valCoinbases[id];
    }

    /// @custom:selector 0x0cb9f3ad
    function STAKING_PRECOMPILE() public pure virtual override(FastLaneERC4626) returns (IMonadStaking);
    function _settleCoinbaseContract(uint64 valId, address coinbase) internal virtual;
}
