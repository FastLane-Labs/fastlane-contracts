// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import { ShMonadEvents } from "../../src/shmonad/Events.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import { OWNER_COMMISSION_ACCOUNT, MIN_VALIDATOR_DEPOSIT, SCALE, UNSTAKE_BLOCK_DELAY } from "../../src/shmonad/Constants.sol";

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

    function setUp() public override {
        super.setUp();
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
        while (!shMonad.crank()) {}
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
            _advanceEpochAndCrank();
            if (shMonad.isValidatorActive(valId)) {
                active = true;
                break;
            }
        }
        require(active, "validator should be active");
    }

    // --------------------------------------------- //
    //          depositToZeroYieldTranche            //
    // --------------------------------------------- //

    function test_ZeroYield_deposit_updatesBalancesAndLiability_andEmitsEvent() public {
        uint256 amount = 10 ether;
        address receiver = bob; // credit zero-yield to a third party

        // Snapshot queueToStake/queueForUnstake before deposit
        (uint120 qToStakeBefore, uint120 qForUnstakeBefore) = shMonad.getGlobalCashFlows(0);

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
        assertEq(uint256(qToStakeAfter - qToStakeBefore), amount, "queueToStake += amount");
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
        vm.prank(alice);
        shMonad.depositToZeroYieldTranche{ value: commissionZY }(commissionZY, OWNER_COMMISSION_ACCOUNT);

        // Views return current balances
        assertEq(shMonad.balanceOfZeroYieldTranche(alice), aliceZY, "alice ZY view reflects balance");
        assertEq(shMonad.unclaimedOwnerCommission(), commissionZY, "commission ZY view reflects balance");

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
            shMonad.unclaimedOwnerCommission(), commissionZY - commissionClaim, "commission decreases after claim"
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
        _advanceEpochAndCrank();
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
        // Prepare an active validator and set a staking commission
        (, uint64 valId) = _ensureActiveValidator(address(0), "yieldVal");
        uint16 stakingCommissionBps = 700; // 7%
        vm.prank(deployer);
        shMonad.updateStakingCommission(stakingCommissionBps);
        // Make ShMonad a delegator with stake so it accrues claimable rewards
        uint256 shmonadStake = 1 ether;
        // Fund ShMonad via a third-party deposit so its balance increases naturally (works in both modes)
        vm.deal(bob, shmonadStake);
        vm.prank(bob);
        shMonad.deposit{ value: shmonadStake }(shmonadStake, bob);
        // Run a crank cycle so the contract pulls from the staking queue and delegates internally
        _advanceEpochAndCrank();
        // Advance once more to activate the freshly scheduled stake on the validator
        _advanceEpochAndCrank();

        // Inject rewards into the mock precompile (held there until ShMonad claims on crank)
        uint256 reward = 9 ether;
        vm.deal(alice, reward);
        vm.prank(alice);
        staking.harnessSyscallReward{ value: reward }(valId, reward);

        uint256 adminLiabilityBefore = _totalZeroYieldPayable();
        uint256 ownerCommissionBefore = shMonad.unclaimedOwnerCommission();
        uint256 contractEthBefore = address(shMonad).balance;

        // Equity is maintained via normal flows; no direct balance resets.

        // Advance epoch and crank; this triggers _claimRewards -> _handleEarnedStakingYield
        _advanceEpochAndCrank();

        // Compute the share of reward accrued to ShMonad based on current epoch stake
        (
            address authAddress,,,,,, uint256 consensusStake,,,,,
        ) = staking.getValidator(valId);
        (
            uint256 shmonadStakeUpdated,,,,,,
        ) = staking.getDelegator(valId, address(shMonad));

        uint256 shmonadReward = (reward * shmonadStakeUpdated) / consensusStake;
        uint256 expectedCommission = (shmonadReward * stakingCommissionBps) / 10_000;

        // Owner commission and admin pool increase by staking commission on ShMonad's share
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
    }
}
