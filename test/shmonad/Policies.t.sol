// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ShMonad} from "../../src/shmonad/ShMonad.sol";
import {ShMonadEvents} from "../../src/shmonad/Events.sol";
import {Policies, CommittedData, TopUpData, TopUpSettings} from "../../src/shmonad/Policies.sol";
import {AddressHub} from "../../src/common/AddressHub.sol";
import {BaseTest} from "../base/BaseTest.t.sol";
import {IERC4626Custom} from "../../src/shmonad/interfaces/IERC4626Custom.sol";
import {ShMonadErrors} from "../../src/shmonad/Errors.sol";
import {Policy} from "../../src/shmonad/Types.sol";
import {UncommitApproval} from "../../src/shmonad/Types.sol";
import {MIN_TOP_UP_PERIOD_BLOCKS} from "../../src/shmonad/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import { TestShMonad } from "../base/helpers/TestShMonad.sol";

contract PoliciesTest is BaseTest, ShMonadEvents {
    address public alice;
    address public bob;
    address public charlie;
    ShMonad public shmonad;
    uint256 public constant INITIAL_BALANCE = 100 ether;
    uint48 public constant ESCROW = 10;

    function setUp() public override {
        // Setup accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        super.setUp();

        // Fund accounts
        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
        vm.deal(deployer, INITIAL_BALANCE);
        vm.deal(charlie, INITIAL_BALANCE);

        //TODO fix this
        shmonad = ShMonad(payable(address(shMonad)));

        // Seed liquidity and disable fees for deterministic previews
        vm.startPrank(deployer);
        shmonad.setPoolTargetLiquidityPercentage(SCALE - 1);
        shmonad.setUnstakeFeeCurve(0, 0);
        vm.deal(deployer, 200 ether);
        shmonad.deposit{ value: 200 ether }(200 ether, deployer);
        vm.stopPrank();

        _advanceEpochAndCrank();
    }

    function _advanceEpochAndCrank() internal {
        vm.roll(block.number + 50_000);
        staking.harnessSyscallOnEpochChange(false);
        if (!useLocalMode) {
            uint64 internalEpochBefore = shmonad.getInternalEpoch();
            for (uint256 i = 0; i < 4; i++) {
                TestShMonad(payable(address(shmonad))).harnessCrankGlobalOnly();
                if (shmonad.getInternalEpoch() > internalEpochBefore) {
                    return;
                }
            }
            revert("fork: crank did not advance internal epoch");
        }
        while (!shmonad.crank()) {}
    }

    function _sharesFromUnderlyingNoDeductCeil(uint256 assets) internal view returns (uint256 shares) {
        // agentTransferFromCommitted(..., inUnderlying=true) uses `_convertToShares(amount, Ceil, deductRecentRevenue=false)`.
        // There is no direct public wrapper for `deductRecentRevenue=false`, so replicate the math here:
        // shares = ceil(assets * totalSupply / totalEquityWithoutDeduct)
        uint256 supply = shmonad.totalSupply();
        if (supply == 0) return 0;
        uint256 equityNoDeduct = ShMonad(payable(address(shmonad))).totalAssets();
        // Note: ShMonad.totalAssets() is the "no-deduct" view (matches deductRecentRevenue=false paths).
        shares = Math.mulDiv(assets, supply, equityNoDeduct, Math.Rounding.Ceil);
    }

    // --------------------------------------------- //
    //              Basic Commit Tests               //
    // --------------------------------------------- //

    // Create a policy, add/remove agents, and disable policy. Checks events and error cases.
    function test_Policies_createAddRemoveDisablePolicy() public {
        // Create policy
        uint64 prev = shmonad.policyCount();
        uint64 expected = prev + 1;
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true, address(shmonad));
        emit CreatePolicy(expected, alice, ESCROW);
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.stopPrank();

        // Owner adds bob
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true, address(shmonad));
        emit AddPolicyAgent(policyID, bob);
        shmonad.addPolicyAgent(policyID, bob);

        // Duplicate add should revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyAgentAlreadyExists.selector, policyID, bob));
        shmonad.addPolicyAgent(policyID, bob);

        // Removing non-existent agent should revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyAgentNotFound.selector, policyID, address(0xBEEF)));
        shmonad.removePolicyAgent(policyID, address(0xBEEF));

        // Removing last agent should revert (policy initially has creator as primary + bob; remove both then one more)
        // First remove bob
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true, address(shmonad));
        emit RemovePolicyAgent(policyID, bob);
        shmonad.removePolicyAgent(policyID, bob);

        // Attempt to remove the last remaining agent (primary) should revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyNeedsAtLeastOneAgent.selector, policyID));
        shmonad.removePolicyAgent(policyID, alice);

        // Disable policy by primary agent
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(shmonad));
        emit DisablePolicy(policyID);
        shmonad.disablePolicy(policyID);

        // Disabled policies reject commits
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyInactive.selector, policyID));
        shmonad.commit(policyID, alice, 0);
        vm.stopPrank();
    }

    function test_Policies_removePolicyAgent_resetsPrimary() public {
        vm.startPrank(alice);
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.stopPrank();

        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, bob);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, charlie);

        Policy memory beforeRemoval = shmonad.getPolicy(policyID);
        assertEq(beforeRemoval.primaryAgent, alice, "Creator should be primary agent before removal");

        vm.prank(deployer);
        shmonad.removePolicyAgent(policyID, alice);

        Policy memory afterRemoval = shmonad.getPolicy(policyID);
        address[] memory agents = shmonad.getPolicyAgents(policyID);
        assertEq(agents.length, 2, "Two agents should remain");
        assertFalse(shmonad.isPolicyAgent(policyID, alice), "Alice should no longer be an agent");
        assertTrue(shmonad.isPolicyAgent(policyID, bob), "Bob should remain an agent");
        assertTrue(shmonad.isPolicyAgent(policyID, charlie), "Charlie should remain an agent");
        assertEq(afterRemoval.primaryAgent, agents[0], "Primary agent should roll over to first remaining agent");
    }

    // Request uncommit should revert if held amount leaves insufficient unheld committed
    function test_Policies_requestUncommit_insufficientUnheld_reverts() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 amount = 5 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: amount }(policyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        vm.stopPrank();

        // Place hold equal to committed (creator is primary agent)
        shmonad.hold(policyID, alice, committed);

        // Alice cannot uncommit if committed - held < requested
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShMonadErrors.InsufficientUnheldCommittedBalance.selector,
                uint128(committed), uint128(committed), uint128(committed)
            )
        );
        shmonad.requestUncommit(policyID, committed, 0);
    }

    // Complete uncommit before escrow period should revert with precise block
    function test_Policies_completeUncommit_beforeEscrow_reverts() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 amount = 3 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: amount }(policyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        shmonad.requestUncommit(policyID, committed, 0);
        vm.stopPrank();

        Policy memory p = shmonad.getPolicy(policyID);
        uint256 expectedBlock = block.number + p.escrowDuration;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.UncommittingPeriodIncomplete.selector, expectedBlock)
        );
        shmonad.completeUncommit(policyID, committed);
    }

    function test_Policies_commit_ZeroAddress_reverts() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 amount = 10 ether;

        vm.startPrank(alice);
        shmonad.deposit{value: amount}(amount, alice);

        vm.expectRevert(ShMonadErrors.CommitRecipientCannotBeZeroAddress.selector);
        shmonad.commit(policyID, address(0), amount);
        vm.stopPrank();
    }

    function test_Policies_commit() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 amount = 10 ether;

        vm.startPrank(alice);
        uint256 shares = shmonad.deposit{value: amount}(amount, alice);
        uint256 committedSupplyBefore = shmonad.committedTotalSupply();
        uint256 totalSupplyBefore = shmonad.totalSupply();

        vm.expectEmit(true, true, true, true);
        emit Commit(policyID, bob, shares);
        shmonad.commit(policyID, bob, shares);

        // Check balances
        assertEq(shmonad.balanceOfCommitted(policyID, bob), shares, "Bob's committed balance should equal shares");
        assertEq(shmonad.balanceOfCommitted(policyID, alice), 0, "Alice's committed balance should be 0");

        assertEq(shmonad.totalSupply(), totalSupplyBefore, "Total supply should remain unchanged");
        assertEq(shmonad.committedTotalSupply(), committedSupplyBefore + shares, "Committed total supply should increase by shares");

        vm.stopPrank();
    }

    function test_Policies_depositAndCommit_ZeroAddress_reverts() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 amount = 5 ether;

        vm.startPrank(alice);
        vm.expectRevert(ShMonadErrors.CommitRecipientCannotBeZeroAddress.selector);
        shmonad.depositAndCommit{value: amount}(policyID, address(0), type(uint256).max);
        vm.stopPrank();
    }

    function test_Policies_depositAndCommit() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 amountToCommit = 5 ether;
        uint256 committedSupplyBefore = shmonad.committedTotalSupply();

        // Preview the shares that will be minted
        uint256 expectedShares = shmonad.previewDeposit(amountToCommit);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Commit(policyID, alice, expectedShares);
        uint256 sharesMinted = shmonad.depositAndCommit{value: amountToCommit}(policyID, alice, type(uint256).max);

        // Get actual committed amount
        uint256 committedAmount = shmonad.balanceOfCommitted(policyID, alice);

        // Check return value and balances
        assertEq(sharesMinted, expectedShares, "sharesMinted should equal previewed shares");
        assertEq(committedAmount, expectedShares, "Alice's committed balance should equal expected shares");
        assertEq(alice.balance, INITIAL_BALANCE - amountToCommit, "Alice's ETH balance should decrease by deposit amount");

        assertEq(shmonad.totalSupply(), committedAmount + shmonad.totalSupply() - committedAmount, "Total supply calculation should be correct");
        assertEq(shmonad.committedTotalSupply(), committedSupplyBefore + committedAmount, "Committed total supply should increase by committed amount");

        vm.stopPrank();
    }

    function test_Policies_depositAndCommit_PartialCommit() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 depositAmount = 6 ether;
        vm.deal(alice, INITIAL_BALANCE + depositAmount);
        uint256 mintedPreview = shmonad.previewDeposit(depositAmount);
        uint256 partialShares = mintedPreview / 2;
        uint256 committedSupplyBefore = shmonad.committedTotalSupply();

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Commit(policyID, alice, partialShares);
        uint256 sharesMinted = shmonad.depositAndCommit{ value: depositAmount }(policyID, alice, partialShares);
        vm.stopPrank();

        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        uint256 uncommitted = shmonad.balanceOf(alice);

        assertEq(sharesMinted, mintedPreview, "sharesMinted should equal previewed shares");
        assertEq(committed, partialShares, "Committed should equal partial shares");
        assertEq(uncommitted, mintedPreview - partialShares, "Uncommitted should keep remainder");
        assertEq(
            shmonad.committedTotalSupply(),
            committedSupplyBefore + partialShares,
            "Committed supply should increase by partial amount"
        );
    }

    function test_Policies_depositAndCommit_InsufficientUncommitted_reverts() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 depositAmount = 4 ether;
        vm.deal(alice, INITIAL_BALANCE + depositAmount);
        uint256 mintedPreview = shmonad.previewDeposit(depositAmount);
        uint256 overCommit = mintedPreview + 1;

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShMonadErrors.InsufficientUncommittedBalance.selector, mintedPreview, overCommit
            )
        );
        shmonad.depositAndCommit{ value: depositAmount }(policyID, alice, overCommit);
        vm.stopPrank();
    }

    function test_Policies_requestUncommit() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 amount = 5 ether;
        uint256 newMinBalance = 1 ether;

        vm.startPrank(alice);
        // Deposit and commit with max amount
        shmonad.depositAndCommit{value: amount}(policyID, alice, type(uint256).max);
        uint256 committedAmount = shmonad.balanceOfCommitted(policyID, alice);
        uint256 committedSupplyBefore = shmonad.committedTotalSupply();
        uint256 totalSupplyBefore = shmonad.totalSupply();
        
        vm.expectEmit(true, true, true, true);
        emit RequestUncommit(policyID, alice, committedAmount, block.number + 10);
        shmonad.requestUncommit(policyID, committedAmount, newMinBalance);
        vm.stopPrank();

        // Check balances
        assertEq(shmonad.balanceOfCommitted(policyID, alice), 0, "Alice's committed balance should be 0 after uncommitting");
        assertEq(alice.balance, INITIAL_BALANCE - amount, "Alice's ETH balance should remain unchanged");
        assertEq(shmonad.balanceOfUncommitting(policyID, alice), committedAmount, "Alice's uncommitting balance should equal committed amount");
        // Check uncommitting data
        assertEq(shmonad.uncommittingCompleteBlock(policyID, alice), block.number + 10, "Uncommitting should complete in 10 blocks");

        assertEq(shmonad.totalSupply(), totalSupplyBefore, "Total supply should remain unchanged");
        assertEq(shmonad.committedTotalSupply(), committedSupplyBefore - committedAmount, "Committed total supply should decrease by committed amount");
    }

    function test_Policies_requestUncommit_updatesMinCommittedOnly() public {
        vm.prank(alice);
        uint64 policyID = shmonad.createPolicy(10);

        uint256 depositAmount = 80 ether;
        vm.prank(alice);
        uint256 mintedShares = shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        uint256 committedShares = mintedShares / 2;
        vm.prank(alice);
        shmonad.commit(policyID, alice, committedShares);

        uint256 uncommittedShares = mintedShares - committedShares;
        uint128 initialMinCommitted = uint128(committedShares / 2);
        uint128 initialMaxTopUp = uint128(uncommittedShares);
        vm.prank(alice);
        shmonad.setMinCommittedBalance(policyID, initialMinCommitted, initialMaxTopUp, uint32(MIN_TOP_UP_PERIOD_BLOCKS));

        uint256 availableBefore = shmonad.topUpAvailable(policyID, alice, false);
        assertEq(availableBefore, initialMaxTopUp, "precondition: top-up allowance should equal max setting");

        uint128 sharesToUncommit = uint128(committedShares / 4);
        uint128 newMinCommitted = 5 ether;
        vm.prank(alice);
        shmonad.requestUncommit(policyID, sharesToUncommit, newMinCommitted);

        uint256 availableAfter = shmonad.topUpAvailable(policyID, alice, false);
        assertEq(
            availableAfter,
            initialMaxTopUp,
            "top-up allowance should remain unchanged when only minCommitted updates"
        );
    }

    function test_Policies_completeUncommit() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 amount = 5 ether;

        vm.startPrank(alice);
        shmonad.depositAndCommit{value: amount}(policyID, alice, type(uint256).max);
        uint256 committedAmount = shmonad.balanceOfCommitted(policyID, alice);
        // Capture system-wide committed total supply before uncommitting
        uint256 committedTotalSupplyBefore = shmonad.committedTotalSupply();
        shmonad.requestUncommit(policyID, committedAmount, 0);
        uint256 totalSupplyBefore = shmonad.totalSupply();
        vm.roll(block.number + 11); // Fast forward to after uncommitting period

        uint256 uncommittingAmount = shmonad.balanceOfUncommitting(policyID, alice);
        
        vm.expectEmit(true, true, true, true);
        emit CompleteUncommit(policyID, alice, uncommittingAmount);

        shmonad.completeUncommit(policyID, uncommittingAmount);

        // Check balances
        assertEq(shmonad.balanceOfUncommitting(policyID, alice), 0, "Uncommitting balance should be 0");
        assertEq(shmonad.balanceOfCommitted(alice), 0, "Committed balance should be 0");
        assertEq(shmonad.balanceOf(alice), uncommittingAmount, "Balance of should be uncommitting amount");
        assertEq(alice.balance, INITIAL_BALANCE - amount, "Alice's balance should be INITIAL_BALANCE - amount");

        assertEq(shmonad.totalSupply(), totalSupplyBefore, "Total supply should remain unchanged");
        
        // We can't check for exactly 0 since the system may have other commits
        // Check that Alice's commits were removed from the total
        assertEq(shmonad.committedTotalSupply(), committedTotalSupplyBefore - committedAmount, "Committed total supply should decrease by Alice's committed amount");
        
        vm.stopPrank();
    }

    function test_Policies_completeUncommit_InsufficientUncommittingBalance_reverts() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 amount = 4 ether;

        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: amount }(policyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        shmonad.requestUncommit(policyID, committed, 0);
        vm.stopPrank();

        vm.roll(block.number + ESCROW + 1);

        uint256 uncommitting = shmonad.balanceOfUncommitting(policyID, alice);
        vm.prank(alice);
        shmonad.completeUncommit(policyID, uncommitting);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.InsufficientUncommittingBalance.selector, uint256(0), uint256(1))
        );
        shmonad.completeUncommit(policyID, 1);
    }

    function test_Policies_completeUncommitAndRedeem() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 amount = 5 ether;
        
        // Give Alice plenty of ETH to ensure we don't run into dust issues
        vm.deal(alice, INITIAL_BALANCE + amount);
        uint256 aliceInitialBalance = alice.balance;
        uint256 aliceInitialRegularBalance = shmonad.balanceOf(alice);
        
        vm.startPrank(alice);
                
        shmonad.depositAndCommit{value: amount}(policyID, alice, type(uint256).max);
        uint256 committedAmount = shmonad.balanceOfCommitted(policyID, alice);
        shmonad.requestUncommit(policyID, committedAmount, 0);
        vm.roll(block.number + 11); // Fast forward to after requestUncommiting period

        _advanceEpochAndCrank();

        uint256 requestUncommitingAmount = shmonad.balanceOfUncommitting(policyID, alice);
        uint256 totalSupplyBefore = shmonad.totalSupply();

        // Preview the ETH amount that will be withdrawn
        vm.expectEmit(true, true, true, true);
        emit CompleteUncommit(policyID, alice, requestUncommitingAmount);
        uint256 assets = shmonad.completeUncommitAndRedeem(policyID, requestUncommitingAmount);

        // Check balances
        assertEq(shmonad.balanceOfUncommitting(policyID, alice), 0, "Unbonding balance should be 0");
        assertEq(shmonad.balanceOfCommitted(alice), 0, "Bonded balance should be 0");
        //TODO: This is not true, because of the gas fees
        assertEq(shmonad.balanceOf(alice), aliceInitialRegularBalance, "Regular balance should be aliceInitialRegularBalance");
        // Check ETH balance with a tolerance to account for gas fees
        assertApproxEqAbs(
            alice.balance,
            aliceInitialBalance,
            0.01 ether,
            "Alice's ETH balance should be approximately restored to initial balance"
        );
        // Total supply should decrease by the ETH amount that was withdrawn
        assertEq(shmonad.totalSupply() + requestUncommitingAmount, totalSupplyBefore, "Total supply should decrease by requestUncommiting shares amount");
        
        vm.stopPrank();
    }

    function test_Policies_completeUncommitAndRecommit() public {
        uint64 fromPolicyID = shmonad.createPolicy(10);
        uint64 toPolicyID = shmonad.createPolicy(10);
        uint256 amount = 5 ether;

        vm.startPrank(alice);
        shmonad.depositAndCommit{value: amount}(fromPolicyID, alice, type(uint256).max);
        uint256 committedAmount = shmonad.balanceOfCommitted(fromPolicyID, alice);
        shmonad.requestUncommit(fromPolicyID, committedAmount, 0);
        vm.roll(block.number + 11); // Fast forward to after requestUncommiting period

        uint256 requestUncommitingAmount = shmonad.balanceOfUncommitting(fromPolicyID, alice);
        uint256 totalSupplyBefore = shmonad.totalSupply();
        uint256 bondedSupplyBefore = shmonad.committedTotalSupply();
        
        vm.expectEmit(true, true, true, true);
        emit CompleteUncommit(fromPolicyID, alice, requestUncommitingAmount);
        emit Commit(toPolicyID, alice, requestUncommitingAmount);
        shmonad.completeUncommitAndRecommit(fromPolicyID, toPolicyID, alice, requestUncommitingAmount);

        // Check balances
        assertEq(alice.balance, INITIAL_BALANCE - amount, "Alice's ETH balance should remain unchanged");
        assertEq(shmonad.balanceOf(alice), 0, "Alice's regular balance should be 0");
        
        assertEq(shmonad.balanceOfCommitted(fromPolicyID, alice), 0, "Alice's bonded balance in fromPolicy should be 0");
        assertEq(shmonad.balanceOfUncommitting(fromPolicyID, alice), 0, "Alice's requestUncommiting balance in fromPolicy should be 0");

        assertEq(shmonad.balanceOfCommitted(toPolicyID, alice), requestUncommitingAmount, "Alice's bonded balance in toPolicy should equal requestUncommiting amount");
        assertEq(shmonad.balanceOfUncommitting(toPolicyID, alice), 0, "Alice's requestUncommiting balance in toPolicy should be 0");

        assertEq(shmonad.totalSupply(), totalSupplyBefore, "Total supply should remain unchanged");
        assertEq(shmonad.committedTotalSupply(), bondedSupplyBefore + requestUncommitingAmount, "Bonded total supply should increase by requestUncommiting amount");

        vm.stopPrank();
    }

    function test_Policies_completeUncommitAndRecommit_InactiveDestination_reverts() public {
        vm.startPrank(alice);
        uint64 fromPolicyID = shmonad.createPolicy(ESCROW);
        uint64 toPolicyID = shmonad.createPolicy(ESCROW);
        shmonad.disablePolicy(toPolicyID);

        uint256 amount = 3 ether;
        shmonad.depositAndCommit{ value: amount }(fromPolicyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(fromPolicyID, alice);
        shmonad.requestUncommit(fromPolicyID, committed, 0);
        vm.stopPrank();

        vm.roll(block.number + ESCROW + 1);

        uint256 uncommitting = shmonad.balanceOfUncommitting(fromPolicyID, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyInactive.selector, toPolicyID));
        shmonad.completeUncommitAndRecommit(fromPolicyID, toPolicyID, alice, uncommitting);
    }

    // --------------------------------------------- //
    //               View Function Tests             //
    // --------------------------------------------- //
    function test_Policies_policyAccountGetters() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        // Deposit and commit all to set committed
        uint256 amount = 4 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: amount }(policyID, alice, type(uint256).max);
        vm.stopPrank();

        // Set min committed + top-up settings
        uint128 minCommitted = 1 ether;
        uint128 maxTopUp = 2 ether;
        uint32 period = MIN_TOP_UP_PERIOD_BLOCKS;
        vm.prank(alice);
        shmonad.setMinCommittedBalance(policyID, minCommitted, maxTopUp, period);

        // Set uncommit approval (open completor)
        vm.prank(alice);
        shmonad.setUncommitApproval(policyID, address(0), 5 ether);

        // Start an uncommit to populate uncommitting + start block
        vm.prank(alice);
        shmonad.requestUncommit(policyID, 1 ether, minCommitted);

        // Validate granular getters
        (uint128 committed, uint128 minSet) = shmonad.getCommittedData(policyID, alice);
        assertEq(minSet, minCommitted, "minCommitted should match");
        assertGt(committed, 0, "committed should be > 0");

        (uint128 uncommitting, uint48 startBlock) = shmonad.getUncommittingData(policyID, alice);
        assertGt(startBlock, 0, "uncommitStartBlock should be set");
        assertGt(uncommitting, 0, "uncommitting should be > 0");

        (uint128 maxTopUpPerPeriod, uint32 topUpPeriodDuration) = shmonad.getTopUpSettings(policyID, alice);
        assertEq(maxTopUpPerPeriod, maxTopUp, "maxTopUpPerPeriod should match");
        assertEq(topUpPeriodDuration, period, "topUpPeriodDuration should match");
    }

    // --------------------------------------------- //
    //            Event Pair (expectEmit)             //
    // --------------------------------------------- //

    // Standard Transfer event from IERC20
    event Transfer(address indexed from, address indexed to, uint256 value);
    // Standard Deposit event from IERC4626
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    function test_Policies_commit_recipientIsCaller_emitsCommitAndTransferEvents() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 amount = 3 ether;
        vm.startPrank(alice);
        uint256 shares = shmonad.deposit{ value: amount }(amount, alice);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Commit(policyID, alice, shares);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Transfer(alice, address(shmonad), shares);
        shmonad.commit(policyID, alice, shares);
        vm.stopPrank();
    }

    function test_Policies_commit_recipientIsNotCaller_emitsCommitAndTransferEvents() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 amount = 2 ether;
        vm.startPrank(alice);
        uint256 shares = shmonad.deposit{ value: amount }(amount, alice);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Commit(policyID, bob, shares);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Transfer(alice, address(shmonad), shares);
        shmonad.commit(policyID, bob, shares);
        vm.stopPrank();
    }

    function test_Policies_depositAndCommit_emitsCommitAndTransferEvents() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 depositAmount = 4 ether;
        uint256 expectedShares = shmonad.previewDeposit(depositAmount);
        vm.startPrank(alice);
        // ERC20 mint during deposit
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Transfer(address(0), alice, expectedShares);
        // ERC4626 Deposit
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Deposit(alice, alice, depositAmount, expectedShares);
        // Then Commit and Transfer(user->ShMonad)
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Commit(policyID, alice, expectedShares);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Transfer(alice, address(shmonad), expectedShares);
        shmonad.depositAndCommit{ value: depositAmount }(policyID, alice, type(uint256).max);
        vm.stopPrank();
    }

    function test_Policies_topUp_emitsCommitAndTransferEvents() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);
        // Alice balances
        uint256 c0 = 1 ether; // initial committed
        uint256 u0 = 10 ether; // uncommitted
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: c0 }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: u0 }(u0, alice);
        // Enable top-up
        uint128 minC = uint128(3 ether);
        shmonad.setMinCommittedBalance(policyID, minC, type(uint128).max, uint32(MIN_TOP_UP_PERIOD_BLOCKS));
        vm.stopPrank();
        // Spend to force top-up. Calculate the exact shortfall in shares to avoid conversion rounding errors.
        uint256 spend = 2 ether;
        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        assertGt(spend, committedBefore, "precondition: spend must exceed committed balance");
        uint256 shortfallShares = spend - committedBefore;
        uint256 expectedCommitted = shortfallShares + uint256(minC);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Commit(policyID, alice, expectedCommitted);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Transfer(alice, address(shmonad), expectedCommitted);
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spend, 0, false);
    }

    function test_Policies_completeUncommit_emitsCompleteUncommitAndTransferEvents() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 amount = 3 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: amount }(policyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        shmonad.requestUncommit(policyID, committed, 0);
        vm.roll(block.number + ESCROW + 1);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit CompleteUncommit(policyID, alice, committed);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Transfer(address(shmonad), alice, committed);
        shmonad.completeUncommit(policyID, committed);
        vm.stopPrank();
    }

    function test_Policies_completeUncommitWithApproval_emitsCompleteUncommitAndTransferEvents() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 amount = 2 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: amount }(policyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        shmonad.requestUncommitWithApprovedCompletor(policyID, committed, 0, bob);
        vm.stopPrank();
        vm.roll(block.number + ESCROW + 1);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit CompleteUncommit(policyID, alice, committed);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Transfer(address(shmonad), alice, committed);
        vm.prank(bob);
        shmonad.completeUncommitWithApproval(policyID, committed, alice);
    }

    function test_Policies_completeUncommitAndRedeem_emitsCompleteUncommitAndTransferEvents() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 amount = 2 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: amount }(policyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        shmonad.requestUncommit(policyID, committed, 0);
        vm.roll(block.number + ESCROW + 1);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit CompleteUncommit(policyID, alice, committed);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Transfer(address(shmonad), alice, committed);
        shmonad.completeUncommitAndRedeem(policyID, committed);
        vm.stopPrank();
    }

    // --------------------------------------------- //
    //                  Fuzz Tests                   //
    // --------------------------------------------- //

    function testFuzz_Policies_commit_self_and_cross(uint256 amount) public {
        amount = bound(amount, 1 ether, 20 ether);
        uint64 policyID = shmonad.createPolicy(10);
        vm.deal(alice, amount);

        // Self-commit path
        vm.startPrank(alice);
        uint256 minted = shmonad.deposit{ value: amount }(amount, alice);
        uint256 committedBefore = shmonad.committedTotalSupply();
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Commit(policyID, alice, minted);
        shmonad.commit(policyID, alice, minted);
        vm.stopPrank();

        assertEq(shmonad.balanceOfCommitted(policyID, alice), minted);
        assertEq(shmonad.committedTotalSupply(), committedBefore + minted);

        // Cross-account commit path
        vm.deal(bob, amount);
        vm.startPrank(bob);
        uint256 mintedBob = shmonad.deposit{ value: amount }(amount, bob);
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit Commit(policyID, alice, mintedBob);
        shmonad.commit(policyID, alice, mintedBob);
        vm.stopPrank();

        assertEq(shmonad.balanceOfCommitted(policyID, alice), minted + mintedBob);
    }

    function testFuzz_Policies_openInfiniteApproval_andComplete(uint256 amount) public {
        amount = bound(amount, 1 ether, 10 ether);
        uint64 policyID = shmonad.createPolicy(10);
        vm.deal(alice, amount);

        // Alice deposits and commits, then sets open infinite approval
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: amount }(policyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        // Set infinite open approval (avoid brittle event matching under fuzz)
        shmonad.setUncommitApproval(policyID, address(0), type(uint96).max);
        shmonad.requestUncommit(policyID, committed, 0);
        vm.stopPrank();

        // Advance beyond escrow period (escrowDuration = 10; strict > check requires +11)
        vm.roll(block.number + 11);

        // Anyone can complete; infinite allowance should not decrement
        uint256 before = shmonad.balanceOfUncommitting(policyID, alice);
        vm.prank(bob);
        shmonad.completeUncommitWithApproval(policyID, before, alice);

        UncommitApproval memory appr = shmonad.getUncommitApproval(policyID, alice);
        assertEq(appr.completor, address(0));
        assertEq(uint256(appr.shares), uint256(type(uint96).max));
    }

    function test_Policies_agentWithdrawFromCommitted() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 commitAmount = 10 ether;
        uint256 withdrawAmount = 3 ether;
        
        // First bond some amount as alice
        vm.startPrank(alice);
        shmonad.depositAndCommit{value: commitAmount}(policyID, alice, type(uint256).max);
        uint256 committedAmount = shmonad.balanceOfCommitted(policyID, alice);
        vm.stopPrank();

        // Deployer makes himself a policy agent
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        _advanceEpochAndCrank();

        // Calculate the share amount required to withdraw the requested assets
        uint256 expectedShares = shmonad.previewWithdraw(withdrawAmount);

        // Agent (deployer) withdraws from alice's bonded balance
        uint256 deployerBalanceBefore = deployer.balance;
        vm.startPrank(deployer);
        vm.expectEmit(true, true, true, true);
        emit AgentWithdrawFromCommitted(policyID, alice, deployer, withdrawAmount);
        shmonad.agentWithdrawFromCommitted(policyID, alice, deployer, withdrawAmount, 0, true);

        uint256 deployerBalanceAfter = deployer.balance;

        // Check balances
        assertEq(
            shmonad.balanceOfCommitted(policyID, alice),
            committedAmount - expectedShares,
            "Alice's bonded balance should decrease by burned shares"
        );
        assertEq(
            shmonad.balanceOfCommitted(alice),
            committedAmount - expectedShares,
            "Alice's total bonded balance should decrease by burned shares"
        );
        assertEq(
            deployerBalanceAfter - deployerBalanceBefore,
            withdrawAmount,
            "Deployer's ETH balance should increase by withdraw amount"
        );

        vm.stopPrank();
    }

    function test_Policies_agentTransferFromCommitted() public {
        uint64 policyID = shmonad.createPolicy(10);
        uint256 depositAmount = 10 ether;
        uint256 transferAmount = 3 ether;
        
        // First bond some amount as alice
        vm.startPrank(alice);
        shmonad.depositAndCommit{value: depositAmount}(policyID, alice, type(uint256).max);
        uint256 committedAmount = shmonad.balanceOfCommitted(policyID, alice);
        uint256 expectedTotalSupply = shmonad.committedTotalSupply();
        vm.stopPrank();

        // Deployer makes himself a policy agent
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        _advanceEpochAndCrank();

        // Calculate the actual transfer amount before the transfer (shares)
        uint256 expectedShares = _sharesFromUnderlyingNoDeductCeil(transferAmount);
        uint256 deployerBondedBalanceBefore = shmonad.balanceOfCommitted(deployer);

        // Agent (deployer) transfers from alice's bonded balance
        vm.startPrank(deployer);
        vm.expectEmit(true, true, true, true);
        emit AgentTransferFromCommitted(policyID, alice, deployer, expectedShares);
        shmonad.agentTransferFromCommitted(policyID, alice, deployer, transferAmount, 0, true);

        // Check balances
        assertEq(shmonad.balanceOfCommitted(policyID, alice), committedAmount - expectedShares, "Alice's bonded balance should decrease by burned shares");
        assertEq(shmonad.balanceOfCommitted(policyID, deployer), expectedShares, "Deployer's bonded balance should increase by burned shares");
        assertEq(shmonad.balanceOfCommitted(deployer), deployerBondedBalanceBefore + expectedShares, "Deployer's total bonded balance should increase by burned shares");
        assertEq(shmonad.committedTotalSupply(), expectedTotalSupply, "Bonded total supply should be the same"); // Total bonded supply remains the same

        vm.stopPrank();
    }

    function test_Policies_agentTransferToUncommitted_InsufficientFunds_reverts() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        uint256 depositAmount = 3 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: depositAmount }(policyID, alice, type(uint256).max);
        uint256 committedInitial = shmonad.balanceOfCommitted(policyID, alice);
        uint256 uncommitRequest = committedInitial / 2;
        shmonad.requestUncommit(policyID, uncommitRequest, 0);
        vm.stopPrank();

        uint256 committedAfterRequest = shmonad.balanceOfCommitted(policyID, alice);
        uint256 uncommitting = shmonad.balanceOfUncommitting(policyID, alice);
        shmonad.hold(policyID, alice, committedAfterRequest);

        uint256 requestedSpend = committedAfterRequest + uncommitting + 1;
        uint256 takenFromUncommitting = uncommitting < requestedSpend ? uncommitting : requestedSpend;
        uint128 expectedCommitted = uint128(committedAfterRequest + takenFromUncommitting);
        uint128 expectedUncommitting = uint128(uncommitting - takenFromUncommitting);
        uint128 expectedHeld = uint128(committedAfterRequest);
        uint128 requestedShares = uint128(requestedSpend);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShMonadErrors.InsufficientFunds.selector,
                expectedCommitted,
                expectedUncommitting,
                expectedHeld,
                requestedShares
            )
        );
        shmonad.agentTransferToUncommitted(policyID, alice, bob, requestedSpend, 0, false);
    }

    function test_Policies_agentTransferToUncommitted_maxMinCommitted_doesNotOverflow() public {
        vm.prank(deployer);
        uint64 policyID = shmonad.createPolicy(ESCROW);

        uint256 depositAmount = 2 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: depositAmount }(policyID, alice, type(uint256).max);
        shmonad.setMinCommittedBalance(policyID, type(uint128).max, 0, 0);
        vm.stopPrank();

        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        uint256 spendShares = 1;
        assertGt(committedBefore, spendShares, "precondition: committed > spend");

        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendShares, 0, false);

        assertEq(
            shmonad.balanceOfCommitted(policyID, alice),
            committedBefore - spendShares,
            "committed balance should decrease"
        );
        assertEq(shmonad.balanceOf(bob), spendShares, "recipient uncommitted should increase");
    }

    // --------------------------------------------- //
    //                 Top-Up Tests                  //
    // --------------------------------------------- //

    function _setTopUp(address account, uint64 policyID, uint128 minCommitted, uint128 maxTopUp, uint32 periodBlocks)
        internal
    {
        vm.prank(account);
        shmonad.setMinCommittedBalance(policyID, minCommitted, maxTopUp, periodBlocks);
    }

    // When there is insufficient uncommitted balance to cover the shortfall (and cap allows it),
    // _tryTopUp returns early with 0 and the overall spend reverts with InsufficientFunds.
    // Expected: revert InsufficientFunds with committed, uncommitting, held, and requested shares values.
    function test_TopUp_insufficientUncommitted_earlyReturn_reverts() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        // Make deployer an agent to perform spends
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Alice: small committed, no extra uncommitted; enable top-up with large cap so only uncommitted shortage matters
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 1 ether }(policyID, alice, type(uint256).max);
        shmonad.setMinCommittedBalance(policyID, uint128(1 ether), type(uint128).max, uint32(MIN_TOP_UP_PERIOD_BLOCKS));
        vm.stopPrank();

        // Force fundsAvailable = 0 by putting a hold on full committed balance
        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        vm.prank(deployer);
        shmonad.hold(policyID, alice, committedBefore);

        // Attempt to spend > 0 shares with zero uncommitted available for top-up -> early return from _tryTopUp and revert
        uint256 spendShares = 1 ether;
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShMonadErrors.InsufficientFunds.selector,
                uint128(committedBefore), // committed (policy-specific) at time of check
                uint128(0),               // uncommitting
                uint128(committedBefore), // held amount
                uint128(spendShares)      // requested shares
            )
        );
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendShares, 0, false);
    }

    // If cap is sufficient for the shortfall but not enough for (shortfall + minCommitted),
    // _tryTopUp falls back to committing just the shortfall. Expected: committedAfter = 0 (all spent),
    // Alice's uncommitted decreases by the shortfall only, and Bob receives the full spend amount to uncommitted.
    function test_TopUp_capPreventsMin_fallbacksToShortfallOnly() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        // Agent setup
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Alice: some committed and ample uncommitted
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 2 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 10 ether }(10 ether, alice);
        vm.stopPrank();

        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        uint256 aliceUncommittedBefore = shmonad.balanceOf(alice);
        uint256 bobUncommittedBefore = shmonad.balanceOf(bob);

        // Set minCommitted > 0, but cap = shortfall only. This forces fallback to shortfall-only behavior.
        uint256 deltaShortfall = 1 ether;
        uint128 cap = uint128(deltaShortfall);
        uint128 minC = uint128(5 ether);
        _setTopUp(alice, policyID, minC, cap, uint32(MIN_TOP_UP_PERIOD_BLOCKS));

        // Spend = committedBefore + shortfall -> sharesRequested = shortfall
        uint256 spendShares = committedBefore + deltaShortfall;

        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendShares, 0, false);

        uint256 committedAfter = shmonad.balanceOfCommitted(policyID, alice);
        uint256 aliceUncommittedAfter = shmonad.balanceOf(alice);
        uint256 bobUncommittedAfter = shmonad.balanceOf(bob);

        // Only the shortfall was topped-up; all spend shares leave committed -> final committed is zero
        assertEq(committedAfter, 0, "committed should be fully spent after shortfall-only top-up");
        assertEq(
            aliceUncommittedBefore - aliceUncommittedAfter,
            deltaShortfall,
            "alice uncommitted should decrease by shortfall only"
        );
        assertEq(
            bobUncommittedAfter - bobUncommittedBefore,
            spendShares,
            "bob uncommitted should increase by spend amount"
        );
    }

    // Top-up should also apply for agentTransferFromCommitted (Committed -> Committed delivery path).
    // Expected: committedTotalSupply increases by the top-up amount, Alice's uncommitted decreases by the same amount,
    // and Bob's committed increases by the transfer shares.
    function test_TopUp_appliesForAgentTransferFromCommitted() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        // Agent setup
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Alice: small committed and ample uncommitted; enable top-up with minCommitted = 0 (top-up equals shortfall)
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 1 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 5 ether }(5 ether, alice);
        shmonad.setMinCommittedBalance(policyID, 0, type(uint128).max, uint32(MIN_TOP_UP_PERIOD_BLOCKS));
        vm.stopPrank();

        // Force fundsAvailable = 0 via hold so all transfer must be covered by top-up
        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        vm.prank(deployer);
        shmonad.hold(policyID, alice, committedBefore);

        // Transfer more than available (here, fundsAvailable=0), so sharesRequested == spendShares
        uint256 spendShares = 2 ether;
        uint256 supplyBefore = shmonad.committedTotalSupply();
        uint256 aliceUncommittedBefore = shmonad.balanceOf(alice);
        uint256 bobCommittedBefore = shmonad.balanceOfCommitted(policyID, bob);

        vm.prank(deployer);
        shmonad.agentTransferFromCommitted(policyID, alice, bob, spendShares, 0, false);

        uint256 supplyAfter = shmonad.committedTotalSupply();
        uint256 aliceUncommittedAfter = shmonad.balanceOf(alice);
        uint256 bobCommittedAfter = shmonad.balanceOfCommitted(policyID, bob);

        // With minCommitted = 0, top-up equals shortfall = spendShares
        assertEq(supplyAfter - supplyBefore, spendShares, "committedTotalSupply should increase by top-up amount");
        assertEq(aliceUncommittedBefore - aliceUncommittedAfter, spendShares, "alice uncommitted decreases by top-up");
        assertEq(bobCommittedAfter - bobCommittedBefore, spendShares, "bob committed increases by transfer shares");
    }

    // maxTopUpPerPeriod is enforced for both:
    // - the first top-up of a period (after reset)
    // - the second top-up within the same period (sum exceeding the cap)
    // Expected:
    // 1) Attempt > cap on first top-up -> revert InsufficientFunds (top-up returns 0).
    // 2) Top-up up to cap succeeds.
    // 3) Second top-up in same period exceeding remaining cap -> revert.
    // 4) After period reset, a top-up within cap succeeds again.
    function test_TopUp_capEnforced_onFirstAndSecondInPeriod() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Alice: no effective fundsAvailable; large uncommitted to allow top-up when permitted by cap
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 1 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 10 ether }(10 ether, alice);
        vm.stopPrank();

        // Cap of 2 shares per period
        uint128 cap = uint128(2 ether);
        _setTopUp(alice, policyID, 0, cap, uint32(MIN_TOP_UP_PERIOD_BLOCKS));

        // Force fundsAvailable = 0 to ensure spending requires top-up
        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        vm.prank(deployer);
        shmonad.hold(policyID, alice, committedBefore);

        // 1) First top-up attempt exceeding cap should revert (no partial top-up)
        uint256 spendOverCap = uint256(cap) + 1 ether;
        vm.prank(deployer);
        vm.expectRevert();
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendOverCap, 0, false);

        // 2) Top-up exactly up to cap succeeds
        uint256 spendAtCap = cap;
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendAtCap, 0, false);

        // 3) Second top-up within same period exceeding remaining cap should revert
        vm.prank(deployer);
        vm.expectRevert();
        shmonad.agentTransferToUncommitted(policyID, alice, bob, 1 ether, 0, false);

        // 4) After period reset, a within-cap top-up succeeds again
        vm.roll(block.number + MIN_TOP_UP_PERIOD_BLOCKS + 1);
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, 1 ether, 0, false);
    }

    // Top-up covers shortfall and targets minCommitted when capacity allows
    function test_TopUp_basicCoversShortfall_targetsMin() public {
        uint64 policyID = shmonad.createPolicy(10);

        // Make deployer an agent
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Scenario params
        uint256 c0 = 2 ether; // initial committed
        uint256 u0 = 10 ether; // initial uncommitted
        uint256 spend = 4 ether; // shares to spend
        uint128 minC = uint128(3 ether);

        // Alice: fund balances
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: c0 }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: u0 }(u0, alice);
        vm.stopPrank();

        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        uint256 aliceUncommittedBefore = shmonad.balanceOf(alice);
        uint256 bobUncommittedBefore = shmonad.balanceOf(bob);

        // Enable top-up: minCommitted, cap big, period large enough
        _setTopUp(alice, policyID, minC, type(uint128).max, uint32(MIN_TOP_UP_PERIOD_BLOCKS));

        // Agent spends shares from committed (inUnderlying=false). Recipient is bob's uncommitted.
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spend, 0, false);

        uint256 committedAfter = shmonad.balanceOfCommitted(policyID, alice);
        uint256 aliceUncommittedAfter = shmonad.balanceOf(alice);
        uint256 bobUncommittedAfter = shmonad.balanceOf(bob);

        // Compute expected
        uint256 shortfall = spend > committedBefore ? spend - committedBefore : 0;
        uint256 targetToMin = shortfall + minC;
        uint256 expectedTopUp = targetToMin; // cap and balance are generous here
        uint256 expectedCommittedAfter = committedBefore + expectedTopUp - spend;

        assertEq(committedAfter, expectedCommittedAfter, "final committed should equal minCommitted");
        assertEq(aliceUncommittedBefore - aliceUncommittedAfter, expectedTopUp, "alice uncommitted reduced by top-up amount");
        assertEq(bobUncommittedAfter - bobUncommittedBefore, spend, "bob uncommitted increased by spend amount");
    }

    // Uncommitting is consumed before any top-up
    function test_TopUp_usesUncommitting_beforeTopUp() public {
        uint64 policyID = shmonad.createPolicy(10);

        // Agent
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Scenario params
        uint256 c0 = 3 ether; // initial committed
        uint256 uncommitReq = 2 ether; // move to uncommitting
        uint256 spend = 2 ether; // to spend

        // Alice balances
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: c0 }(policyID, alice, type(uint256).max);
        shmonad.requestUncommit(policyID, uncommitReq, 0);
        vm.stopPrank();

        uint256 uncommittingBefore = shmonad.balanceOfUncommitting(policyID, alice);
        uint256 committedBeforeSpend = shmonad.balanceOfCommitted(policyID, alice);
        uint256 aliceUncommittedBefore = shmonad.balanceOf(alice);
        uint256 bobUncommittedBefore = shmonad.balanceOf(bob);

        // Top-up generous but should not be used for this spend
        _setTopUp(alice, policyID, 0, type(uint128).max, uint32(MIN_TOP_UP_PERIOD_BLOCKS));

        // Spend shares (should be covered by uncommitting shortfall-first)
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spend, 0, false);

        uint256 uncommittingAfter = shmonad.balanceOfUncommitting(policyID, alice);
        uint256 aliceUncommittedAfter = shmonad.balanceOf(alice);
        uint256 bobUncommittedAfter = shmonad.balanceOf(bob);

        // Only the shortfall (spend - committedBeforeSpend) is taken from uncommitting.
        uint256 expectedFromUncommitting = spend > committedBeforeSpend ? spend - committedBeforeSpend : 0;
        assertEq(uncommittingBefore - uncommittingAfter, expectedFromUncommitting, "uncommitting consumes only the shortfall first");
        // Alice's uncommitted does not change (recipient is bob)
        assertEq(aliceUncommittedAfter, aliceUncommittedBefore, "alice uncommitted unchanged");
        // Bob receives the spend amount to uncommitted
        assertEq(bobUncommittedAfter - bobUncommittedBefore, spend, "bob uncommitted increases by spend amount");
    }

    // Per-period cap is enforced and reset by duration
    function test_TopUp_enforcesPerPeriod_and_Resets() public {
        uint64 policyID = shmonad.createPolicy(10);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Alice balances
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 2 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 5 ether }(5 ether, alice);
        vm.stopPrank();

        // Cap per period
        uint128 cap = uint128(2 ether);
        _setTopUp(alice, policyID, 0, cap, uint32(MIN_TOP_UP_PERIOD_BLOCKS));

        // First spend needs A1 top-up (force need by blocking fundsAvailable with a hold)
        uint256 A1 = 1.5 ether;
        // Force top-up by putting a hold to reduce fundsAvailable to 0
        vm.prank(deployer);
        shmonad.hold(policyID, alice, shmonad.balanceOfCommitted(policyID, alice));

        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, A1, 0, false);

        // Second spend attempts A2 in same period -> should revert (exceeds cap)
        uint256 A2 = 1 ether;
        vm.prank(deployer);
        vm.expectRevert();
        shmonad.agentTransferToUncommitted(policyID, alice, bob, A2, 0, false);

        // Reset period by rolling blocks beyond duration
        vm.roll(block.number + MIN_TOP_UP_PERIOD_BLOCKS + 1);

        // Now A2 should succeed after reset
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, A2, 0, false);
    }

    // If Alice sets a high minCommitted target but only has a small
    // uncommitted balance, a spend should trigger top-up that uses as
    // much uncommitted as available, but still cannot restore to the
    // min target. Net effect in this scenario: committed stays the same
    // (we commit all uncommitted first, then immediately spend that same amount).
    function test_TopUp_cannotRestoreToMinCommitted() public {
        // 1) Setup policy and authorize deployer as agent to initiate spends.
        uint64 policyID = shmonad.createPolicy(10);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // 2) Alice has a small committed balance and limited uncommitted.
        //    She configures a very high minCommitted target with an effectively
        //    unlimited top-up cap for the period.
        uint256 initialCommitted = 2 ether;
        uint256 initialUncommitted = 3 ether;
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: initialCommitted }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: initialUncommitted }(initialUncommitted, alice);
        uint128 minCommittedTarget = uint128(10 ether);
        vm.stopPrank();
        
        _setTopUp(alice, policyID, minCommittedTarget, type(uint128).max, uint32(MIN_TOP_UP_PERIOD_BLOCKS));

        // Pre-spend snapshots (all values in shMON shares)
        // Note: In fork mode the shMON:MON exchange rate may not be 1:1, so we
        // always reason in shares returned by balance views to avoid assumptions.
        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        uint256 aliceUncommittedBefore = shmonad.balanceOf(alice);
        uint256 bobUncommittedBefore = shmonad.balanceOf(bob);

        // 3) Spend that requires topping-up. The system will try to restore
        //    committed to the min target, but Alice only has 3 ether uncommitted.
        //    So it commits all 3, then spends 3, leaving committed unchanged.
        uint256 spendShares = 3 ether;
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendShares, 0, false);

        // 4) Assertions (share-aware):
        //    - Requested top-up in shares equals spend + minCommitted - fundsAvailable
        //    - Actual shares committed via top-up are clamped by Alice's available
        //      uncommitted shares (cap is unlimited here)
        //    - Final committed balance = committedBefore + sharesUsedForTopUp - spendShares
        //    - Bob receives the full spend amount to uncommitted (in shares)
        uint256 committedAfter = shmonad.balanceOfCommitted(policyID, alice);
        uint256 aliceUncommittedAfter = shmonad.balanceOf(alice);
        uint256 bobUncommittedAfter = shmonad.balanceOf(bob);

        // Compute shares requested by the top-up logic, then clamp by Alice's available uncommitted shares.
        uint256 fundsAvailableBefore = committedBefore; // no holds in this test
        uint256 sharesRequested = spendShares + uint256(minCommittedTarget) - fundsAvailableBefore;
        uint256 sharesUsedForTopUp = sharesRequested < aliceUncommittedBefore ? sharesRequested : aliceUncommittedBefore;

        // Expected final committed shares after top-up and spend.
        uint256 expectedCommittedAfter = committedBefore + sharesUsedForTopUp - spendShares;
        assertEq(
            committedAfter,
            expectedCommittedAfter,
            "committed should reflect min(requested, available) top-up minus spend"
        );

        // Alice's uncommitted decreases exactly by the shares used for top-up.
        assertEq(
            aliceUncommittedBefore - aliceUncommittedAfter,
            sharesUsedForTopUp,
            "alice uncommitted should decrease by top-up shares used"
        );

        // Bob receives the full spend in uncommitted (shares).
        assertEq(
            bobUncommittedAfter - bobUncommittedBefore,
            spendShares,
            "recipient should receive full spend amount"
        );
    }

    function test_TopUp_triggersBeforeCommittedDropsBelowMin() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        uint256 initialCommit = 10 ether;
        uint256 uncommittedReserve = 10 ether;

        vm.startPrank(alice);
        uint256 committedShares = shmonad.depositAndCommit{ value: initialCommit }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: uncommittedReserve }(uncommittedReserve, alice);
        uint128 minCommitted = uint128(committedShares / 2);
        shmonad.setMinCommittedBalance(policyID, minCommitted, type(uint128).max, MIN_TOP_UP_PERIOD_BLOCKS);
        vm.stopPrank();

        uint256 slack = committedShares - uint256(minCommitted);
        require(slack > 2, "precondition: need slack to test top-up");
        uint256 spendAmount = (slack / 2) + 1;

        // First spend should not require a top-up because committed - spend >= minCommitted
        uint256 committedBeforeFirst = shmonad.balanceOfCommitted(policyID, alice);
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendAmount, 0, false);
        uint256 committedAfterFirst = shmonad.balanceOfCommitted(policyID, alice);
        assertEq(
            committedAfterFirst,
            committedBeforeFirst - spendAmount,
            "first spend should leave committed above min"
        );

        uint256 uncommittedBeforeSecondSpend = shmonad.balanceOf(alice);

        // Second spend would push committed below min, so the new logic must top up beforehand
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendAmount, 0, false);

        uint256 committedAfterSecondSpend = shmonad.balanceOfCommitted(policyID, alice);
        assertEq(committedAfterSecondSpend, minCommitted, "committed balance should stay at min after second spend");

        uint256 uncommittedAfter = shmonad.balanceOf(alice);
        // Top-up consumed equals shortfall needed to keep min committed prior to the second spend
        // committedBeforeSecond = committedAfterFirst
        uint256 committedBeforeSecond = committedAfterFirst;
        uint256 expectedTopUpShares = 0;
        if (committedBeforeSecond < spendAmount + minCommitted) {
            expectedTopUpShares = spendAmount + minCommitted - committedBeforeSecond;
        }
        assertGt(expectedTopUpShares, 0, "precondition: expected a top-up on second spend");
        assertEq(
            uncommittedBeforeSecondSpend - uncommittedAfter,
            expectedTopUpShares,
            "top-up should only consume the shortfall needed to keep min committed"
        );
    }

    function test_TopUp_handlesPartialDueToCap() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 2 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 10 ether }(10 ether, alice);
        shmonad.setMinCommittedBalance(policyID, 5 ether, 1 ether, MIN_TOP_UP_PERIOD_BLOCKS);
        vm.stopPrank();

        // With a 1 share cap and a 3 share spend ask, whether the call reverts depends on
        // if committedBefore + sharesCommitted < sharesRequested. Handle both modes.
        // Verify the available top-up before the call equals the cap (in shares) or is positive.
        uint256 preCap = shmonad.topUpAvailable(policyID, alice, false);
        assertGt(preCap, 0, "expected positive top-up availability");
        assertLe(preCap, 1 ether, "top-up availability should not exceed configured cap");

        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);
        uint256 uncommittedBefore = shmonad.balanceOf(alice);
        uint256 spendSharesReq = 3 ether;
        uint256 minCommitted = 5 ether;

        uint256 committedShortfall = 0;
        if (committedBefore < spendSharesReq + minCommitted) {
            committedShortfall = spendSharesReq + minCommitted - committedBefore;
        }
        uint256 sharesCap = preCap; // remaining per-period cap in shares
        uint256 sharesCommitted = committedShortfall;
        if (sharesCommitted > sharesCap) sharesCommitted = sharesCap;
        if (sharesCommitted > uncommittedBefore) sharesCommitted = uncommittedBefore;

        // If even after capped top-up we cannot cover the spend, expect revert; else expect success and verify deltas
        if (committedBefore + sharesCommitted < spendSharesReq) {
            uint256 expectedCommittedOnRevert = committedBefore + sharesCommitted;
            vm.prank(deployer);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ShMonadErrors.InsufficientFunds.selector,
                    uint128(expectedCommittedOnRevert),
                    uint128(0),
                    uint128(0),
                    uint128(spendSharesReq)
                )
            );
            shmonad.agentTransferToUncommitted(policyID, alice, bob, spendSharesReq, 0, false);
            // After revert, availability unchanged
            assertEq(shmonad.topUpAvailable(policyID, alice, false), preCap, "cap should remain after revert");
        } else {
            vm.prank(deployer);
            shmonad.agentTransferToUncommitted(policyID, alice, bob, spendSharesReq, 0, false);
            uint256 uncommittedAfter = shmonad.balanceOf(alice);
            assertEq(
                uncommittedBefore - uncommittedAfter,
                sharesCommitted,
                "top-up should be limited by the remaining per-period allowance"
            );
            assertEq(shmonad.topUpAvailable(policyID, alice, false), 0, "cap should be exhausted after partial top-up");
        }
    }

    function test_TopUp_shortfallLessThanMinDoesNotRevert() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        vm.startPrank(alice);
        uint256 committedShares = shmonad.depositAndCommit{ value: 10 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 5 ether }(5 ether, alice);
        uint128 minCommitted = uint128(committedShares / 2);
        shmonad.setMinCommittedBalance(policyID, minCommitted, type(uint128).max, MIN_TOP_UP_PERIOD_BLOCKS);
        vm.stopPrank();

        uint256 uncommittedBefore = shmonad.balanceOf(alice);
        uint256 committedBefore = shmonad.balanceOfCommitted(policyID, alice);

        vm.prank(deployer);
        uint256 spendShares = committedBefore - uint256(minCommitted) + 1;
        shmonad.agentTransferToUncommitted(policyID, alice, bob, spendShares, 0, false);

        assertEq(
            shmonad.balanceOfCommitted(policyID, alice),
            uint256(minCommitted),
            "committed balance should remain at the minimum even when spend < committed"
        );

        // Shortfall in shares is max(0, minCommitted - (committedBefore - spend))
        uint256 expectedShortfall = 0;
        if (committedBefore < spendShares + uint256(minCommitted)) {
            expectedShortfall = spendShares + uint256(minCommitted) - committedBefore;
        }
        assertEq(
            uncommittedBefore - shmonad.balanceOf(alice),
            expectedShortfall,
            "only the true shortfall should be top-upped (share-based)"
        );
    }

    // When a policy is disabled, agent spend calls must revert and must not top-up (i.e. must not reduce user's
    // uncommitted). This ensures agents cannot draw from a user's uncommitted balance via top-up through a
    // deactivated policy.
    function test_TopUp_policyDisabled_preventsAgentSpendViaTopUp_uncommittedUnchanged() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        // Allow deployer to act as an agent for spends in this test
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Alice has a small committed balance and ample uncommitted; enable top-up generously so the attempted
        // spends (if policy were active) would try to pull from uncommitted via top-up
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 1 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 5 ether }(5 ether, alice);
        shmonad.setMinCommittedBalance(policyID, 0, type(uint128).max, uint32(MIN_TOP_UP_PERIOD_BLOCKS));
        vm.stopPrank();

        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        uint256 requestShares = committed + 1 ether; // requires top-up if policy were active
        uint256 uncommittedBefore = shmonad.balanceOf(alice);

        // Disable the policy (only agents may do this); all agent spend functions must now revert
        shmonad.disablePolicy(policyID);

        // 1) agentTransferToUncommitted
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyInactive.selector, policyID));
        shmonad.agentTransferToUncommitted(policyID, alice, bob, requestShares, 0, false);
        assertEq(shmonad.balanceOf(alice), uncommittedBefore, "uncommitted unchanged after failed transferToUncommitted");

        // 2) agentTransferFromCommitted
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyInactive.selector, policyID));
        shmonad.agentTransferFromCommitted(policyID, alice, bob, requestShares, 0, false);
        assertEq(shmonad.balanceOf(alice), uncommittedBefore, "uncommitted unchanged after failed transferFromCommitted");

        // 3) agentWithdrawFromCommitted
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyInactive.selector, policyID));
        shmonad.agentWithdrawFromCommitted(policyID, alice, bob, requestShares, 0, false);
        assertEq(shmonad.balanceOf(alice), uncommittedBefore, "uncommitted unchanged after failed withdrawFromCommitted");
    }

    function test_Policies_topUpAvailable_EarlyReturns() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        assertEq(shmonad.topUpAvailable(policyID, alice, false), 0, "No settings should return zero");

        vm.prank(alice);
        shmonad.setMinCommittedBalance(policyID, 0, uint128(5 ether), MIN_TOP_UP_PERIOD_BLOCKS);
        assertEq(shmonad.topUpAvailable(policyID, alice, false), 0, "Missing uncommitted balance should return zero");

        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 1 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 2 ether }(2 ether, alice);
        uint256 shareCap = shmonad.previewWithdraw(1 ether);
        shmonad.setMinCommittedBalance(policyID, 0, uint128(shareCap), MIN_TOP_UP_PERIOD_BLOCKS);
        vm.stopPrank();

        vm.prank(deployer);
        shmonad.hold(policyID, alice, shmonad.balanceOfCommitted(policyID, alice));

        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, shareCap, 0, false);

        assertEq(shmonad.topUpAvailable(policyID, alice, false), 0, "Cap reached should return zero within period");

        vm.roll(block.number + MIN_TOP_UP_PERIOD_BLOCKS + 1);
        uint256 refreshed = shmonad.topUpAvailable(policyID, alice, false);
        uint256 uncommitted = shmonad.balanceOf(alice);
        assertGt(refreshed, 0, "New period should restore allowance");
        assertLe(refreshed, uncommitted, "Allowance should not exceed uncommitted");
    }

    function test_Policies_topUpAvailable_ReturnsZeroWhenExhausted() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 1 ether }(policyID, alice, type(uint256).max);
        shmonad.deposit{ value: 4 ether }(4 ether, alice);
        uint256 shareCap = shmonad.previewWithdraw(1 ether);
        shmonad.setMinCommittedBalance(policyID, 0, uint128(shareCap), MIN_TOP_UP_PERIOD_BLOCKS);
        vm.stopPrank();

        vm.prank(deployer);
        shmonad.hold(policyID, alice, shmonad.balanceOfCommitted(policyID, alice));

        uint256 shareHalf = shareCap / 2;
        uint256 shareRemaining = shareCap - shareHalf;
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, shareHalf, 0, false);
        vm.prank(deployer);
        shmonad.agentTransferToUncommitted(policyID, alice, bob, shareRemaining, 0, false);

        assertEq(shmonad.topUpAvailable(policyID, alice, false), 0, "Exhausted allowance should return zero");
    }

    function test_Policies_policyBalanceAvailable_inUnderlying() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 10 ether }(policyID, alice, type(uint256).max);
        uint256 uncommitShares = shmonad.previewWithdraw(3 ether);
        shmonad.requestUncommit(policyID, uncommitShares, 0);
        uint256 holdShares = shmonad.previewWithdraw(2 ether);
        vm.stopPrank();

        shmonad.hold(policyID, alice, holdShares);

        vm.startPrank(alice);
        shmonad.deposit{ value: 5 ether }(5 ether, alice);
        shmonad.setMinCommittedBalance(policyID, 0, type(uint128).max, MIN_TOP_UP_PERIOD_BLOCKS);
        vm.stopPrank();

        uint256 balanceShares = shmonad.policyBalanceAvailable(policyID, alice, false);
        uint256 balanceAssets = shmonad.policyBalanceAvailable(policyID, alice, true);
        assertEq(balanceAssets, shmonad.previewRedeem(balanceShares), "Underlying view should match previewRedeem");

        uint256 topUpShares = shmonad.topUpAvailable(policyID, alice, false);
        uint256 topUpAssets = shmonad.topUpAvailable(policyID, alice, true);
        assertEq(topUpAssets, shmonad.previewRedeem(topUpShares), "Underlying top-up should match previewRedeem");
    }

    // ================================================== //
    //            UncommitApproval Functions             //
    // ================================================== //

    function test_Policies_setUncommitApproval() public {
        uint64 policyID = shmonad.createPolicy(10);

        // Deposit and commit for Alice to get shares context
        vm.startPrank(alice);
        uint256 depositAmount = 9 ether;
        shmonad.depositAndCommit{value: depositAmount}(policyID, alice, type(uint256).max);
        uint256 committedShares = shmonad.balanceOfCommitted(policyID, alice);

        // First set approval to bob
        uint256 sharesAllow1 = committedShares / 3;
        vm.expectEmit(true, true, true, true);
        emit UncommitApprovalUpdated(policyID, alice, bob, uint96(sharesAllow1));
        shmonad.setUncommitApproval(policyID, bob, sharesAllow1);

        // Override approval to charlie with a different allowance
        uint256 sharesAllow2 = committedShares / 5;
        vm.expectEmit(true, true, true, true);
        emit UncommitApprovalUpdated(policyID, alice, charlie, uint96(sharesAllow2));
        shmonad.setUncommitApproval(policyID, charlie, sharesAllow2);
        vm.stopPrank();

        // Verify getUncommitApproval reflects the override
        UncommitApproval memory approval = shmonad.getUncommitApproval(policyID, alice);
        assertEq(approval.completor, charlie, "Completor should be overridden to charlie");
        assertEq(uint256(approval.shares), sharesAllow2, "Allowance should equal the second set value");
    }

    function test_Policies_requestUncommitWithApprovedCompletor() public {
        uint64 policyID = shmonad.createPolicy(10);

        // Alice deposits and commits
        vm.startPrank(alice);
        uint256 depositAmount = 12 ether;
        shmonad.depositAndCommit{value: depositAmount}(policyID, alice, type(uint256).max);
        uint256 committedShares = shmonad.balanceOfCommitted(policyID, alice);

        // First request uncommit with bob as completor
        uint256 shares1 = committedShares / 3;
        vm.expectEmit(true, true, true, true);
        emit RequestUncommit(policyID, alice, shares1, block.number + 10);
        vm.expectEmit(true, true, true, true);
        emit UncommitApprovalUpdated(policyID, alice, bob, uint96(shares1));
        shmonad.requestUncommitWithApprovedCompletor(policyID, shares1, 0, bob);

        // Second request uncommit with charlie as completor; allowance should accumulate
        uint256 shares2 = committedShares / 4;
        vm.expectEmit(true, true, true, true);
        emit RequestUncommit(policyID, alice, shares2, block.number + 10);
        vm.expectEmit(true, true, true, true);
        emit UncommitApprovalUpdated(policyID, alice, charlie, uint96(shares1 + shares2));
        shmonad.requestUncommitWithApprovedCompletor(policyID, shares2, 0, charlie);
        vm.stopPrank();

        // Verify accumulated approval and overridden completor
        UncommitApproval memory approval = shmonad.getUncommitApproval(policyID, alice);
        assertEq(approval.completor, charlie, "Completor should be overridden to charlie");
        assertEq(uint256(approval.shares), shares1 + shares2, "Allowance should accumulate shares1 + shares2");
    }

    function test_Policies_completeUncommitWithApproval_standardSettings() public {
        uint64 policyID = shmonad.createPolicy(10);

        // Alice deposits, commits, and requests uncommit with bob approved
        vm.startPrank(alice);
        shmonad.depositAndCommit{value: 8 ether}(policyID, alice, type(uint256).max);
        uint256 committedShares = shmonad.balanceOfCommitted(policyID, alice);
        uint256 uncommitShares = committedShares / 2;

        vm.expectEmit(true, true, true, true);
        emit RequestUncommit(policyID, alice, uncommitShares, block.number + 10);
        vm.expectEmit(true, true, true, true);
        emit UncommitApprovalUpdated(policyID, alice, bob, uint96(uncommitShares));
        shmonad.requestUncommitWithApprovedCompletor(policyID, uncommitShares, 0, bob);
        vm.stopPrank();

        // Move past escrow period
        vm.roll(block.number + 11);

        // Unauthorized completor should revert
        vm.prank(charlie);
        vm.expectRevert(ShMonadErrors.InvalidUncommitCompletor.selector);
        shmonad.completeUncommitWithApproval(policyID, uncommitShares, alice);

        // Authorized completor (bob) completes on Alice's behalf; operates on Alice balances
        uint256 aliceUncommittingBefore = shmonad.balanceOfUncommitting(policyID, alice);
        uint256 aliceUncommittedBefore = shmonad.balanceOf(alice);

        vm.startPrank(bob);
        // Expect allowance reduction event then completion event
        vm.expectEmit(true, true, true, true);
        emit UncommitApprovalUpdated(policyID, alice, bob, uint96(0));
        vm.expectEmit(true, true, true, true);
        emit CompleteUncommit(policyID, alice, uncommitShares);
        shmonad.completeUncommitWithApproval(policyID, uncommitShares, alice);
        vm.stopPrank();

        // Verify balances updated for Alice, not for Bob
        assertEq(
            shmonad.balanceOfUncommitting(policyID, alice),
            aliceUncommittingBefore - uncommitShares,
            "Alice uncommitting should decrease"
        );
        assertEq(
            shmonad.balanceOf(alice),
            aliceUncommittedBefore + uncommitShares,
            "Alice uncommitted balance should increase"
        );
        assertEq(shmonad.balanceOf(bob), 0, "Bob's uncommitted balance should not change");

        // Approval should be reduced to zero
        UncommitApproval memory approval = shmonad.getUncommitApproval(policyID, alice);
        assertEq(approval.completor, bob, "Completor remains bob after reduction");
        assertEq(uint256(approval.shares), 0, "Allowance should be reduced to zero");
    }

    function test_Policies_completeUncommitWithApproval_openAndInfiniteSettings() public {
        uint64 policyID = shmonad.createPolicy(10);

        // Alice deposits and commits; set open infinite approval
        vm.startPrank(alice);
        shmonad.depositAndCommit{value: 6 ether}(policyID, alice, type(uint256).max);
        uint256 committedShares = shmonad.balanceOfCommitted(policyID, alice);
        uint256 uncommitShares = committedShares / 3;

        // Set infinite open approval (address(0), type(uint96).max)
        vm.expectEmit(true, true, true, true);
        emit UncommitApprovalUpdated(policyID, alice, address(0), type(uint96).max);
        shmonad.setUncommitApproval(policyID, address(0), type(uint96).max);

        // Request uncommit without changing approval
        vm.expectEmit(true, true, true, true);
        emit RequestUncommit(policyID, alice, uncommitShares, block.number + 10);
        shmonad.requestUncommit(policyID, uncommitShares, 0);
        vm.stopPrank();

        // Move past escrow period
        vm.roll(block.number + 11);

        // Anyone (charlie) can complete; infinite approval should not decrement or emit update
        uint256 aliceUncommittingBefore = shmonad.balanceOfUncommitting(policyID, alice);
        vm.prank(charlie);
        vm.expectEmit(true, true, true, true);
        emit CompleteUncommit(policyID, alice, uncommitShares);
        shmonad.completeUncommitWithApproval(policyID, uncommitShares, alice);

        // Approval remains infinite and open
        UncommitApproval memory approval = shmonad.getUncommitApproval(policyID, alice);
        assertEq(approval.completor, address(0), "Approval should remain open to anyone");
        assertEq(uint256(approval.shares), uint256(type(uint96).max), "Allowance should remain infinite");
        assertEq(
            shmonad.balanceOfUncommitting(policyID, alice),
            aliceUncommittingBefore - uncommitShares,
            "Alice uncommitting should decrease"
        );
    }

    function test_Policies_completeUncommitWithApproval_InsufficientApproval_reverts() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint256 depositAmount = 9 ether;

        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: depositAmount }(policyID, alice, type(uint256).max);
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        uint256 uncommitShares = committed;

        uint256 allowance = uncommitShares / 2;
        vm.expectEmit(true, true, true, true);
        emit UncommitApprovalUpdated(policyID, alice, bob, uint96(allowance));
        shmonad.setUncommitApproval(policyID, bob, allowance);

        vm.expectEmit(true, true, true, true);
        emit RequestUncommit(policyID, alice, uncommitShares, block.number + ESCROW);
        shmonad.requestUncommit(policyID, uncommitShares, 0);
        vm.stopPrank();

        vm.roll(block.number + ESCROW + 1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.InsufficientUncommitApproval.selector, allowance, uncommitShares)
        );
        shmonad.completeUncommitWithApproval(policyID, uncommitShares, alice);
    }

    function test_Policies_setMinCommittedBalance_PeriodTooShort_reverts() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShMonadErrors.TopUpPeriodDurationTooShort.selector,
                uint32(MIN_TOP_UP_PERIOD_BLOCKS - 1),
                MIN_TOP_UP_PERIOD_BLOCKS
            )
        );
        shmonad.setMinCommittedBalance(policyID, 0, 0, MIN_TOP_UP_PERIOD_BLOCKS - 1);
    }

    // Views: policyBalanceAvailable and topUpAvailable
    function test_Policies_policyBalanceAvailable_and_topUpAvailable_viewConsistency() public {
        uint64 policyID = shmonad.createPolicy(10);

        // Alice deposits and commits 10 ether worth of shares
        vm.startPrank(alice);
        shmonad.depositAndCommit{ value: 10 ether }(policyID, alice, type(uint256).max);

        // Request uncommit for 3 ether worth (in shares)
        uint256 uncommitShares = shmonad.previewWithdraw(3 ether);
        shmonad.requestUncommit(policyID, uncommitShares, 0);

        // Place a hold of 2 ether worth (in shares)
        uint256 holdShares = shmonad.previewWithdraw(2 ether);
        vm.stopPrank();
        shmonad.hold(policyID, alice, holdShares);

        // Seed uncommitted balance and enable top-up with a generous per-period cap
        vm.startPrank(alice);
        shmonad.deposit{ value: 5 ether }(5 ether, alice);
        shmonad.setMinCommittedBalance(policyID, 0, type(uint128).max, MIN_TOP_UP_PERIOD_BLOCKS);
        vm.stopPrank();

        // Compute expected using view helpers (all in shares)
        uint256 committed = shmonad.balanceOfCommitted(policyID, alice);
        uint256 uncommitting = shmonad.balanceOfUncommitting(policyID, alice);
        uint256 topUpAvail = shmonad.topUpAvailable(policyID, alice, false);
        uint256 held = shmonad.getHoldAmount(policyID, alice);

        uint256 expected = committed + uncommitting + topUpAvail - held;
        uint256 available = shmonad.policyBalanceAvailable(policyID, alice, false);
        assertEq(available, expected, "policyBalanceAvailable mismatch");
    }

    // setMinCommittedBalance: Zero value validation
    function test_Policies_setMinCommittedBalanceAllowsZeroValues() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        vm.prank(alice);
        // Should allow setting all values to zero to disable top-up
        vm.expectEmit(true, true, true, true);
        emit ShMonadEvents.SetTopUp(policyID, alice, 0, 0, 0);
        shmonad.setMinCommittedBalance(policyID, 0, 0, 0);
    }

    function test_Policies_setMinCommittedBalanceValidNonZeroValues() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint128 minCommitted = 100 ether;
        uint128 maxTopUp = 10 ether;
        uint32 validDuration = MIN_TOP_UP_PERIOD_BLOCKS;

        vm.prank(alice);
        // Should succeed with valid non-zero values
        vm.expectEmit(true, true, true, true);
        emit ShMonadEvents.SetTopUp(policyID, alice, minCommitted, maxTopUp, validDuration);
        shmonad.setMinCommittedBalance(policyID, minCommitted, maxTopUp, validDuration);
    }

    function test_Policies_setMinCommittedBalancePartialZeroValues() public {
        uint64 policyID = shmonad.createPolicy(ESCROW);
        uint32 validDuration = MIN_TOP_UP_PERIOD_BLOCKS * 2;

        vm.prank(alice);
        // Should allow zero minCommitted and maxTopUp with valid duration
        vm.expectEmit(true, true, true, true);
        emit ShMonadEvents.SetTopUp(policyID, alice, 0, 0, validDuration);
        shmonad.setMinCommittedBalance(policyID, 0, 0, validDuration);
    }

    function testFuzz_Policies_setMinCommittedBalanceZeroDurationAlwaysAllowed(
        uint128 minCommitted,
        uint128 maxTopUp
    )
        public
    {
        uint64 policyID = shmonad.createPolicy(ESCROW);

        vm.prank(alice);
        // Any minCommitted and maxTopUp values should work with zero duration
        vm.expectEmit(true, true, true, true);
        emit ShMonadEvents.SetTopUp(policyID, alice, minCommitted, maxTopUp, 0);
        shmonad.setMinCommittedBalance(policyID, minCommitted, maxTopUp, 0);
    }

    function testFuzz_Policies_setMinCommittedBalanceValidDuration(
        uint128 minCommitted,
        uint128 maxTopUp,
        uint32 duration
    )
        public
    {
        // Bound duration to valid range
        duration = uint32(bound(duration, MIN_TOP_UP_PERIOD_BLOCKS, type(uint32).max));

        uint64 policyID = shmonad.createPolicy(ESCROW);

        vm.prank(alice);
        // Should succeed with any valid duration >= MIN_TOP_UP_PERIOD_BLOCKS
        vm.expectEmit(true, true, true, true);
        emit ShMonadEvents.SetTopUp(policyID, alice, minCommitted, maxTopUp, duration);
        shmonad.setMinCommittedBalance(policyID, minCommitted, maxTopUp, duration);
    }

    // ================================================== //
    //        Commitment System Security Tests            //
    // ================================================== //

    /**
     * @notice Test that demonstrates the auditor's concern is invalid
     * @dev Shows that users cannot instantly requestUnstake after committing because
     *      requestUnstake only operates on uncommitted balance, not committed balance
     */
    function test_Policies_requestUnstake_afterCommit_reverts() public {
        uint256 depositAmount = 10 ether; // Smaller amount to avoid atomic pool issues
        uint256 commitAmount = 5 ether;
        
        // Setup: Alice deposits and commits some funds
        vm.startPrank(alice);
        uint256 totalShares = shmonad.deposit{ value: depositAmount }(depositAmount, alice);
        vm.stopPrank();
        
        // Create a policy for testing
        uint64 policyID = shmonad.createPolicy(3); // 3 blocks escrow period
        
        // Verify Alice has uncommitted balance
        assertEq(shmonad.balanceOf(alice), totalShares, "Alice should have uncommitted balance");
        assertEq(shmonad.balanceOfCommitted(policyID, alice), 0, "Alice should have no committed balance initially");
        
        // Alice commits 5 ether worth of shares to the policy
        uint256 sharesToCommit = shmonad.previewDeposit(commitAmount);
        vm.startPrank(alice);
        shmonad.commit(policyID, alice, sharesToCommit);
        vm.stopPrank();
        
        // Verify the commitment worked correctly
        assertEq(shmonad.balanceOf(alice), totalShares - sharesToCommit, "Alice's uncommitted balance should decrease");
        assertEq(shmonad.balanceOfCommitted(policyID, alice), sharesToCommit, "Alice should have committed balance");
        
        // THE KEY TEST: Alice tries to requestUnstake on her remaining uncommitted balance
        // This should work because she still has uncommitted balance
        uint256 remainingUncommitted = shmonad.balanceOf(alice);
        assertTrue(remainingUncommitted > 0, "Alice should still have uncommitted balance");
        
        vm.startPrank(alice);
        uint64 completionEpoch = shmonad.requestUnstake(remainingUncommitted);
        vm.stopPrank();
        
        // Verify unstake request was successful
        assertTrue(completionEpoch > 0, "Unstake request should succeed");
        assertEq(shmonad.balanceOf(alice), 0, "Alice's uncommitted balance should be zero after unstake request");
        
        // CRITICAL: Alice CANNOT requestUnstake on her committed balance
        // This is the core security property that invalidates the auditor's concern
        // Note: We need to try to unstake 1 share to test the insufficient balance error
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InsufficientBalanceForUnstake.selector));
        shmonad.requestUnstake(1); // Try to unstake 1 share, but Alice has 0 uncommitted balance
        vm.stopPrank();
        
        // Verify committed balance is still there and untouched
        assertEq(shmonad.balanceOfCommitted(policyID, alice), sharesToCommit, "Committed balance should be unchanged");
    }

    /**
     * @notice Test that demonstrates the proper uncommit flow works as intended
     * @dev Shows that users must go through the proper uncommit -> completeUncommit flow
     */
    function test_Policies_requestUncommitAndCompleteUncommit_worksAsIntended() public {
        uint256 depositAmount = 10 ether; // Smaller amount
        uint256 commitAmount = 5 ether;
        
        // Setup: Alice deposits and commits funds
        vm.startPrank(alice);
        uint256 totalShares = shmonad.deposit{ value: depositAmount }(depositAmount, alice);
        uint256 sharesToCommit = shmonad.previewDeposit(commitAmount);
        vm.stopPrank();
        
        // Create a policy for testing
        uint64 policyID = shmonad.createPolicy(3); // 3 blocks escrow period
        
        vm.startPrank(alice);
        shmonad.commit(policyID, alice, sharesToCommit);
        vm.stopPrank();
        
        // Alice requests uncommit (starts escrow period)
        vm.startPrank(alice);
        uint256 uncommitCompleteBlock = shmonad.requestUncommit(policyID, sharesToCommit, 0);
        vm.stopPrank();
        
        // Verify the uncommit request worked
        assertEq(shmonad.balanceOfCommitted(policyID, alice), 0, "Committed balance should be zero");
        assertEq(shmonad.balanceOfUncommitting(policyID, alice), sharesToCommit, "Should have uncommitting balance");
        assertEq(uncommitCompleteBlock, block.number + 3, "Uncommit should complete after escrow duration");
        
        // Alice cannot complete uncommit before escrow period ends
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.UncommittingPeriodIncomplete.selector, uncommitCompleteBlock));
        shmonad.completeUncommit(policyID, sharesToCommit);
        vm.stopPrank();
        
        // Fast forward past escrow period
        vm.roll(block.number + 4);
        
        // Now Alice can complete the uncommit
        vm.startPrank(alice);
        shmonad.completeUncommit(policyID, sharesToCommit);
        vm.stopPrank();
        
        // Verify uncommit completed successfully
        assertEq(shmonad.balanceOfUncommitting(policyID, alice), 0, "Uncommitting balance should be zero");
        assertEq(shmonad.balanceOf(alice), totalShares, "Alice should have all her uncommitted balance back");
    }

    /**
     * @notice Test that demonstrates backend policy commitment is secure
     * @dev Shows that when users commit to a backend's policy, the backend retains control
     *      regardless of what users do with their uncommitted balance
     */
    function test_Policies_commitment_remainsSecureWhenUserUnstakesUncommitted() public {
        uint256 depositAmount = 2 ether; // Very small amount
        uint256 commitAmount = 0.5 ether;
        
        // Setup: Alice deposits and commits some funds to the backend's policy
        vm.startPrank(alice);
        shmonad.deposit{ value: depositAmount }(depositAmount, alice);
        uint256 sharesToCommit = shmonad.previewDeposit(commitAmount);
        vm.stopPrank();
        
        // Create a policy for testing
        uint64 policyID = shmonad.createPolicy(3); // 3 blocks escrow period
        
        vm.startPrank(alice);
        shmonad.commit(policyID, alice, sharesToCommit); // Commit to backend's policy
        vm.stopPrank();
        
        // Alice still has uncommitted balance
        uint256 remainingUncommitted = shmonad.balanceOf(alice);
        assertTrue(remainingUncommitted > 0, "Alice should have remaining uncommitted balance");
        
        // Alice can unstake her remaining uncommitted balance
        vm.startPrank(alice);
        uint64 completionEpoch = shmonad.requestUnstake(remainingUncommitted);
        vm.stopPrank();
        
        // Verify unstake request succeeded
        assertTrue(completionEpoch > 0, "Unstake request should succeed");
        assertEq(shmonad.balanceOf(alice), 0, "Alice's uncommitted balance should be zero");
        
        // CRITICAL: Alice's committed balance to the backend's policy is still there and available
        assertEq(shmonad.balanceOfCommitted(policyID, alice), sharesToCommit, "Backend's committed balance should be unchanged");
        
        // The backend can still operate on Alice's committed funds
        // This demonstrates that the backend's policy commitment is secure:
        // - Backend only cares about funds committed to its specific policy
        // - Uncommitted balance is irrelevant to backend operations
        // - Backend retains full control over committed funds regardless of user's uncommitted actions
    }

    /**
     * @notice Test that demonstrates balanceOf only returns uncommitted balance
     * @dev This is the key insight that invalidates the auditor's concern
     */
    function test_Policies_balanceOf_onlyReturnsUncommittedBalance() public {
        uint256 depositAmount = 10 ether; // Smaller amount
        uint256 commitAmount = 5 ether;
        
        // Setup: Alice deposits and commits funds
        vm.startPrank(alice);
        uint256 totalShares = shmonad.deposit{ value: depositAmount }(depositAmount, alice);
        uint256 sharesToCommit = shmonad.previewDeposit(commitAmount);
        vm.stopPrank();
        
        // Create a policy for testing
        uint64 policyID = shmonad.createPolicy(3); // 3 blocks escrow period
        
        vm.startPrank(alice);
        shmonad.commit(policyID, alice, sharesToCommit);
        vm.stopPrank();
        
        // Verify balanceOf only returns uncommitted balance
        assertEq(shmonad.balanceOf(alice), totalShares - sharesToCommit, "balanceOf should only return uncommitted balance");
        assertEq(shmonad.balanceOfCommitted(alice), sharesToCommit, "balanceOfCommitted should return committed balance");
        assertEq(shmonad.balanceOfCommitted(policyID, alice), sharesToCommit, "balanceOfCommitted(policyID) should return policy committed balance");
        
        // The total "real" balance is uncommitted + committed
        uint256 realTotalBalance = shmonad.balanceOf(alice) + shmonad.balanceOfCommitted(alice);
        assertEq(realTotalBalance, totalShares, "Real total balance should equal original deposit");
    }

    /**
     * @notice Test that demonstrates the commitment system prevents the auditor's attack
     * @dev Shows that even if a user tries to game the system, they cannot bypass the escrow mechanism
     */
    function test_Policies_commitmentSystem_preventsAuditorAttack() public {
        uint256 depositAmount = 10 ether; // Smaller amount
        uint256 commitAmount = 5 ether;
        
        // Setup: Alice deposits and commits funds
        vm.startPrank(alice);
        uint256 totalShares = shmonad.deposit{ value: depositAmount }(depositAmount, alice);
        uint256 sharesToCommit = shmonad.previewDeposit(commitAmount);
        vm.stopPrank();
        
        // Create a policy for testing
        uint64 policyID = shmonad.createPolicy(3); // 3 blocks escrow period
        
        vm.startPrank(alice);
        shmonad.commit(policyID, alice, sharesToCommit);
        vm.stopPrank();
        
        // Alice immediately tries to request uncommit (auditor's concern)
        vm.startPrank(alice);
        uint256 uncommitCompleteBlock = shmonad.requestUncommit(policyID, sharesToCommit, 0);
        vm.stopPrank();
        
        // Verify uncommit request started escrow period
        assertEq(shmonad.balanceOfCommitted(policyID, alice), 0, "Committed balance should be zero");
        assertEq(shmonad.balanceOfUncommitting(policyID, alice), sharesToCommit, "Should have uncommitting balance");
        
        // Alice cannot complete uncommit before escrow period ends
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.UncommittingPeriodIncomplete.selector, uncommitCompleteBlock));
        shmonad.completeUncommit(policyID, sharesToCommit);
        vm.stopPrank();
        
        // Fast forward past escrow period
        vm.roll(block.number + 4);
        
        // Now Alice can complete the uncommit
        vm.startPrank(alice);
        shmonad.completeUncommit(policyID, sharesToCommit);
        vm.stopPrank();
        
        // Verify Alice got her funds back
        assertEq(shmonad.balanceOf(alice), totalShares, "Alice should have all her balance back");
        
        // This demonstrates that the escrow mechanism is enforced and cannot be bypassed
        // Even if users try to game the system by immediately requesting uncommit after commit,
        // they must still wait the full escrow period before they can complete the uncommit
    }

    /**
     * @notice Test that demonstrates the escrow mechanism is not bypassable
     * @dev Shows that the escrow duration is enforced and cannot be circumvented
     */
    function test_Policies_completeUncommit_beforeEscrowPeriod_reverts() public {
        uint256 depositAmount = 10 ether; // Smaller amount
        uint256 commitAmount = 5 ether;
        
        // Setup: Alice deposits and commits funds
        vm.startPrank(alice);
        uint256 totalShares = shmonad.deposit{ value: depositAmount }(depositAmount, alice);
        uint256 sharesToCommit = shmonad.previewDeposit(commitAmount);
        vm.stopPrank();
        
        // Create a policy for testing
        uint64 policyID = shmonad.createPolicy(3); // 3 blocks escrow period
        
        vm.startPrank(alice);
        shmonad.commit(policyID, alice, sharesToCommit);
        vm.stopPrank();
        
        // Alice requests uncommit
        vm.startPrank(alice);
        uint256 uncommitCompleteBlock = shmonad.requestUncommit(policyID, sharesToCommit, 0);
        vm.stopPrank();
        
        // Try to complete uncommit before escrow ends
        vm.roll(block.number + 1);
        
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.UncommittingPeriodIncomplete.selector, uncommitCompleteBlock));
        shmonad.completeUncommit(policyID, sharesToCommit);
        vm.stopPrank();
        
        // Only after the full escrow period can Alice complete uncommit
        vm.roll(uncommitCompleteBlock + 1);
        
        vm.startPrank(alice);
        shmonad.completeUncommit(policyID, sharesToCommit);
        vm.stopPrank();
        
        // Verify uncommit completed successfully
        assertEq(shmonad.balanceOf(alice), totalShares, "Alice should have all her balance back");
    }

    function test_Policies_POC_minCommittedNotMaintained() public {       
        // Charlie creates policy and remains the controlling agent
        vm.prank(charlie);
        uint64 policyID = shmonad.createPolicy(ESCROW);

        // Alice deposits 20 ether worth of shMON, keeping most uncommitted initially
        uint256 depositAmount = 20 ether;
        vm.prank(alice);
        uint256 mintedShares = shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        // Alice commits 10 ether, leaving the remainder uncommitted
        uint256 initialCommit = 10 ether;
        vm.prank(alice);
        shmonad.commit(policyID, alice, initialCommit);

        uint256 uncommittedBefore = shmonad.balanceOf(alice);
        assertEq(uncommittedBefore, mintedShares - initialCommit, "precondition: uncommitted balance mismatch");

        // Alice enables auto top-up with a minimum commited of 5 shMON and generous cap
        uint256 minCommitted = 5 ether;
        vm.prank(alice);
        shmonad.setMinCommittedBalance(
            policyID,
            uint128(minCommitted),
            type(uint128).max,
            MIN_TOP_UP_PERIOD_BLOCKS
        );

        assertEq(
            shmonad.balanceOfCommitted(policyID, alice),
            initialCommit,
            "precondition: committed balance mismatch"
        );

        uint256 agentTransferBalance = 6 ether;

        // Policy agent transfers 6 shMON from alice, leaving her with 4 shMON uncommitted, 1 shMON below the minCommitted threshold
        vm.prank(charlie);
        shmonad.agentTransferToUncommitted(policyID, alice, charlie, agentTransferBalance, 0, false);

        uint256 uncommittedAfter = shmonad.balanceOf(alice);
        uint256 committedAfter = shmonad.balanceOfCommitted(policyID, alice);
        // committed balance should equal minCommitted
        assertGe(committedAfter, minCommitted, "committed balance should equal minCommitted");

        // uncommitted shares were consumed to replenish the committed balance
        assertLt(
            uncommittedAfter,
            uncommittedBefore,
            "top-up should have consumed some uncommitted shares to replenish the committed balance"
        );
    }
}
