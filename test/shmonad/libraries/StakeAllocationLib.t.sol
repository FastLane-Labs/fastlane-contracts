// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";

import { StakeAllocationLib } from "../../../src/shmonad/libraries/StakeAllocationLib.sol";
import { CashFlows, PendingBoost, Epoch, StakingEscrow, WorkingCapital, Revenue } from "../../../src/shmonad/Types.sol";
import { DUST_THRESHOLD, MIN_VALIDATOR_DEPOSIT } from "../../../src/shmonad/Constants.sol";

/// Test coverage for StakeAllocationLib
/// - This library is used by StakeTracker to compute per-validator stake deltas for the current epoch
///   based on global and validator cash flows and smoothed revenues.
/// - Tests exercise all branches: increase/decrease gating, rounding behavior, min-deposit clamp,
///   and saturating subtraction in available-to-unstake calculations.
contract StakeAllocationLibTest is Test {
    // --------------------------------------------- //
    //                     Helpers                   //
    // --------------------------------------------- //

    function _makeEpoch(
        uint128 targetStake,
        bool hasDeposit,
        bool crankBoundary
    )
        internal
        pure
        returns (Epoch memory epoch)
    {
        epoch = Epoch({
            epoch: 0,
            withdrawalId: 0,
            hasWithdrawal: false,
            hasDeposit: hasDeposit,
            crankedInBoundaryPeriod: crankBoundary,
            wasCranked: false,
            frozen: false,
            closed: false,
            targetStakeAmount: targetStake
        });
    }

    function _makePendingBoost(
        uint120 rewardsPayable,
        uint120 earnedRevenue
    )
        internal
        pure
        returns (PendingBoost memory pendingBoost)
    {
        pendingBoost = PendingBoost({ rewardsPayable: rewardsPayable, earnedRevenue: earnedRevenue, alwaysTrue: true });
    }

    function _makeRevenue(
        uint120 allocatedRevenue,
        uint120 earnedRevenue
    )
        internal
        pure
        returns (Revenue memory revenue)
    {
        revenue = Revenue({ allocatedRevenue: allocatedRevenue, earnedRevenue: earnedRevenue, alwaysTrue: true });
    }

    function _makeStakingEscrow(
        uint120 pendingStaking,
        uint120 pendingUnstaking
    )
        internal
        pure
        returns (StakingEscrow memory stakingEscrow)
    {
        stakingEscrow =
            StakingEscrow({ pendingStaking: pendingStaking, pendingUnstaking: pendingUnstaking, alwaysTrue: true });
    }

    function _makeCashFlows(uint120 toStake, uint120 forUnstake) internal pure returns (CashFlows memory cashFlows) {
        cashFlows = CashFlows({ queueToStake: toStake, queueForUnstake: forUnstake, alwaysTrue: true });
    }

    function _makeWorkingCapital(
        uint128 staked,
        uint128 reserved
    )
        internal
        pure
        returns (WorkingCapital memory workingCapital)
    {
        workingCapital = WorkingCapital({ stakedAmount: staked, reservedAmount: reserved });
    }

    // --------------------------------------------- //
    //      calculateValidatorEpochStakeDelta()      //
    // --------------------------------------------- //

    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_IncreaseOnly_RoundsDown() public {
        // Setup: smoothed validator revenue and queueToStake above dust -> increase only
        // Use values > DUST_THRESHOLD (1e9 wei) to pass gating.
        CashFlows memory globalCashFlows = _makeCashFlows(uint120(DUST_THRESHOLD + 1_000_000), 0);
        Revenue memory globalRevenue_lastLast = _makeRevenue(0, 6_000_000_000); // 6e9
        Revenue memory globalRevenue_last = _makeRevenue(0, 10_000_000_000); // 10e9
        PendingBoost memory validatorRewards_lastLast = _makePendingBoost(0, 1_000_000_000); // 1e9
        PendingBoost memory validatorRewards_last = _makePendingBoost(0, 3_000_000_000); // 3e9
        Epoch memory validatorEpoch_last = _makeEpoch(1_000_000, false, false);
        uint256 validatorAvailable = 0; // irrelevant (no decrease path)
        uint256 globalAvailable = 0; // irrelevant (no decrease path)

        // Smoothed values: validator = avg(1e9,3e9)=2e9; global=avg(6e9,10e9)=8e9
        // Expected increase = floor(queueToStake * 2e9 / 8e9) = floor(queueToStake / 4)
        uint256 expectedIncrease = (uint256(globalCashFlows.queueToStake) * 2_000_000_000) / 8_000_000_000;

        (uint128 target, uint128 net, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
            globalCashFlows,
            globalRevenue_lastLast,
            globalRevenue_last,
            validatorRewards_lastLast,
            validatorRewards_last,
            validatorEpoch_last,
            validatorAvailable,
            globalAvailable
        );

        assertFalse(isWithdrawal, "should be stake direction");
        assertEq(net, uint128(expectedIncrease), "net should equal rounded-down increase");
        assertEq(target, validatorEpoch_last.targetStakeAmount + net, "target stake should increase by net");
    }

    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_DecreaseOnly_RoundsUp() public {
        // Setup: queueForUnstake > dust and both avail > 0 -> decrease only
        // Use validatorAvailable >= MIN_VALIDATOR_DEPOSIT to avoid clamp and validate pure rounding.
        CashFlows memory globalCashFlows = _makeCashFlows(0, uint120(DUST_THRESHOLD + 1));
        PendingBoost memory pendingBoostZero = _makePendingBoost(0, 0);
        Revenue memory revenueZero = _makeRevenue(0, 0);
        Epoch memory validatorEpoch_last = _makeEpoch(uint128(200 ether), false, false);

        uint256 validatorAvailable = uint256(MIN_VALIDATOR_DEPOSIT) + 10 ether; // >= min deposit
        uint256 globalAvailable = 100 ether; // global eligible amount
        // Expected decrease = ceil(queueForUnstake * validatorAvailable / globalAvailable)
        uint256 expectedDecrease =
            Math.mulDivUp(uint256(globalCashFlows.queueForUnstake), validatorAvailable, globalAvailable);

        (uint128 target, uint128 net, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
            globalCashFlows,
            revenueZero,
            revenueZero,
            pendingBoostZero,
            pendingBoostZero,
            validatorEpoch_last,
            validatorAvailable,
            globalAvailable
        );

        assertTrue(isWithdrawal, "should be withdrawal direction");
        assertEq(net, uint128(expectedDecrease), "net should equal rounded-up decrease");
        assertEq(target, validatorEpoch_last.targetStakeAmount - net, "target stake should decrease by net");
    }

    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_DecreaseOnly_AllowsPartialWhenTargetAboveMin()
        public
    {
        CashFlows memory globalCashFlows = _makeCashFlows(0, uint120(DUST_THRESHOLD + 1));
        PendingBoost memory pendingBoostZero = _makePendingBoost(0, 0);
        Revenue memory revenueZero = _makeRevenue(0, 0);
        Epoch memory validatorEpoch_last = _makeEpoch(uint128(200 ether), false, false);

        uint256 validatorAvailable = 0.5 ether; // below min deposit but target is large
        uint256 globalAvailable = 100 ether;
        uint256 expectedDecrease = Math.mulDivUp(
            uint256(globalCashFlows.queueForUnstake), validatorAvailable, globalAvailable
        );

        (uint128 target, uint128 net, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
            globalCashFlows,
            revenueZero,
            revenueZero,
            pendingBoostZero,
            pendingBoostZero,
            validatorEpoch_last,
            validatorAvailable,
            globalAvailable
        );

        assertTrue(isWithdrawal, "direction should be withdrawal");
        assertEq(net, uint128(expectedDecrease), "partial withdrawal when target remains above MIN");
        assertEq(target, validatorEpoch_last.targetStakeAmount - net, "target reduced by partial amount");
    }

    // Tie case: non-zero increase equals non-zero decrease -> zero net; tie resolves to withdrawal.
    // We keep last and lastLast earnings equal to emphasize smoothing does not skew the split.
    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_TieNonZero_YieldsWithdrawalAndNoChange()
        public
    {
        // Queues chosen so inc = 2e9 and dec = 2e9
        CashFlows memory globalCashFlows = _makeCashFlows(uint120(8_000_000_000), uint120(4_000_000_000));
        // Equal last/lastLast earnings to keep smoothing neutral: validator/global = 2e9 / 8e9 = 1/4
        Revenue memory globalRevenue_lastLast = _makeRevenue(0, 8_000_000_000);
        Revenue memory globalRevenue_last = _makeRevenue(0, 8_000_000_000);
        PendingBoost memory validatorRewards_lastLast = _makePendingBoost(0, 2_000_000_000);
        PendingBoost memory validatorRewards_last = _makePendingBoost(0, 2_000_000_000);
        Epoch memory validatorEpoch_last = _makeEpoch(uint128(1_000 ether), false, false);

        // Decrease share ratio: 100 / 200 = 1/2, so dec = ceil(4e9 * 1/2) = 2e9
        uint256 validatorAvailable = 100 ether;
        uint256 globalAvailable = 200 ether;

        (uint128 target, uint128 net, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
            globalCashFlows,
            globalRevenue_lastLast,
            globalRevenue_last,
            validatorRewards_lastLast,
            validatorRewards_last,
            validatorEpoch_last,
            validatorAvailable,
            globalAvailable
        );

        assertEq(net, 0, "net must be zero when inc == dec");
        assertTrue(isWithdrawal, "tie resolves to withdrawal branch by design");
        assertEq(target, validatorEpoch_last.targetStakeAmount, "target remains unchanged on zero net");
    }

    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_BothPaths_NetIncrease() public {
        // Setup both increase and decrease -> increase outweighs decrease
        // Use values > DUST_THRESHOLD for queues and validator revenue to activate both paths.
        CashFlows memory globalCashFlows = _makeCashFlows(uint120(1_600_000_000), uint120(1_000_000_001));
        Revenue memory globalRevenue_lastLast = _makeRevenue(0, 8_000_000_000);
        Revenue memory globalRevenue_last = _makeRevenue(0, 8_000_000_000);
        PendingBoost memory validatorRewards_lastLast = _makePendingBoost(0, 1_000_000_000);
        PendingBoost memory validatorRewards_last = _makePendingBoost(0, 3_000_000_000);
        Epoch memory validatorEpoch_last = _makeEpoch(uint128(200 ether), false, false);

        // Increase = floor(1.6e9 * 2e9 / 8e9) = 400_000_000
        uint256 inc = (uint256(globalCashFlows.queueToStake) * 2_000_000_000) / 8_000_000_000;
        // Decrease = ceil(1.000000001e9 * 11 ether / 100 ether) = 110_000_001
        uint256 validatorAvailable = uint256(MIN_VALIDATOR_DEPOSIT) + 10 ether;
        uint256 globalAvailable = 100 ether;
        uint256 dec = Math.mulDivUp(uint256(globalCashFlows.queueForUnstake), validatorAvailable, globalAvailable);

        (uint128 target, uint128 net, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
            globalCashFlows,
            globalRevenue_lastLast,
            globalRevenue_last,
            validatorRewards_lastLast,
            validatorRewards_last,
            validatorEpoch_last,
            validatorAvailable,
            globalAvailable
        );

        assertFalse(isWithdrawal, "net direction should be increase");
        assertEq(net, uint128(inc - dec), "net equals increase - decrease");
        assertEq(target, validatorEpoch_last.targetStakeAmount + net, "target stake should add net");
    }

    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_BothPaths_NetDecrease() public {
        // Setup both increase and decrease -> decrease outweighs increase
        // Use values > DUST_THRESHOLD for queues and validator revenue.
        CashFlows memory globalCashFlows = _makeCashFlows(uint120(1_200_000_000), uint120(1_900_000_000));
        Revenue memory globalRevenue_lastLast = _makeRevenue(0, 8_000_000_000);
        Revenue memory globalRevenue_last = _makeRevenue(0, 8_000_000_000);
        PendingBoost memory validatorRewards_lastLast = _makePendingBoost(0, 2_000_000_000);
        PendingBoost memory validatorRewards_last = _makePendingBoost(0, 2_000_000_000);
        // In real scenarios, validator target stake is large (>= MIN_VALIDATOR_DEPOSIT).
        // Use a realistic target to avoid underflow when subtracting the computed net decrease.
        Epoch memory validatorEpoch_last = _makeEpoch(uint128(100 ether), false, false);

        // Increase = floor(1.2e9 * 2e9 / 8e9) = 300_000_000
        uint256 inc = (uint256(globalCashFlows.queueToStake) * 2_000_000_000) / 8_000_000_000; // floor
        // Decrease = ceil(1.9e9 * 50 ether / 100 ether) = 950_000_000
        uint256 validatorAvailable = 50 ether; // ensure >= MIN_VALIDATOR_DEPOSIT to avoid underflow
        uint256 globalAvailable = 100 ether;
        uint256 dec = Math.mulDivUp(uint256(globalCashFlows.queueForUnstake), validatorAvailable, globalAvailable); // ceil

        (uint128 target, uint128 net, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
            globalCashFlows,
            globalRevenue_lastLast,
            globalRevenue_last,
            validatorRewards_lastLast,
            validatorRewards_last,
            validatorEpoch_last,
            validatorAvailable,
            globalAvailable
        );

        assertTrue(isWithdrawal, "net direction should be decrease");
        assertEq(net, uint128(dec - inc), "net equals decrease - increase");
        assertEq(target, validatorEpoch_last.targetStakeAmount - net, "target stake should subtract net");
    }

    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_DustThresholdBlocksIncrease() public {
        // If smoothed validator revenue <= dust OR queueToStake <= dust OR smoothed global == 0 -> no increase
        Epoch memory validatorEpoch_last = _makeEpoch(1_234_567, false, false);
        Revenue memory globalPendingBoostZero = _makeRevenue(0, 0);
        PendingBoost memory validatorPendingBoostDust = _makePendingBoost(0, uint120(DUST_THRESHOLD)); // equals
            // threshold -> not strictly greater

        // Case A: queueToStake <= DUST_THRESHOLD blocks increase. With no decrease, both deltas are 0,
        // and the library treats tie (inc == dec) as withdrawal=false? No: tie falls into else-branch ->
        // isWithdrawal=true.
        {
            CashFlows memory gCF = _makeCashFlows(uint120(DUST_THRESHOLD), 0);
            (uint128 target,, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
                gCF,
                globalPendingBoostZero,
                globalPendingBoostZero,
                validatorPendingBoostDust,
                validatorPendingBoostDust,
                validatorEpoch_last,
                0,
                0
            );
            assertTrue(isWithdrawal, "tie (0,0) falls to withdrawal branch by design");
            assertEq(target, validatorEpoch_last.targetStakeAmount, "no change when increase is blocked");
        }

        // Case B: smoothed validator revenue <= DUST_THRESHOLD blocks increase
        {
            CashFlows memory globalCashFlows = _makeCashFlows(uint120(DUST_THRESHOLD + 1), 0);
            Revenue memory globalRevenue_lastLast = _makeRevenue(0, 100_000);
            Revenue memory globalRevenue_last = _makeRevenue(0, 100_000);
            PendingBoost memory validatorPendingBoostDust = _makePendingBoost(0, uint120(DUST_THRESHOLD)); // not
                // strictly greater
            (uint128 target,,,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
                globalCashFlows,
                globalRevenue_lastLast,
                globalRevenue_last,
                validatorPendingBoostDust,
                validatorPendingBoostDust,
                validatorEpoch_last,
                0,
                0
            );
            assertEq(target, validatorEpoch_last.targetStakeAmount, "no increase when validator revenue at/below dust");
        }

        // Case C: smoothed global revenue == 0 blocks increase
        {
            CashFlows memory gCF = _makeCashFlows(uint120(DUST_THRESHOLD + 10), 0);
            PendingBoost memory validatorPendingBoostNonDust = _makePendingBoost(0, 2000); // > dust
            (uint128 target,,,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
                gCF,
                globalPendingBoostZero,
                globalPendingBoostZero,
                validatorPendingBoostNonDust,
                validatorPendingBoostNonDust,
                validatorEpoch_last,
                0,
                0
            );
            assertEq(target, validatorEpoch_last.targetStakeAmount, "no increase when global revenue is zero");
        }
    }

    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_MinDepositClampsWhenTargetFallsBelowMin()
        public
    {
        // Decrease path proposes leaving less than MIN_VALIDATOR_DEPOSIT -> clamp to full available (unstake all)
        CashFlows memory globalCashFlows = _makeCashFlows(0, uint120(10 ether));
        Revenue memory revenueZero = _makeRevenue(0, 0);
        PendingBoost memory pendingBoostZero = _makePendingBoost(0, 0);
        // Target is barely above MIN so a large decrease would leave it below the deposit requirement
        Epoch memory validatorEpoch_last = _makeEpoch(uint128(MIN_VALIDATOR_DEPOSIT + 0.1 ether), false, false);

        uint256 validatorAvailable = uint256(validatorEpoch_last.targetStakeAmount); // all stake is liquid
        uint256 globalAvailable = 10 ether;
        uint256 proposed = Math.mulDivUp(uint256(globalCashFlows.queueForUnstake), validatorAvailable, globalAvailable);
        assertGt(proposed, validatorEpoch_last.targetStakeAmount - MIN_VALIDATOR_DEPOSIT, "precondition holds");

        (uint128 target, uint128 net, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
            globalCashFlows,
            revenueZero,
            revenueZero,
            pendingBoostZero,
            pendingBoostZero,
            validatorEpoch_last,
            validatorAvailable,
            globalAvailable
        );

        assertTrue(isWithdrawal, "direction should be withdrawal");
        assertEq(net, uint128(validatorAvailable), "clamps to full available when target would fall below MIN");
        assertEq(target, 0, "target drops to zero when fully unstaked");
    }

    function test_StakeAllocationLib_calculateValidatorEpochStakeDelta_DecreaseGating_BlocksWhenNoAvail() public {
        // Case A: globalAmountAvailableToUnstake == 0 blocks decrease
        {
            CashFlows memory globalCashFlows = _makeCashFlows(0, uint120(DUST_THRESHOLD + 5));
            PendingBoost memory pendingBoostZero = _makePendingBoost(0, 0);
            Revenue memory revenueZero = _makeRevenue(0, 0);
            Epoch memory validatorEpoch_last = _makeEpoch(7_000_000, false, false);
            (uint128 target,, bool isWithdrawal,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
                globalCashFlows,
                revenueZero,
                revenueZero,
                pendingBoostZero,
                pendingBoostZero,
                validatorEpoch_last,
                1,
                0
            );
            // Both inc and dec are 0 -> else-branch (withdrawal) with no delta
            assertTrue(isWithdrawal, "tie falls to withdrawal branch");
            assertEq(target, validatorEpoch_last.targetStakeAmount, "no change when global avail is zero");
        }

        // Case B: validatorAmountAvailableToUnstake == 0 blocks decrease
        {
            CashFlows memory globalCashFlows = _makeCashFlows(0, uint120(DUST_THRESHOLD + 5));
            PendingBoost memory pendingBoostZero = _makePendingBoost(0, 0);
            Revenue memory revenueZero = _makeRevenue(0, 0);
            Epoch memory validatorEpoch_last = _makeEpoch(7_000_000, false, false);
            (uint128 target,,,,) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
                globalCashFlows,
                revenueZero,
                revenueZero,
                pendingBoostZero,
                pendingBoostZero,
                validatorEpoch_last,
                0,
                12_345
            );
            assertEq(target, validatorEpoch_last.targetStakeAmount, "no change when validator avail is zero");
        }
    }

    // ------------------------------------------------ //
    //  calculateDeactivatedValidatorEpochStakeDelta()  //
    // ------------------------------------------------ //

    function test_StakeAllocationLib_calculateDeactivatedValidatorEpochStakeDelta_AlwaysWithdrawalAndSubtracts()
        public
    {
        Epoch memory validatorEpoch_last = _makeEpoch(10 ether, false, false);
        uint256 avail = 3.4 ether;

        (uint128 target, uint128 net, bool isWithdrawal) =
            StakeAllocationLib.calculateDeactivatedValidatorEpochStakeDelta(validatorEpoch_last, avail);

        assertTrue(isWithdrawal, "deactivated validator always withdraws");
        assertEq(net, uint128(avail), "net equals available amount");
        assertEq(target, uint128(10 ether) - uint128(avail), "target reduced by net amount");
    }

    // --------------------------------------------- //
    //   getValidatorAmountAvailableToUnstake()      //
    // --------------------------------------------- //

    function test_StakeAllocationLib_getValidatorAmountAvailableToUnstake_NoPending_ReturnsTarget() public {
        Epoch memory validatorEpoch_LastLast = _makeEpoch(0, false, false);
        Epoch memory validatorEpoch_Last = _makeEpoch(1_000_000, false, false);
        StakingEscrow memory validatorPendingEscrow_Last = _makeStakingEscrow(0, 0);
        StakingEscrow memory validatorPendingEscrow_LastLast = _makeStakingEscrow(0, 0);

        uint256 amount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
            validatorEpoch_LastLast, validatorEpoch_Last, validatorPendingEscrow_Last, validatorPendingEscrow_LastLast
        );
        assertEq(amount, validatorEpoch_Last.targetStakeAmount, "no pending -> full target available");
    }

    function test_StakeAllocationLib_getValidatorAmountAvailableToUnstake_PendingLast_SubtractsSaturating() public {
        Epoch memory validatorEpoch_LastLast = _makeEpoch(0, false, false);
        Epoch memory validatorEpoch_Last = _makeEpoch(1_000_000, true, false); // hasDeposit
        StakingEscrow memory validatorPendingEscrow_Last = _makeStakingEscrow(600_000, 0);
        StakingEscrow memory validatorPendingEscrow_LastLast = _makeStakingEscrow(0, 0);

        uint256 amount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
            validatorEpoch_LastLast, validatorEpoch_Last, validatorPendingEscrow_Last, validatorPendingEscrow_LastLast
        );
        assertEq(amount, 400_000, "subtract pending staking from last epoch");

        // Saturating case: pending > target -> available is 0
        validatorPendingEscrow_Last = _makeStakingEscrow(2_000_000, 0);
        amount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
            validatorEpoch_LastLast, validatorEpoch_Last, validatorPendingEscrow_Last, validatorPendingEscrow_LastLast
        );
        assertEq(amount, 0, "saturates to zero when pending exceeds target");
    }

    function test_StakeAllocationLib_getValidatorAmountAvailableToUnstake_PendingLastLast_RequiresBoundary() public {
        Epoch memory validatorEpoch_Last = _makeEpoch(1_000_000, false, false);
        // hasDeposit at lastLast but not cranked in boundary -> should NOT subtract
        Epoch memory validatorEpoch_LastLast = _makeEpoch(0, true, false);
        StakingEscrow memory validatorPendingEscrow_Last = _makeStakingEscrow(0, 0);
        StakingEscrow memory validatorPendingEscrow_LastLast = _makeStakingEscrow(250_000, 0);

        uint256 amount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
            validatorEpoch_LastLast, validatorEpoch_Last, validatorPendingEscrow_Last, validatorPendingEscrow_LastLast
        );
        assertEq(amount, validatorEpoch_Last.targetStakeAmount, "no boundary crank -> ignore lastLast pending");

        // Now set boundary flag -> should subtract lastLast pending as well
        validatorEpoch_LastLast = _makeEpoch(0, true, true);
        amount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
            validatorEpoch_LastLast, validatorEpoch_Last, validatorPendingEscrow_Last, validatorPendingEscrow_LastLast
        );
        assertEq(amount, 750_000, "subtract lastLast pending when cranked in boundary");
    }

    function test_StakeAllocationLib_getValidatorAmountAvailableToUnstake_PendingBoth_SaturatesToZero() public {
        Epoch memory validatorEpoch_Last = _makeEpoch(500_000, true, false);
        Epoch memory validatorEpoch_LastLast = _makeEpoch(0, true, true);
        StakingEscrow memory validatorPendingEscrow_Last = _makeStakingEscrow(400_000, 0);
        StakingEscrow memory validatorPendingEscrow_LastLast = _makeStakingEscrow(200_000, 0);

        uint256 amount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
            validatorEpoch_LastLast, validatorEpoch_Last, validatorPendingEscrow_Last, validatorPendingEscrow_LastLast
        );
        assertEq(amount, 0, "combined pending exceeds target -> saturate to 0");
    }

    // --------------------------------------------- //
    //     getGlobalAmountAvailableToUnstake()       //
    // --------------------------------------------- //

    function test_StakeAllocationLib_getGlobalAmountAvailableToUnstake_SubtractsPendingSaturating() public {
        WorkingCapital memory globalCapital = _makeWorkingCapital(5_000_000, 0);
        StakingEscrow memory globalPending = _makeStakingEscrow(1_000_000, 2_000_000);

        uint256 amount = StakeAllocationLib.getGlobalAmountAvailableToUnstake(globalCapital, globalPending);
        assertEq(amount, 2_000_000, "staked - (pendingStake + pendingUnstake)");

        // Equal -> zero
        globalPending = _makeStakingEscrow(2_500_000, 2_500_000);
        amount = StakeAllocationLib.getGlobalAmountAvailableToUnstake(globalCapital, globalPending);
        assertEq(amount, 0, "equal pending saturates to zero");

        // Over -> zero
        globalPending = _makeStakingEscrow(3_000_000, 3_000_000);
        amount = StakeAllocationLib.getGlobalAmountAvailableToUnstake(globalCapital, globalPending);
        assertEq(amount, 0, "over-subtraction saturates to zero");
    }
}
