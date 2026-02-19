// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Vm } from "forge-std/Vm.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import {
    UNSTAKE_BLOCK_DELAY,
    TARGET_FLOAT,
    SCALE,
    SHMONAD_VALIDATOR_DEACTIVATION_PERIOD
} from "../../src/shmonad/Constants.sol";
import { FixedPointMathLib } from "@solady/utils/FixedPointMathLib.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import { ValidatorStats, Epoch } from "../../src/shmonad/Types.sol";
import { TestShMonad } from "../base/helpers/TestShMonad.sol";

contract StakeTrackerUnstakeFlowsTest is BaseTest {
    address public alice;
    address public bob;

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant POOL_SEED = 200 ether;
    uint256 internal constant AMOUNT_TOLERANCE = 2; // allow for share↔asset rounding dust

    TestShMonad internal testShMonad;

    function setUp() public override {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);

        super.setUp();

        testShMonad = TestShMonad(payable(address(shMonad)));

        vm.deal(deployer, INITIAL_BALANCE);

        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(TARGET_FLOAT);
        shMonad.setUnstakeFeeCurve(0, 0);
        vm.deal(deployer, POOL_SEED);
        shMonad.deposit{ value: POOL_SEED }(POOL_SEED, deployer);
        vm.stopPrank();

        _advanceEpochAndCrank();
    }


    function test_StakeTracker_deactivateValidator_invalidId_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(ShMonadErrors.ValidatorAlreadyDeactivated.selector);
        shMonad.deactivateValidator(999999);
    }

    function test_StakeTracker_deactivateValidator_enforcesDelay() public {
        vm.startPrank(deployer);
        address validator = makeAddr("validatorDelay");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);

        // Validator should be in the active registry initially
        assertTrue(shMonad.isValidatorActive(valId), "Validator should be in active registry initially");
        assertEq(shMonad.getValidatorCoinbase(valId), validator, "Coinbase should be mapped");

        // Begin deactivation
        shMonad.deactivateValidator(valId);

        // After 4 epochs, validator should still be in the active registry (s_validatorIsActive)
        for (uint256 i = 0; i < SHMONAD_VALIDATOR_DEACTIVATION_PERIOD - 1; i++) {
            _advanceEpochAndCrankValidator(validator);
            // Validator should still be in s_validatorIsActive during the delay
            assertTrue(
                shMonad.isValidatorActive(valId),
                "Validator should remain in active registry during 5-epoch delay"
            );
            assertEq(
                shMonad.getValidatorCoinbase(valId),
                validator,
                "Coinbase mapping should persist during delay"
            );
        }

        // After the 5th epoch, crank should complete the deactivation
        _advanceEpochAndCrankValidator(validator);
        assertFalse(shMonad.isValidatorActive(valId), "Validator should be fully deactivated after 5 epochs");
        assertEq(shMonad.getValidatorIdForCoinbase(validator), 0, "Validator mapping should be cleared");
        assertEq(shMonad.getValidatorCoinbase(valId), address(0), "Coinbase should be cleared");
        vm.stopPrank();
    }

    // --------------------------------------------- //
    //          Fund Category Management Tests       //
    // --------------------------------------------- //

    function test_StakeTracker_depositsFillPoolLiquidityFirst() public {
        vm.startPrank(deployer);
        vm.stopPrank();

        uint256 initialBalance = address(shMonad).balance;
        uint256 initialTarget = shMonad.getTargetLiquidity();
        uint256 initialAssets = shMonad.totalAssets();

        uint256 depositAmount = 150 ether;
        vm.prank(alice);
        shMonad.deposit{ value: depositAmount }(depositAmount, alice);
        // Deposit is payable, so native balance must increase immediately (even on forks).
        assertEq(address(shMonad).balance, initialBalance + depositAmount, "Contract balance should increase by deposit");

        _advanceEpochAndCrank();

        uint256 currentLiq = shMonad.getCurrentLiquidity();
        uint256 targetLiq = shMonad.getTargetLiquidity();
        uint256 currentAssets = shMonad.totalAssets();

        uint256 assetDelta = currentAssets - initialAssets;
        if (useLocalMode) {
            uint256 expectedTargetLiquidityDelta = FixedPointMathLib.mulDiv(depositAmount, TARGET_FLOAT, SCALE);
            assertApproxEqAbs(
                targetLiq,
                initialTarget + expectedTargetLiquidityDelta,
                AMOUNT_TOLERANCE,
                "Target liquidity should match expectation"
            );
        } else {
            assertLe(targetLiq, currentAssets, "Target liquidity should not exceed total assets on fork");
            assertLe(currentLiq, targetLiq, "Current liquidity should not exceed target on fork");
        }
        // On a mainnet fork, a crank can also realize background yield (claimRewards / withdrawal settlement),
        // so totalAssets may increase by more than the deposit amount. In local mode we expect equality.
        if (useLocalMode) {
            assertEq(assetDelta, depositAmount, "Asset delta should equal deposit amount");
        } else {
            assertGe(assetDelta, depositAmount, "Asset delta should be at least the deposit amount on fork");
        }

        // After a crank, forked mainnet state can settle withdrawals / claim rewards which changes native balance.

        _advanceEpochAndCrank();

        uint256 targetAfterCrank = shMonad.getTargetLiquidity();
        uint256 liquidityAfterCrank = shMonad.getCurrentLiquidity();
        uint256 totalAssetsAfterCrank = shMonad.totalAssets();
        if (useLocalMode) {
            assertApproxEqAbs(
                targetAfterCrank,
                targetLiq,
                1e17,
                "Target liquidity should remain relatively unchanged ex interest after crank"
            );
        } else {
            assertLe(targetAfterCrank, totalAssetsAfterCrank, "Target liquidity should not exceed total assets");
        }
        // Local mode converges to target exactly after a crank; forked mainnet may have outstanding
        // liabilities/queues that prevent reaching the target in a single step.
        if (useLocalMode) {
            assertEq(liquidityAfterCrank, targetAfterCrank, "Liquidity should match target after crank");
        } else {
            assertLe(liquidityAfterCrank, targetAfterCrank, "Liquidity should not exceed target after crank on fork");
        }
    }

    function test_StakeTracker_rejectsDuplicateCoinbase() public {
        vm.startPrank(deployer);
        address validator = makeAddr("validatorDuplicate");
        uint64 valId1 = staking.registerValidator(validator);
        shMonad.addValidator(valId1, validator);

        address validatorAlt = makeAddr("validatorDuplicateAlt");
        uint64 valId2 = staking.registerValidator(validatorAlt);
        vm.expectRevert(ShMonadErrors.ValidatorAlreadyAdded.selector);
        shMonad.addValidator(valId2, validator);
        vm.stopPrank();
    }

    function test_StakeTracker_addValidator_revertsIfNotFullyRemoved() public {
        vm.startPrank(deployer);
        address validator = makeAddr("validatorNotFullyRemoved");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        shMonad.deactivateValidator(valId);

        // Simulate partial cleanup performed by crank without resetting validator epoch to allow guard coverage.
        bytes32 validatorIsActiveSlot = keccak256(abi.encode(uint256(valId), uint256(15)));
        vm.store(address(shMonad), validatorIsActiveSlot, bytes32(uint256(0)));

        bytes32 validatorDataSlot = keccak256(abi.encode(validator, uint256(46)));
        bytes32 validatorDataRaw = vm.load(address(shMonad), validatorDataSlot);
        uint64 storedEpoch = uint64(uint256(validatorDataRaw) & type(uint64).max);
        vm.store(address(shMonad), validatorDataSlot, bytes32(uint256(storedEpoch)));

        bytes32 validatorCoinbaseSlot = keccak256(abi.encode(uint256(valId), uint256(47)));
        vm.store(address(shMonad), validatorCoinbaseSlot, bytes32(uint256(0)));

        bytes32 validatorEpochSlot = keccak256(abi.encode(validator, uint256(37)));
        uint64 epochToKeep = storedEpoch == 0 ? uint64(1) : storedEpoch;
        vm.store(address(shMonad), validatorEpochSlot, bytes32(uint256(epochToKeep)));

        vm.expectRevert(ShMonadErrors.ValidatorNotFullyRemoved.selector);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
    }

    function test_StakeTracker_storesValidatorCoinbaseMapping() public {
        vm.startPrank(deployer);
        address validator = makeAddr("validatorMapping");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();

        assertEq(shMonad.getValidatorIdForCoinbase(validator), valId, "should resolve validator id");
        assertEq(shMonad.getValidatorCoinbase(valId), validator, "should resolve coinbase address");

        vm.prank(deployer);
        shMonad.deactivateValidator(valId);
        uint256 removalEpoch = uint256(testShMonad.exposeInternalEpoch()) + SHMONAD_VALIDATOR_DEACTIVATION_PERIOD + 1;
        _advanceToInternalEpochForValidator(validator, removalEpoch);
        assertEq(shMonad.getValidatorIdForCoinbase(validator), 0, "mapping should clear after deactivate");
    }

    function test_StakeTracker_validatorStatsView() public {
        vm.startPrank(deployer);
        address validator = makeAddr("validatorStats");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();

        ValidatorStats memory stats = shMonad.getValidatorStats(valId);
        assertTrue(stats.isActive, "validator should report active");
        assertEq(stats.coinbase, validator, "validator coinbase should match");
        uint256 internalEpoch = uint256(testShMonad.exposeInternalEpoch());
        uint256 expectedLastEpoch = internalEpoch == 0 ? 0 : internalEpoch - 1;
        assertEq(stats.lastEpoch, expectedLastEpoch, "last epoch should trail internal epoch by one");

        assertTrue(shMonad.isValidatorActive(valId), "validator should be active via view");

        vm.prank(deployer);
        shMonad.deactivateValidator(valId);
        uint256 removalEpoch = uint256(testShMonad.exposeInternalEpoch()) + SHMONAD_VALIDATOR_DEACTIVATION_PERIOD + 1;
        _advanceToInternalEpochForValidator(validator, removalEpoch);
        assertFalse(shMonad.isValidatorActive(valId), "validator should deactivate");
    }

    function test_StakeTracker_canReactivateValidator() public {
        vm.startPrank(deployer);
        address validator = makeAddr("validatorCycle");
        uint64 valId = staking.registerValidator(validator);

        shMonad.addValidator(valId, validator);
        shMonad.deactivateValidator(valId);

        // Should be possible to re-add the same validatorId + coinbase.
        uint256 reactivateEpoch = uint256(testShMonad.exposeInternalEpoch()) + SHMONAD_VALIDATOR_DEACTIVATION_PERIOD + 1;
        _advanceToInternalEpochForValidator(validator, reactivateEpoch);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();

        assertTrue(shMonad.isValidatorActive(valId), "validator should be reactivated");
        assertEq(shMonad.getValidatorCoinbase(valId), validator, "coinbase mapping should restore");
    }

    function test_StakeTracker_reactivateValidator_linksBackIntoCrank() public {
        vm.startPrank(deployer);
        address validator = makeAddr("validatorRelink");
        uint64 valId = staking.registerValidator(validator);

        shMonad.addValidator(valId, validator);
        shMonad.deactivateValidator(valId);

        uint256 reactivateEpoch = uint256(testShMonad.exposeInternalEpoch()) + SHMONAD_VALIDATOR_DEACTIVATION_PERIOD + 1;
        _advanceToInternalEpochForValidator(validator, reactivateEpoch);

        shMonad.addValidator(valId, validator);
        ValidatorStats memory statsBefore = shMonad.getValidatorStats(valId);
        vm.stopPrank();

        _advanceEpochAndCrankValidator(validator);

        ValidatorStats memory statsAfter = shMonad.getValidatorStats(valId);
        assertEq(
            statsAfter.lastEpoch,
            statsBefore.lastEpoch + 1,
            "validator should advance to next epoch when re-linked"
        );
        assertEq(
            shMonad.getValidatorCoinbase(valId),
            validator,
            "coinbase mapping should persist after relinking"
        );
    }

    function test_StakeTracker_withdrawalBoundaryDelayIsRetried() public {
        vm.startPrank(deployer);
        address validator = makeAddr("validatorBoundaryDelay");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();

        _activateValidator(validator, valId);

        uint256 stakeSeed = 100 ether;
        vm.deal(address(shMonad), stakeSeed);
        vm.prank(address(shMonad));
        staking.delegate{ value: stakeSeed }(valId);
        staking.harnessSyscallOnEpochChange(false);
        staking.harnessSyscallOnEpochChange(false);
        testShMonad.harnessSetGlobalStakedAmount(uint128(stakeSeed));

        (uint128 pendingStakingBaseline, uint128 pendingUnstakingBaseline) = testShMonad.exposeGlobalPendingRaw();

        uint128 withdrawAmount = uint128(stakeSeed / 2);
        uint128 desiredNextTarget = uint128(stakeSeed - withdrawAmount);

        Epoch memory currentEpoch = testShMonad.exposeValidatorEpochCurrent(validator);
        uint8 withdrawalId = currentEpoch.withdrawalId;

        vm.prank(address(shMonad));
        staking.undelegate(valId, withdrawAmount, withdrawalId);
        testShMonad.harnessMarkPendingWithdrawal(validator, uint120(withdrawAmount));

        (, uint120 pendingUnstakingCurrent) = testShMonad.exposeValidatorPending(validator, 0);
        assertEq(pendingUnstakingCurrent, uint120(withdrawAmount), "pending unstake queued");

        (uint64 baseEpochExternal,) = staking.getEpoch();
        uint64 epochOffset = staking.INITIAL_INTERNAL_EPOCH();
        uint64 baseEpoch = baseEpochExternal - epochOffset;
        uint64 delayedEpoch = baseEpoch + 2;
        staking.harnessSetWithdrawalEpoch(valId, address(shMonad), withdrawalId, delayedEpoch);

        uint64 internalEpoch = testShMonad.exposeInternalEpoch();

        testShMonad.setInternalEpoch(internalEpoch + 1);
        testShMonad.harnessRollValidatorEpochForwards(validator, desiredNextTarget);

        staking.harnessSyscallOnEpochChange(false);

        testShMonad.setInternalEpoch(internalEpoch + 2);
        testShMonad.harnessRollValidatorEpochForwards(validator, desiredNextTarget);

        vm.recordLogs();
        testShMonad.harnessSettlePastEpochEdges(validator);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 delayedSig =
            keccak256("WithdrawSettlementDelayed(address,uint64,uint64,uint256,uint256,uint8)");
        bool foundDelayed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == delayedSig) {
                foundDelayed = true;
                break;
            }
        }
        assertTrue(foundDelayed, "delay event emitted");

        Epoch memory epochMinusTwo = testShMonad.exposeValidatorEpochLastLast(validator);
        assertTrue(epochMinusTwo.crankedInBoundaryPeriod, "N-2 epoch tagged for boundary retry");

        (, uint120 pendingAfterDelay) = testShMonad.exposeValidatorPending(validator, -2);
        assertEq(pendingAfterDelay, uint120(withdrawAmount), "pending unstake still queued");

        staking.harnessSetWithdrawalEpoch(valId, address(shMonad), withdrawalId, baseEpoch + 1);
        staking.harnessSyscallOnEpochChange(false);

        testShMonad.setInternalEpoch(internalEpoch + 3);
        testShMonad.harnessRollValidatorEpochForwards(validator, desiredNextTarget);
        testShMonad.harnessSettlePastEpochEdges(validator);

        Epoch memory epochMinusThree = testShMonad.exposeValidatorEpochLastLastLast(validator);
        assertFalse(epochMinusThree.hasWithdrawal, "withdrawal flag cleared after retry");


        (uint128 pendingStakingGlobal, uint128 pendingUnstakingGlobal) = testShMonad.exposeGlobalPendingRaw();
        assertEq(pendingStakingGlobal, pendingStakingBaseline, "global pending staking should remain unchanged");
        assertEq(pendingUnstakingGlobal, pendingUnstakingBaseline, "global pending unstake drained after retry");

        (uint256 remaining,,) = staking.getWithdrawalRequest(valId, address(shMonad), withdrawalId);
        assertEq(remaining, 0, "withdrawal request cleared on precompile");
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
        while (testShMonad.exposeInternalEpoch() < targetInternalEpoch) {
            _advanceEpochAndCrank();
        }
    }

    function _advanceToInternalEpochForValidator(address validator, uint256 targetInternalEpoch) internal {
        while (testShMonad.exposeInternalEpoch() < targetInternalEpoch) {
            _advanceEpochAndCrankValidator(validator);
        }
    }

    function _advanceEpochAndCrankValidator(address validator) internal {
        _advanceEpochAndCrank();
        if (!useLocalMode) {
            uint256 valId = shMonad.getValidatorIdForCoinbase(validator);
            if (valId == 0) return;
            Epoch memory currentEpoch = testShMonad.exposeValidatorEpochCurrent(validator);
            testShMonad.harnessRollValidatorEpochForwards(validator, currentEpoch.targetStakeAmount);
        }
    }

    function _advanceEpochAndCrank() internal {
        uint256 rollBy = useLocalMode ? UNSTAKE_BLOCK_DELAY + 1 : 50_000;
        vm.roll(block.number + rollBy);
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
}
