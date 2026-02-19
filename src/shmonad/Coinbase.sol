//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IMonadStaking } from "./interfaces/IMonadStaking.sol";
import { ICoinbase } from "./interfaces/ICoinbase.sol";
import {
    STAKING,
    MIN_VALIDATOR_DEPOSIT,
    MAX_EXTERNAL_REWARD,
    SCALE,
    TRANSFER_GAS_LIMIT,
    STAKING_GAS_BUFFER,
    STAKING_GAS_EXTERNAL_REWARD,
    STAKING_GAS_GET_VALIDATOR
} from "./Constants.sol";

struct CoinbaseConfig {
    address commissionRecipient; // receives validator commission sent in `process()`
    uint96 priorityCommissionRate; // as a fraction of 1e18
    uint96 donationRate; // as a fraction of 1e18. donations count as validator revenue to shMON
    uint96 mevCommissionRate; // as a fraction of 1e18
    address authAddress; // the last authAddress of the validator according to staking precompile
}

struct UnpaidBalances {
    uint120 commission;
    uint120 rewards;
    bool alwaysTrue;
}

contract Coinbase is ICoinbase, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    uint64 public immutable VAL_ID;
    address public immutable SHMONAD;
    address public immutable SELF;

    CoinbaseConfig internal s_config;
    UnpaidBalances internal s_unpaid;

    /// @custom:selector 0x688065ed
    error OnlyShMonadCaller();
    /// @custom:selector 0x9bfdc6ff
    error OnlyAuthAddress();
    /// @custom:selector 0x8e238934
    error OnlySelfCaller();
    /// @custom:selector 0x8fe552e0
    error InvalidCommissionRate();
    /// @custom:selector 0x57471710
    error InvalidDonationRate();
    /// @custom:selector 0x0721e756
    error AuthAddressNotChanged();
    /// @custom:selector 0xd48c2547
    error RewardFailed();
    /// @custom:selector 0x4cd921bb
    error CommissionFailed();
    /// @custom:selector 0x77f4312b
    error DonationFailed();
    /// @custom:selector 0xd8707052
    error RecipientCannotBeZeroAddress();
    /// @custom:selector 0x19708e71
    error ValidatorNotFoundInPrecompile(uint64 validatorId);
    /// @custom:selector 0x193baad9
    error MEVMustExceedZero();

    /// @custom:selector 0x36914845
    event PriorityCommissionRateUpdated(uint256 oldCommissionRate, uint256 newCommissionRate);
    /// @custom:selector 0xd2bbd200
    event MEVCommissionRateUpdated(uint256 oldCommissionRate, uint256 newCommissionRate);

    /// @custom:selector 0x8013f423
    event DonationRateUpdated(uint256 oldDonationRate, uint256 newDonationRate);
    /// @custom:selector 0x2c40de6e
    event CommissionRecipientUpdated(address oldRecipient, address newRecipient);
    /// @custom:selector 0xc0bb63ce
    event AuthAddressUpdated(address oldAuthAddress, address newAuthAddress);

    constructor(uint64 valId) {
        VAL_ID = valId;
        SHMONAD = msg.sender;
        SELF = address(this);

        (address _authAddress, uint256 _commissionRate) = _getValidator(valId);

        s_config = CoinbaseConfig({
            commissionRecipient: _authAddress,
            priorityCommissionRate: _commissionRate.toUint96(),
            donationRate: 0,
            mevCommissionRate: _commissionRate.toUint96(),
            authAddress: _authAddress
        });

        s_unpaid.alwaysTrue = true;

        emit PriorityCommissionRateUpdated(0, _commissionRate);
        emit MEVCommissionRateUpdated(0, _commissionRate);
        emit CommissionRecipientUpdated(address(0), _authAddress);
    }

    receive() external payable { }

    modifier onlyAuthAddress() {
        require(msg.sender == s_config.authAddress, OnlyAuthAddress());
        _;
    }

    modifier onlyShMonad() {
        require(msg.sender == SHMONAD, OnlyShMonadCaller());
        _;
    }

    modifier onlySelf() {
        require(msg.sender == SELF, OnlySelfCaller());
        _;
    }

    /// @custom:selector 0xbeac7323
    function handleMEVPayable() external payable onlyShMonad nonReentrant {
        require(msg.value > 0, MEVMustExceedZero());

        uint256 _grossMEV = msg.value;
        uint256 _mevCommissionRate = s_config.mevCommissionRate;

        uint256 _mevCommissionToValidator = _grossMEV * _mevCommissionRate / SCALE;
        uint256 _netMEV = _grossMEV - _mevCommissionToValidator;

        UnpaidBalances memory _unpaid = s_unpaid;
        _unpaid.commission += _mevCommissionToValidator.toUint120();
        _unpaid.rewards += _netMEV.toUint120();
        s_unpaid = _unpaid;
    }

    /// @dev This is called during `_crankValidator()` in ShMonad, so should never revert.
    /// @custom:selector 0xc33fb877
    function process() external onlyShMonad nonReentrant returns (bool success) {
        // Strategy:
        // 1) Split current balance (excluding previously unpaid) into commission, donation, rewards.
        // 2) Cap rewards to a single externalReward call under the precompile limit; store remainder as unpaid.
        // 3) Attempt rewards and commission/donation independently; record unpaid on failure.
        CoinbaseConfig memory _config = s_config;
        UnpaidBalances memory _unpaid = s_unpaid;
        uint256 _unpaidCommission = _unpaid.commission;
        uint256 _unpaidRewards = _unpaid.rewards;
        bool _updateUnpaidBalances = false;

        // All balances other than previously unpaid rewards are accrued priority fees
        uint256 _currentBalance = address(this).balance;
        // Allow exact-paydown of arrears without requiring extra headroom.
        uint256 _arrearsTotal = _unpaidCommission + _unpaidRewards;
        if (_currentBalance < _arrearsTotal) return false;
        if (_currentBalance == 0) return false;
        if (_config.priorityCommissionRate + _config.donationRate > SCALE) return false;
        _currentBalance -= _arrearsTotal;

        // Calculate the commission
        uint256 _validatorCommission = (_currentBalance * _config.priorityCommissionRate / SCALE);
        uint256 _shMonadDonation = _currentBalance * _config.donationRate / SCALE;
        uint256 _rewardPortion = _currentBalance - _validatorCommission - _shMonadDonation;

        _validatorCommission += _unpaidCommission;
        _rewardPortion += _unpaidRewards;

        // Compute reward payout cap upfront (single externalReward call)
        bool _canPayRewards = _rewardPortion >= MIN_VALIDATOR_DEPOSIT;
        uint256 _rewardPayout;
        uint256 _rewardRemainder;
        if (_canPayRewards) {
            // stay 1 MON below the externalReward hard limit to avoid reverts
            _rewardPayout = Math.min(MAX_EXTERNAL_REWARD - 1e18, _rewardPortion);
            _rewardRemainder = _rewardPortion - _rewardPayout;
        }

        // Attempt rewards (single call, capped) and commission/donation independently; track partial success.
        bool _rewardsSucceeded = false;
        if (_canPayRewards) {
            try this.sendRewardsToDelegates(_rewardPayout) {
                _rewardsSucceeded = true;
                _unpaidRewards = _rewardRemainder.toUint128();
                if (_unpaidRewards > 0 || _unpaid.rewards > 0) _updateUnpaidBalances = true;
            } catch {
                _unpaidRewards = _rewardPortion.toUint128();
                _updateUnpaidBalances = true;
            }
        } else {
            // Not enough to pay out; record and keep success=false for rewards.
            _unpaidRewards = _rewardPortion.toUint128();
            if (_unpaidRewards > _unpaid.rewards) _updateUnpaidBalances = true;
        }

        bool _commissionSucceeded = true;
        bool _donationSucceeded = true;
        if (_validatorCommission > 0 || _shMonadDonation > 0) {
            try this.sendCommissionAndDonation(_config.commissionRecipient, _validatorCommission, _shMonadDonation)
            returns (bool commissionSucceeded, bool donationSucceeded) {
                _commissionSucceeded = commissionSucceeded;
                _donationSucceeded = donationSucceeded;
            } catch {
                _commissionSucceeded = false;
                _donationSucceeded = false;
            }

            if (_commissionSucceeded) {
                if (_unpaidCommission > 0) {
                    _unpaidCommission = 0;
                    _updateUnpaidBalances = true;
                }
            } else {
                if (_validatorCommission > _unpaidCommission) {
                    _unpaidCommission = _validatorCommission;
                    _updateUnpaidBalances = true;
                }
            }
        }

        // Success only if all intended payouts succeeded; partial effects are kept via unpaid balances.
        success = _rewardsSucceeded && _commissionSucceeded && _donationSucceeded;

        if (_updateUnpaidBalances) {
            s_unpaid = UnpaidBalances({
                commission: _unpaidCommission.toUint120(),
                rewards: _unpaidRewards.toUint120(),
                alwaysTrue: true
            });
        }
    }

    /// @custom:selector 0x97751992
    function sendRewardsToDelegates(uint256 rewardPortion) external onlySelf {
        bool _sendRewardsSucceeded = _sendRewards(VAL_ID, rewardPortion);
        require(_sendRewardsSucceeded, RewardFailed());
    }

    /// @custom:selector 0x5f69d439
    function sendCommissionAndDonation(
        address commissionRecipient,
        uint256 validatorCommission,
        uint256 shMonadDonation
    )
        external
        onlySelf
        returns (bool commissionSucceeded, bool donationSucceeded)
    {
        // Send commission to recipient and donation to shMonad (where it counts as revenue).
        // Transfers are independent; failures are reported via return values for unpaid tracking.
        commissionSucceeded = true;
        donationSucceeded = true;
        if (validatorCommission > 0) {
            commissionSucceeded = commissionRecipient.trySafeTransferETH(validatorCommission, TRANSFER_GAS_LIMIT);
        }
        if (shMonadDonation > 0) {
            donationSucceeded = SHMONAD.trySafeTransferETH(shMonadDonation, TRANSFER_GAS_LIMIT);
        }
    }

    /// @custom:selector 0x8982e4ee
    function updateAuthAddress() external {
        address _previousAuthAddress = s_config.authAddress;
        (address _newAuthAddress,) = _getValidator(VAL_ID);

        require(msg.sender == _previousAuthAddress || msg.sender == _newAuthAddress, OnlyAuthAddress());
        require(_previousAuthAddress != _newAuthAddress, AuthAddressNotChanged());

        s_config.authAddress = _newAuthAddress;

        emit AuthAddressUpdated(_previousAuthAddress, _newAuthAddress);
    }

    /// @custom:selector 0x33c2c2c1
    function updatePriorityCommissionRate(uint256 newCommissionRate) external onlyAuthAddress {
        // donation + commission cannot exceed 100%
        uint256 _oldDonationRate = s_config.donationRate;
        require(newCommissionRate + _oldDonationRate <= SCALE, InvalidCommissionRate());

        uint256 _oldCommissionRate = s_config.priorityCommissionRate;
        s_config.priorityCommissionRate = newCommissionRate.toUint96();

        emit PriorityCommissionRateUpdated(_oldCommissionRate, newCommissionRate);
    }

    /// @custom:selector 0xcaefb7df
    function updateMEVCommissionRate(uint256 newCommissionRate) external onlyAuthAddress {
        // commission cannot exceed 100%
        require(newCommissionRate <= SCALE, InvalidCommissionRate());

        uint256 _oldCommissionRate = s_config.mevCommissionRate;
        s_config.mevCommissionRate = newCommissionRate.toUint96();

        emit MEVCommissionRateUpdated(_oldCommissionRate, newCommissionRate);
    }

    /// @custom:selector 0x1056c7fe
    function updateShMonadDonationRate(uint256 newDonationRate) external onlyAuthAddress {
        // donation + commission cannot exceed 100%
        uint256 _oldCommissionRate = s_config.priorityCommissionRate;
        require(_oldCommissionRate + newDonationRate <= SCALE, InvalidDonationRate());

        uint256 _oldDonationRate = s_config.donationRate;
        s_config.donationRate = newDonationRate.toUint96();

        emit DonationRateUpdated(_oldDonationRate, newDonationRate);
    }

    /// @custom:selector 0x6f7cbce4
    function updateCommissionRateFromStakingConfig() external onlyAuthAddress {
        (, uint256 _newCommissionRate) = _getValidator(VAL_ID);
        require(_newCommissionRate <= SCALE, InvalidCommissionRate());

        uint256 _oldCommissionRate = s_config.priorityCommissionRate;
        uint256 _oldMEVCommissionRate = s_config.mevCommissionRate;
        uint256 _oldDonationRate = s_config.donationRate;
        uint256 _newDonationRate = _oldDonationRate;

        // If new commission rate + old donation rate > SCALE, adjust donation rate downwards
        if (_newCommissionRate + _oldDonationRate > SCALE) {
            _newDonationRate = SCALE - _newCommissionRate;
        }

        s_config.priorityCommissionRate = _newCommissionRate.toUint96();
        s_config.mevCommissionRate = _newCommissionRate.toUint96();

        if (_newDonationRate != _oldDonationRate) {
            s_config.donationRate = _newDonationRate.toUint96();
            emit DonationRateUpdated(_oldDonationRate, _newDonationRate);
        }

        emit PriorityCommissionRateUpdated(_oldCommissionRate, _newCommissionRate);
        emit MEVCommissionRateUpdated(_oldMEVCommissionRate, _newCommissionRate);
    }

    /// @custom:selector 0x3f3b061a
    function updateCommissionRecipient(address newRecipient) external onlyAuthAddress {
        require(newRecipient != address(0), RecipientCannotBeZeroAddress());
        address _oldRecipient = s_config.commissionRecipient;
        s_config.commissionRecipient = newRecipient;

        emit CommissionRecipientUpdated(_oldRecipient, newRecipient);
    }

    /// @custom:selector 0x15f6194e
    function getPriorityCommissionRate() external view returns (uint256) {
        return s_config.priorityCommissionRate;
    }

    /// @custom:selector 0x9afefbbd
    function getMEVCommissionRate() external view returns (uint256) {
        return s_config.mevCommissionRate;
    }

    /// @custom:selector 0x4890f108
    function getShMonadDonationRate() external view returns (uint256) {
        return s_config.donationRate;
    }

    /// @custom:selector 0x9b296734
    function getCommissionRecipient() external view returns (address) {
        return s_config.commissionRecipient;
    }

    /// @custom:selector 0x7c827bc2
    function getUnpaidBalances() external view returns (uint256 commission, uint256 rewards) {
        UnpaidBalances memory _unpaid = s_unpaid;
        return (_unpaid.commission, _unpaid.rewards);
    }

    /// @custom:selector 0x7c359fe0
    function AUTH_ADDRESS() external view returns (address) {
        return s_config.authAddress;
    }

    function _inEpochDelayPeriod() internal returns (bool) {
        (, bool _isInEpochDelayPeriod) = STAKING.getEpoch();
        return _isInEpochDelayPeriod;
    }

    function _sendRewards(uint64 validatorId, uint256 rewardAmount) internal returns (bool) {
        try STAKING.externalReward{ value: rewardAmount, gas: STAKING_GAS_EXTERNAL_REWARD + STAKING_GAS_BUFFER }(
            validatorId
        ) returns (bool _precompileSuccess) {
            return _precompileSuccess;
        } catch {
            return false;
        }
    }

    function _getValidator(uint64 validatorId) internal returns (address authAddress, uint256 commissionRate) {
        // Note: Real precompile returns zeros for missing, mock reverts with UnknownValidator()
        try STAKING.getValidator{ gas: STAKING_GAS_GET_VALIDATOR + STAKING_GAS_BUFFER }(validatorId) returns (
            address _authAddress,
            uint64,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256 _consensusCommissionRate,
            uint256,
            uint256 _snapshotCommissionRate,
            bytes memory,
            bytes memory
        ) {
            authAddress = _authAddress;
            commissionRate = _inEpochDelayPeriod() ? _snapshotCommissionRate : _consensusCommissionRate;
        } catch { }
        require(authAddress != address(0), ValidatorNotFoundInPrecompile(validatorId));
    }
}
