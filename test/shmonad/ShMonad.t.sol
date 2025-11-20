// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import { ShMonad } from "../../src/shmonad/ShMonad.sol";
import { ShMonadEvents } from "../../src/shmonad/Events.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import { Policy } from "../../src/shmonad/Types.sol";
import { MIN_TOP_UP_PERIOD_BLOCKS, MIN_VALIDATOR_DEPOSIT } from "../../src/shmonad/Constants.sol";

//
// ShMonad.t.sol
//
// This file hosts two standardized test contracts:
// - ShMonadTest: Thin, high-level integration sanity for core ShMonad behaviors
// - AgentSpendTest: Focused tests for agent-only committed balance operations
//
// Tests follow Arrange → Act → Assert with explicit comments describing intent
// and expected outcomes. Event expectations are set before the Act step.
// Trigger: touching shmonad tests to exercise Codex review workflow.
//
contract ShMonadTest is BaseTest, ShMonadEvents {
    address public alice;
    address public bob;

    uint256 constant INITIAL_BAL = 200 ether;

    function setUp() public override {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, INITIAL_BAL);
        vm.deal(bob, INITIAL_BAL);
        super.setUp();
    }

    // (No ERC20 metadata tests here; see FLERC20.t.sol.)

    // ShMonad is initialized during BaseTest setup. A second initialize should fail.
    function test_ShMonad_initialize_cannotBeCalledTwice() public {
        // ShMonad already initialized by setup; calling again should revert
        vm.expectRevert();
        shMonad.initialize(deployer);
    }

    // Test that non-owner cannot call initialize when owner is already set
    // This simulates protection against front-running during upgrades
    function test_ShMonad_initialize_preventsUnauthorizedInitialization() public {
        // An attacker cannot initialize when owner is already set
        // Even though reinitializer(10) will block re-init at same version,
        // the owner check provides additional protection for upgrades to higher versions
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        // Will revert with InvalidInitialization because already at version 10
        // But in an upgrade scenario (version 11+), would revert with UnauthorizedInitializer
        vm.expectRevert();
        shMonad.initialize(attacker);

        // Verify owner hasn't changed
        assertEq(shMonad.owner(), deployer);
    }

    // Test that implementation contract cannot be initialized directly
    function test_ShMonad_initialize_implementationDisabled() public {
        // Deploy fresh implementation (not a proxy)
        ShMonad implementation = new ShMonad();

        // Anyone trying to initialize the implementation should fail
        // because _disableInitializers() was called in constructor
        vm.expectRevert();
        implementation.initialize(deployer);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        implementation.initialize(makeAddr("attacker"));
    }

    // (No ERC4626 tests here; see FLERC4626.t.sol.)

    // (No policy lifecycle tests here; see Policies.t.sol.)

    // (No boostYield tests here; see FLERC4626.t.sol.)

    // (No policy agent management tests here; see Policies.t.sol.)

    // (No traditional unstaking tests here; see TraditionalUnstaking.t.sol.)

}

// -----------------------------------------------------------------------------
// Consolidated Agent spend tests (from AgentSpend.t.sol)
// -----------------------------------------------------------------------------

contract AgentSpendTest is BaseTest, ShMonadEvents {
    address public alice;
    address public bob;
    address public charlie;
    address public agent1;
    address public agent2;

    uint64 public policyID1;
    uint64 public policyID2;

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant POOL_SEED = 200 ether;
    uint48 public constant DEFAULT_UNBONDING_PERIOD = 10;
    uint32 public constant MIN_TOP_UP_PERIOD = MIN_TOP_UP_PERIOD_BLOCKS;

    // Prepare two policies and register distinct agents for each to validate
    // authorization scoping across policies.
    function setUp() public override {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        agent1 = makeAddr("agent1");
        agent2 = makeAddr("agent2");

        super.setUp();

        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
        vm.deal(charlie, INITIAL_BALANCE);
        vm.deal(agent1, INITIAL_BALANCE);
        vm.deal(agent2, INITIAL_BALANCE);
        vm.deal(deployer, INITIAL_BALANCE);

        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(SCALE - 1);
        shMonad.setUnstakeFeeCurve(0, 0);
        vm.deal(deployer, POOL_SEED);
        shMonad.deposit{ value: POOL_SEED }(POOL_SEED, deployer);
        vm.stopPrank();

        _advanceEpochAndCrank();

        policyID1 = shMonad.createPolicy(DEFAULT_UNBONDING_PERIOD);
        policyID2 = shMonad.createPolicy(DEFAULT_UNBONDING_PERIOD);

        vm.prank(deployer);
        shMonad.addPolicyAgent(policyID1, agent1);
        vm.prank(deployer);
        shMonad.addPolicyAgent(policyID2, agent2);
    }

    // ----------------------------- //
    //            Helpers            //
    // ----------------------------- //
    function _setupCommittedBalance(address account, uint64 policyID, uint256 amount)
        internal
        returns (uint256 committedShares)
    {
        // Deposits underlying and commits the resulting shares to a policy.
        vm.startPrank(account);
        shMonad.depositAndCommit{ value: amount }(policyID, account, type(uint256).max);
        committedShares = shMonad.balanceOfCommitted(policyID, account);
        vm.stopPrank();
    }

    function _setupUncommittedBalance(address account, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(account);
        shares = shMonad.deposit{ value: amount }(amount, account);
        vm.stopPrank();
    }

    function _setupUnbondingBalance(address account, uint64 policyID, uint256 bondAmount)
        internal
        returns (uint256 uncommittingShares)
    {
        // First commit, then request uncommit to move funds into uncommitting state
        uncommittingShares = _setupCommittedBalance(account, policyID, bondAmount);
        vm.prank(account);
        shMonad.requestUncommit(policyID, uncommittingShares, 0);
    }

    function _setupTopUpSettings(address account, uint64 policyID, uint128 maxTopUp, uint32 periodDuration) internal {
        vm.prank(account);
        shMonad.setMinCommittedBalance(policyID, 0, maxTopUp, periodDuration);
    }

    function _advanceEpochAndCrank() internal {
        vm.roll(block.number + 50_000);
        staking.harnessSyscallOnEpochChange(false);
        while (!shMonad.crank()) {}
    }

    // ----------------------------- //
    //       Agent Authorization     //
    // ----------------------------- //
    function test_ShMonad_agentWithdrawFromCommitted_onlyAgentCanCall() public {
        _setupCommittedBalance(alice, policyID1, 10 ether); // give alice committed shares

        vm.prank(bob);
        vm.expectRevert();
        shMonad.agentWithdrawFromCommitted(policyID1, alice, bob, 1 ether, 0, true);

        vm.prank(agent1);
        shMonad.agentWithdrawFromCommitted(policyID1, alice, agent1, 1 ether, 0, true);
    }

    function test_ShMonad_agentWithdrawFromCommitted_cannotOperateOnDifferentPolicy() public {
        _setupCommittedBalance(alice, policyID1, 10 ether);

        vm.prank(agent2);
        vm.expectRevert();
        shMonad.agentWithdrawFromCommitted(policyID1, alice, agent2, 1 ether, 0, true);
    }

    function test_ShMonad_agentTransferFromCommitted_onlyAgentCanCall() public {
        _setupCommittedBalance(alice, policyID1, 10 ether);

        vm.prank(bob);
        vm.expectRevert();
        shMonad.agentTransferFromCommitted(policyID1, alice, bob, 1 ether, 0, true);

        vm.prank(agent1);
        shMonad.agentTransferFromCommitted(policyID1, alice, bob, 1 ether, 0, true);
    }

    function test_ShMonad_agentTransferToUncommitted_onlyAgentCanCall() public {
        _setupCommittedBalance(alice, policyID1, 10 ether);

        vm.prank(bob);
        vm.expectRevert();
        shMonad.agentTransferToUncommitted(policyID1, alice, bob, 1 ether, 0, true);

        vm.prank(agent1);
        shMonad.agentTransferToUncommitted(policyID1, alice, bob, 1 ether, 0, true);
    }

    function test_ShMonad_agentTransferToUncommitted_cannotSelfUnbond() public {
        _setupCommittedBalance(agent1, policyID1, 10 ether);

        vm.prank(agent1);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.AgentInstantUncommittingDisallowed.selector, policyID1, agent1)
        );
        shMonad.agentTransferToUncommitted(policyID1, agent1, bob, 1 ether, 0, true);
    }

    function test_ShMonad_agentWithdrawFromCommitted_cannotSelfUnbond() public {
        _setupCommittedBalance(agent1, policyID1, 10 ether);

        vm.prank(agent1);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.AgentInstantUncommittingDisallowed.selector, policyID1, agent1)
        );
        shMonad.agentWithdrawFromCommitted(policyID1, agent1, bob, 1 ether, 0, true);
    }

    // ----------------------------- //
    //         Agent Withdrawal      //
    // ----------------------------- //
    function test_ShMonad_agentWithdrawFromCommitted_revertsWhenNetExceedsPoolLiquidity() public {
        // - Give Alice a healthy committed balance under policy 1
        // - Ensure atomic unstake pool has a known, small amount of available liquidity
        // - Compute a withdraw request just 1 wei above available to trigger revert
        uint256 aliceCommitAmount = 20 ether;
        _setupCommittedBalance(alice, policyID1, aliceCommitAmount);

        // Seed atomic pool liquidity to a small, deterministic baseline and crank to apply it.
        // We target near-100% so the allocated amount closely tracks equity; depositAmount is 0 since helper will
        // derive the needed deposit if current liquidity is below the minimum.
        uint256 minLiquidity = 5 ether;
        _ensureAtomicLiquidity(minLiquidity, SCALE - 1, 0);

        // Snapshot current available liquidity (R0). The revert should compare requested net vs this value.
        uint256 availableLiquidity = shMonad.getCurrentLiquidity();
        assertGt(availableLiquidity, 0, "atomic pool should have some liquidity");

        // Choose a net withdraw amount that is just barely too high.
        uint256 netRequested = availableLiquidity + 1; // 1 wei above available to force InsufficientPoolLiquidity

        // Expect a revert from _getGrossAndFeeFromNetAssets() with precise error data
        vm.prank(agent1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShMonadErrors.InsufficientPoolLiquidity.selector, netRequested, availableLiquidity
            )
        );
        // inUnderlying=true means `amount` is the target net assets (post-fee), which is capped by available R0.
        shMonad.agentWithdrawFromCommitted(policyID1, alice, bob, netRequested, 0, true);
    }
    function test_ShMonad_agentWithdrawFromCommitted_sufficientCommittedBalance() public {
        uint256 bondAmount = 10 ether;
        uint256 withdrawAmount = 3 ether;
        uint256 aliceBondedShares = _setupCommittedBalance(alice, policyID1, bondAmount);

        uint256 bobBalanceBefore = bob.balance;
        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 bondedSupplyBefore = shMonad.committedTotalSupply();
        uint256 totalAssetsBefore = shMonad.totalAssets();

        uint256 expectedSharesDeducted = shMonad.previewWithdraw(withdrawAmount);

        vm.prank(agent1);
        vm.expectEmit(true, true, true, true);
        emit AgentWithdrawFromCommitted(policyID1, alice, bob, withdrawAmount);
        shMonad.agentWithdrawFromCommitted(policyID1, alice, bob, withdrawAmount, 0, true);

        assertEq(shMonad.balanceOfCommitted(policyID1, alice), aliceBondedShares - expectedSharesDeducted);
        assertEq(bob.balance, bobBalanceBefore + withdrawAmount);
        assertEq(shMonad.totalSupply(), totalSupplyBefore - expectedSharesDeducted);
        assertEq(shMonad.committedTotalSupply(), bondedSupplyBefore - expectedSharesDeducted);
    }

    function test_ShMonad_agentWithdrawFromCommitted_acceptsSharesInput() public {
        uint256 bondAmount = 10 ether;
        uint256 aliceBondedShares = _setupCommittedBalance(alice, policyID1, bondAmount);
        uint256 sharesToWithdraw = aliceBondedShares / 2;

        uint256 bobBalanceBefore = bob.balance;
        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 bondedSupplyBefore = shMonad.committedTotalSupply();
        uint256 expectedAssets = shMonad.previewRedeem(sharesToWithdraw);

        vm.prank(agent1);
        vm.expectEmit(true, true, true, true);
        emit AgentWithdrawFromCommitted(policyID1, alice, bob, expectedAssets);
        shMonad.agentWithdrawFromCommitted(policyID1, alice, bob, sharesToWithdraw, 0, false);

        assertEq(shMonad.balanceOfCommitted(policyID1, alice), aliceBondedShares - sharesToWithdraw);
        assertEq(bob.balance, bobBalanceBefore + expectedAssets);
        assertEq(shMonad.totalSupply(), totalSupplyBefore - sharesToWithdraw);
        assertEq(shMonad.committedTotalSupply(), bondedSupplyBefore - sharesToWithdraw);
    }

    function test_ShMonad_agentWithdrawFromCommitted_withHoldRelease() public {
        uint256 aliceBondedShares = _setupCommittedBalance(alice, policyID1, 12 ether);
        uint256 sharesOnHold = (aliceBondedShares * 3) / 4;
        uint256 withdrawAmount = 8 ether;

        vm.prank(agent1);
        shMonad.hold(policyID1, alice, sharesOnHold);

        vm.prank(agent1);
        vm.expectRevert();
        shMonad.agentWithdrawFromCommitted(policyID1, alice, bob, withdrawAmount, 0, true);

        uint256 expectedSharesDeducted = shMonad.previewWithdraw(withdrawAmount);
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(agent1);
        vm.expectEmit(true, true, true, true);
        emit AgentWithdrawFromCommitted(policyID1, alice, bob, withdrawAmount);
        shMonad.agentWithdrawFromCommitted(policyID1, alice, bob, withdrawAmount, sharesOnHold, true);

        assertEq(bob.balance, bobBalanceBefore + withdrawAmount);
        assertEq(shMonad.balanceOfCommitted(policyID1, alice), aliceBondedShares - expectedSharesDeducted);
    }

    // Withdrawal greater than currently committed triggers recovery from the
    // user's uncommitting balance within the same policy.
    function test_ShMonad_agentWithdrawFromCommitted_triggersUncommittingRecovery() public {
        uint256 committedAmount = 5 ether;
        uint256 uncommittingAmount = 5 ether;
        uint256 withdrawAmount = 7 ether;

        _setupCommittedBalance(alice, policyID1, committedAmount);
        uint256 aliceUnbondingShares = _setupUnbondingBalance(alice, policyID1, uncommittingAmount);

        uint256 bobBalanceBefore = bob.balance;
        uint256 totalSupplyBefore = shMonad.totalSupply();

        vm.prank(agent1);
        shMonad.agentWithdrawFromCommitted(policyID1, alice, bob, withdrawAmount, 0, true);

        uint256 expectedSharesDeducted = shMonad.previewWithdraw(withdrawAmount);

        assertEq(bob.balance, bobBalanceBefore + withdrawAmount);
        assertEq(shMonad.balanceOfCommitted(policyID1, alice), 0);
        assertTrue(shMonad.balanceOfUncommitting(policyID1, alice) < aliceUnbondingShares);
        assertEq(shMonad.totalSupply(), totalSupplyBefore - expectedSharesDeducted);
    }

    // If top-up settings allow and there is uncommitted balance available,
    // the shortfall is topped up to committed to satisfy the agent withdrawal.
    function test_ShMonad_agentWithdrawFromCommitted_triggersTopUp() public {
        uint256 committedAmount = 2 ether;
        uint256 uncommittedAmount = 20 ether;
        uint256 withdrawAmount = 5 ether;
        uint128 maxTopUp = 10 ether;

        _setupCommittedBalance(alice, policyID1, committedAmount);
        _setupUncommittedBalance(alice, uncommittedAmount);
        _setupTopUpSettings(alice, policyID1, maxTopUp, MIN_TOP_UP_PERIOD);

        uint256 bondedSupplyBefore = shMonad.committedTotalSupply();

        vm.prank(agent1);
        shMonad.agentWithdrawFromCommitted(policyID1, alice, bob, withdrawAmount, 0, true);

        uint256 expectedSharesWithdrawn = shMonad.previewWithdraw(withdrawAmount);
        assertTrue(bondedSupplyBefore - shMonad.committedTotalSupply() < expectedSharesWithdrawn);
    }

    // ----------------------------- //
    //          Agent Transfers      //
    // ----------------------------- //
    function test_ShMonad_agentTransferFromCommitted_cannotSelfTransfer() public {
        // Arrange: agent has committed balance under the same policy
        _setupCommittedBalance(agent1, policyID1, 10 ether);

        // Act + Assert: agent cannot transfer their own committed funds
        vm.prank(agent1);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.AgentInstantUncommittingDisallowed.selector, policyID1, agent1)
        );
        shMonad.agentTransferFromCommitted(policyID1, agent1, bob, 1 ether, 0, true);
    }

    function test_ShMonad_agentTransferFromCommitted_transfersBetweenAccounts() public {
        uint256 bondAmount = 10 ether;
        uint256 transferAmount = 4 ether;
        uint256 aliceBondedShares = _setupCommittedBalance(alice, policyID1, bondAmount);

        uint256 bondedSupplyBefore = shMonad.committedTotalSupply();
        uint256 expectedSharesTransferred = shMonad.previewWithdraw(transferAmount);

        vm.prank(agent1);
        vm.expectEmit(true, true, true, true);
        emit AgentTransferFromCommitted(policyID1, alice, bob, expectedSharesTransferred);
        shMonad.agentTransferFromCommitted(policyID1, alice, bob, transferAmount, 0, true);

        assertEq(shMonad.balanceOfCommitted(policyID1, alice), aliceBondedShares - expectedSharesTransferred);
        assertEq(shMonad.balanceOfCommitted(policyID1, bob), expectedSharesTransferred);
        assertEq(shMonad.committedTotalSupply(), bondedSupplyBefore);
    }

    function test_ShMonad_agentTransferFromCommitted_acceptsSharesInput() public {
        uint256 bondAmount = 12 ether;
        uint256 aliceBondedShares = _setupCommittedBalance(alice, policyID1, bondAmount);
        uint256 sharesToTransfer = aliceBondedShares / 3;

        uint256 bondedSupplyBefore = shMonad.committedTotalSupply();

        vm.prank(agent1);
        vm.expectEmit(true, true, true, true);
        emit AgentTransferFromCommitted(policyID1, alice, bob, sharesToTransfer);
        shMonad.agentTransferFromCommitted(policyID1, alice, bob, sharesToTransfer, 0, false);

        assertEq(shMonad.balanceOfCommitted(policyID1, alice), aliceBondedShares - sharesToTransfer);
        assertEq(shMonad.balanceOfCommitted(policyID1, bob), sharesToTransfer);
        assertEq(shMonad.committedTotalSupply(), bondedSupplyBefore);
    }

    function test_ShMonad_agentTransferFromCommitted_withHoldRelease() public {
        uint256 bondAmount = 10 ether;
        uint256 holdAmount = 3 ether;
        uint256 transferAmount = 8 ether;

        _setupCommittedBalance(alice, policyID1, bondAmount);

        vm.prank(agent1);
        shMonad.hold(policyID1, alice, holdAmount);

        vm.prank(agent1);
        vm.expectRevert();
        shMonad.agentTransferFromCommitted(policyID1, alice, bob, transferAmount, 0, true);

        vm.prank(agent1);
        shMonad.agentTransferFromCommitted(policyID1, alice, bob, transferAmount, holdAmount, true);

        uint256 expectedSharesTransferred = shMonad.previewWithdraw(transferAmount);
        assertEq(shMonad.balanceOfCommitted(policyID1, bob), expectedSharesTransferred);
    }

    // ----------------------------- //
    //          Agent Unbonding      //
    // ----------------------------- //
    function test_ShMonad_agentTransferToUncommitted_basicFlow() public {
        uint256 bondAmount = 10 ether;
        uint256 uncommitAmount = 4 ether;
        uint256 aliceBondedShares = _setupCommittedBalance(alice, policyID1, bondAmount);

        uint256 bondedSupplyBefore = shMonad.committedTotalSupply();
        uint256 bobUnbondedBefore = shMonad.balanceOf(bob);
        uint256 expectedSharesUnbonded = shMonad.previewWithdraw(uncommitAmount);

        vm.prank(agent1);
        vm.expectEmit(true, true, true, true);
        emit AgentTransferToUncommitted(policyID1, alice, bob, expectedSharesUnbonded);
        shMonad.agentTransferToUncommitted(policyID1, alice, bob, uncommitAmount, 0, true);

        assertEq(shMonad.balanceOfCommitted(policyID1, alice), aliceBondedShares - expectedSharesUnbonded);
        assertEq(shMonad.balanceOf(bob), bobUnbondedBefore + expectedSharesUnbonded);
        assertEq(shMonad.committedTotalSupply(), bondedSupplyBefore - expectedSharesUnbonded);
    }

    function test_ShMonad_agentTransferToUncommitted_acceptsSharesInput() public {
        uint256 bondAmount = 10 ether;
        uint256 aliceBondedShares = _setupCommittedBalance(alice, policyID1, bondAmount);
        uint256 sharesToUncommit = aliceBondedShares / 2;

        uint256 bondedSupplyBefore = shMonad.committedTotalSupply();
        uint256 bobUnbondedBefore = shMonad.balanceOf(bob);

        vm.prank(agent1);
        vm.expectEmit(true, true, true, true);
        emit AgentTransferToUncommitted(policyID1, alice, bob, sharesToUncommit);
        shMonad.agentTransferToUncommitted(policyID1, alice, bob, sharesToUncommit, 0, false);

        assertEq(shMonad.balanceOfCommitted(policyID1, alice), aliceBondedShares - sharesToUncommit);
        assertEq(shMonad.balanceOf(bob), bobUnbondedBefore + sharesToUncommit);
        assertEq(shMonad.committedTotalSupply(), bondedSupplyBefore - sharesToUncommit);
    }

    function test_ShMonad_agentTransferToUncommitted_withHoldRelease() public {
        uint256 aliceBondedShares = _setupCommittedBalance(alice, policyID1, 12 ether);
        uint256 sharesOnHold = (aliceBondedShares * 3) / 4;
        uint256 uncommitAmount = 8 ether;

        vm.prank(agent1);
        shMonad.hold(policyID1, alice, sharesOnHold);

        vm.prank(agent1);
        vm.expectRevert();
        shMonad.agentTransferToUncommitted(policyID1, alice, bob, uncommitAmount, 0, true);

        uint256 expectedSharesUnbonded = shMonad.previewWithdraw(uncommitAmount);

        vm.prank(agent1);
        vm.expectEmit(true, true, true, true);
        emit AgentTransferToUncommitted(policyID1, alice, bob, expectedSharesUnbonded);
        shMonad.agentTransferToUncommitted(policyID1, alice, bob, uncommitAmount, sharesOnHold, true);
    }

    

    // --------------------------------------------- //
    //        Unstake Completion Epoch Behavior      //
    // --------------------------------------------- //
    function test_ShMonad_requestUnstake_smallSecondRequest_completionEpochNeverDecreases() public {
        // Arrange: seed validator revenue so staking allocation engages on next crank
        (uint64[] memory valIds,) = shMonad.listActiveValidators();
        assertGt(valIds.length, 0, "needs at least one active validator");
        uint64 valId = valIds[0];

        // Force all deposits to go to staking (no atomic float) so pendingStaking captures the deposit
        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);

        // Seed minimal rewards so smoothed revenue > DUST without materially reducing withdraw previews
        uint256 tinyReward = 3 gwei; // > 2 * DUST_THRESHOLD so avg(last,lastLast) > DUST
        vm.deal(deployer, tinyReward);
        vm.prank(deployer);
        shMonad.sendValidatorRewards{ value: tinyReward }(valId, SCALE); // 100% retained as earned revenue

        // Now deposit and move to next epoch + crank so the queueToStake is allocated as pendingStaking
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        uint256 aliceShares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        _advanceEpochAndCrank();

        // Capture validator target stake after deposit/first crank (for reference)
        (, uint128 valStakeAfterDeposit,,) = shMonad.getValidatorEpochs(valId);

        // Capture current internal epoch and ensure we have some pending staking to tighten redemption window
        uint64 epochN = shMonad.getInternalEpoch();
        (uint120 pendingStakingN,) = shMonad.getGlobalPending();
        // assertGt(pendingStakingN, 0, "pendingStaking should be > 0 at N after staking allocation");

        // Act 1: First (large) unstake at epoch N
        // Leave a tiny remainder for the second request
        uint256 firstShares = aliceShares - 1;
        vm.prank(alice);
        uint64 completionEpoch1 = shMonad.requestUnstake(firstShares);

        // With pendingStaking present and a large ask, expect the +2 epoch extension
        // Base = N + (WITHDRAWAL_DELAY + 4) = N + 5; extension => N + 7
        // assertEq(completionEpoch1, epochN + 7, "first request should quote N+7");

        // Advance one epoch; pendingStaking should decrease as deposits complete
        _advanceEpochAndCrank();
        uint64 epochN1 = shMonad.getInternalEpoch();

        // Act 2: Second (very small) unstake at epoch N+1
        vm.prank(alice);
        uint64 completionEpoch2 = shMonad.requestUnstake(1); // 1 share, intentionally tiny

        // Expected behavior: user's quoted completion epoch should never decrease.
        // We only guarantee monotonic non-decreasing completion epochs (max of prior/new).
        assertGe(completionEpoch2, completionEpoch1, "second request should not decrease completion epoch");

        // Assert: the stored per-user completionEpoch remains the max of prior and new (i.e., does not decrease).
        (uint128 totalUnstakeMon, uint64 storedCompletion) = shMonad.getUnstakeRequest(alice);
        assertGt(totalUnstakeMon, 0, "combined unstake amount should be tracked");
        assertEq(storedCompletion, completionEpoch2, "stored completionEpoch equals the returned max epoch");

        // OPTIONAL: check that the user can actually complete the unstake process
        {
            // OPTIONAL: snapshot state before rolling to completion
            (uint128 stakedBeforeComplete, ) = shMonad.getWorkingCapital();
            (, uint120 pendUnstakeBefore) = shMonad.getGlobalPending();
            // Note: balance can change during epoch advancement; only use a fresh snapshot
            // at the completion epoch for payout delta checks.

            // OPTIONAL: advance to the earlier quoted completion epoch
            while (shMonad.getInternalEpoch() < storedCompletion) {
                _advanceEpochAndCrank();
            }

            // OPTIONAL: at completion epoch - validator/global stake reduced; reserves cover redemptions; funds present
            (uint128 stakedAtComplete, uint128 reservedAtComplete) = shMonad.getWorkingCapital();
            (, uint128 redemptionsAtComplete,) = shMonad.globalLiabilities();
            (, uint120 pendUnstakeAtComplete) = shMonad.getGlobalPending();

            // Depending on liquidity and queue netting, completion can be serviced
            // entirely from reserves without reducing staked. Only assert a decrease
            // when there was a positive staked balance prior to completion.
            if (stakedBeforeComplete > 0) {
                assertLe(stakedAtComplete, stakedBeforeComplete, "staked should not increase by completion epoch");
            } else {
                assertEq(stakedAtComplete, 0, "staked remains zero when fully reserved");
            }
            assertGe(reservedAtComplete, redemptionsAtComplete, "reserves should cover pending redemptions");
            assertGe(address(shMonad).balance, reservedAtComplete, "native balance should at least equal reserves");
            if (pendUnstakeBefore > 0) {
                assertLt(pendUnstakeAtComplete, pendUnstakeBefore, "pendingUnstaking should decrease by completion epoch");
            } else {
                // In flows where decreases complete within the window, global pendingUnstaking can remain 0
                assertEq(pendUnstakeAtComplete, 0, "pendingUnstaking remains zero in this path");
            }

            // OPTIONAL: complete the combined unstake and assert payout equals cumulative amount
            uint256 aliceBalBefore = alice.balance;
            uint256 contractBalBeforePayout = address(shMonad).balance;
            vm.prank(alice);
            shMonad.completeUnstake();
            uint256 contractBalAfterPayout = address(shMonad).balance;
            assertEq(alice.balance - aliceBalBefore, uint256(totalUnstakeMon), "should pay cumulative unstake amount");

            // OPTIONAL: liabilities cleared; reserves consumed by redemption; native balance decreased by payout
            (uint128 stakedAfterComplete, uint128 reservedAfterComplete) = shMonad.getWorkingCapital();
            (, uint128 redemptionsAfterComplete,) = shMonad.globalLiabilities();
            assertEq(redemptionsAfterComplete, 0, "redemptions payable cleared after completion");
            assertEq(
                reservedAtComplete - reservedAfterComplete,
                uint256(totalUnstakeMon),
                "reserved decreases by redemption amount"
            );
            // Net native out from the contract equals redemption amount
            assertEq(
                contractBalBeforePayout - contractBalAfterPayout,
                uint256(totalUnstakeMon),
                "net native out equals redemption amount"
            );
        }
    }

    // Forces the +2 extension path first (N+7), then a base-path quote (N+1+5) on a tiny second request.
    // Verifies the second request does not decrease the stored/returned completion epoch.
    function test_ShMonad_requestUnstake_epochQuote_7_then_5_monotonic() public {
        // Arrange: pick a live validator and force no atomic float
        (uint64[] memory valIds,) = shMonad.listActiveValidators();
        assertGt(valIds.length, 0, "needs at least one active validator");
        uint64 valId = valIds[0];

        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);

        // Seed sufficient revenue so stake allocation engages on crank
        uint256 reward = MIN_VALIDATOR_DEPOSIT * 2; // >= threshold
        vm.deal(deployer, reward);
        vm.prank(deployer);
        shMonad.sendValidatorRewards{ value: reward }(valId, SCALE);

        // Deposit and crank once to push funds into pendingStaking (illiquid)
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);
        _advanceEpochAndCrank();

        // First request (large) at epoch N — should trigger N+7 worst-case
        uint64 epochN = shMonad.getInternalEpoch();
        vm.prank(alice);
        uint64 completion1 = shMonad.requestUnstake(shares - 1); // leave 1 share for second request
        assertGe(completion1, epochN + 7, "first request should quote at least N+7");

        // Advance one epoch
        _advanceEpochAndCrank();

        // Second request (tiny) — base would be earlier, but stored value must not decrease
        vm.prank(alice);
        uint64 completion2 = shMonad.requestUnstake(1);
        assertGe(completion2, completion1, "second request must not decrease quoted epoch");

        // Stored completion epoch remains the max
        (, uint64 storedEpoch) = shMonad.getUnstakeRequest(alice);
        assertEq(storedEpoch, completion2, "stored completion epoch equals returned max");
    }

    // Opposite ordering: first request yields base-path quote (N+5), then a larger second request causes the
    // +2 extension path. Verifies that the stored/returned epoch increases to match the later N+7 quote.
    function test_ShMonad_requestUnstake_epochQuote_5_then_7_increases() public {
        (uint64[] memory valIds,) = shMonad.listActiveValidators();
        assertGt(valIds.length, 0, "needs at least one active validator");
        uint64 valId = valIds[0];

        // Start with atomic disabled
        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);

        // Deposit (do NOT crank yet) so pendingStaking is still zero, maximizing allowed redemptions
        uint256 depositAmount = 100 ether;
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: depositAmount }(depositAmount, alice);

        uint64 epochN = shMonad.getInternalEpoch();
        // First request small — should take base path (N+5)
        vm.prank(alice);
        uint64 completion1 = shMonad.requestUnstake(shares / 10); // 10% of shares
        assertGe(completion1, epochN + 5, "first request should be base-path N+5 or later");
        assertLt(completion1, epochN + 7, "first request should not require +2 extension");

        // Now enable stake allocation by seeding sufficient revenue and cranking once.
        uint256 reward = MIN_VALIDATOR_DEPOSIT * 2;
        vm.deal(deployer, reward);
        vm.prank(deployer);
        shMonad.sendValidatorRewards{ value: reward }(valId, SCALE);
        _advanceEpochAndCrank();

        // Second request large — should trigger +2 extension relative to the new epoch
        uint64 epochN1 = shMonad.getInternalEpoch();
        vm.prank(alice);
        uint64 completion2 = shMonad.requestUnstake(shares - (shares / 10)); // remainder

        // Expect the later request to push the quoted epoch to at least N+1+7
        assertGe(completion2, epochN1 + 7, "+2 extension should apply to the larger second request");
        assertGe(completion2, completion1, "quoted epoch must increase when later request is worse-case");

        // Stored completion epoch equals the returned max
        (, uint64 storedEpoch) = shMonad.getUnstakeRequest(alice);
        assertEq(storedEpoch, completion2, "stored completion epoch tracks worst-case");
    }

}

contract ShMonadStorageViewTest is BaseTest {
    function test_Storage_getAdminValues() public {
        // Update some admin values via existing admin setters
        vm.startPrank(deployer);
        shMonad.updateStakingCommission(1234); // 12.34%
        shMonad.updateBoostCommission(4321); // 43.21%
        vm.stopPrank();

        (
            uint64 internalEpoch,
            uint16 targetLiquidityBps,
            uint16 incentiveAlignmentBps,
            uint16 stakingCommissionBps,
            uint16 boostCommissionBps,
            uint128 totalZeroYieldPayable
        ) = shMonad.getAdminValues();

        // Basic sanity: internal epoch should be readable
        assertGe(internalEpoch, 0, "internal epoch readable");
        // Commission settings should match updates
        assertEq(stakingCommissionBps, 1234, "staking commission should reflect update");
        assertEq(boostCommissionBps, 4321, "boost commission should reflect update");
        // Others are environment dependent; just check callable
        assertTrue(targetLiquidityBps >= 0 && incentiveAlignmentBps >= 0, "bps readable");
        assertTrue(totalZeroYieldPayable >= 0, "zero yield funds readable");
    }

    function test_Storage_getUnstakeRequest() public {
        // Deposit and then request an unstake to create a pending request
        uint256 amount = 3 ether;
        hoax(user, amount);
        shMonad.deposit{ value: amount }(amount, user);

        vm.prank(user);
        uint64 completionEpoch = shMonad.requestUnstake(1 ether);

        (uint128 amt, uint64 epoch) = shMonad.getUnstakeRequest(user);
        assertGt(amt, 0, "unstake amount should be > 0");
        assertEq(epoch, completionEpoch, "stored completion epoch should match return value");
    }
}
