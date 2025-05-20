// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {BaseTest} from "../base/BaseTest.t.sol";

import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AddressHub} from "../../src/common/AddressHub.sol";
import {Directory} from "../../src/common/Directory.sol";

import {MockUpgradedAddressHub} from "./mocks/MockUpgradedAddressHub.sol";

contract AddressHubTest is BaseTest {
    function setUp() public override {
        BaseTest.setUp();
    }

    function test_AddressHub_upgrade() public {
        assertEq(addressHub.isOwner(deployer), true);
        assertEq(addressHub.getAddressFromPointer(Directory._ATLAS), address(atlas));

        // Should revert if missing functions called
        vm.expectRevert();
        MockUpgradedAddressHub(address(addressHub)).newSpecialAddress();

        // Upgrade AddressHub to MockUpgradedAddressHub
        bytes memory initCalldata = abi.encodeCall(MockUpgradedAddressHub.initialize2, ());

        vm.startPrank(deployer);

        MockUpgradedAddressHub newAddressHub = new MockUpgradedAddressHub();

        addressHubProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(addressHub)),
            address(newAddressHub),
            initCalldata
        );

        vm.stopPrank();

        // Previous functions should still work
        assertEq(addressHub.isOwner(deployer), true);
        assertEq(addressHub.getAddressFromPointer(Directory._ATLAS), address(atlas));

        // New function on MockUpgradedAddressHub should also work now
        address expected = address(0x12345);
        assertEq(MockUpgradedAddressHub(address(addressHub)).newSpecialAddress(), expected);
    }
}
