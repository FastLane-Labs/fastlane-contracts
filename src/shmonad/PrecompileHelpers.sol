//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

import { IMonadStaking } from "./interfaces/IMonadStaking.sol";
import {
    MIN_VALIDATOR_DEPOSIT,
    DUST_THRESHOLD,
    UNKNOWN_VAL_ID,
    MAX_EXTERNAL_REWARD,
    VALIDATOR_CRANK_LIMIT,
    STAKING_GAS_BUFFER,
    STAKING_GAS_CLAIM_REWARDS,
    STAKING_GAS_EXTERNAL_REWARD,
    STAKING_GAS_GET_WITHDRAWAL_REQUEST,
    STAKING_GAS_GET_DELEGATOR,
    STAKING_GAS_DELEGATE,
    STAKING_GAS_UNDELEGATE,
    STAKING_GAS_WITHDRAW,
    STAKING_GAS_PROPOSER_VAL_ID
} from "./Constants.sol";

abstract contract PrecompileHelpers {
    using SafeCastLib for uint256;
    using Math for uint256;

    // ================================================== //
    //             Staking Precompile Helpers             //
    // ================================================== //

    // We always pull rewards rather than compound them in a validator
    function _claimRewards(uint64 valId) internal returns (uint120 rewardAmount, bool success) {
        uint256 _balance = address(this).balance;
        try STAKING_PRECOMPILE().claimRewards{ gas: STAKING_GAS_CLAIM_REWARDS + STAKING_GAS_BUFFER }(valId) returns (
            bool precompileSuccess
        ) {
            if (!precompileSuccess) {
                return (0, false);
            }
            rewardAmount = uint120(address(this).balance - _balance);
            return (rewardAmount, true);
        } catch {
            // Validator may not have an active delegation yet; skip without reverting
            return (0, false);
        }
    }

    function _initiateWithdrawal(
        uint64 valId,
        uint128 withdrawalAmount,
        uint8 withdrawalId
    )
        internal
        returns (bool success, uint128)
    {
        uint256 _withdrawalAmount = uint256(withdrawalAmount);
        try STAKING_PRECOMPILE().undelegate{ gas: STAKING_GAS_UNDELEGATE + STAKING_GAS_BUFFER }(
            valId, _withdrawalAmount, withdrawalId
        ) returns (bool precompileSuccess) {
            if (!precompileSuccess) {
                return (false, 0);
            }
            return (true, withdrawalAmount);
        } catch {
            try STAKING_PRECOMPILE().getDelegator{ gas: STAKING_GAS_GET_DELEGATOR + STAKING_GAS_BUFFER }(
                valId, address(this)
            ) returns (uint256 stake, uint256, uint256, uint256, uint256, uint64, uint64) {
                if (stake > 0) {
                    if (stake < _withdrawalAmount) {
                        // NOTE: Ideally we would never reach this point, but we should aim to handle it so that we can
                        // handle emergency Monad hard forks that
                        // impact staking and that occur faster than our upgrade window will allow us to upgrade ShMonad
                        // source code. The most likely
                        // scenario is handling slashing.
                        _withdrawalAmount = stake;
                        try STAKING_PRECOMPILE().undelegate{ gas: STAKING_GAS_UNDELEGATE + STAKING_GAS_BUFFER }(
                            valId, _withdrawalAmount, withdrawalId
                        ) returns (bool retrySuccess) {
                            if (!retrySuccess) {
                                return (false, 0);
                            }
                            return (true, _withdrawalAmount.toUint128());
                        } catch {
                            // Pass - If we cant withdraw our staked amount, consider it a failure.
                        }
                    } else {
                        // Pass - If we cant withdraw our staked amount, consider it a failure.
                    }
                } else {
                    // Count it as a success if we're seeing a zero balance because hey at least we can see it. Silver
                    // lining.
                    return (true, 0);
                }
            } catch {
                // Pass - count it as a faillure because we can't even see our delegation
            }
        }
        return (false, 0);
    }

    function _initiateStaking(
        uint64 valId,
        uint128 stakingAmount
    )
        internal
        returns (bool success, uint128 amountStaked)
    {
        // stakingAmount should never be more than the contract balance.
        assert(stakingAmount <= address(this).balance);

        if (stakingAmount > DUST_THRESHOLD) {
            try STAKING_PRECOMPILE().delegate{ value: stakingAmount, gas: STAKING_GAS_DELEGATE + STAKING_GAS_BUFFER }(
                valId
            ) returns (bool precompileSuccess) {
                if (!precompileSuccess) {
                    return (false, 0);
                }
                return (true, stakingAmount);
            } catch {
                return (false, 0);
            }
        } else {
            return (true, 0);
        }
    }

    function _completeWithdrawal(
        uint64 valId,
        uint8 withdrawalId
    )
        internal
        returns (uint128 withdrawalAmount, bool success, bool delayed)
    {
        uint256 _balance = address(this).balance;
        try STAKING_PRECOMPILE().withdraw{ gas: STAKING_GAS_WITHDRAW + STAKING_GAS_BUFFER }(valId, withdrawalId)
        returns (bool precompileSuccess) {
            if (!precompileSuccess) {
                // Precompile rejected the withdrawal, check if it's delayed
                try STAKING_PRECOMPILE().getWithdrawalRequest{
                    gas: STAKING_GAS_GET_WITHDRAWAL_REQUEST + STAKING_GAS_BUFFER
                }(valId, address(this), withdrawalId) returns (uint256 amountRaw, uint256, uint64) {
                    if (amountRaw > 0) delayed = true;
                    withdrawalAmount = amountRaw.toUint128();
                } catch {
                    withdrawalAmount = 0;
                }
                return (withdrawalAmount, false, delayed);
            }
            withdrawalAmount = (address(this).balance - _balance).toUint128();
            success = true;
        } catch {
            try STAKING_PRECOMPILE().getWithdrawalRequest{ gas: STAKING_GAS_GET_WITHDRAWAL_REQUEST + STAKING_GAS_BUFFER }(
                valId, address(this), withdrawalId
            ) returns (uint256 amountRaw, uint256, uint64) {
                if (amountRaw > 0) delayed = true;
                withdrawalAmount = amountRaw.toUint128();
            } catch {
                // NOTE: In reality we should never reach this point, but we should aim to handle it so that we can
                // handle emergency Monad hard forks that
                // impact staking and that occur faster than our upgrade window will allow us to upgrade ShMonad source
                // code. The most likely
                // scenario is handling slashing.
                withdrawalAmount = 0;
            }
            success = false;
        }
        return (withdrawalAmount, success, delayed);
    }

    function _sendRewards(uint64 valId, uint128 rewardAmount) internal returns (bool success, uint120 amountSent) {
        uint256 _remaining = uint256(rewardAmount);

        if (_remaining > address(this).balance) {
            _remaining = address(this).balance;
        }

        if (_remaining < MIN_VALIDATOR_DEPOSIT) {
            return (true, 0);
        }

        // Loop sends rewards in chunks of MAX_EXTERNAL_REWARD. We always attempt
        // at least one send, then break early if gasleft() drops below
        // VALIDATOR_CRANK_LIMIT to avoid OOG during validator cranks.
        while (_remaining >= MIN_VALIDATOR_DEPOSIT) {
            uint256 _amountToSend = _remaining > MAX_EXTERNAL_REWARD ? MAX_EXTERNAL_REWARD : _remaining;

            try STAKING_PRECOMPILE().externalReward{
                value: _amountToSend,
                gas: STAKING_GAS_EXTERNAL_REWARD + STAKING_GAS_BUFFER
            }(valId) returns (bool precompileSuccess) {
                if (!precompileSuccess) {
                    // Unreachable in production (precompile returns true or reverts), but keep this to preserve
                    // partial-send accounting if a later iteration reports false after earlier chunks succeeded.
                    return (amountSent > 0, amountSent);
                }
                amountSent += _amountToSend.toUint120();
                _remaining -= _amountToSend;
            } catch {
                return (amountSent > 0, amountSent);
            }

            // Attempt at least one send; thereafter bail out if we're low on gas to avoid cranking stalls.
            if (_remaining < MIN_VALIDATOR_DEPOSIT) break;
            if (gasleft() <= VALIDATOR_CRANK_LIMIT) break;
        }

        // Return true so callers treat any unsent remainder as a partial payment to retry next epoch.
        return (true, amountSent);
    }

    function _getStakeInfo(uint64 valId) internal returns (uint256 activeStake, uint256 pendingDeposits) {
        try STAKING_PRECOMPILE().getDelegator(valId, address(this)) returns (
            uint256 _stake, uint256, uint256, uint256 _deltaStake, uint256 _nextDeltaStake, uint64, uint64
        ) {
            return (_stake, _deltaStake + _nextDeltaStake);
        } catch {
            return (0, 0);
        }
    }

    function _getWithdrawalAmount(uint64 valId, uint8 withdrawId) internal returns (uint256 withdrawalAmount) {
        try STAKING_PRECOMPILE().getWithdrawalRequest(valId, address(this), withdrawId) returns (
            uint256 _withdrawalAmount, uint256, uint64
        ) {
            return _withdrawalAmount;
        } catch {
            return 0;
        }
    }

    function _getEpoch() internal returns (uint64) {
        (uint64 _epoch,) = STAKING_PRECOMPILE().getEpoch();
        return _epoch;
    }

    function _getEpochBarrierAdj() internal returns (uint64) {
        (uint64 _epoch, bool __inEpochDelayPeriod) = STAKING_PRECOMPILE().getEpoch();
        if (__inEpochDelayPeriod) ++_epoch;
        return _epoch;
    }

    function _inEpochDelayPeriod() internal returns (bool) {
        (, bool __inEpochDelayPeriod) = STAKING_PRECOMPILE().getEpoch();
        return __inEpochDelayPeriod;
    }

    /// @notice Returns whether a validator is in the active set for the current epoch context
    /// @dev Uses snapshot stake during the epoch delay window, otherwise consensus stake
    function _isValidatorInActiveSet(uint64 valId) internal returns (bool) {
        bool inDelay = _inEpochDelayPeriod();
        try STAKING_PRECOMPILE().getValidator(valId) returns (
            address,
            uint64,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256 consensusStake,
            uint256,
            uint256 snapshotStake,
            uint256,
            bytes memory,
            bytes memory
        ) {
            if (inDelay) {
                return snapshotStake > 0;
            } else {
                return consensusStake > 0;
            }
        } catch {
            // If the precompile reverts or is unavailable, treat as not in active set
            return false;
        }
    }

    /// @notice Helper to fetch current validator ID from precompile with safe fallback
    /// @dev Tries getProposerValId(), and returns UNKNOWN_VAL_ID on failure/zero
    function _getCurrentValidatorId() internal returns (uint64 validatorId) {
        try STAKING_PRECOMPILE().getProposerValId{ gas: STAKING_GAS_PROPOSER_VAL_ID + STAKING_GAS_BUFFER }() returns (
            uint64 _valId
        ) {
            if (_valId != 0) return _valId;
        } catch {
            return uint64(UNKNOWN_VAL_ID);
        }
    }

    // ================================================== //
    //                   Virtual Methods                  //
    // ================================================== //

    /// @custom:selector 0x0cb9f3ad
    function STAKING_PRECOMPILE() public pure virtual returns (IMonadStaking);

    modifier expectsRewards() virtual;

    function _totalEquity(bool deductRecentRevenue) internal view virtual returns (uint256);
    function _validatorIdForCoinbase(address coinbase) internal view virtual returns (uint64);
}
