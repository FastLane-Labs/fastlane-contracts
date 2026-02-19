// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";

import { StakeTracker } from "./StakeTracker.sol";
import { FeeParams, AtomicCapital } from "./Types.sol";
import {
    RAY,
    DEFAULT_Y_INTERCEPT_RAY,
    DEFAULT_SLOPE_RATE_RAY,
    FLOAT_PLACEHOLDER,
    SCALE,
    ATOMIC_MIN_FEE_WEI
} from "./Constants.sol";
import { FeeLib } from "./libraries/FeeLib.sol";

/// @notice See `FeeLib` for the detailed affine-in-utilization fee derivation and solver docs.
abstract contract AtomicUnstakePool is StakeTracker {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using Math for uint256;
    using FeeLib for uint256;

    function __AtomicUnstakePool_init() internal {
        FeeParams memory _feeParams = s_feeParams;

        if (_feeParams.mRay == 0 && _feeParams.cRay == 0) {
            // Initialize to default fee curve if not already set
            _feeParams = FeeParams({ mRay: DEFAULT_SLOPE_RATE_RAY, cRay: DEFAULT_Y_INTERCEPT_RAY });
            s_feeParams = _feeParams;

            emit FeeCurveUpdated(0, 0, _feeParams.mRay, _feeParams.cRay);
        }
    }

    // ================================================== //
    //                 Parameter Management               //
    // ================================================== //

    // Fees are always enabled. To disable fees, set the fee curve to (0, 0)
    // via `setUnstakeFeeCurve(0, 0)`.

    /// @custom:selector 0x9a7a039b
    function setPoolTargetLiquidityPercentage(uint256 newPercentageScaled) public virtual onlyOwner {
        require(newPercentageScaled <= SCALE, TargetLiquidityCannotExceed100Percent());

        // Pending target liquidity percentages are tracked in 1e18-scaled units.
        s_pendingTargetAtomicLiquidityPercent = newPercentageScaled;
    }

    /// @notice Update fee curve parameters.
    /// @dev The fee curve is defined as y = mx + c, where:
    /// - y is the fee rate in RAY (1e27)
    /// - m is the slopeRateRay (RAY at u=1)
    /// - c is the yInterceptRay (intercept/base fee in RAY)
    /// - x is the pool utilization
    /// @param newSlopeRateRay slope a (RAY at u=1)
    /// @param newYInterceptRay intercept/base fee (RAY)
    /// @custom:selector 0x4f8da2a7
    function setUnstakeFeeCurve(uint256 newSlopeRateRay, uint256 newYInterceptRay) external onlyOwner {
        require(newYInterceptRay <= RAY, YInterceptExceedsRay());
        require(newSlopeRateRay <= RAY, SlopeRateExceedsRay());
        require(newYInterceptRay + newSlopeRateRay <= RAY, FeeCurveFullUtilizationExceedsRay());

        FeeParams memory _oldParams = s_feeParams;
        s_feeParams = FeeParams({ mRay: uint128(newSlopeRateRay), cRay: uint128(newYInterceptRay) });

        emit FeeCurveUpdated(_oldParams.mRay, _oldParams.cRay, s_feeParams.mRay, s_feeParams.cRay);
    }

    // ================================================== //
    //                  View Functions                    //
    // ================================================== //

    /// @custom:selector 0x2a743e0a
    function yInterceptRay() public view returns (uint256) {
        return uint256(s_feeParams.cRay);
    }

    /// @custom:selector 0xdf19afcf
    function slopeRateRay() public view returns (uint256) {
        return uint256(s_feeParams.mRay);
    }

    /// @custom:selector 0xd813f074
    function getCurrentLiquidity() external view returns (uint256) {
        (uint256 _currentAvailableAmount, uint256 _totalAllocatedAmount) = _getLiquidityForAtomicUnstaking();
        // No allocation implies no withdrawable liquidity even if idle balance exists.
        if (_totalAllocatedAmount == 0) return 0;

        return _currentAvailableAmount;
    }

    /// @custom:selector 0x602f41d1
    function getTargetLiquidity() external view returns (uint256) {
        return _getTargetLiquidity();
    }

    /// @custom:selector 0xc8a505f0
    function getPendingTargetLiquidity() external view returns (uint256) {
        uint256 _targetLiquidity = _getTargetLiquidity();
        uint256 _newScaledTargetPercent = s_pendingTargetAtomicLiquidityPercent;

        if (_newScaledTargetPercent == FLOAT_PLACEHOLDER) {
            return _targetLiquidity;
        } else {
            uint256 _oldScaledTargetPercent = _scaledTargetLiquidityPercentage();
            if (_oldScaledTargetPercent == 0) return 0;
            return _targetLiquidity * _newScaledTargetPercent / _oldScaledTargetPercent;
        }
    }

    /// @custom:selector 0xdb8a582b
    function getFeeCurveParams() external view returns (uint256 slopeRateRayOut, uint256 yInterceptRayOut) {
        slopeRateRayOut = s_feeParams.mRay;
        yInterceptRayOut = s_feeParams.cRay;
    }

    /// @notice Current atomic pool utilization in 1e18 scale (0 to 1e18).
    /// @return utilizationWad Utilization scaled by 1e18
    /// @custom:selector 0x8b5f6d52
    function getAtomicUtilizationWad() external view returns (uint256 utilizationWad) {
        (uint256 available, uint256 allocated) = _getLiquidityForAtomicUnstaking();
        if (allocated == 0) return 0;
        uint256 frac = available * SCALE / allocated; // available / allocated in 1e18
        utilizationWad = frac >= SCALE ? 0 : (SCALE - frac);
    }

    /// @notice Current marginal unstake fee rate (RAY) under y = min(c + m*u, c + m).
    /// @return feeRateRay Fee rate in RAY (1e27)
    /// @custom:selector 0x7710d4ff
    function getCurrentUnstakeFeeRateRay() external view returns (uint256 feeRateRay) {
        (uint256 available, uint256 allocated) = _getLiquidityForAtomicUnstaking();
        if (allocated == 0) return uint256(s_feeParams.cRay) + uint256(s_feeParams.mRay); // capped full utilization
        uint256 frac = available * SCALE / allocated;
        uint256 u = frac >= SCALE ? 0 : (SCALE - frac); // utilization in 1e18
        uint256 c = uint256(s_feeParams.cRay);
        uint256 m = uint256(s_feeParams.mRay);
        uint256 y = c + (m * u) / SCALE;
        uint256 yMax = c + m;
        feeRateRay = Math.min(yMax, y);
    }

    /// @notice Detailed atomic pool state and utilization in one call.
    /// @return utilized Amount utilized (distributed) adjusted for smoothing
    /// @return allocated Total allocated (target) for atomic pool
    /// @return available Currently available liquidity
    /// @return utilizationWad Utilization scaled to 1e18
    /// @custom:selector 0xe65f8087
    function getAtomicPoolUtilization()
        external
        view
        returns (uint256 utilized, uint256 allocated, uint256 available, uint256 utilizationWad)
    {
        (available, allocated) = _getLiquidityForAtomicUnstaking();
        utilized = allocated - available;
        if (allocated == 0) return (0, 0, 0, 0);
        uint256 frac = available * SCALE / allocated;
        utilizationWad = frac >= SCALE ? 0 : (SCALE - frac);
    }

    // ================================================== //
    //                Fee Math Functions                  //
    // ================================================== //

    // Forward (runtime): compute net from a gross budget; if that net exceeds liquidity R0,
    // recompute at a NET cap (cap applies to what actually leaves the pool). If the `revertIfNetExceedsLiquidity` param
    // is set to `true`, it causes this function to revert if the net assets calculated will exceed the pool's available
    // liquidity.
    function _getGrossCappedAndFeeFromGrossAssets(
        uint256 grossRequested,
        bool revertIfNetExceedsLiquidity
    )
        internal
        view
        override
        returns (uint256 grossCapped, uint256 feeAssets)
    {
        if (grossRequested == 0) return (0, 0);
        (uint256 R0, uint256 L) = _getLiquidityForAtomicUnstaking();

        // First, calculate the net given gross (ignoring available liquidity)
        uint256 netOut;
        (feeAssets, netOut) =
            FeeLib.solveNetGivenGrossWithMinFee(grossRequested, R0, L, s_feeParams, ATOMIC_MIN_FEE_WEI);

        // If that net exceeds current liquidity, clamp by net and recalculate gross + fee exactly.
        bool netExceedsPoolLiquidity = netOut > R0;

        if (netExceedsPoolLiquidity) {
            // Conditional revert to prevent `agentWithdrawFromCommitted()` from resulting in insufficient net assets
            // after burning a specified amount of shares, due to hitting the pool liquidity limits.
            require(!revertIfNetExceedsLiquidity, InsufficientPoolLiquidity(netOut, R0));

            (grossCapped, feeAssets) = FeeLib.solveGrossGivenNetWithMinFee(R0, R0, L, s_feeParams, ATOMIC_MIN_FEE_WEI);

            // implied net = R0 (since grossCapped - feeAssets == R0)
            return (grossCapped, feeAssets);
        }

        // Otherwise we can spend the full grossRequested.
        return (grossRequested, feeAssets);
    }

    // Forward (for previewRedeem): no liquidity clamp; uses net-path forward solver.
    // L==0 flat-max behavior is handled inside the library.
    function _quoteFeeFromGrossAssetsNoLiquidityLimit(uint256 grossRequested)
        internal
        view
        override
        returns (uint256 feeAssets)
    {
        if (grossRequested == 0) return 0;
        (uint256 R0, uint256 L) = _getLiquidityForAtomicUnstaking();
        (feeAssets,) = FeeLib.solveNetGivenGrossWithMinFee(grossRequested, R0, L, s_feeParams, ATOMIC_MIN_FEE_WEI);
    }

    // Inverse (runtime): liquidity cap applies to net (the amount that actually leaves the pool), not gross.
    function _getGrossAndFeeFromNetAssets(uint256 netAssets)
        internal
        view
        returns (uint256 grossAssets, uint256 feeAssets)
    {
        (uint256 R0, uint256 L) = _getLiquidityForAtomicUnstaking();
        if (netAssets == 0) return (0, 0);

        // NOTE: This function is only called by `agentWithdrawFromCommitted()`, and should revert if the specified
        // netAssets amount cannot be fulfilled given the current liquidity available.
        require(netAssets <= R0, InsufficientPoolLiquidity(netAssets, R0));

        (grossAssets, feeAssets) =
            FeeLib.solveGrossGivenNetWithMinFee(netAssets, R0, L, s_feeParams, ATOMIC_MIN_FEE_WEI);
    }

    // Inverse (for previewWithdraw): no liquidity limit; L==0 fallback handled in library.
    function _quoteGrossAndFeeFromNetAssetsNoLiquidityLimit(uint256 targetNet)
        internal
        view
        override
        returns (uint256 gross, uint256 fee)
    {
        if (targetNet == 0) return (0, 0);
        (uint256 R0, uint256 L) = _getLiquidityForAtomicUnstaking();
        (gross, fee) = FeeLib.solveGrossGivenNetWithMinFee(targetNet, R0, L, s_feeParams, ATOMIC_MIN_FEE_WEI);
    }

    // ================================================== //
    //            Internal Accounting Helpers             //
    // ================================================== //

    function _getTargetLiquidity() internal view returns (uint128 targetLiquidity) {
        // Calculate target liquidity as a percentage of total assets
        targetLiquidity = s_atomicAssets.allocatedAmount;
    }
}
