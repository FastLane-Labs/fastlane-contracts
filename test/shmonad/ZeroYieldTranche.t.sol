// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import { ShMonadEvents } from "../../src/shmonad/Events.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import { OWNER_COMMISSION_ACCOUNT, MIN_VALIDATOR_DEPOSIT, SCALE, UNSTAKE_BLOCK_DELAY } from "../../src/shmonad/Constants.sol";
import { MockMonadStakingPrecompile } from "../../src/shmonad/mocks/MockMonadStakingPrecompile.sol";
import { TestShMonad } from "../base/helpers/TestShMonad.sol";

/**
 * ZeroYieldTranche.t.sol
 *
 * Tests cover the full surface of the "Zero Yield Tranche Functions" in ShMonad:
 * - depositToZeroYieldTranche
 * - convertZeroYieldTrancheToShares
 * - claimOwnerCommissionAsShares
 * - balanceOfZeroYieldTranche (view)
 * - unclaimedOwnerCommission (view)
 * 
 * Also tests the integration of zero-yield tranche commission accounting with:
 * - boostYield()
 * - sendValidatorRewards()
 * - _handleEarnedStakingYield() via crank()
 * 
 */
contract ZeroYieldTrancheTest is BaseTest, ShMonadEvents {
    // Mirror ERC4626 Deposit event for expectEmit matching
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    address internal alice;
    address internal bob;

    uint256 internal constant INITIAL_BAL = 200 ether;
    TestShMonad internal testShMonad;

    function setUp() public override {
        super.setUp();
        testShMonad = TestShMonad(payable(address(shMonad)));
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, INITIAL_BAL);
        vm.deal(bob, INITIAL_BAL);
    }

    // Helper: fetch current total zero-yield funds from global liabilities snapshot
    function _totalZeroYieldPayable() internal view returns (uint256) {
        (,, uint128 totalZeroYieldPayable) = shMonad.globalLiabilities();
        return uint256(totalZeroYieldPayable);
    }

    // Advance the mock staking epoch and fully crank ShMonad (global + validators).
    function _advanceEpochAndCrank() internal {
        // Move forward sufficiently in blocks to avoid boundary issues and trigger epoch change
        vm.roll(block.number + UNSTAKE_BLOCK_DELAY + 1);
        staking.harnessSyscallOnEpochChange(false);
        if (!useLocalMode) {
            uint64 internalEpochBefore = shMonad.getInternalEpoch();
            for (uint256 i = 0; i < 4; i++) {
                testShMonad.harnessCrankGlobalOnly();
                if (shMonad.getInternalEpoch() > internalEpochBefore) {
                    return;
                }
            }
            revert("fork: crank did not advance internal epoch");
        }
        while (!shMonad.crank()) {}
    }

    function _advanceEpochAndCrankValidator(uint64 valId) internal {
        _advanceEpochAndCrank();
        if (!useLocalMode) {
            testShMonad.harnessCrankValidator(valId);
        }
    }

    function _expectedDepositQueueDelta(uint256 assets) internal view returns (uint256 expected) {
        (uint128 rewardsPayable, uint128 redemptionsPayable,) = shMonad.globalLiabilities();
        uint256 currentLiabilities = uint256(rewardsPayable) + uint256(redemptionsPayable);
        (, uint128 reservedAmount) = shMonad.getWorkingCapital();
        (, uint128 pendingUnstaking) = shMonad.getGlobalPending();
        uint256 currentAssets = testShMonad.exposeCurrentAssets();

        if (currentLiabilities > uint256(reservedAmount) + uint256(pendingUnstaking) + currentAssets) {
            uint256 uncovered = currentLiabilities - (uint256(reservedAmount) + uint256(pendingUnstaking));
            if (assets > uncovered) {
                uint256 surplus = assets - uncovered;
                return uncovered + _subtractNetToAtomicLiquidityPreview(surplus);
            }
            return assets;
        }

        return _subtractNetToAtomicLiquidityPreview(assets);
    }

    function _subtractNetToAtomicLiquidityPreview(uint256 assets) internal view returns (uint256 remaining) {
        uint256 targetPercent = testShMonad.scaledTargetLiquidityPercentage();
        (, uint128 distributedAmount) = testShMonad.exposeGlobalAtomicCapital();
        uint256 netToAtomic = (assets * targetPercent) / SCALE;
        if (netToAtomic > uint256(distributedAmount)) netToAtomic = uint256(distributedAmount);
        return assets - netToAtomic;
    }

    // Ensure a validator is registered, staked, and active so yield/rewards flows are exercised.
    // Returns the validator coinbase address and id.
    function _ensureActiveValidator(address validator, string memory tag)
        internal
        returns (address coinbase, uint64 valId)
    {
        coinbase = validator == address(0) ? makeAddr(tag) : validator;
        // Register validator in the precompile mock and link in ShMonad
        valId = staking.registerValidator(coinbase);
        vm.prank(deployer);
        shMonad.addValidator(valId, coinbase);

        // Ensure ShMonad is tracked as a delegator for reward settlement
        staking.harnessEnsureDelegator(valId, address(shMonad));

        // Self-delegate to activate the validator (mock requires >= MIN_VALIDATOR_DEPOSIT)
        vm.deal(coinbase, MIN_VALIDATOR_DEPOSIT);
        vm.prank(coinbase);
        staking.delegate{ value: MIN_VALIDATOR_DEPOSIT }(valId);

        // Crank forward until validator marked active
        bool active;
        for (uint256 i = 0; i < 4; ++i) {
            _advanceEpochAndCrankValidator(valId);
            if (shMonad.isValidatorActive(valId)) {
                active = true;
                break;
            }
        }
        require(active, "validator should be active");
    }

    /// @dev Fork-mode friendly staking-yield setup:
    ///      - creates a brand-new validator ID (>= 10_000 after snapshot seeding)
    ///      - seeds validator+delegator state directly in the mock precompile so `addValidator()` sees it as active
    ///      - does NOT rely on ShMonad's staking queue/deposit flows (which depend on existing fork state)
    function _seedValidatorWithShMonadStake(
        string memory tag,
        uint256 totalStake,
        uint256 shmonadStake
    )
        internal
        returns (uint64 valId)
    {
        require(totalStake != 0, "totalStake=0");
        require(shmonadStake != 0, "shmonadStake=0");
        require(shmonadStake <= totalStake, "shmonadStake>totalStake");

        address coinbase = makeAddr(tag);
        valId = staking.registerValidator(coinbase);

        // Seed validator stake so ShMonad's `addValidator()` seeds it as active immediately.
        MockMonadStakingPrecompile.ValidatorSeed[] memory validators = new MockMonadStakingPrecompile.ValidatorSeed[](1);
        validators[0] = MockMonadStakingPrecompile.ValidatorSeed({
            valId: valId,
            authAddress: coinbase,
            consensusStake: totalStake,
            consensusCommission: 0,
            snapshotStake: totalStake,
            snapshotCommission: 0,
            executionAccumulator: 0,
            executionUnclaimedRewards: 0,
            secpPubkey: new bytes(0),
            blsPubkey: new bytes(0)
        });
        staking.harnessUpsertValidators(validators);

        // Seed ShMonad as a delegator so it can actually accrue and claim rewards.
        MockMonadStakingPrecompile.DelegatorSeed[] memory delegators = new MockMonadStakingPrecompile.DelegatorSeed[](1);
        delegators[0] = MockMonadStakingPrecompile.DelegatorSeed({
            valId: valId,
            delegator: address(shMonad),
            stake: shmonadStake,
            lastAccumulator: 0,
            rewards: 0,
            deltaStake: 0,
            nextDeltaStake: 0,
            deltaEpoch: 0,
            nextDeltaEpoch: 0
        });
        staking.harnessUpsertDelegators(delegators);

        vm.prank(deployer);
        shMonad.addValidator(valId, coinbase);
    }

    // --------------------------------------------- //
    //          depositToZeroYieldTranche            //
    // --------------------------------------------- //

    function test_ZeroYield_deposit_updatesBalancesAndLiability_andEmitsEvent() public {
        uint256 amount = 10 ether;
        address receiver = bob; // credit zero-yield to a third party

        // Snapshot queueToStake/queueForUnstake before deposit
        (uint120 qToStakeBefore, uint120 qForUnstakeBefore) = shMonad.getGlobalCashFlows(0);
        uint256 expectedQueueDelta = _expectedDepositQueueDelta(amount);

        uint256 zyBefore = shMonad.balanceOfZeroYieldTranche(receiver);
        uint256 totalZeroYieldBefore = _totalZeroYieldPayable();
        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 assetsBefore = shMonad.totalAssets();
        uint256 contractEthBefore = address(shMonad).balance;

        // Expect a Zero-Yield deposit event with (sender=alice, receiver=bob, assets=amount)
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit DepositToZeroYieldTranche(alice, receiver, amount);
        shMonad.depositToZeroYieldTranche{ value: amount }(amount, receiver);

        // Zero-yield tranche balance credited to receiver
        assertEq(shMonad.balanceOfZeroYieldTranche(receiver), zyBefore + amount, "receiver ZY balance increases");
        // Admin liability increases 1:1 with deposit
        assertEq(_totalZeroYieldPayable(), totalZeroYieldBefore + amount, "admin totalZeroYieldPayable increases");
        // Queue to stake increases by the deposited amount; queue for unstake unchanged
        (uint120 qToStakeAfter, uint120 qForUnstakeAfter) = shMonad.getGlobalCashFlows(0);
        assertEq(uint256(qToStakeAfter - qToStakeBefore), expectedQueueDelta, "queueToStake += amount");
        assertEq(qForUnstakeAfter, qForUnstakeBefore, "queueForUnstake unchanged");
        // No shares minted on ZY deposit
        assertEq(shMonad.totalSupply(), totalSupplyBefore, "totalSupply unchanged on ZY deposit");
        // Contract holds the received native tokens; equity unchanged because liability increased equally
        assertEq(address(shMonad).balance, contractEthBefore + amount, "contract native balance increases");
        assertEq(shMonad.totalAssets(), assetsBefore, "equity/totalAssets unchanged by ZY deposit");
    }

    function test_ZeroYield_deposit_revertsOnMismatchedMsgValue() public {
        // Attempt to deposit 5 ETH with only 4 ETH sent should revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.IncorrectNativeTokenAmountSent.selector));
        shMonad.depositToZeroYieldTranche{ value: 4 ether }(5 ether, alice);
    }

    // --------------------------------------------- //
    //      convertZeroYieldTrancheToShares          //
    // --------------------------------------------- //

    function test_ZeroYield_convertToShares_mintsExpectedSharesAndUpdatesState() public {
        uint256 amount = 8 ether;

        // First, fund alice's zero-yield balance
        vm.prank(alice);
        shMonad.depositToZeroYieldTranche{ value: amount }(amount, alice);

        uint256 zyBefore = shMonad.balanceOfZeroYieldTranche(alice);
        uint256 totalZeroYieldBefore = _totalZeroYieldPayable();
        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 bobBalBefore = shMonad.balanceOf(bob);
        uint256 contractEthBefore = address(shMonad).balance;

        // Expected shares are based on previewDeposit (no msg.value deduction path)
        uint256 expectedShares = shMonad.previewDeposit(amount);

        // Expect: (1) ZeroYieldBalanceConvertedToShares and (2) ERC4626 Deposit events
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit ZeroYieldBalanceConvertedToShares(alice, bob, amount, expectedShares);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit Deposit(alice, bob, amount, expectedShares);
        uint256 minted = shMonad.convertZeroYieldTrancheToShares(amount, bob);

        // Return value equals minted shares
        assertEq(minted, expectedShares, "returned shares should equal previewDeposit");

        // ZY balance debited; admin liability reduced 1:1
        assertEq(shMonad.balanceOfZeroYieldTranche(alice), zyBefore - amount, "alice ZY balance decreases");
        assertEq(_totalZeroYieldPayable(), totalZeroYieldBefore - amount, "admin totalZeroYieldPayable decreases");

        // Shares minted to receiver; total supply increases by minted amount
        assertEq(shMonad.balanceOf(bob), bobBalBefore + expectedShares, "receiver gets minted shares");
        assertEq(shMonad.totalSupply(), totalSupplyBefore + expectedShares, "totalSupply increases by minted");

        // No native token moves during conversion; only internal accounting changes
        assertEq(address(shMonad).balance, contractEthBefore, "contract native balance unchanged");
    }

    function test_ZeroYield_convertToShares_revertsOnInsufficientBalance() public {
        uint256 requested = 2 ether;
        // Alice has not deposited to zero-yield; available=0
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.InsufficientZeroYieldBalance.selector, 0, requested)
        );
        shMonad.convertZeroYieldTrancheToShares(requested, alice);
    }

    // --------------------------------------------- //
    //        claimOwnerCommissionAsShares           //
    // --------------------------------------------- //

    function test_ZeroYield_claimOwnerCommission_onlyOwner() public {
        uint256 amount = 3 ether;

        // Seed the commission account via a zero-yield deposit
        vm.prank(alice);
        shMonad.depositToZeroYieldTranche{ value: amount }(amount, OWNER_COMMISSION_ACCOUNT);

        // Non-owner cannot claim
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        shMonad.claimOwnerCommissionAsShares(amount, alice);
    }

    function test_ZeroYield_claimOwnerCommission_mintsExpectedSharesAndEmitsEvents() public {
        uint256 amount = 6 ether;

        // Arrange: seed commission balance
        vm.prank(alice);
        shMonad.depositToZeroYieldTranche{ value: amount }(amount, OWNER_COMMISSION_ACCOUNT);

        uint256 zyBefore = shMonad.unclaimedOwnerCommission();
        uint256 totalZeroYieldBefore = _totalZeroYieldPayable();
        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 receiverBalBefore = shMonad.balanceOf(bob);
        uint256 expectedShares = shMonad.previewDeposit(amount);

        // Expect both conversion and admin-claimed events. Order: conversion events then admin claimed.
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit ZeroYieldBalanceConvertedToShares(OWNER_COMMISSION_ACCOUNT, bob, amount, expectedShares);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit Deposit(OWNER_COMMISSION_ACCOUNT, bob, amount, expectedShares);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit AdminCommissionClaimedAsShares(bob, amount, expectedShares);
        uint256 minted = shMonad.claimOwnerCommissionAsShares(amount, bob);

        // Minted shares equal preview; receiver gets the minted amount
        assertEq(minted, expectedShares, "returned shares should equal previewDeposit");
        assertEq(shMonad.balanceOf(bob), receiverBalBefore + expectedShares, "receiver gets minted shares");

        // Commission balance reduced; admin liability reduced
        assertEq(shMonad.unclaimedOwnerCommission(), zyBefore - amount, "commission ZY balance decreases");
        assertEq(_totalZeroYieldPayable(), totalZeroYieldBefore - amount, "admin totalZeroYieldPayable decreases");

        // Supply increases by minted amount
        assertEq(shMonad.totalSupply(), totalSupplyBefore + expectedShares, "totalSupply increases by minted");
    }

    function test_ZeroYield_depositToZeroYieldTranche_revertsWhenClosed() public {
        // Close the contract via owner-only setter
        vm.prank(deployer);
        shMonad.setClosedStatus(true);

        // Attempting to deposit to zero-yield should revert with NotWhenClosed
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.NotWhenClosed.selector));
        shMonad.depositToZeroYieldTranche{ value: 1 ether }(1 ether, alice);
    }

    function test_ZeroYield_convertZeroYieldTrancheToShares_revertsWhenClosed() public {
        // Close the contract via owner-only setter
        vm.prank(deployer);
        shMonad.setClosedStatus(true);

        // Attempting to convert should revert with NotWhenClosed, regardless of balance
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.NotWhenClosed.selector));
        shMonad.convertZeroYieldTrancheToShares(1 ether, alice);
    }

    // --------------------------------------------- //
    //                 View Functions                //
    // --------------------------------------------- //

    function test_ZeroYield_viewFunctions_balanceAndCommission() public {
        uint256 aliceZY = 2 ether;
        uint256 commissionZY = 4 ether;

        // Seed distinct zero-yield balances
        vm.prank(alice);
        shMonad.depositToZeroYieldTranche{ value: aliceZY }(aliceZY, alice);
        uint256 commissionBefore = shMonad.unclaimedOwnerCommission();
        vm.prank(alice);
        shMonad.depositToZeroYieldTranche{ value: commissionZY }(commissionZY, OWNER_COMMISSION_ACCOUNT);

        // Views return current balances
        assertEq(shMonad.balanceOfZeroYieldTranche(alice), aliceZY, "alice ZY view reflects balance");
        assertEq(
            shMonad.unclaimedOwnerCommission(),
            commissionBefore + commissionZY,
            "commission ZY view reflects balance"
        );

        // After converting part of alice's and claiming part of commission, views should decrease accordingly
        uint256 aliceConvert = 1 ether;
        uint256 commissionClaim = 3 ether;

        vm.prank(alice);
        shMonad.convertZeroYieldTrancheToShares(aliceConvert, alice);

        vm.prank(deployer);
        shMonad.claimOwnerCommissionAsShares(commissionClaim, deployer);

        assertEq(
            shMonad.balanceOfZeroYieldTranche(alice), aliceZY - aliceConvert, "alice ZY decreases after conversion"
        );
        assertEq(
            shMonad.unclaimedOwnerCommission(),
            commissionBefore + commissionZY - commissionClaim,
            "commission decreases after claim"
        );
    }

    // --------------------------------------------- //
    //          Commission Earnings (Section)         //
    // --------------------------------------------- //

    // Commission on boost yield should increase both the global zero-yield liability and
    // the owner's commission balance by `amount * boostCommissionBps / 10_000`.
    function test_ShMonadCommission_boostYield_increasesAdminLiability_andOwnerBalance() public {
        uint256 boostBps = 1500; // 15.00%
        uint256 amount = 20 ether;
        address originator = makeAddr("originator");

        // Configure boost commission
        vm.prank(deployer);
        shMonad.updateBoostCommission(uint16(boostBps));

        uint256 totalZeroYieldBefore = _totalZeroYieldPayable();
        uint256 ownerCommissionBefore = shMonad.unclaimedOwnerCommission();
        uint256 contractEthBefore = address(shMonad).balance;

        // Fund sender and send a boost
        vm.deal(alice, amount);
        vm.prank(alice);
        shMonad.boostYield{ value: amount }(originator);

        uint256 expectedCommission = (amount * boostBps) / 10_000;

        // Assertions: admin liability increases by commission; owner account also increases; ETH held by contract
        assertEq(_totalZeroYieldPayable(), totalZeroYieldBefore + expectedCommission, "admin pool += commission");
        assertEq(
            shMonad.unclaimedOwnerCommission(), ownerCommissionBefore + expectedCommission, "owner += commission"
        );
        assertEq(address(shMonad).balance, contractEthBefore + amount, "contract holds boost amount");
    }

    // Commission on MEV validator rewards: sendValidatorRewards(amount, feeRate) credits protocol fee,
    // applies the boost commission on that fee, and credits the owner's ZY balance by the commission.
    function test_ShMonadCommission_validatorRewards_creditsOwnerAndLiability() public {
        // Prepare an active validator
        (, uint64 valId) = _ensureActiveValidator(address(0), "mevVal");
        // Fresh crank so inActiveSet_Current is set for this epoch
        _advanceEpochAndCrankValidator(valId);
        // Configure fee params
        uint256 feeRateScaled = SCALE / 100; // 1%
        uint16 boostBps = 500; // Owner commission is 5% of the protocol fee
        vm.prank(deployer);
        shMonad.updateBoostCommission(boostBps);

        uint256 amount = 12 ether; // total MEV reward sent by relayer
        uint256 grossFee = (amount * feeRateScaled) / SCALE;
        uint256 commission = (grossFee * boostBps) / 10_000;
        uint256 feeTaken = grossFee - commission;
        uint256 validatorPayout = amount - feeTaken - commission;

        // Baselines
        (uint128 rewardsPayableBefore,,) = shMonad.globalLiabilities();
        (uint128 stakedBefore, uint128 reservedBefore) = shMonad.getWorkingCapital();
        uint256 adminLiabilityBefore = _totalZeroYieldPayable();
        uint256 ownerCommissionBefore = shMonad.unclaimedOwnerCommission();
        uint256 contractEthBefore = address(shMonad).balance;

        // Send validator rewards (permissionless); caller funds msg.value
        vm.deal(bob, amount);
        vm.prank(bob);
        shMonad.sendValidatorRewards{ value: amount }(valId, feeRateScaled);

        // Owner commission balance and admin liability increase by `commission`
        assertEq(
            shMonad.unclaimedOwnerCommission(), ownerCommissionBefore + commission, "owner commission increases"
        );
        assertEq(_totalZeroYieldPayable(), adminLiabilityBefore + commission, "admin pool += commission");

        // Rewards payable and reserved move by validatorPayout
        (uint128 rewardsPayableAfter,,) = shMonad.globalLiabilities();
        (uint128 stakedAfter, uint128 reservedAfter) = shMonad.getWorkingCapital();
        assertEq(uint256(rewardsPayableAfter - rewardsPayableBefore), validatorPayout, "rewardsPayable += payout");
        assertEq(uint256(reservedAfter - reservedBefore), validatorPayout, "reserved += payout");
        assertEq(stakedAfter, stakedBefore, "staking not affected by pure MEV receipt");

        // Contract native balance increases by total amount sent
        assertEq(address(shMonad).balance, contractEthBefore + amount, "contract balance += amount");
    }

    // Commission on earned staking yield: rewards are claimed to ShMonad on validator crank.
    // The owner's commission is taken from the realized yield at `stakingCommissionBps`.
    function test_ShMonadCommission_stakingYield_creditsOwnerAndLiability_onCrank() public {
        uint16 stakingCommissionBps = 700; // 7%
        uint256 reward = 9 ether;

        uint64 valId;
        if (useLocalMode) {
            // Local mode: exercise the full deposit -> queue -> delegate path.
            (, valId) = _ensureActiveValidator(address(0), "yieldVal");

            vm.prank(deployer);
            shMonad.updateStakingCommission(stakingCommissionBps);

            // Give ShMonad stake via the normal ERC4626 deposit flow.
            uint256 shmonadStake = 1 ether;
            vm.deal(bob, shmonadStake);
            vm.prank(bob);
            shMonad.deposit{ value: shmonadStake }(shmonadStake, bob);

            // Delegate + activate stake on the validator.
            _advanceEpochAndCrankValidator(valId);
            _advanceEpochAndCrankValidator(valId);
        } else {
            // Fork mode: avoid relying on ShMonad's staking queue (which depends on existing fork state).
            // Seed a validator where ShMonad has stake so it can accrue/claim rewards deterministically.
            uint256 shmonadStake = 1 ether;
            valId = _seedValidatorWithShMonadStake("yieldVal", shmonadStake, shmonadStake);

            vm.prank(deployer);
            shMonad.updateStakingCommission(stakingCommissionBps);

            // New validators start with wasCranked=true on past epochs; advance twice so _crankValidator will run.
            _advanceEpochAndCrankValidator(valId);
            _advanceEpochAndCrankValidator(valId);
        }

        // Inject rewards into the mock precompile (held there until ShMonad claims on crank).
        vm.deal(alice, reward);
        vm.prank(alice);
        staking.harnessSyscallReward{ value: reward }(valId, reward);

        uint256 adminLiabilityBefore = _totalZeroYieldPayable();
        uint256 ownerCommissionBefore = shMonad.unclaimedOwnerCommission();

        // Compute expected commission from ShMonad's stake share (works in both modes).
        (,,,,,, uint256 consensusStake,,,,,) = staking.getValidator(valId);
        (uint256 shmonadStakeUpdated,,,,,,) = staking.getDelegator(valId, address(shMonad));
        uint256 shmonadReward = (reward * shmonadStakeUpdated) / consensusStake;
        uint256 expectedCommission = (shmonadReward * stakingCommissionBps) / 10_000;

        // Advance epoch and crank; this triggers _claimRewards -> _handleEarnedStakingYield.
        _advanceEpochAndCrankValidator(valId);

        if (useLocalMode) {
            // Local: clean slate, no fork background noise; assert exact deltas.
            assertEq(
                shMonad.unclaimedOwnerCommission(),
                ownerCommissionBefore + expectedCommission,
                "owner staking commission did not increase as expected"
            );
            assertEq(
                _totalZeroYieldPayable(),
                adminLiabilityBefore + expectedCommission,
                "admin staking commission did not increase as expected"
            );
        } else {
            // Fork: ShMonad may claim background rewards from existing validators during a crank.
            // We only require that our injected reward increases commission/liability by at least the expected amount.
            assertGe(
                shMonad.unclaimedOwnerCommission(),
                ownerCommissionBefore + expectedCommission,
                "owner staking commission did not increase as expected"
            );
            assertGe(
                _totalZeroYieldPayable(),
                adminLiabilityBefore + expectedCommission,
                "admin staking commission did not increase as expected"
            );
        }
    }

    // Verify that staking commission emits DepositToZeroYieldTranche event
    function test_ShMonadCommission_stakingYield_emitsDepositToZeroYieldTranche() public {
        uint16 stakingCommissionBps = 700; // 7%
        uint256 reward = 9 ether;

        uint64 valId;
        if (useLocalMode) {
            (, valId) = _ensureActiveValidator(address(0), "yieldVal");

            vm.prank(deployer);
            shMonad.updateStakingCommission(stakingCommissionBps);

            // Give ShMonad stake via the normal ERC4626 deposit flow.
            uint256 shmonadStake = 1 ether;
            vm.deal(bob, shmonadStake);
            vm.prank(bob);
            shMonad.deposit{ value: shmonadStake }(shmonadStake, bob);

            // Delegate + activate stake on the validator.
            _advanceEpochAndCrankValidator(valId);
            _advanceEpochAndCrankValidator(valId);
        } else {
            uint256 shmonadStake = 1 ether;
            valId = _seedValidatorWithShMonadStake("yieldVal", shmonadStake, shmonadStake);

            vm.prank(deployer);
            shMonad.updateStakingCommission(stakingCommissionBps);

            // New validators start with wasCranked=true on past epochs; advance twice so _crankValidator will run.
            _advanceEpochAndCrankValidator(valId);
            _advanceEpochAndCrankValidator(valId);
        }

        // Inject rewards into the mock precompile.
        vm.deal(alice, reward);
        vm.prank(alice);
        staking.harnessSyscallReward{ value: reward }(valId, reward);

        uint256 ownerCommissionBefore = shMonad.unclaimedOwnerCommission();

        // Compute expected commission from ShMonad's stake share (works in both modes).
        (,,,,,, uint256 consensusStake,,,,,) = staking.getValidator(valId);
        (uint256 shmonadStakeUpdated,,,,,,) = staking.getDelegator(valId, address(shMonad));
        uint256 shmonadReward = (reward * shmonadStakeUpdated) / consensusStake;
        uint256 expectedCommission = (shmonadReward * stakingCommissionBps) / 10_000;

        // Record logs to capture DepositToZeroYieldTranche event
        vm.recordLogs();

        // Advance epoch and crank; this triggers _claimRewards -> _handleEarnedStakingYield
        _advanceEpochAndCrankValidator(valId);

        // Verify commission was added
        uint256 actualCommission = shMonad.unclaimedOwnerCommission() - ownerCommissionBefore;
        if (useLocalMode) {
            assertEq(actualCommission, expectedCommission, "commission mismatch");
        } else {
            assertGe(actualCommission, expectedCommission, "commission mismatch");
        }

        // Find and verify the DepositToZeroYieldTranche event for the staking commission
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("DepositToZeroYieldTranche(address,address,uint256)");
        bool foundExpectedEvent = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                address sender = address(uint160(uint256(entries[i].topics[1])));
                address receiver = address(uint160(uint256(entries[i].topics[2])));
                uint256 assets = abi.decode(entries[i].data, (uint256));

                if (sender == address(shMonad) && receiver == OWNER_COMMISSION_ACCOUNT) {
                    if (useLocalMode) {
                        if (assets == expectedCommission) {
                            foundExpectedEvent = true;
                            break;
                        }
                    } else {
                        if (assets >= expectedCommission) {
                            foundExpectedEvent = true;
                            break;
                        }
                    }
                }
            }
        }
        assertTrue(foundExpectedEvent, "DepositToZeroYieldTranche event not emitted for staking commission");
    }
}
