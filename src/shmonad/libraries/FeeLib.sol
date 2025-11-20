// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { FeeParams } from "../Types.sol";
import { BPS_SCALE, RAY } from "../Constants.sol";

/// @notice Capped-linear utilization fee math.
/// @dev Responsibilities:
///      1) Price forward (gross -> {fee, net}) and inverse (target net -> {gross, fee})
///         under r(u) = min(c + m*u, c + m) with u in WAD and rates in RAY.
///      2) Preserve integer rounding parity between forward and inverse without searches.
///      3) Provide a flat-cap path (L==0) and an optional per-call min-fee floor.
/// Invariants / Intent:
///      - Forward identity: net + fee == gross (always).
///      - Inverse minimality: net(gross-1) < targetNet ≤ net(gross).
///      - Fees never exceed gross; disabled fees (c==0 && m==0) bypass the min-fee.
///      - Units: mRay / cRay in RAY (1e27), utilization in WAD (1e18), assets in raw units.
/// @notice Fee math for capped-linear utilization model:
///         r(u) = min(c + m*u, c + m), with u in WAD and assets in raw units.
/// - Rates m, c are in RAY (1e27).
/// - Utilization u is in WAD (1e18), with u = max(0, 1 - R/L).
library FeeLib {
    // Pre-calculated constants
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY_WAD = 1e45; // RAY * WAD
    uint256 internal constant RAY_WAD2 = 1e63; // RAY * WAD * WAD

    // Used when no minimum fee is specified
    uint256 internal constant DEFAULT_MIN_FEE_WEI = 1;

    // ================================================================
    // Flat-cap helpers (L == 0)
    // ================================================================

    /// @notice Forward fee with a flat maximum fee rate rMax = c + m (RAY). Ignores liquidity and utilization.
    /// @dev Used for preview paths when target liquidity L == 0; treats the pool as fully capped across the interval.
    function solveNetGivenGross_FlatMaxFee(
        uint256 gross,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 fee, uint256 net)
    {
        if (gross == 0) return (0, 0);
        uint256 rMax = uint256(p.cRay) + uint256(p.mRay);
        if (rMax >= RAY) {
            return (gross, 0); // 100% fee wall, no net delivered
        }
        // Fully capped regime mirrors tail rounding: slope 1 + rMax applied to gross increment.
        uint256 denom = RAY + rMax;
        net = Math.mulDiv(gross, RAY, denom); // floor (never over-delivers net)
        fee = gross - net;
    }

    /// @notice Inverse solve with flat maximum fee rate rMax = c + m (RAY). Ignores liquidity and utilization.
    /// @dev Used for preview paths when target liquidity L == 0; solves g = ceil(N / (1 - rMax)).
    function solveGrossGivenNet_FlatMaxFee(
        uint256 targetNet,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 gross, uint256 fee)
    {
        if (targetNet == 0) return (0, 0);

        uint256 rMax = uint256(p.cRay) + uint256(p.mRay);
        if (rMax >= RAY) {
            // No positive net achievable at or above 100% fee.
            return (0, 0);
        }

        uint256 numerator = RAY + rMax; // slope 1 + rMax
        gross = Math.mulDivUp(targetNet, numerator, RAY);
        fee = gross - targetNet;
    }

    // ================================================================
    // Geometry / integrals
    // ================================================================

    /// @notice u0 in WAD from current liquidity R0 and target L.
    /// @dev u0 = max(0, 1 - R0/L). If L == 0, returns 0 (caller should guard).
    function utilFromLiquidity(uint256 R0, uint256 L) internal pure returns (uint256 u0Wad) {
        if (L == 0) return 0;
        // 1 - R0/L, scaled to WAD: u0 = WAD - (R0 * WAD / L)
        uint256 frac = Math.mulDiv(R0, WAD, L);
        // Clamp at 0 if R0 > L (over-supplied pool -> treat as u = 0)
        u0Wad = frac >= WAD ? 0 : (WAD - frac);
    }

    /// @notice Integral over [uA,uB] of the *uncapped* linear rate r(u)=c + m*u, scaled to asset fee by multiplying L.
    /// @dev Returns fee in asset units. Assumes uB >= uA. Pure helper for the capped integral.
    function _feeIntegralLinear(
        uint256 uA, // WAD
        uint256 uB, // WAD
        uint256 L, // assets
        uint256 baseRay, // c (RAY)
        uint256 slopeRay // m (RAY)
    )
        private
        pure
        returns (uint256 fee)
    {
        if (uB <= uA || L == 0) return 0;

        unchecked {
            // term1 = c * (uB - uA)
            uint256 dU = uB - uA; // Result is WAD
            // Use difference-of-squares as Δ(u^2) = (uB - uA) * (uB + uA).
            uint256 dU2 = Math.fullMulDiv(dU, uA + uB, 1); // Result is WAD^2

            // term1 numerator: baseRay * Δu  (RAY * WAD).
            // Using fullMulDiv(*, *, 1) gives us an exact 512-bit multiply without overflow.
            uint256 term1Numerator = Math.fullMulDiv(baseRay, dU, 1);

            // term2 numerator: (slopeRay * Δ(u^2)) / 2  -> (RAY * WAD^2)/2.
            // Do the divide-by-2 here (floor) to mirror original semantics.
            uint256 term2Numerator = Math.fullMulDiv(slopeRay, dU2, 2);

            // fee = L * [ t1Num/(RAY*WAD) + t2Num/(RAY*WAD^2) ].
            // Each fullMulDiv performs a 512-bit (L * numerator) / denominator with floor rounding.
            uint256 term1 = Math.fullMulDiv(L, term1Numerator, RAY_WAD);
            uint256 term2 = Math.fullMulDiv(L, term2Numerator, RAY_WAD2);

            fee = term1 + term2;
        }
    }

    /// @dev Enforce a per-call minimum fee floor (applied only when fees are enabled and g>0).
    function _enforceMinFee(
        uint256 fee,
        uint256 g,
        uint256 c,
        uint256 m,
        uint256 minFeeWei
    )
        private
        pure
        returns (uint256)
    {
        // No-op if disabled, zero gross, or no fees configured.
        if (minFeeWei == 0 || g == 0) return fee;
        if (c == 0 && m == 0) return fee; // no fees configured -> no min-fee
        if (fee >= minFeeWei) return fee;
        // Enforce floor but never charge more than gross.
        return g < minFeeWei ? g : minFeeWei;
    }

    /// @notice Integral over [u0,u1] for r(u) = min(c + m*u, c + m), scaled to asset fee by L.
    function feeIntegralCappedOverUtil(
        uint256 u0Wad,
        uint256 u1Wad,
        uint256 L,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 fee)
    {
        if (u1Wad <= u0Wad || L == 0) return 0;

        uint256 m = uint256(p.mRay);
        uint256 c = uint256(p.cRay);

        // Degenerates to constant if slope == 0.
        if (m == 0) {
            uint256 dU = u1Wad - u0Wad; // WAD
            return Math.mulDiv(L, c * dU, RAY * WAD);
        }

        // Crossing is fixed at u = WAD (100% util).
        if (u1Wad <= WAD) {
            return _feeIntegralLinear(u0Wad, u1Wad, L, c, m); // fully linear
        }

        uint256 rMax = c + m; // r(WAD)

        if (u0Wad >= WAD) {
            uint256 dU = u1Wad - u0Wad; // fully capped region
            return Math.mulDiv(L, rMax * dU, RAY * WAD);
        }

        // Crossing case: [u0, WAD] linear + [WAD, u1] constant at rMax
        unchecked {
            uint256 feeLinear = _feeIntegralLinear(u0Wad, WAD, L, c, m);
            uint256 dUConst = (u1Wad - WAD);
            uint256 feeConst = Math.mulDiv(L, rMax * dUConst, RAY * WAD);
            fee = feeLinear + feeConst;
        }
    }

    // ================================================================
    // Shared building blocks (ticks & boundary)
    // ================================================================

    /// @dev Forward-solver tick selection (linear branch) for a given gross.
    /// Mirrors the quadratic seed + two-candidate snap used by `solveNetGivenGross`.
    /// Returns feeAtTick only.
    function _linearFeeAtGross(
        uint256 gross,
        uint256 u0, // WAD
        uint256 dUMax, // WAD
        uint256 L,
        uint256 c, // RAY
        uint256 m, // RAY
        uint256 minFeeWei
    )
        private
        pure
        returns (uint256 feeAtTick)
    {
        if (gross == 0 || dUMax == 0) return 0;

        // Quadratic seed on the uncapped linear curve. Two-plateau snap:
        // - Candidate 0 = lower plateau (d0).
        // - Candidate 1 = upper plateau (d1 = d0+1).
        // We prefer the LOWER plateau when both are viable to avoid over-delivery.
        uint256 A = RAY + c + Math.fullMulDiv(m, u0, WAD);
        uint256 twoRayM = m * (2 * RAY);
        uint256 D = A * A + Math.fullMulDiv(gross, twoRayM, L);
        uint256 sD = Math.sqrt(D);
        uint256 net0 = sD > A ? Math.fullMulDiv(sD - A, L, m) : 0;

        // Candidate 0
        uint256 d0 = Math.mulDiv(net0, WAD, L);
        if (d0 > dUMax) d0 = dUMax;

        uint256 fee0 = _feeIntegralLinear(u0, u0 + d0, L, c, m);
        // If the integral is 0 (tiny gross / huge L), enforce the min-fee floor.
        fee0 = _enforceMinFee(fee0, gross, c, m, minFeeWei);

        uint256 net0f = gross - fee0;
        uint256 imp0 = Math.mulDiv(net0f, WAD, L);
        if (imp0 > dUMax) imp0 = dUMax;
        if (imp0 == d0) {
            return fee0;
        }

        // Candidate 1
        uint256 d1 = d0 < dUMax ? d0 + 1 : dUMax;
        if (d1 == d0) {
            return fee0;
        }

        uint256 fee1 = _feeIntegralLinear(u0, u0 + d1, L, c, m);
        // If fee1 is 0, it means the integral is 0, which means the utilization is 0.
        // In this case, we need to round up to the minimum fee.
        fee1 = _enforceMinFee(fee1, gross, c, m, minFeeWei);

        uint256 net1f = gross - fee1;
        uint256 imp1 = Math.mulDiv(net1f, WAD, L);
        if (imp1 > dUMax) imp1 = dUMax;
        if (imp1 == d1) {
            return fee1;
        }

        // True 2-cycle -> choose LOWER plateau (fee already min-clamped if needed).
        return fee0;
    }

    /// @dev Solve linear region at gross using the forward tick snap.
    function _solveLinearAtGross(
        uint256 gross,
        uint256 u0,
        uint256 dUMax,
        uint256 L,
        uint256 c,
        uint256 m,
        uint256 minFeeWei
    )
        private
        pure
        returns (uint256 fee, uint256 net)
    {
        uint256 feeAtTick = _linearFeeAtGross(gross, u0, dUMax, L, c, m, minFeeWei);
        fee = feeAtTick;
        net = gross - fee;
    }

    /// @dev Compute boundary tuple once.
    /// Returns:
    /// - u0        : starting utilization (WAD)
    /// - dUMax     : WAD - u0
    /// - net1      : net to reach u=1 (assets)
    /// - gross1    : gross to reach u=1 (net1 + fee(u0 -> 1) under linear part)
    /// - rMax      : c + m
    function _boundaryFor(
        uint256 R0,
        uint256 L,
        uint256 c,
        uint256 m
    )
        private
        pure
        returns (uint256 u0, uint256 dUMax, uint256 net1, uint256 gross1, uint256 rMax)
    {
        u0 = utilFromLiquidity(R0, L);
        dUMax = WAD - u0;
        net1 = Math.mulDiv(dUMax, L, WAD);
        uint256 feeToCap = _feeIntegralLinear(u0, WAD, L, c, m);
        gross1 = net1 + feeToCap;
        rMax = c + m;
    }

    // ================================================================
    // Forward: gross -> (fee, net)
    // ================================================================

    /// @notice Forward (gross -> (fee, net)) with net-path semantics:
    ///         gross = net + fee(u0 -> u0 + net/L), r(u) = min(c + m*u, c + m).
    /// @dev Linear region uses quadratic seed + two-candidate snap. Tail is piecewise with slope 1+rMax.
    function solveNetGivenGross(
        uint256 g,
        uint256 R0,
        uint256 L,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 fee, uint256 net)
    {
        return solveNetGivenGrossWithMinFee(g, R0, L, p, DEFAULT_MIN_FEE_WEI);
    }

    /// @notice Forward with explicit min fee floor (applied in all branches).
    function solveNetGivenGrossWithMinFee(
        uint256 gross,
        uint256 R0,
        uint256 L,
        FeeParams memory p,
        uint256 minFeeWei
    )
        internal
        pure
        returns (uint256 fee, uint256 net)
    {
        if (gross == 0) return (0, 0);

        uint256 c = uint256(p.cRay);
        uint256 m = uint256(p.mRay);

        // L == 0 uses flat rMax semantics but still must respect the min-fee floor on the total fee.
        if (L == 0) {
            (uint256 feeFlat,) = solveNetGivenGross_FlatMaxFee(gross, p);
            feeFlat = _enforceMinFee(feeFlat, gross, c, m, minFeeWei);
            return (feeFlat, gross - feeFlat);
        }

        // Constant-rate: g = (1 + c) * net  (fee charged on net)
        if (m == 0) {
            uint256 denom = RAY + c;
            net = Math.mulDiv(gross, RAY, denom); // floor
            fee = gross - net;
            fee = _enforceMinFee(fee, gross, c, m, minFeeWei);
            net = gross - fee;
            return (fee, net);
        }

        (uint256 u0, uint256 dUMax, uint256 net1, uint256 gross1, uint256 rMax) = _boundaryFor(R0, L, c, m);

        if (gross <= gross1) {
            // Linear region — single helper mirrors solver tick snap with mandatory min-fee rounding.
            return _solveLinearAtGross(gross, u0, dUMax, L, c, m, minFeeWei);
        }

        // Tail: piecewise linear with slope 1 + rMax
        // net2 = floor((gross - gross1) * RAY / (RAY + rMax)); fee2 = (gross - gross1) - net2
        uint256 net2 = Math.mulDiv((gross - gross1), RAY, (RAY + rMax));
        uint256 netTail = net1 + net2;
        uint256 feeTail = gross - netTail; // exact by construction
        feeTail = _enforceMinFee(feeTail, gross, c, m, minFeeWei);
        return (feeTail, gross - feeTail);
    }

    // ================================================================
    // Inverse: target net -> (gross, fee)
    // ================================================================

    /// @dev Linear-region inverse that:
    ///   (1) seeds on the lower plateau,
    ///   (2) calibrates to the forward tick at that gross,
    ///   (3) enforces 1‑wei minimality: net(gross - 1) < targetNet.
    function _inverseLinearCalibrated(
        uint256 targetNet,
        uint256 u0,
        uint256 dUMax,
        uint256 L,
        uint256 c,
        uint256 m,
        uint256 minFeeWei
    )
        private
        pure
        returns (uint256 gross, uint256 fee)
    {
        // Seed gross by pricing the lower implied tick.
        uint256 tickImplied = Math.mulDiv(targetNet, WAD, L); // floor implied Δu
        if (tickImplied > dUMax) tickImplied = dUMax;
        uint256 tickSeed = tickImplied == 0 ? 0 : (tickImplied - 1);
        uint256 feeSeed = _feeIntegralLinear(u0, u0 + tickSeed, L, c, m);
        uint256 grossSeed = targetNet + feeSeed;

        // Align to the tick the forward will actually select at grossSeed.
        uint256 feeAligned = _linearFeeAtGross(grossSeed, u0, dUMax, L, c, m, minFeeWei);
        gross = targetNet + feeAligned;
        fee = feeAligned;

        // Enforce minimality envelope: net(gross - 1) < targetNet.
        if (gross > 0) {
            uint256 feeMinus = _linearFeeAtGross(gross - 1, u0, dUMax, L, c, m, minFeeWei);
            // If dropping 1 wei still meets/exceeds target, shift down one plateau.
            if ((gross - 1) >= feeMinus && (gross - 1 - feeMinus) >= targetNet) {
                gross = targetNet + feeMinus;
                fee = feeMinus;
            }
        }
    }

    /// @notice Inverse (preview): given target net, return (gross, fee).
    /// @dev O(1), no binary search. Matches forward rounding semantics exactly.
    function solveGrossGivenNet(
        uint256 targetNet,
        uint256 R0,
        uint256 L,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 gross, uint256 fee)
    {
        return solveGrossGivenNetWithMinFee(targetNet, R0, L, p, DEFAULT_MIN_FEE_WEI);
    }

    /// @notice Inverse with explicit min fee floor (mirrors forward).
    function solveGrossGivenNetWithMinFee(
        uint256 targetNet,
        uint256 R0,
        uint256 L,
        FeeParams memory p,
        uint256 minFeeWei
    )
        internal
        pure
        returns (uint256 gross, uint256 fee)
    {
        if (targetNet == 0) return (0, 0);

        uint256 c = uint256(p.cRay);
        uint256 m = uint256(p.mRay);

        // L == 0 uses flat rMax semantics (including 100% wall) and applies min-fee on total fee.
        if (L == 0) {
            (uint256 grossFlat, uint256 feeFlat) = solveGrossGivenNet_FlatMaxFee(targetNet, p);
            if (grossFlat == 0 && feeFlat == 0) return (0, 0); // 100% fee wall case
            feeFlat = _enforceMinFee(feeFlat, grossFlat, c, m, minFeeWei);
            grossFlat = targetNet + feeFlat;
            return (grossFlat, feeFlat);
        }

        // Constant-rate (fee charged on net): gross = net + floor(c * net / RAY)
        if (m == 0) {
            uint256 feeOnNet = Math.mulDiv(targetNet, c, RAY);
            feeOnNet = _enforceMinFee(feeOnNet, targetNet + feeOnNet, c, m, minFeeWei);
            return (targetNet + feeOnNet, feeOnNet);
        }

        (uint256 u0, uint256 dUMax, uint256 net1, uint256 gross1, uint256 rMax) = _boundaryFor(R0, L, c, m);

        if (targetNet <= net1) {
            return _inverseLinearCalibrated(targetNet, u0, dUMax, L, c, m, minFeeWei);
        }

        // Tail: exact rounding inverse to match forward
        uint256 net2 = targetNet - net1;
        uint256 dG2 = Math.mulDivUp(net2, (RAY + rMax), RAY); // minimal gross to deliver net2
        gross = gross1 + dG2;
        fee = gross - targetNet;
        fee = _enforceMinFee(fee, gross, c, m, minFeeWei);
        gross = targetNet + fee;
        return (gross, fee);
    }

    // ================================================================
    // Other helpers
    // ================================================================

    /// @notice Fee for delivering exactly `net` units (net-path), with utilization evolving as u1 = u0 + net/L.
    /// @dev Handles capping internally via feeIntegralCappedOverUtil; for L==0, applies flat rMax.
    function feeGivenNet(uint256 net, uint256 R0, uint256 L, FeeParams memory p) internal pure returns (uint256 fee) {
        if (net == 0) return 0;

        // Fully capped assumption when L == 0 (same semantics as other L==0 paths).
        if (L == 0) {
            uint256 rMax = uint256(p.cRay) + uint256(p.mRay);
            if (rMax >= RAY) return net; // 100% fee wall
            return Math.mulDiv(net, rMax, RAY);
        }

        uint256 u0 = utilFromLiquidity(R0, L);
        // net-path integral with CEIL on Δu = ceil(net/L) to avoid undercharging.
        uint256 dU = Math.mulDivUp(net, WAD, L);
        uint256 u1 = u0 + dU;

        if (uint256(p.mRay) == 0 || u1 <= WAD) {
            // Cheaper when fully linear.
            return _feeIntegralLinear(u0, u1, L, uint256(p.cRay), uint256(p.mRay));
        }
        return feeIntegralCappedOverUtil(u0, u1, L, p);
    }

    /// @notice Same as `feeGivenNet` but enforces a min-fee floor on the total fee.
    /// @dev Provided for completeness to mirror the *WithMinFee family; original function kept unchanged.
    function feeGivenNetWithMinFee(
        uint256 net,
        uint256 R0,
        uint256 L,
        FeeParams memory p,
        uint256 minFeeWei
    )
        internal
        pure
        returns (uint256 fee)
    {
        fee = feeGivenNet(net, R0, L, p);
        // Apply the min-fee on the total fee; gross = net + fee
        fee = _enforceMinFee(fee, net + fee, uint256(p.cRay), uint256(p.mRay), minFeeWei);
    }

    /// @notice Calculates the pool's target liquidity using a percentage expressed in basis points (1e4 = 100%).
    /// @dev Callers working with 1e18-scale percentages should convert via `_unscaledTargetLiquidityPercentage`.
    function calcTargetLiquidity(
        uint256 totalEquity,
        uint256 targetLiquidityPercentage
    )
        internal
        pure
        returns (uint256 targetLiquidity)
    {
        if (targetLiquidityPercentage == 0) return 0; // If targetLiqPercentage is 0, return early

        // Calculate target liquidity as a percentage of total assets
        targetLiquidity = Math.mulDiv(totalEquity, targetLiquidityPercentage, BPS_SCALE);
    }
}
