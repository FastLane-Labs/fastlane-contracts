// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TaskMetadata, Size, Depth, LoadBalancer, Tracker, Trackers } from "../types/TaskTypes.sol";
import { TaskLoadBalancer } from "./LoadBalancer.sol";
import { IShMonad } from "../../shmonad/interfaces/IShMonad.sol";
import { TaskAccountingMath } from "../libraries/TaskAccountingMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TaskPricing
/// @notice Handles fee calculations and pricing for task execution
/// @dev Core component responsible for:
/// 1. Fee Calculation:
///    - Calculates fees at block (B), group (C), and supergroup (D) levels
///    - Adjusts fees based on period sizes (1 block, 4 blocks, 128 blocks)
///    - Handles fee collection and payment tracking
///
/// 2. Period Management:
///    - B level: Individual block metrics
///    - C level: Group metrics (4 blocks per group via _BITMAP_SPECIFICITY)
///    - D level: Supergroup metrics (128 blocks per group via _GROUP_SIZE)
///
/// 3. Fee Optimization:
///    - Uses weighted averages across different periods
///    - Adjusts for congestion and forecast windows
///    - Maintains minimum base fees per size category
///
/// TODO: Consider moving pricing logic to a dedicated pricing module
abstract contract TaskPricing is TaskLoadBalancer {
    /// @notice Constructor to set immutable variables
    /// @param shMonad The address of the shMonad contract
    /// @param policyId The policy ID for the task manager
    constructor(address shMonad, uint64 policyId) TaskLoadBalancer(shMonad, policyId) { }

    /// @notice Modifiers for weighted fee calculations
    /// @dev B_MOD (64) weighs recent blocks highest, C_MOD (16) for medium-term, D_MOD (4) for long-term
    uint256 private constant _B_MOD = 64;
    uint256 private constant _C_MOD = 16;
    uint256 private constant _D_MOD = 4;
    uint256 private constant _MOD_BASE = 84; // Sum of all modifiers

    /// @notice Calculates reimbursement amount for task execution
    /// @dev Considers metrics at all levels with period size adjustments:
    /// 1. B level: Raw block metrics (1 block period)
    /// 2. C level: Group metrics (4 block period)
    /// 3. D level: Supergroup metrics (128 block period)
    /// Takes maximum average fee across all levels after period adjustments
    /// @param trackers Current execution metrics at all levels
    /// @return payout trackers and calculated payout amount
    function _getReimbursementAmount(Trackers memory trackers) internal pure returns (uint256 payout) {
        // Get average unpaid fees rounded down
        (uint256 _avgFeeB, uint256 _avgFeeC, uint256 _avgFeeD) = _getAverageUnpaidFees(trackers, Math.Rounding.Floor);
        uint256 _incompleteTasksB = uint256(trackers.b.totalTasks) - uint256(trackers.b.executedTasks);

        if (_incompleteTasksB > 1) {
            uint256 _altPayout = ((_avgFeeB * _B_MOD) + (_avgFeeC * _C_MOD) + (_avgFeeD * _D_MOD)) / _MOD_BASE;
            if (_altPayout < _avgFeeB) {
                payout = _avgFeeB;
            } else if (_altPayout * 3 > _avgFeeB * (_incompleteTasksB + 2)) {
                payout = _avgFeeB * (_incompleteTasksB + 2) / 3;
            } else {
                payout = _altPayout;
            }
        } else {
            payout = _avgFeeB;
        }

        // The payout is NOT calculated from the net fee (what the executor will receive)
        // We must adjust by _FEE_SIG_FIG later
        return payout;
    }

    /// @notice Generates execution quote for future task scheduling
    /// @dev Uses weighted average of fees across periods:
    /// 1. Calculates period-adjusted averages for B, C, D levels
    /// 2. Applies weighting (_B_MOD:_C_MOD:_D_MOD = 64:16:4)
    /// 3. Adjusts for congestion and forecast distance
    /// @param trackers Metrics for target block and size
    /// @return executionQuote Estimated execution cost with adjustments
    function _getExecutionQuote(Trackers memory trackers) internal view returns (uint256 executionQuote) {
        // Get base fee from gas limit for this task size if we have no fees collected
        uint256 _baseFee = uint256(_MIN_FEE_RATE * _maxGasFromSize(trackers.size));

        // Get average unpaid fees rounded up
        (uint256 _avgFeeB, uint256 _avgFeeC, uint256 _avgFeeD) = _getAverageUnpaidFees(trackers, Math.Rounding.Ceil);

        // Adjust avg fee if they're below the base fee
        if (_avgFeeB < _baseFee) _avgFeeB = _baseFee;
        if (_avgFeeC < _baseFee) _avgFeeC = _baseFee;
        if (_avgFeeD < _baseFee) _avgFeeD = _baseFee;

        // Get the weighted average with ceiling rounding for quotes rounded up
        uint256 weightedB = Math.mulDiv(_avgFeeB, _B_MOD, _MOD_BASE, Math.Rounding.Ceil);
        uint256 weightedC = Math.mulDiv(_avgFeeC, _C_MOD, _MOD_BASE, Math.Rounding.Ceil);
        uint256 weightedD = Math.mulDiv(_avgFeeD, _D_MOD, _MOD_BASE, Math.Rounding.Ceil);
        executionQuote = weightedB + weightedC + weightedD;
        // This can be _BASE_RATE * GAS at the lowest

        // Add the congestion modifier with ceiling rounding
        executionQuote = Math.mulDiv(executionQuote, _CONGESTION_GROWTH_RATE, _BASE_RATE, Math.Rounding.Ceil);

        // Add the forecast modifier with ceiling rounding
        uint256 _forecastModifier = (trackers.blockNumber - block.number) / _GROUP_SIZE;
        uint256 forecastRate = Math.mulDiv(
            _BASE_RATE + (_FORECAST_GROWTH_RATE * _forecastModifier), _BASE_RATE, _BASE_RATE, Math.Rounding.Ceil
        );
        executionQuote = Math.mulDiv(executionQuote, forecastRate, _BASE_RATE, Math.Rounding.Ceil);

        return executionQuote;
    }

    /// @notice Generates average fees for incomplete tasks for the different task groupings
    /// @dev Uses weighted average of fees across periods
    /// NOTE: This is not adjusted for _FEE_SIG_FIG
    /// @param trackers Metrics for target block and size
    /// @param rounding The rounding mode for the calculation
    /// @return avgFeeB Average unpaid fee per task of B grouping
    /// @return avgFeeC Average unpaid fee per task of C grouping
    /// @return avgFeeD Average unpaid fee per task of D grouping
    function _getAverageUnpaidFees(
        Trackers memory trackers,
        Math.Rounding rounding
    )
        internal
        pure
        returns (uint256 avgFeeB, uint256 avgFeeC, uint256 avgFeeD)
    {
        // Calculate average fees for each tracker, defaulting to 1 task if totalTasks is 0
        uint256 _incompleteTasksB = uint256(trackers.b.totalTasks) - uint256(trackers.b.executedTasks);
        uint256 _incompleteTasksC = uint256(trackers.c.totalTasks) - uint256(trackers.c.executedTasks);
        uint256 _incompleteTasksD = uint256(trackers.d.totalTasks) - uint256(trackers.d.executedTasks);

        // Calculate average fees for each tracker, using base fee as fallback when no fees collected
        // NOTE: Fees paid can exceed fees collected in groups B and C due to avg payout calcs from D.
        uint256 _unpaidFeesB = trackers.b.cumulativeFeesPaid > trackers.b.cumulativeFeesCollected
            ? 0
            : uint256(trackers.b.cumulativeFeesCollected) - uint256(trackers.b.cumulativeFeesPaid);
        uint256 _unpaidFeesC = trackers.c.cumulativeFeesPaid > trackers.c.cumulativeFeesCollected
            ? 0
            : uint256(trackers.c.cumulativeFeesCollected) - uint256(trackers.c.cumulativeFeesPaid);
        uint256 _unpaidFeesD = trackers.d.cumulativeFeesPaid > trackers.d.cumulativeFeesCollected
            ? 0
            : uint256(trackers.d.cumulativeFeesCollected) - uint256(trackers.d.cumulativeFeesPaid);

        // Calculate average fees for each tracker, using base fee as fallback when no fees collected rounded down on
        // payouts and rounded up on quotes
        avgFeeB = _incompleteTasksB == 0 ? 0 : Math.mulDiv(_unpaidFeesB, 1, _incompleteTasksB, rounding);
        avgFeeC = _incompleteTasksC == 0 ? 0 : Math.mulDiv(_unpaidFeesC, 1, _incompleteTasksC, rounding);
        avgFeeD = _incompleteTasksD == 0 ? 0 : Math.mulDiv(_unpaidFeesD, 1, _incompleteTasksD, rounding);
    }

    function _convertMonToShMon(uint256 amount) internal view returns (uint256 shares) {
        shares = IShMonad(SHMONAD).previewDeposit(amount);
    }

    function _convertShMonToMon(uint256 shares) internal view returns (uint256 amount) {
        amount = IShMonad(SHMONAD).previewMint(shares);
    }
}
