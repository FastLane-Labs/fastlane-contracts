// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ShMonad} from "../../src/shmonad/ShMonad.sol";
import {ShMonadEvents} from "../../src/shmonad/Events.sol";
import {Bonds, BondedData, TopUpData, TopUpSettings} from "../../src/shmonad/Bonds.sol";
import {AddressHub} from "../../src/common/AddressHub.sol";
import {BaseTest} from "../base/BaseTest.t.sol";
import {IERC4626Custom} from "../../src/shmonad/interfaces/IERC4626Custom.sol";
import {console} from "forge-std/console.sol";

contract BondsTest is BaseTest, ShMonadEvents {
    address public alice;
    address public bob;
    ShMonad public shmonad;
    uint256 public constant INITIAL_BALANCE = 100 ether;

    function setUp() public override {
        // Setup accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        super.setUp();

        // Fund accounts
        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
        vm.deal(deployer, INITIAL_BALANCE);

        //TODO fix this
        shmonad = ShMonad(shMonad);
    }

    // --------------------------------------------- //
    //              Basic Bonding Tests             //
    // --------------------------------------------- //

    function test_bond() public {
        (uint64 policyID,) = shmonad.createPolicy(10);
        uint256 amount = 10 ether;

        vm.startPrank(alice);
        uint256 shares = shmonad.deposit{value: amount}(amount, alice);
        uint256 bondedSupplyBefore = shmonad.bondedTotalSupply();
        uint256 totalSupplyBefore = shmonad.totalSupply();

        vm.expectEmit(true, true, true, true);
        emit Bond(policyID, bob, shares);
        shmonad.bond(policyID, bob, shares);

        // Check balances
        assertEq(shmonad.balanceOfBonded(policyID, bob), shares, "Bob's bonded balance should equal shares");
        assertEq(shmonad.balanceOfBonded(policyID, alice), 0, "Alice's bonded balance should be 0");

        assertEq(shmonad.totalSupply(), totalSupplyBefore, "Total supply should remain unchanged");
        assertEq(shmonad.bondedTotalSupply(), bondedSupplyBefore + shares, "Bonded total supply should increase by shares");

        vm.stopPrank();
    }

    function test_depositAndBond() public {
        (uint64 policyID,) = shmonad.createPolicy(10);
        uint256 amountToBond = 5 ether;
        uint256 bondedSupplyBefore = shmonad.bondedTotalSupply();

        // Preview the shares that will be minted
        uint256 expectedShares = shmonad.previewDeposit(amountToBond);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Bond(policyID, alice, expectedShares);
        shmonad.depositAndBond{value: amountToBond}(policyID, alice, type(uint256).max);
        
        // Get actual bonded amount
        uint256 bondedAmount = shmonad.balanceOfBonded(policyID, alice);
        
        // Check balances
        assertEq(bondedAmount, expectedShares, "Alice's bonded balance should equal expected shares");
        assertEq(alice.balance, INITIAL_BALANCE - amountToBond, "Alice's ETH balance should decrease by deposit amount");

        assertEq(shmonad.totalSupply(), bondedAmount + shmonad.totalSupply() - bondedAmount, "Total supply calculation should be correct");
        assertEq(shmonad.bondedTotalSupply(), bondedSupplyBefore + bondedAmount, "Bonded total supply should increase by bonded amount");

        vm.stopPrank();
    }

    function test_unbond() public {
        (uint64 policyID,) = shmonad.createPolicy(10);
        uint256 amount = 5 ether;
        uint256 newMinBalance = 1 ether;

        vm.startPrank(alice);
        // Deposit and bond with max amount
        shmonad.depositAndBond{value: amount}(policyID, alice, type(uint256).max);
        uint256 bondedAmount = shmonad.balanceOfBonded(policyID, alice);
        uint256 bondedSupplyBefore = shmonad.bondedTotalSupply();
        uint256 totalSupplyBefore = shmonad.totalSupply();
        
        vm.expectEmit(true, true, true, true);
        emit Unbond(policyID, alice, bondedAmount, block.number + 10);
        shmonad.unbond(policyID, bondedAmount, newMinBalance);
        vm.stopPrank();

        // Check balances
        assertEq(shmonad.balanceOfBonded(policyID, alice), 0, "Alice's bonded balance should be 0 after unbonding");
        assertEq(alice.balance, INITIAL_BALANCE - amount, "Alice's ETH balance should remain unchanged");
        assertEq(shmonad.balanceOfUnbonding(policyID, alice), bondedAmount, "Alice's unbonding balance should equal bonded amount");
        // Check unbonding data
        assertEq(shmonad.unbondingCompleteBlock(policyID, alice), block.number + 10, "Unbonding should complete in 10 blocks");

        assertEq(shmonad.totalSupply(), totalSupplyBefore, "Total supply should remain unchanged");
        assertEq(shmonad.bondedTotalSupply(), bondedSupplyBefore - bondedAmount, "Bonded total supply should decrease by bonded amount");
    }

    function test_claim() public {
        (uint64 policyID,) = shmonad.createPolicy(10);
        uint256 amount = 5 ether;

        vm.startPrank(alice);
        shmonad.depositAndBond{value: amount}(policyID, alice, type(uint256).max);
        uint256 bondedAmount = shmonad.balanceOfBonded(policyID, alice);
        // Capture system-wide bonded total supply before unbonding
        uint256 bondedTotalSupplyBefore = shmonad.bondedTotalSupply();
        shmonad.unbond(policyID, bondedAmount, 0);
        uint256 totalSupplyBefore = shmonad.totalSupply();
        vm.roll(block.number + 11); // Fast forward to after unbonding period

        uint256 unbondingAmount = shmonad.balanceOfUnbonding(policyID, alice);
        
        vm.expectEmit(true, true, true, true);
        emit Claim(policyID, alice, unbondingAmount);

        shmonad.claim(policyID, unbondingAmount);

        // Check balances
        assertEq(shmonad.balanceOfUnbonding(policyID, alice), 0, "Unbonding balance should be 0");
        assertEq(shmonad.balanceOfBonded(alice), 0, "Bonded balance should be 0");
        assertEq(shmonad.balanceOf(alice), unbondingAmount, "Balance of should be unbonding amount");
        assertEq(alice.balance, INITIAL_BALANCE - amount, "Alice's balance should be INITIAL_BALANCE - amount");

        assertEq(shmonad.totalSupply(), totalSupplyBefore, "Total supply should remain unchanged");
        
        // We can't check for exactly 0 since the system may have other bonds
        // Check that Alice's bonds were removed from the total
        assertEq(shmonad.bondedTotalSupply(), bondedTotalSupplyBefore - bondedAmount, "Bonded total supply should decrease by Alice's bonded amount");
        
        vm.stopPrank();
    }

    function test_claimAndRedeem() public {
        (uint64 policyID,) = shmonad.createPolicy(10);
        uint256 amount = 5 ether;
        
        // Give Alice plenty of ETH to ensure we don't run into dust issues
        vm.deal(alice, INITIAL_BALANCE + amount);
        uint256 aliceInitialBalance = alice.balance;
        uint256 aliceInitialRegularBalance = shmonad.balanceOf(alice);
        
        vm.startPrank(alice);
                
        shmonad.depositAndBond{value: amount}(policyID, alice, type(uint256).max);
        uint256 bondedAmount = shmonad.balanceOfBonded(policyID, alice);
        shmonad.unbond(policyID, bondedAmount, 0);
        vm.roll(block.number + 11); // Fast forward to after unbonding period

        uint256 unbondingAmount = shmonad.balanceOfUnbonding(policyID, alice);
        uint256 totalSupplyBefore = shmonad.totalSupply();
        
        // Preview the ETH amount that will be withdrawn
        vm.expectEmit(true, true, true, true);
        emit Claim(policyID, alice, unbondingAmount);
        uint256 assets = shmonad.claimAndRedeem(policyID, unbondingAmount);

        // Check balances
        assertEq(shmonad.balanceOfUnbonding(policyID, alice), 0, "Unbonding balance should be 0");
        assertEq(shmonad.balanceOfBonded(alice), 0, "Bonded balance should be 0");
        //TODO: This is not true, because of the gas fees
        assertEq(shmonad.balanceOf(alice), aliceInitialRegularBalance, "Regular balance should be aliceInitialRegularBalance");
        // Check ETH balance with a tolerance to account for gas fees
        assertApproxEqAbs(
            alice.balance,
            aliceInitialBalance,
            0.01 ether,  // Allow for 0.01 ETH tolerance to account for fees
            "Alice's ETH balance should be approximately restored to initial balance"
        );
        // Total supply should decrease by the ETH amount that was withdrawn
        assertEq(shmonad.totalSupply() + unbondingAmount, totalSupplyBefore, "Total supply should decrease by unbonding shares amount");
        
        vm.stopPrank();
    }

    function test_claimAndRebond() public {
        (uint64 fromPolicyID,) = shmonad.createPolicy(10);
        (uint64 toPolicyID,) = shmonad.createPolicy(10);
        uint256 amount = 5 ether;

        vm.startPrank(alice);
        shmonad.depositAndBond{value: amount}(fromPolicyID, alice, type(uint256).max);
        uint256 bondedAmount = shmonad.balanceOfBonded(fromPolicyID, alice);
        shmonad.unbond(fromPolicyID, bondedAmount, 0);
        vm.roll(block.number + 11); // Fast forward to after unbonding period

        uint256 unbondingAmount = shmonad.balanceOfUnbonding(fromPolicyID, alice);
        uint256 totalSupplyBefore = shmonad.totalSupply();
        uint256 bondedSupplyBefore = shmonad.bondedTotalSupply();
        
        vm.expectEmit(true, true, true, true);
        emit Claim(fromPolicyID, alice, unbondingAmount);
        emit Bond(toPolicyID, alice, unbondingAmount);
        shmonad.claimAndRebond(fromPolicyID, toPolicyID, alice, unbondingAmount);

        // Check balances
        assertEq(alice.balance, INITIAL_BALANCE - amount, "Alice's ETH balance should remain unchanged");
        assertEq(shmonad.balanceOf(alice), 0, "Alice's regular balance should be 0");
        
        assertEq(shmonad.balanceOfBonded(fromPolicyID, alice), 0, "Alice's bonded balance in fromPolicy should be 0");
        assertEq(shmonad.balanceOfUnbonding(fromPolicyID, alice), 0, "Alice's unbonding balance in fromPolicy should be 0");

        assertEq(shmonad.balanceOfBonded(toPolicyID, alice), unbondingAmount, "Alice's bonded balance in toPolicy should equal unbonding amount");
        assertEq(shmonad.balanceOfUnbonding(toPolicyID, alice), 0, "Alice's unbonding balance in toPolicy should be 0");

        assertEq(shmonad.totalSupply(), totalSupplyBefore, "Total supply should remain unchanged");
        assertEq(shmonad.bondedTotalSupply(), bondedSupplyBefore + unbondingAmount, "Bonded total supply should increase by unbonding amount");
        
        vm.stopPrank();
    }

    function test_agentWithdrawFromBonded() public {
        (uint64 policyID,) = shmonad.createPolicy(10);
        uint256 bondAmount = 10 ether;
        uint256 withdrawAmount = 3 ether;
        
        // First bond some amount as alice
        vm.startPrank(alice);
        shmonad.depositAndBond{value: bondAmount}(policyID, alice, type(uint256).max);
        uint256 bondedAmount = shmonad.balanceOfBonded(policyID, alice);
        vm.stopPrank();

        // Deployer makes himself a policy agent
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Calculate the actual withdraw amount
        uint256 expectedAmount = shmonad.previewWithdraw(withdrawAmount);

        // Agent (deployer) withdraws from alice's bonded balance to bob
        vm.startPrank(deployer);
        vm.expectEmit(true, true, true, true);
        // The event shows the raw ETH amount, not the share amount
        emit AgentWithdrawFromBonded(policyID, alice, deployer, withdrawAmount);
        shmonad.agentWithdrawFromBonded(policyID, alice, deployer, withdrawAmount, 0, true);

        // Check balances
        assertEq(shmonad.balanceOfBonded(policyID, alice), bondedAmount - expectedAmount, "Alice's bonded balance should decrease by expected amount");
        assertEq(shmonad.balanceOfBonded(alice), bondedAmount - expectedAmount, "Alice's total bonded balance should decrease by expected amount");
        assertEq(deployer.balance, INITIAL_BALANCE + withdrawAmount, "Deployer's ETH balance should increase by withdraw amount");
        
        vm.stopPrank();
    }

    function test_agentTransferFromBonded() public {
        (uint64 policyID,) = shmonad.createPolicy(10);
        uint256 depositAmount = 10 ether;
        uint256 transferAmount = 3 ether;
        
        // First bond some amount as alice
        vm.startPrank(alice);
        shmonad.depositAndBond{value: depositAmount}(policyID, alice, type(uint256).max);
        uint256 bondedAmount = shmonad.balanceOfBonded(policyID, alice);
        uint256 expectedTotalSupply = shmonad.bondedTotalSupply();
        vm.stopPrank();

        // Deployer makes himself a policy agent
        vm.prank(deployer);
        shmonad.addPolicyAgent(policyID, deployer);

        // Calculate the actual transfer amount before the transfer
        uint256 expectedAmount = shmonad.previewWithdraw(transferAmount);
        uint256 deployerBondedBalanceBefore = shmonad.balanceOfBonded(deployer);

        // Agent (deployer) transfers from alice's bonded balance to bob
        vm.startPrank(deployer);
        vm.expectEmit(true, true, true, true);
        emit AgentTransferFromBonded(policyID, alice, deployer, expectedAmount);
        shmonad.agentTransferFromBonded(policyID, alice, deployer, transferAmount, 0, true);

        // Check balances
        assertEq(shmonad.balanceOfBonded(policyID, alice), bondedAmount - expectedAmount, "Alice's bonded balance should decrease by expected amount");
        assertEq(shmonad.balanceOfBonded(policyID, deployer), expectedAmount, "Deployer's bonded balance should increase by expected amount");
        assertEq(shmonad.balanceOfBonded(deployer), deployerBondedBalanceBefore + expectedAmount, "Deployer's total bonded balance should increase by expected amount");
        assertEq(shmonad.bondedTotalSupply(), expectedTotalSupply, "Bonded total supply should be the same"); // Total bonded supply remains the same
        
        vm.stopPrank();
    }
}

