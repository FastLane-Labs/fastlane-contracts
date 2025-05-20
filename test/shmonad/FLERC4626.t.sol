// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ShMonad} from "../../src/shmonad/ShMonad.sol";
import {ShMonadEvents} from "../../src/shmonad/Events.sol";
import {Bonds, BondedData, TopUpData, TopUpSettings} from "../../src/shmonad/Bonds.sol";
import {AddressHub} from "../../src/common/AddressHub.sol";
import {BaseTest} from "../base/BaseTest.t.sol";
import {IERC4626Custom} from "../../src/shmonad/interfaces/IERC4626Custom.sol";

contract FLERC4626Test is BaseTest, ShMonadEvents {
    using Math for uint256;

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
    //              ERC4626 Basic Tests             //
    // --------------------------------------------- //

    function test_boostYield_payable_emitsEvent() public {
        uint256 boostValue = 1 ether;
        uint256 initialContractBalance = address(shmonad).balance;

        vm.startPrank(alice);
        // Expect BoostYield(alice, boostValue)
        // Event: BoostYield(address indexed who, uint256 amount)
        // checkTopic1 for 'who', no other indexed topics, checkData for 'amount'
        vm.expectEmit(true, false, false, true, address(shmonad));
        emit BoostYield(alice, boostValue, false); // Expected event signature and parameters

        shmonad.boostYield{value: boostValue}();
        vm.stopPrank();

        assertEq(address(shmonad).balance, initialContractBalance + boostValue, "Contract balance should increase by boostValue");
    }

    function test_boostYield_burnShares_emitsEvent() public {
        uint256 depositAmount = 10 ether;
        uint256 sharesToBurn = 2 ether;

        // Alice deposits to get shares
        vm.deal(alice, depositAmount); // Fund Alice for deposit
        vm.startPrank(alice);
        uint256 sharesReceived = shmonad.deposit{value: depositAmount}(depositAmount, alice);
        // For the first depositor, shares received should equal assets deposited due to ERC4626 logic
        // and our _convertToShares with +1 logic for empty supply/assets.
        uint256 expectedSharesViaPreview = shmonad.previewDeposit(depositAmount);
        assertEq(sharesReceived, expectedSharesViaPreview, "Shares received should match public previewDeposit output");
        vm.stopPrank();

        uint256 contractBalanceAfterDeposit = address(shmonad).balance;
        uint256 totalSupplyBeforeBurn = shmonad.totalSupply();

        // Calculate the expected asset value for the BoostYield event.
        // With the updated boostYield(shares, from) logic where assets are calculated *before* the burn,
        // previewRedeem(sharesToBurn) should accurately reflect the value emitted in the event.
        uint256 expectedAssetValue = shmonad.previewRedeem(sharesToBurn);

        vm.startPrank(alice);
        // Expect BoostYield(alice, expectedAssetValue)
        vm.expectEmit(true, false, false, true, address(shmonad));
        emit BoostYield(alice, expectedAssetValue, true); // Expected event

        shmonad.boostYield(sharesToBurn, alice);
        vm.stopPrank();

        // Assertions
        assertEq(shmonad.balanceOf(alice), sharesReceived - sharesToBurn, "Alice's shares should be reduced");
        assertEq(shmonad.totalSupply(), totalSupplyBeforeBurn - sharesToBurn, "Total supply should be reduced");
        // The boostYield(shares, from) function does not itself change the contract's ETH balance.
        assertEq(address(shmonad).balance, contractBalanceAfterDeposit, "Contract ETH balance should remain unchanged by this type of boost");
    }
}

