// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { BaseTest } from "../base/BaseTest.t.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { ShMonadEvents } from "../../src/shmonad/Events.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import { SCALE, UNSTAKE_BLOCK_DELAY, WITHDRAWAL_DELAY } from "../../src/shmonad/Constants.sol";

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
        uint256 depositAmount = 100 ether;

        vm.startPrank(deployer);
        // Set atomic target liquidity to 0% for this scenario; redemptions
        // will be satisfied via scheduled exits (and atomic fallback if needed).
        shMonad.setPoolTargetLiquidityPercentage(0);
        address validator = makeAddr("validator1");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
        _activateValidator(validator, valId);

        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);
        assertEq(shMonad.balanceOf(alice), shares, "Should have shares after deposit");

        _advanceEpochAndCrank();

        vm.startPrank(alice);
        uint256 sharesToUnstake = shares / 2;
        uint256 expectedMon = shMonad.convertToAssets(sharesToUnstake);
        // Snapshot current global queues and liabilities for precise delta checks
        (uint120 queueToStakeBefore, uint120 queueForUnstakeBefore) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsBefore,) = shMonad.globalLiabilities();
        // Record current internal epoch to verify lower-bound on completion timing
        uint64 internalEpochAtRequest = shMonad.getInternalEpoch();
        uint64 completionEpoch = shMonad.requestUnstake(sharesToUnstake);
        (uint120 queueToStakeAfterRequest, uint120 queueForUnstakeAfterRequest) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsAfterRequest,) = shMonad.globalLiabilities();

        assertEq(uint256(queueToStakeAfterRequest), uint256(queueToStakeBefore), "queueToStake unaffected by request");
        assertEq(
            uint256(queueForUnstakeAfterRequest) - uint256(queueForUnstakeBefore),
            expectedMon,
            "queueForUnstake increases by requested amount"
        );
        assertEq(
            uint256(redemptionsAfterRequest) - uint256(redemptionsBefore),
            expectedMon,
            "redemptions payable increases by requested amount"
        );
        // Verify user request is persisted to storage and baseline completion window is respected
        (uint128 reqAmount, uint64 reqEpoch) = shMonad.getUnstakeRequest(alice);
        assertEq(reqAmount, uint128(expectedMon), "stored request amount should equal expected");
        assertEq(reqEpoch, completionEpoch, "stored completion epoch should match return value");
        assertGe(
            completionEpoch,
            internalEpochAtRequest + uint64(WITHDRAWAL_DELAY) + 4,
            "completion epoch must satisfy worst-case delay bound"
        );
        assertEq(shMonad.balanceOf(alice), shares - sharesToUnstake, "Shares should be burned on request");
        vm.stopPrank();

        // Fast-forward to the completion epoch when this request becomes eligible
        _advanceToInternalEpoch(completionEpoch);

        // After reaching the completion epoch, completing the unstake should succeed.
        // Even with target liquidity set to 0, the system uses reserved liquidity and/or
        // available atomic liquidity to fulfill redemptions safely.
        vm.startPrank(alice);
        uint256 aliceBalanceBefore = alice.balance; // Track user's balance to validate payout
        vm.txGasPrice(0); // Eliminate gas price noise to measure exact balance delta
        shMonad.completeUnstake();
        uint256 aliceBalanceAfter = alice.balance;
        assertEq(aliceBalanceAfter - aliceBalanceBefore, expectedMon, "Should receive unstaked assets");
        vm.stopPrank();
    }

    function test_ShMonad_completeUnstake_cannotCompleteEarly() public {
        uint256 depositAmount = 100 ether;

        vm.startPrank(deployer);
        // Disable target atomic liquidity; test focuses on epoch boundary rules
        // for traditional unstake timing and eligibility.
        shMonad.setPoolTargetLiquidityPercentage(0);

        address validator = makeAddr("validator1");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
        _activateValidator(validator, valId);

        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        vm.startPrank(alice);

        uint64 completionEpoch = shMonad.requestUnstake(shares);
        uint64 internalEpochBefore = shMonad.getInternalEpoch();
        vm.expectRevert(
            abi.encodeWithSelector(
                ShMonadErrors.CompletionEpochNotReached.selector,
                internalEpochBefore,
                completionEpoch
            )
        );
        shMonad.completeUnstake();
        vm.stopPrank();

        if (completionEpoch > internalEpochBefore + 1) {
            _advanceToInternalEpoch(completionEpoch - 1);
            vm.startPrank(alice);
            uint64 preCompletionEpoch = shMonad.getInternalEpoch();
            vm.expectRevert(
                abi.encodeWithSelector(
                    ShMonadErrors.CompletionEpochNotReached.selector,
                    preCompletionEpoch,
                    completionEpoch
                )
            );
            shMonad.completeUnstake();
            vm.stopPrank();
        }

        // Once the completion epoch is reached, the user should be able to successfully
        // complete the unstake and receive the expected assets.
        // Advance until the stacked requests are eligible to complete
        _advanceToInternalEpoch(completionEpoch);

        vm.startPrank(alice);
        uint256 expected = shMonad.convertToAssets(shares);
        uint256 aliceBalanceBefore = alice.balance; // Capture pre-withdrawal balance
        vm.txGasPrice(0);
        shMonad.completeUnstake();
        uint256 aliceBalanceAfter = alice.balance;
        assertEq(aliceBalanceAfter - aliceBalanceBefore, expected, "Should receive unstaked assets");
        vm.stopPrank();
    }

    function test_ShMonad_requestUnstake_multipleRequestsStack() public {
        uint256 depositAmount = 200 ether;

        vm.startPrank(deployer);
        // Disable target atomic liquidity; verify stacked requests still redeem
        // the combined expected amount at the computed completion epoch.
        shMonad.setPoolTargetLiquidityPercentage(0);

        address validator = makeAddr("validator1");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
        _activateValidator(validator, valId);

        vm.prank(alice);
        uint256 totalShares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        vm.startPrank(alice);

        uint256 firstUnstake = 50 ether;
        uint256 firstShares = shMonad.convertToShares(firstUnstake);
        uint256 firstExpected = shMonad.convertToAssets(firstShares);
        (, uint120 queueForUnstakeBeforeFirst) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsBeforeFirst,) = shMonad.globalLiabilities();
        uint64 firstCompletionEpoch = shMonad.requestUnstake(firstShares);
        (, uint120 queueForUnstakeAfterFirst) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsAfterFirst,) = shMonad.globalLiabilities();

        uint256 secondUnstake = 30 ether;
        uint256 secondShares = shMonad.convertToShares(secondUnstake);
        uint256 secondExpected = shMonad.convertToAssets(secondShares);
        uint64 completionEpoch = shMonad.requestUnstake(secondShares);
        (, uint120 queueForUnstakeAfterSecond) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsAfterSecond,) = shMonad.globalLiabilities();

        assertEq(
            shMonad.balanceOf(alice),
            totalShares - firstShares - secondShares,
            "Should have burned both amounts"
        );
        assertEq(uint256(queueForUnstakeAfterFirst) - uint256(queueForUnstakeBeforeFirst), firstExpected,
            "queueForUnstake increases by first request");
        assertEq(
            uint256(redemptionsAfterFirst) - uint256(redemptionsBeforeFirst),
            firstExpected,
            "redemptions payable increases by first request"
        );
        assertEq(uint256(queueForUnstakeAfterSecond) - uint256(queueForUnstakeAfterFirst), secondExpected,
            "queueForUnstake increases by second request");
        assertEq(
            uint256(redemptionsAfterSecond) - uint256(redemptionsAfterFirst),
            secondExpected,
            "redemptions payable increases by second request"
        );

        // Combined request persists with cumulative amount and furthest completion epoch
        (uint128 reqAmount, uint64 reqEpoch) = shMonad.getUnstakeRequest(alice);
        assertEq(reqAmount, uint128(firstExpected + secondExpected), "stored amount should sum both requests");
        assertEq(reqEpoch, completionEpoch, "stored epoch equals returned max completion epoch");

        vm.stopPrank();
        _advanceToInternalEpoch(completionEpoch);

        // With stacked requests, the completion epoch accounts for the furthest
        // request, and completing should return the sum of both requests.
        vm.startPrank(alice);
        uint256 totalExpected = firstExpected + secondExpected;
        uint256 aliceBalanceBefore = alice.balance;
        vm.txGasPrice(0);
        shMonad.completeUnstake();
        uint256 aliceBalanceAfter = alice.balance;
        assertEq(aliceBalanceAfter - aliceBalanceBefore, totalExpected, "Should receive combined unstaked assets");
        vm.stopPrank();
    }

    function test_ShMonad_requestUnstake_accountingValidation() public {
        // Set pool liquidity to 0 and crank to apply it
        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);
        _advanceEpochAndCrank();

        vm.prank(alice);
        shMonad.deposit{ value: INITIAL_BAL }(INITIAL_BAL, alice);
        _advanceEpochAndCrank();

        uint256 sharesToUnstake = shMonad.balanceOf(alice) / 2;
        uint256 expectedMonGross = shMonad.convertToAssets(sharesToUnstake);

        (uint128 stakedBefore, uint128 reservedBefore) = shMonad.getWorkingCapital();
        // Capture both queues prior to the request to attribute netting correctly.
        (uint120 queueToStakeBefore, uint120 queueForUnstakeBefore) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsBefore,) = shMonad.globalLiabilities();

        vm.prank(alice);
        shMonad.requestUnstake(sharesToUnstake);
        (, uint120 queueForUnstakeAfterRequest) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsAfterRequest,) = shMonad.globalLiabilities();
        assertEq(
            uint256(queueForUnstakeAfterRequest) - uint256(queueForUnstakeBefore),
            expectedMonGross,
            "queueForUnstake increases by requested amount"
        );
        assertEq(
            uint256(redemptionsAfterRequest) - uint256(redemptionsBefore),
            expectedMonGross,
            "redemptions payable tracks requested amount"
        );

        _advanceEpochAndCrank();

        (uint128 stakedAfter, uint128 reservedAfterCrank) = shMonad.getWorkingCapital();
        (uint120 queueToStakeAfterCrank, uint120 queueForUnstakeAfterCrank) = shMonad.getGlobalCashFlows(0);
        (, uint128 redemptionsAfterCrank,) = shMonad.globalLiabilities();

        assertEq(
            uint256(redemptionsAfterCrank),
            uint256(redemptionsAfterRequest),
            "redemptions payable remains pending post-crank"
        );

        uint256 queueConsumed = uint256(queueForUnstakeAfterRequest) - uint256(queueForUnstakeAfterCrank);
        uint256 outstandingQueue = uint256(queueForUnstakeAfterCrank);
        uint256 queueToStakeNetted = uint256(queueToStakeBefore) - uint256(queueToStakeAfterCrank);

        assertApproxEqAbs(
            outstandingQueue,
            expectedMonGross - queueConsumed,
            2,
            "queueForUnstake retains the scheduled validator exits"
        );

        // With no validator exits processed this epoch, queueForUnstake is netted against queueToStake.
        // The reduction in queueToStake should equal the consumed portion of queueForUnstake.
        assertEq(queueToStakeNetted, queueConsumed, "queueToStake reduction equals consumed queueForUnstake");

        // Additionally, reserves are topped up to match pending redemptions, increasing by the consumed amount.
        assertEq(
            uint256(reservedAfterCrank) - uint256(reservedBefore),
            queueConsumed,
            "reserved increases by the consumed queue amount"
        );
    }

    function test_ShMonad_completeUnstake_usesAtomicLiquidityWhenReservedInsufficient() public {
        // Seed atomic pool so it can satisfy withdrawals when reserved < amount.
        // Use a 50% target and ensure a healthy minimum liquidity.
        // Seed at least the amount we plan to withdraw so atomic can cover any reserved shortfall.
        // Note: atomic allocation can only increase by up to current assets per crank, so avoid overshooting
        // in a single epoch. 60 ether aligns with the planned withdrawal below.
        uint256 minAtomicLiquidity = 60 ether;
        _ensureAtomicLiquidity(minAtomicLiquidity, SCALE / 2, 120 ether);

        // Alice deposits and requests full unstake; with no reserved balance available, the
        // completion path should draw down from atomic liquidity instead of reverting.
        uint256 depositAmount = 60 ether;
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank(); // Apply deposit to queues so accounting is up to date

        vm.startPrank(alice);
        uint64 completionEpoch = shMonad.requestUnstake(shares);
        vm.stopPrank();

        // Fast-forward to eligibility
        _advanceToInternalEpoch(completionEpoch);

        // Snapshots prior to completion
        (uint128 stakedBefore, uint128 reservedBefore) = shMonad.getWorkingCapital();
        (uint128 atomicAllocatedBefore, uint128 atomicDistributedBefore) = shMonad.getAtomicCapital();
        (, uint128 redemptionsBefore,) = shMonad.globalLiabilities();

        // Complete and assert accounting adjustments
        vm.startPrank(alice);
        uint256 expected = shMonad.convertToAssets(shares);
        uint256 balBefore = alice.balance;
        vm.txGasPrice(0);
        shMonad.completeUnstake();
        uint256 balAfter = alice.balance;
        vm.stopPrank();

        (uint128 stakedAfter, uint128 reservedAfter) = shMonad.getWorkingCapital();
        (uint128 atomicAllocatedAfter, uint128 atomicDistributedAfter) = shMonad.getAtomicCapital();
        (, uint128 redemptionsAfter,) = shMonad.globalLiabilities();

        // User receives exact expected amount
        assertEq(balAfter - balBefore, expected, "user should receive expected assets");

        // Redemptions payable is reduced by the completed amount
        assertEq(uint256(redemptionsBefore) - uint256(redemptionsAfter), expected, "liability reduced by payout");

        // Reserved decreases by min(reservedBefore, expected)
        uint256 expectedReservedAfter = reservedBefore > expected ? reservedBefore - expected : 0;
        assertEq(reservedAfter, expectedReservedAfter, "reserved adjusted correctly");

        // Atomic allocated decreases by the portion not covered by reserved
        uint256 expectedAtomicDelta = expected > reservedBefore ? expected - reservedBefore : 0;
        assertEq(
            uint256(atomicAllocatedBefore) - uint256(atomicAllocatedAfter),
            expectedAtomicDelta,
            "atomic allocated reduced for shortfall"
        );

        // User request is cleared
        (uint128 reqAmt, uint64 reqEpoch) = shMonad.getUnstakeRequest(alice);
        assertEq(reqAmt, 0, "request amount cleared");
        assertEq(reqEpoch, 0, "request epoch cleared");
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
        while (!shMonad.crank()) {}
    }

    function _assertAccountingWithAtomicCarry(uint256 actual, uint256 expected, string memory reason) internal view {
        uint256 targetPercent = shMonad.getScaledTargetLiquidityPercentage();
        uint256 expectedCarry = Math.mulDiv(expected, targetPercent, SCALE);

        if (expectedCarry == 0) {
            assertApproxEqAbs(actual, expected, 2, reason);
            return;
        }

        uint256 delta = actual > expected ? actual - expected : expected - actual;
        uint256 buffer = FORK_TOLERANCE_BUFFER;

        assertLe(delta, expectedCarry + buffer, "atomic float carry exceeds expected bound");
        assertApproxEqAbs(actual, expected, expectedCarry + buffer, reason);
    }
}
