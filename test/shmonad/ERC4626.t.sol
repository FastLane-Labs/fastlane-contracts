// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ShMonad} from "../../src/shmonad/ShMonad.sol";
import {AddressHub} from "../../src/common/AddressHub.sol";
import {BaseTest} from "../base/BaseTest.t.sol";

contract ShMonadERC4626Test is BaseTest {
    ShMonad public shmonad;
    address public alice;
    address public bob;

    uint256 public constant INITIAL_BALANCE = 100 ether;

    function setUp() public override {
        // Setup accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        super.setUp();
        // Fund accounts
        // vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
    }

    // --------------------------------------------- //
    //              ERC4626 Basic Tests             //
    // --------------------------------------------- //

    function test_deposit() public {
        uint256 amount = 10 ether;

        uint256 aliceUnderlyingAmount = amount;
        
        vm.deal(alice, aliceUnderlyingAmount);

        vm.startPrank(alice);

        uint256 alicePreDepositBal = alice.balance;

        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 totalAssetsBefore = shMonad.totalAssets();
        uint256 previewDepositShares = shMonad.previewDeposit(aliceUnderlyingAmount);

        // Deposit
        uint256 aliceShareAmount = shMonad.deposit{value: aliceUnderlyingAmount}(aliceUnderlyingAmount, alice);

        // Assertions
        assertApproxEqAbs(shMonad.previewRedeem(aliceShareAmount), aliceUnderlyingAmount, 0.000000000000000001 ether, "Alice redeem share amount doesn't match underlying amount");
        assertEq(previewDepositShares, aliceShareAmount, "Alice should have received previewDepositShares amount of shares");
        assertEq(shMonad.totalSupply(), totalSupplyBefore + aliceShareAmount, "Total supply doesn't match share amount");
        assertEq(shMonad.totalAssets(), totalAssetsBefore + aliceUnderlyingAmount, "Total assets doesn't match underlying amount");
        assertEq(shMonad.balanceOf(alice), aliceShareAmount, "Alice balance doesn't match share amount");
        assertApproxEqAbs(shMonad.convertToAssets(aliceShareAmount), aliceUnderlyingAmount, 0.000000000000000001 ether, "Alice balance doesn't match underlying amount");
        assertEq(alice.balance, alicePreDepositBal - aliceUnderlyingAmount, "Alice balance doesn't match pre-deposit balance minus underlying amount");
    }

    function test_mint() public {
        uint256 amount = 11 ether; // with some buffer for gas fees
        uint256 aliceShareToMint = 10 ether;

        vm.deal(alice, amount);

        // record the initial state since shMonad has existing state
        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 totalAssetsBefore = shMonad.totalAssets();

        vm.startPrank(alice);
        uint256 alicePreDepositBal = alice.balance;

        // previewMint to the required value to satisfy the mint request
        uint256 requiredUnderlyingAmount = shMonad.previewMint(aliceShareToMint);
        uint256 aliceUnderlyingAmount = shMonad.mint{value: requiredUnderlyingAmount}(aliceShareToMint, alice);

        // Assertions
        assertApproxEqAbs(shMonad.previewWithdraw(aliceUnderlyingAmount), aliceShareToMint, 0.000000000000000001 ether, "previewWithdraw should return correct share amount for assets");
        assertApproxEqAbs(shMonad.previewDeposit(aliceUnderlyingAmount), aliceShareToMint, 0.000000000000000001 ether, "previewDeposit should return correct share amount for assets");
        assertEq(shMonad.totalSupply(), totalSupplyBefore + aliceShareToMint, "Total supply should equal minted shares");
        assertEq(shMonad.totalAssets(), totalAssetsBefore + aliceUnderlyingAmount, "Total assets should equal deposited amount");
        assertEq(shMonad.balanceOf(alice), aliceShareToMint, "Alice's share balance should equal minted shares");
        assertApproxEqAbs(shMonad.convertToAssets(shMonad.balanceOf(alice)), aliceUnderlyingAmount, 0.000000000000000001 ether, "Converting Alice's shares to assets should equal original assets");
        assertEq(alice.balance, alicePreDepositBal - aliceUnderlyingAmount, "Alice's ETH balance should decrease by deposited amount");

        // Add assertion to check previewRedeem specifically
        assertApproxEqAbs(shMonad.previewRedeem(aliceShareToMint), aliceUnderlyingAmount, 0.000000000000000001 ether, "previewRedeem should return original assets amount for shares");
        
        // redeem the minted shares
        uint256 redeemedAssets = shMonad.redeem(shMonad.balanceOf(alice), alice, alice);
        assertApproxEqAbs(redeemedAssets, aliceUnderlyingAmount, 0.000000000000000001 ether, "Redeemed assets should equal original deposit");

        assertApproxEqAbs(shMonad.totalAssets(), totalAssetsBefore, 0.000000000000000001 ether, "Total assets should be 0 after full redemption");
        assertEq(shMonad.balanceOf(alice), 0, "Alice's share balance should be 0 after full redemption");
        assertApproxEqAbs(shMonad.convertToAssets(shMonad.balanceOf(alice)), 0, 0.000000000000000001 ether, "Converted assets should be 0 after full redemption");
        assertApproxEqAbs(alice.balance, alicePreDepositBal, 0.000000000000000001 ether, "Alice's ETH balance should be restored to original amount");
    }

    function test_depositUsingPreviewMintAmount() public {
        uint256 shMonAmount = 1010003000000000;
        
        uint256 requiredUnderlyingAmount = shMonad.previewMint(shMonAmount);
        vm.deal(alice, requiredUnderlyingAmount);

        vm.startPrank(alice);
        uint256 alicePreDepositBal = alice.balance;
        uint256 aliceShareAmount = shMonad.deposit{value: requiredUnderlyingAmount}(requiredUnderlyingAmount, alice);

        assertEq(aliceShareAmount, shMonAmount, "Alice should have received the exact amount of shares");
    }
}
