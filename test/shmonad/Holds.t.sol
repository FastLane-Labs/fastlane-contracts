// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import { ShMonad } from "../../src/shmonad/ShMonad.sol";
import { HoldsLib } from "../../src/shmonad/libraries/HoldsLib.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";

/// Holds.t.sol — Standardized tests for transient hold logic via public surface
contract HoldsTest is BaseTest {
    address public alice;
    address public bob;
    address public agent1;
    address public agent2;
    uint64 public policyID2;

    uint64 public policyID;
    uint48 public constant ESCROW = 10;

    uint256 constant INITIAL_BAL = 1000 ether;

    function setUp() public override {
        // Prepare actors
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        agent1 = makeAddr("agent1");
        agent2 = makeAddr("agent2");

        vm.deal(alice, INITIAL_BAL);
        vm.deal(bob, INITIAL_BAL);
        vm.deal(agent1, INITIAL_BAL);
        vm.deal(agent2, INITIAL_BAL);

        // Deploy protocol stack
        super.setUp();

        // Create a policy with agent1 as primary agent (so agent1 can call onlyPolicyAgent functions)
        vm.prank(agent1);
        policyID = shMonad.createPolicy(ESCROW); // short escrow for tests

        // Provide committed balances for test accounts
        _depositAndCommit(alice, 10 ether);
        _depositAndCommit(bob, 5 ether);

        // Create a second policy and register agent1 as agent for independence test
        vm.prank(agent1);
        policyID2 = shMonad.createPolicy(ESCROW);
        _depositAndCommitPolicy(policyID2, alice, 6 ether);
    }

    // ----------------------------- //
    //         Basic Holds           //
    // ----------------------------- //

    function test_Holds_holdAndRelease_basic() public {
        // Arrange: No hold initially
        assertEq(shMonad.getHoldAmount(policyID, alice), 0, "initial hold should be zero");

        // Act: agent places a hold of 3 ether on Alice
        vm.prank(agent1);
        shMonad.hold(policyID, alice, 3 ether);

        // Assert: hold increased
        assertEq(shMonad.getHoldAmount(policyID, alice), 3 ether, "hold should be 3 ether");

        // Act: release 1 ether
        vm.prank(agent1);
        shMonad.release(policyID, alice, 1 ether);

        // Assert: hold decreased to 2 ether
        assertEq(shMonad.getHoldAmount(policyID, alice), 2 ether, "hold should be 2 ether after partial release");

        // Act: full release using max sentinel
        vm.prank(agent1);
        shMonad.release(policyID, alice, type(uint256).max);

        // Assert: hold cleared
        assertEq(shMonad.getHoldAmount(policyID, alice), 0, "hold should be zero after full release");
    }

    function test_Holds_releaseBeyondHeld_zeroesOut() public {
        vm.prank(agent1);
        shMonad.hold(policyID, alice, 2 ether);
        assertEq(shMonad.getHoldAmount(policyID, alice), 2 ether, "hold precondition");

        vm.prank(agent1);
        shMonad.release(policyID, alice, 5 ether);

        assertEq(shMonad.getHoldAmount(policyID, alice), 0, "release past hold should floor at zero");
    }

    function test_Holds_secondaryAgent_canHoldAndRelease() public {
        vm.prank(deployer);
        shMonad.addPolicyAgent(policyID, agent2);

        vm.prank(agent2);
        shMonad.hold(policyID, bob, 1 ether);
        assertEq(shMonad.getHoldAmount(policyID, bob), 1 ether, "secondary agent hold applied");

        vm.prank(agent2);
        shMonad.release(policyID, bob, type(uint256).max);
        assertEq(shMonad.getHoldAmount(policyID, bob), 0, "secondary agent release cleared hold");
    }

    function test_Holds_holdInactivePolicy_reverts() public {
        vm.prank(agent1);
        shMonad.disablePolicy(policyID);

        vm.startPrank(agent1);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.PolicyInactive.selector, policyID));
        shMonad.hold(policyID, alice, 1 ether);
        vm.stopPrank();
    }

    // Holds on one policy should not impact spending on another policy
    function test_Holds_multiPolicy_independence() public {
        // Place a full hold on policyID
        uint256 aliceCommitted = shMonad.balanceOfCommitted(policyID, alice);
        vm.prank(agent1);
        shMonad.hold(policyID, alice, aliceCommitted);

        // Attempt agent transfer on policyID2 should still succeed
        uint256 transferAssets = 1 ether;
        uint256 aliceCommittedBefore = shMonad.balanceOfCommitted(policyID2, alice);
        uint256 bobCommittedBefore = shMonad.balanceOfCommitted(policyID2, bob);

        vm.prank(agent1);
        shMonad.agentTransferFromCommitted(policyID2, alice, bob, transferAssets, 0, true);

        uint256 aliceCommittedAfter = shMonad.balanceOfCommitted(policyID2, alice);
        uint256 bobCommittedAfter = shMonad.balanceOfCommitted(policyID2, bob);

        uint256 sharesMoved = bobCommittedAfter - bobCommittedBefore;

        assertGt(sharesMoved, 0, "transfer should move shares on second policy");
        assertEq(aliceCommittedBefore - aliceCommittedAfter, sharesMoved, "shares moved must balance");
    }

    function test_Holds_hold_exceedCommitted_reverts() public {
        // Arrange: Alice committed ~10 ether worth of shares
        uint256 committedShares = shMonad.balanceOfCommitted(policyID, alice);

        // Expect revert with exact encoded custom error (committed, requested)
        vm.prank(agent1);
        vm.expectRevert(
            abi.encodeWithSelector(
                HoldsLib.InsufficientCommittedForHold.selector,
                committedShares,
                committedShares + 1
            )
        );
        shMonad.hold(policyID, alice, committedShares + 1);
    }

    // Non-agent should not be able to place holds
    function test_Holds_onlyAgent_canHold() public {
        // Charlie is not an agent
        address charlie = makeAddr("charlie");
        vm.prank(charlie);
        vm.expectRevert(); // NotPolicyAgent
        shMonad.hold(policyID, alice, 1);
    }

    function test_Holds_batchHoldAndRelease_multipleAccounts() public {
        // Arrange
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2 ether;
        amounts[1] = 1 ether;

        // Act: batch hold
        vm.prank(agent1);
        shMonad.batchHold(policyID, accounts, amounts);

        // Assert holds applied
        assertEq(shMonad.getHoldAmount(policyID, alice), 2 ether, "alice hold should be 2 ether");
        assertEq(shMonad.getHoldAmount(policyID, bob), 1 ether, "bob hold should be 1 ether");

        // Act: batch release exact amounts
        vm.prank(agent1);
        shMonad.batchRelease(policyID, accounts, amounts);

        // Assert cleared
        assertEq(shMonad.getHoldAmount(policyID, alice), 0, "alice hold cleared");
        assertEq(shMonad.getHoldAmount(policyID, bob), 0, "bob hold cleared");
    }

    // ----------------------------- //
    //  Length mismatch (batch APIs) //
    // ----------------------------- //

    function test_Holds_batchHold_lengthMismatch_reverts() public {
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.prank(agent1);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.BatchHoldAccountAmountLengthMismatch.selector, 2, 1)
        );
        shMonad.batchHold(policyID, accounts, amounts);
    }

    function test_Holds_batchRelease_lengthMismatch_reverts() public {
        address[] memory accounts = new address[](1);
        accounts[0] = alice;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;

        vm.prank(agent1);
        vm.expectRevert(
            abi.encodeWithSelector(ShMonadErrors.BatchReleaseAccountAmountLengthMismatch.selector, 1, 2)
        );
        shMonad.batchRelease(policyID, accounts, amounts);
    }

    // ----------------------------- //
    //              Fuzz            //
    // ----------------------------- //

    function testFuzz_Holds_holdThenReleaseWithinCommitted(uint256 holdAmt) public {
        // Bound hold amount within Alice's committed shares
        uint256 committed = shMonad.balanceOfCommitted(policyID, alice);
        holdAmt = bound(holdAmt, 0, committed);

        // Act: hold and then full release
        vm.prank(agent1);
        shMonad.hold(policyID, alice, holdAmt);
        assertEq(shMonad.getHoldAmount(policyID, alice), holdAmt, "hold set");

        vm.prank(agent1);
        shMonad.release(policyID, alice, type(uint256).max);

        // Assert: back to zero
        assertEq(shMonad.getHoldAmount(policyID, alice), 0, "hold cleared");
    }

    // ----------------------------- //
    //            Helpers           //
    // ----------------------------- //

    function _depositAndCommit(address user, uint256 assets) internal {
        vm.startPrank(user);
        shMonad.depositAndCommit{ value: assets }(policyID, user, type(uint256).max);
        vm.stopPrank();
    }

    function _depositAndCommitPolicy(uint64 pId, address user, uint256 assets) internal {
        vm.startPrank(user);
        shMonad.depositAndCommit{ value: assets }(pId, user, type(uint256).max);
        vm.stopPrank();
    }
}
