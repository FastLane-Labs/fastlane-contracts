//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { IERC4626Custom } from "./IERC4626Custom.sol";
import { IERC20Full } from "./IERC20Full.sol";
import { IMonadStaking } from "./IMonadStaking.sol";
import { Policy, UncommitApproval, ValidatorStats } from "../Types.sol";

/**
 * @title IShMonad - Interface for the ShMonad Liquid Staking Token contract
 * @notice Canonical NatSpec lives on the concrete mixins; this interface captures every external/public entrypoint.
 */
interface IShMonad is IERC4626Custom, IERC20Full {
    // --------------------------------------------- //
    //          Initialization & Supply Views        //
    // --------------------------------------------- //

    function initialize(address deployer) external;

    function realTotalSupply() external view returns (uint256);

    function committedTotalSupply() external view returns (uint256);

    // --------------------------------------------- //
    //         Yield & Detailed ERC4626 Previews     //
    // --------------------------------------------- //

    function boostYield(address yieldOriginator) external payable;

    function boostYield(uint256 shares, address from, address yieldOriginator) external;

    function sendValidatorRewards(uint64 validatorId, uint256 feeRate) external payable;

    function previewRedeemDetailed(uint256 shares)
        external
        view
        returns (uint256 grossAssets, uint256 feeAssets, uint256 netAssets);

    function previewWithdrawDetailed(uint256 netAssets)
        external
        view
        returns (uint256 shares, uint256 grossAssets, uint256 feeAssets);

    function previewUnstake(uint256 shares) external view returns (uint256 assets);

    // --------------------------------------------- //
    //            Account & Commitment Flow          //
    // --------------------------------------------- //

    function commit(uint64 policyID, address commitRecipient, uint256 shares) external;

    function depositAndCommit(
        uint64 policyID,
        address commitRecipient,
        uint256 shMonToCommit
    )
        external
        payable
        returns (uint256 sharesMinted);

    function requestUncommit(
        uint64 policyID,
        uint256 shares,
        uint256 newMinBalance
    )
        external
        returns (uint256 uncommitCompleteBlock);

    function requestUncommitWithApprovedCompletor(
        uint64 policyID,
        uint256 shares,
        uint256 newMinBalance,
        address completor
    )
        external
        returns (uint256 uncommitCompleteBlock);

    function completeUncommit(uint64 policyID, uint256 shares) external;

    function completeUncommitAndRedeem(uint64 policyID, uint256 shares) external returns (uint256 assets);

    function completeUncommitAndRecommit(
        uint64 fromPolicyID,
        uint64 toPolicyID,
        address commitRecipient,
        uint256 shares
    )
        external;

    function completeUncommitWithApproval(uint64 policyID, uint256 shares, address account) external;

    function setUncommitApproval(uint64 policyID, address completor, uint256 shares) external;

    // --------------------------------------------- //
    //               Unstake Lifecycle               //
    // --------------------------------------------- //

    function requestUnstake(uint256 shares) external returns (uint64 completionEpoch);

    function completeUnstake() external;

    function getUnstakeRequest(address account) external view returns (uint128 amountMon, uint64 completionEpoch);

    // --------------------------------------------- //
    //             Agent & Hold Operations           //
    // --------------------------------------------- //

    function hold(uint64 policyID, address account, uint256 shares) external;

    function release(uint64 policyID, address account, uint256 shares) external;

    function batchHold(uint64 policyID, address[] calldata accounts, uint256[] memory amounts) external;

    function batchRelease(uint64 policyID, address[] calldata accounts, uint256[] calldata amounts) external;

    function agentTransferFromCommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    function agentTransferToUncommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    function agentWithdrawFromCommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool amountSpecifiedInUnderlying
    )
        external;

    function getHoldAmount(uint64 policyID, address account) external view returns (uint256);

    // --------------------------------------------- //
    //         Top-Up Settings & Balance Views       //
    // --------------------------------------------- //

    function setMinCommittedBalance(
        uint64 policyID,
        uint128 minCommitted,
        uint128 maxTopUpPerPeriod,
        uint32 topUpPeriodDuration
    )
        external;

    function getTopUpSettings(
        uint64 policyID,
        address account
    )
        external
        view
        returns (uint128 maxTopUpPerPeriod, uint32 topUpPeriodDuration);

    function getCommittedData(
        uint64 policyID,
        address account
    )
        external
        view
        returns (uint128 committed, uint128 minCommitted);

    function getUncommittingData(
        uint64 policyID,
        address account
    )
        external
        view
        returns (uint128 uncommitting, uint48 uncommitStartBlock);

    function policyBalanceAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        external
        view
        returns (uint256 balanceAvailable);

    function topUpAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        external
        view
        returns (uint256 amountAvailable);

    function getUncommitApproval(
        uint64 policyID,
        address account
    )
        external
        view
        returns (UncommitApproval memory approval);

    function uncommittingCompleteBlock(uint64 policyID, address account) external view returns (uint256);

    function balanceOfCommitted(address account) external view returns (uint256);

    function balanceOfCommitted(uint64 policyID, address account) external view returns (uint256);

    function balanceOfUncommitting(uint64 policyID, address account) external view returns (uint256);

    // --------------------------------------------- //
    //               Policy Management               //
    // --------------------------------------------- //

    function createPolicy(uint48 escrowDuration) external returns (uint64 policyID);

    function addPolicyAgent(uint64 policyID, address agent) external;

    function removePolicyAgent(uint64 policyID, address agent) external;

    function disablePolicy(uint64 policyID) external;

    function policyCount() external view returns (uint64);

    function getPolicy(uint64 policyID) external view returns (Policy memory);

    function isPolicyAgent(uint64 policyID, address agent) external view returns (bool);

    function getPolicyAgents(uint64 policyID) external view returns (address[] memory);

    // --------------------------------------------- //
    //          Atomic Unstake Pool Management       //
    // --------------------------------------------- //

    function setPoolTargetLiquidityPercentage(uint256 newPercentageScaled) external;

    function setUnstakeFeeCurve(uint256 newSlopeRateRay, uint256 newYInterceptRay) external;

    function yInterceptRay() external view returns (uint256);

    function slopeRateRay() external view returns (uint256);

    function getCurrentLiquidity() external view returns (uint256);

    function getTargetLiquidity() external view returns (uint256);

    function getPendingTargetLiquidity() external view returns (uint256);

    function getAtomicPoolUtilization()
        external
        view
        returns (uint256 utilized, uint256 allocated, uint256 available, uint256 utilizationWad);

    function getFeeCurveParams() external view returns (uint256 slopeRateRayOut, uint256 yInterceptRayOut);

    function getAtomicUtilizationWad() external view returns (uint256 utilizationWad);

    function getCurrentUnstakeFeeRateRay() external view returns (uint256 feeRateRay);

    // --------------------------------------------- //
    //           Global Accounting & Cranking        //
    // --------------------------------------------- //

    function crank() external returns (bool complete);

    function isGlobalCrankAvailable() external returns (bool);

    function isValidatorCrankAvailable(uint64 validatorId) external view returns (bool);

    function getWorkingCapital() external view returns (uint128 stakedAmount, uint128 reservedAmount);

    function getAtomicCapital() external view returns (uint128 allocatedAmount, uint128 distributedAmount);

    function getGlobalPending() external view returns (uint120 pendingStaking, uint120 pendingUnstaking);

    function getGlobalCashFlows(int256 epochPointer)
        external
        view
        returns (uint120 queueToStake, uint120 queueForUnstake);

    function getGlobalRevenue(int256 epochPointer)
        external
        view
        returns (uint120 rewardsPayable, uint120 earnedRevenue);

    function getGlobalEpoch(int256 epochPointer)
        external
        view
        returns (
            uint64 epoch,
            uint8 withdrawalId,
            bool hasWithdrawal,
            bool hasDeposit,
            bool crankedInBoundaryPeriod,
            bool wasCranked,
            bool frozen,
            bool closed,
            uint128 targetStakeAmount
        );

    function getInternalEpoch() external view returns (uint64);

    function getGlobalStatus(int256 epochPointer) external view returns (bool frozen, bool closed);

    function getScaledTargetLiquidityPercentage() external view returns (uint256);

    function getGlobalAmountAvailableToUnstake() external view returns (uint256 amount);

    function getCurrentAssets() external view returns (uint256);

    function globalLiabilities()
        external
        view
        returns (uint128 rewardsPayable, uint128 redemptionsPayable, uint128 commissionPayable);

    function getAdminValues()
        external
        view
        returns (
            uint64 internalEpoch,
            uint16 targetLiquidityPercentage,
            uint16 incentiveAlignmentPercentage,
            uint16 stakingCommission,
            uint16 boostCommissionRate,
            uint128 commissionPayable
        );

    function STAKING_PRECOMPILE() external pure returns (IMonadStaking);

    // --------------------------------------------- //
    //             Validator Administration          //
    // --------------------------------------------- //

    function deactivateValidator(uint64 validatorId) external;

    function addValidator(uint64 validatorId, address coinbase) external;

    function addValidator(uint64 validatorId) external returns (address coinbase);

    function updateStakingCommission(uint16 feeInBps) external;

    function updateBoostCommission(uint16 feeInBps) external;

    function updateIncentiveAlignmentPercentage(uint16 percentageInBps) external;

    function setFrozenStatus(bool isFrozen) external;

    function setClosedStatus(bool isClosed) external;

    function processCoinbaseByAuth(uint64 validatorId) external;
    function processCoinbaseByAuth(address coinbase) external;

    function claimOwnerCommissionAsShares(uint256 assets, address receiver) external returns (uint256 sharesMinted);

    // --------------------------------------------- //
    //                 Validator Views               //
    // --------------------------------------------- //

    function previewCoinbaseAddress(uint64 validatorId) external view returns (address predicted);

    function getValidatorStats(uint64 validatorId) external view returns (ValidatorStats memory stats);

    function isValidatorActive(uint64 validatorId) external view returns (bool);

    function getEpochInfo() external returns (uint256 epochNumber, uint256 epochStartBlock);

    function getValidatorCoinbase(uint256 validatorId) external view returns (address);

    function getValidatorIdForCoinbase(address coinbase) external view returns (uint256);

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
        );

    function listActiveValidators() external view returns (uint64[] memory validatorIds, address[] memory coinbases);

    function getValidatorEpochs(uint64 validatorId)
        external
        view
        returns (uint64 lastEpoch, uint128 lastTargetStakeAmount, uint64 currentEpoch, uint128 currentTargetStakeAmount);

    function getValidatorPendingEscrow(uint64 validatorId)
        external
        view
        returns (
            uint120 lastPendingStaking,
            uint120 lastPendingUnstaking,
            uint120 currentPendingStaking,
            uint120 currentPendingUnstaking
        );

    function getValidatorRewards(uint64 validatorId)
        external
        view
        returns (
            uint120 lastRewardsPayable,
            uint120 lastEarnedRevenue,
            uint120 currentRewardsPayable,
            uint120 currentEarnedRevenue
        );

    function getValidatorNeighbors(uint64 validatorId) external view returns (address previous, address next);

    function getActiveValidatorCount() external view returns (uint256);

    function getNextValidatorToCrank() external view returns (address);
}
