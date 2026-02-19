// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { BaseTest } from "../base/BaseTest.t.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { ShMonadEvents } from "../../src/shmonad/Events.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import { SCALE, UNSTAKE_BLOCK_DELAY, WITHDRAWAL_DELAY } from "../../src/shmonad/Constants.sol";
import { TestShMonad } from "../base/helpers/TestShMonad.sol";

/**
 * @title TraditionalUnstakingTest
 * @notice Tests for traditional unstaking flow (requestUnstake → wait → completeUnstake)
 * @dev Tests the delayed unstaking mechanism where users request unstake, wait for epochs, then complete
 */
contract TraditionalUnstakingTest is BaseTest, ShMonadEvents {
    using Math for uint256;

    address public alice;
    address public bob;

    uint256 constant INITIAL_BAL = 200 ether;
    uint256 internal constant FORK_TOLERANCE_BUFFER = 1e12; // 1e-6 MON


    function setUp() public override {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, INITIAL_BAL);
        vm.deal(bob, INITIAL_BAL);
        super.setUp();
        _normalizeForkShMonadState(deployer);
    }

    // --------------------------------------------- //
    //         Traditional Unstaking Tests           //
    // --------------------------------------------- //

    function test_ShMonad_requestUnstake_zeroShares_reverts() public {
        // Expect revert when requesting to unstake 0 shares
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.CannotUnstakeZeroShares.selector));
        shMonad.requestUnstake(0);
    }

    function test_ShMonad_completeUnstake_noRequest_reverts() public {
        // Expect revert when attempting to complete without a prior request
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.NoUnstakeRequestFound.selector));
        shMonad.completeUnstake();
    }

    function test_ShMonad_requestUnstake_thenCompleteUnstakeFlow() public {
        // Split into helpers to avoid `via-ir` stack-too-deep in a single monolithic test.
        uint256 depositAmount = 100 ether;

        _setUpSingleValidatorWithNoAtomicLiquidity();

        vm.prank(alice);
        shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        uint256 aliceShares = shMonad.balanceOf(alice);
        (uint256 expectedMon, uint64 completionEpoch) = _requestUnstakeHalfAndAssertQueues(aliceShares);

        _advanceToInternalEpoch(completionEpoch);
        _completeUnstakeAndAssertPayout(expectedMon);
    }

    function _setUpSingleValidatorWithNoAtomicLiquidity() internal {
        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);
        address validator = makeAddr("validator1");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
        _activateValidator(validator, valId);
    }

    function _requestUnstakeHalfAndAssertQueues(uint256 aliceShares)
        internal
        returns (uint256 expectedMon, uint64 completionEpoch)
    {
        uint256 sharesToUnstake = aliceShares / 2;
        expectedMon = shMonad.convertToAssets(sharesToUnstake);

        vm.startPrank(alice);
        (uint120 queueToStakeBefore, uint120 queueForUnstakeBefore) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsBefore,) = shMonad.globalLiabilities();
        completionEpoch = shMonad.requestUnstake(sharesToUnstake);

        {
            (uint120 queueToStakeAfterRequest, uint120 queueForUnstakeAfterRequest) = shMonad.getGlobalCashFlows(0);
            (, uint128 redemptionsAfterRequest,) = shMonad.globalLiabilities();

            assertEq(queueToStakeAfterRequest, queueToStakeBefore);
            assertEq(uint256(queueForUnstakeAfterRequest) - uint256(queueForUnstakeBefore), expectedMon);
            assertEq(uint256(redemptionsAfterRequest) - uint256(redemptionsBefore), expectedMon);
        }

        {
            (uint128 reqAmount, uint64 reqEpoch) = shMonad.getUnstakeRequest(alice);
            assertEq(reqAmount, uint128(expectedMon));
            assertEq(reqEpoch, completionEpoch);
        }

        {
            // Completion epoch must be in the future (strictly greater than current internal epoch).
            assertTrue(completionEpoch > shMonad.getInternalEpoch());
        }

        assertEq(shMonad.balanceOf(alice), aliceShares - sharesToUnstake);
        vm.stopPrank();
    }

    function _completeUnstakeAndAssertPayout(uint256 expectedMon) internal {
        vm.startPrank(alice);
        uint256 aliceBalanceBefore = alice.balance;
        vm.txGasPrice(0);
        shMonad.completeUnstake();
        uint256 aliceBalanceAfter = alice.balance;
        assertEq(aliceBalanceAfter - aliceBalanceBefore, expectedMon);
        vm.stopPrank();
    }

    function _queueForUnstakeAndRedemptions() internal view returns (uint120 queueForUnstake, uint128 redemptions) {
        (, queueForUnstake) = shMonad.getGlobalCashFlows(0);
        (, redemptions,) = shMonad.globalLiabilities();
    }

    function test_ShMonad_completeUnstake_cannotCompleteEarly() public {
        uint256 depositAmount = 100 ether;

        _setUpSingleValidatorWithNoAtomicLiquidity();

        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        vm.startPrank(alice);
        uint64 completionEpoch = shMonad.requestUnstake(shares);

        // Before the completion epoch, completion must revert with the current internal epoch.
        _expectCompletionEpochNotReached(completionEpoch);

        // One epoch before completion should still revert (when applicable).
        uint64 internalEpoch = shMonad.getInternalEpoch();
        if (completionEpoch > internalEpoch + 1) {
            _advanceToInternalEpoch(completionEpoch - 1);
            _expectCompletionEpochNotReached(completionEpoch);
        }

        vm.stopPrank();

        // Once eligible, completion succeeds and pays out the expected assets.
        _advanceToInternalEpoch(completionEpoch);
        _completeUnstakeAndAssertPayout(shMonad.convertToAssets(shares));
    }

    function test_ShMonad_requestUnstake_multipleRequestsStack() public {
        uint256 depositAmount = 200 ether;

        _setUpSingleValidatorWithNoAtomicLiquidity();

        vm.prank(alice);
        shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        vm.startPrank(alice);

        uint256 totalShares = shMonad.balanceOf(alice);

        // First request
        uint256 firstShares = shMonad.convertToShares(50 ether);
        uint256 firstExpected = shMonad.convertToAssets(firstShares);
        (uint120 queueForUnstakeBeforeFirst, uint128 redemptionsBeforeFirst) = _queueForUnstakeAndRedemptions();
        shMonad.requestUnstake(firstShares);
        (uint120 queueForUnstakeAfterFirst, uint128 redemptionsAfterFirst) = _queueForUnstakeAndRedemptions();
        assertEq(uint256(queueForUnstakeAfterFirst) - uint256(queueForUnstakeBeforeFirst), firstExpected);
        assertEq(uint256(redemptionsAfterFirst) - uint256(redemptionsBeforeFirst), firstExpected);

        // Second request
        uint256 secondShares = shMonad.convertToShares(30 ether);
        uint256 secondExpected = shMonad.convertToAssets(secondShares);
        uint64 completionEpoch = shMonad.requestUnstake(secondShares);
        (uint120 queueForUnstakeAfterSecond, uint128 redemptionsAfterSecond) = _queueForUnstakeAndRedemptions();
        assertEq(uint256(queueForUnstakeAfterSecond) - uint256(queueForUnstakeAfterFirst), secondExpected);
        assertEq(uint256(redemptionsAfterSecond) - uint256(redemptionsAfterFirst), secondExpected);

        assertEq(shMonad.balanceOf(alice), totalShares - firstShares - secondShares);

        // Combined request persists with cumulative amount and furthest completion epoch
        (uint128 reqAmount, uint64 reqEpoch) = shMonad.getUnstakeRequest(alice);
        assertEq(reqAmount, uint128(firstExpected + secondExpected));
        assertEq(reqEpoch, completionEpoch);

        vm.stopPrank();
        _advanceToInternalEpoch(completionEpoch);

        _completeUnstakeAndAssertPayout(firstExpected + secondExpected);
    }

    function test_ShMonad_requestUnstake_accountingValidation() public {
        // This test has two layers:
        // - "request accounting" (deterministic): requestUnstake must increase queueForUnstake and redemptions
        // - "crank netting" (environment-dependent): the next crank may process real validator exits and other
        //   protocol actions that make per-field deltas non-deterministic on mainnet forks.

        // Set pool liquidity to 0. On local tests we crank to apply it; on forks, cranking can be expensive
        // and can legitimately process lots of unrelated validator exit actions.
        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);
        if (useLocalMode) _advanceEpochAndCrank();

        vm.prank(alice);
        shMonad.deposit{ value: INITIAL_BAL }(INITIAL_BAL, alice);
        if (useLocalMode) _advanceEpochAndCrank();

        uint256 sharesToUnstake = shMonad.balanceOf(alice) / 2;
        uint256 expectedMonGross = shMonad.convertToAssets(sharesToUnstake);

        (uint120 queueForUnstakeBefore, uint128 redemptionsBefore) = _queueForUnstakeAndRedemptions();

        vm.prank(alice);
        shMonad.requestUnstake(sharesToUnstake);

        (uint120 queueForUnstakeAfterRequest, uint128 redemptionsAfterRequest) = _queueForUnstakeAndRedemptions();
        assertEq(uint256(queueForUnstakeAfterRequest) - uint256(queueForUnstakeBefore), expectedMonGross);
        assertEq(uint256(redemptionsAfterRequest) - uint256(redemptionsBefore), expectedMonGross);

        // Fork-mode: stop after the deterministic portion.
        if (!useLocalMode) return;

        // Local-mode: validate netting & reserve effects across the next crank.
        (, uint128 reservedBefore) = shMonad.getWorkingCapital();
        (uint120 queueToStakeBefore,) = shMonad.getGlobalCashFlows(0);

        _advanceEpochAndCrank();

        (, uint128 reservedAfterCrank) = shMonad.getWorkingCapital();
        (uint120 queueToStakeAfterCrank, uint120 queueForUnstakeAfterCrank) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsAfterCrank,) = shMonad.globalLiabilities();

        assertEq(uint256(redemptionsAfterCrank), uint256(redemptionsAfterRequest));

        uint256 queueConsumed = uint256(queueForUnstakeAfterRequest) - uint256(queueForUnstakeAfterCrank);
        uint256 queueToStakeNetted = uint256(queueToStakeBefore) - uint256(queueToStakeAfterCrank);

        assertEq(queueToStakeNetted, queueConsumed);
        assertEq(uint256(reservedAfterCrank) - uint256(reservedBefore), queueConsumed);

        uint256 outstandingQueue = uint256(queueForUnstakeAfterCrank);
        assertApproxEqAbs(outstandingQueue, expectedMonGross - queueConsumed, 2);
    }

    function test_ShMonad_completeUnstake_usesAtomicLiquidityWhenReservedInsufficient() public {
        // Seed atomic pool so it can satisfy withdrawals when reserved < amount.
        uint256 minAtomicLiquidity = 60 ether;
        _ensureAtomicLiquidity(minAtomicLiquidity, SCALE / 2, 120 ether);

        uint256 depositAmount = 60 ether;
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        vm.prank(alice);
        uint64 completionEpoch = shMonad.requestUnstake(shares);

        _advanceToInternalEpoch(completionEpoch);

        (, uint128 reservedBefore) = shMonad.getWorkingCapital();
        (uint128 atomicAllocatedBefore,) = shMonad.getAtomicCapital();
        (, uint128 redemptionsBefore,) = shMonad.globalLiabilities();

        uint256 expected = shMonad.convertToAssets(shares);
        _completeUnstakeAndAssertPayout(expected);

        (, uint128 reservedAfter) = shMonad.getWorkingCapital();
        (uint128 atomicAllocatedAfter,) = shMonad.getAtomicCapital();
        (, uint128 redemptionsAfter,) = shMonad.globalLiabilities();

        assertEq(uint256(redemptionsBefore) - uint256(redemptionsAfter), expected);

        uint256 expectedReservedAfter = reservedBefore > expected ? reservedBefore - expected : 0;
        assertEq(reservedAfter, expectedReservedAfter);

        uint256 expectedAtomicDelta = expected > reservedBefore ? expected - reservedBefore : 0;
        assertEq(uint256(atomicAllocatedBefore) - uint256(atomicAllocatedAfter), expectedAtomicDelta);

        (uint128 reqAmt, uint64 reqEpoch) = shMonad.getUnstakeRequest(alice);
        assertEq(reqAmt, 0);
        assertEq(reqEpoch, 0);
    }

    // --------------------------------------------- //
    //      AUDIT FIX TESTS: Liability Coverage     //
    // --------------------------------------------- //

    /**
     * @notice Tests that _settleGlobalNetMONAgainstAtomicUnstaking routes freed liquidity to reserves
     *         when liabilities are uncovered, rather than to the staking queue.
     * @dev This is the primary fix for the Cantina audit finding. When a large requestUnstake lowers
     *      total equity and causes the atomic pool target to shrink, the freed liquidity should
     *      first cover any outstanding liabilities (rewardsPayable + redemptionsPayable) before
     *      being routed to queueToStake.
     *
     *      Attack scenario (pre-fix):
     *      1. Large requestUnstake -> lowers equity -> atomic target shrinks
     *      2. Freed atomic liquidity routed to queueToStake (WRONG)
     *      3. Redemptions remain uncovered, funds get staked
     *      4. MON becomes permanently staked, redemptions fail
     *
     *      Post-fix behavior:
     *      1. Large requestUnstake -> lowers equity -> atomic target shrinks
     *      2. Freed atomic liquidity FIRST covers uncovered liabilities (CORRECT)
     *      3. Only surplus (if any) routes to queueToStake
     *      4. Redemptions are covered, system remains solvent
     */
    function test_ShMonad_atomicSettlement_routesFreedLiquidityToReservesFirst() public {
        // Skip if not in local mode - this test requires precise control over crank timing
        if (!useLocalMode) return;

        // Setup: High atomic pool target (90%) so shrinkage frees significant liquidity
        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(SCALE * 90 / 100); // 90%
        address validator = makeAddr("validator1");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
        _activateValidator(validator, valId);

        // Alice deposits to seed the pool
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        // Capture state before unstake request
        (uint128 reservedBefore,) = _getReservesAndLiabilities();
        (uint120 queueToStakeBefore,) = shMonad.getGlobalCashFlows(0);

        // Alice requests a large unstake - this will:
        // 1. Add to queueForUnstake
        // 2. Add to redemptionsPayable (liability)
        // 3. On next crank, lower total equity -> lower atomic target -> free liquidity
        uint256 aliceShares = shMonad.balanceOf(alice);
        uint256 sharesToUnstake = aliceShares * 80 / 100; // 80% of holdings
        uint256 unstakeAmount = shMonad.convertToAssets(sharesToUnstake);

        vm.prank(alice);
        shMonad.requestUnstake(sharesToUnstake);

        // Verify liability was created
        (, uint128 redemptionsAfterRequest,) = shMonad.globalLiabilities();
        assertEq(redemptionsAfterRequest, unstakeAmount, "redemptionsPayable should match unstake amount");

        // Perform crank - this triggers _settleGlobalNetMONAgainstAtomicUnstaking
        _advanceEpochAndCrank();

        // Capture state after crank
        (uint128 reservedAfter, uint256 liabilitiesAfter) = _getReservesAndLiabilities();
        (uint120 queueToStakeAfter,) = shMonad.getGlobalCashFlows(0);

        // KEY ASSERTION: Reserved should have increased to cover liabilities
        // The fix routes freed atomic liquidity to reserves BEFORE queueToStake
        assertGe(
            reservedAfter,
            reservedBefore,
            "AUDIT FIX: Reserved should not decrease when liabilities exist"
        );

        // The reserved amount should cover liabilities (or be as close as possible given available liquidity)
        // Note: Full coverage depends on available currentAssets
        if (liabilitiesAfter > 0) {
            // If there are still uncovered liabilities, queueToStake should not have increased
            // (freed liquidity should have gone to reserves instead)
            assertLe(
                queueToStakeAfter,
                queueToStakeBefore + 1, // tolerance for rounding
                "AUDIT FIX: queueToStake should not increase when liabilities are uncovered"
            );
        }
    }

    /**
     * @notice Tests that completeUnstake protects validator rewards from being drained by redemptions.
     * @dev When reservedAmount covers both rewardsPayable and redemptionsPayable, a redemption
     *      should not be allowed to drain the rewardsPayable portion. The fix calculates
     *      reservedForRedemptions = reservedAmount - rewardsPayable and only uses that for redemptions.
     *
     *      Attack scenario (pre-fix):
     *      1. Validator reward is pending (rewardsPayable > 0)
     *      2. reservedAmount covers both rewards and redemptions
     *      3. User completes unstake, draining all of reservedAmount
     *      4. Validator reward payment underflows
     *
     *      Post-fix behavior:
     *      1. reservedForRedemptions = reservedAmount - rewardsPayable
     *      2. If reservedForRedemptions < redemption amount, pull from atomic pool
     *      3. Validator reward portion of reserves is protected
     */
    function test_ShMonad_completeUnstake_protectsValidatorRewardsReserve() public {
        // Skip if not in local mode - requires validator reward simulation
        if (!useLocalMode) return;

        // Setup with validator and atomic liquidity
        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(SCALE * 50 / 100); // 50%
        address validator = makeAddr("validator1");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
        _activateValidator(validator, valId);

        // Seed significant atomic liquidity
        _ensureAtomicLiquidity(50 ether, SCALE / 2, 100 ether);

        // Alice deposits
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: 50 ether }(50 ether, alice);

        _advanceEpochAndCrank();

        // Request unstake
        vm.prank(alice);
        uint64 completionEpoch = shMonad.requestUnstake(shares);

        // Advance to completion epoch
        _advanceToInternalEpoch(completionEpoch);

        // Check rewardsPayable before completion
        (uint128 rewardsPayableBefore,,) = shMonad.globalLiabilities();
        (, uint128 reservedBefore) = shMonad.getWorkingCapital();

        // Complete the unstake
        uint256 expectedPayout = shMonad.convertToAssets(shares);
        _completeUnstakeAndAssertPayout(expectedPayout);

        // After completion, reservedAmount should still cover rewardsPayable
        (uint128 rewardsPayableAfter,,) = shMonad.globalLiabilities();
        (, uint128 reservedAfter) = shMonad.getWorkingCapital();

        // KEY ASSERTION: If there were rewards payable, reserved should still cover them
        if (rewardsPayableBefore > 0) {
            assertGe(
                reservedAfter,
                rewardsPayableAfter,
                "AUDIT FIX: Reserved should cover remaining rewardsPayable after redemption"
            );
        }
    }

    /**
     * @notice Tests that the system doesn't leave MON permanently staked when users try to withdraw.
     * @dev This is the end-to-end test for the audit scenario: freed atomic liquidity should enable
     *      redemptions rather than being routed to staking where it becomes inaccessible.
     */
    function test_ShMonad_noPermaStakedMON_redemptionsFulfillable() public {
        // Skip if not in local mode
        if (!useLocalMode) return;

        // Setup: 100% atomic pool target initially
        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(SCALE); // 100%
        address validator = makeAddr("validator1");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
        _activateValidator(validator, valId);

        // Alice deposits
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        // Request full unstake
        uint256 aliceShares = shMonad.balanceOf(alice);
        vm.prank(alice);
        uint64 completionEpoch = shMonad.requestUnstake(aliceShares);

        // Lower the atomic pool target - this would free liquidity that previously
        // could have been routed to staking instead of covering the redemption
        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(SCALE / 10); // 10%

        // Advance and crank multiple times to ensure atomic settlement occurs
        _advanceToInternalEpoch(completionEpoch);

        // Verify redemption is fulfillable
        (uint128 redemptionsPayable,,) = shMonad.globalLiabilities();
        (, uint128 reserved) = shMonad.getWorkingCapital();
        (uint128 atomicAllocated, uint128 atomicDistributed) = shMonad.getAtomicCapital();
        uint256 atomicAvailable = atomicAllocated > atomicDistributed ? atomicAllocated - atomicDistributed : 0;

        uint256 expectedPayout = shMonad.convertToAssets(aliceShares);

        // The combination of reserved + atomic liquidity should cover the redemption
        assertGe(
            reserved + atomicAvailable,
            expectedPayout,
            "AUDIT FIX: System should have liquidity to fulfill redemption"
        );

        // Actually complete and verify payout
        _completeUnstakeAndAssertPayout(expectedPayout);
    }

    function _getReservesAndLiabilities() internal view returns (uint128 reserved, uint256 liabilities) {
        (, reserved) = shMonad.getWorkingCapital();
        (uint128 rewards, uint128 redemptions,) = shMonad.globalLiabilities();
        liabilities = uint256(rewards) + uint256(redemptions);
    }

    // --------------------------------------------- //
    //                Helper Functions               //
    // --------------------------------------------- //

    function _activateValidator(address validator, uint64 valId) internal {
        uint256 minStake = staking.MIN_VALIDATE_STAKE();
        vm.deal(validator, minStake);
        vm.prank(validator);
        staking.delegate{ value: minStake }(valId);
    }

    function _advanceToInternalEpoch(uint256 targetInternalEpoch) internal {
        while (shMonad.getInternalEpoch() < targetInternalEpoch) {
            _advanceEpochAndCrank();
        }
    }

    function _advanceEpochAndCrank() internal {
        vm.roll(block.number + UNSTAKE_BLOCK_DELAY + 1);
        staking.harnessSyscallOnEpochChange(false);
        if (!useLocalMode) {
            uint64 internalEpochBefore = shMonad.getInternalEpoch();
            for (uint256 i = 0; i < 4; i++) {
                TestShMonad(payable(address(shMonad))).harnessCrankGlobalOnly();
                if (shMonad.getInternalEpoch() > internalEpochBefore) {
                    return;
                }
            }
            revert("fork: crank did not advance internal epoch");
        }
        while (!shMonad.crank()) {}
    }

    function _expectCompletionEpochNotReached(uint64 completionEpoch) internal {
        uint64 internalEpoch = shMonad.getInternalEpoch();
        vm.expectRevert(
            abi.encodeWithSelector(
                ShMonadErrors.CompletionEpochNotReached.selector,
                internalEpoch,
                completionEpoch
            )
        );
        shMonad.completeUnstake();
    }

    // NOTE: Keep helper surface minimal to avoid `via-ir` stack pressure.
}
