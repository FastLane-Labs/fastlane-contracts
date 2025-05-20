// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { MockProxyImplementation } from "./MockProxyImplementation.sol";
import { UpgradeUtils } from "../../../script/upgradeability/UpgradeUtils.sol";
import { Paymaster } from "../../../src/paymaster/Paymaster.sol";
import { EntryPoint as EntryPointV7 } from "account-abstraction-v7/contracts/core/EntryPoint.sol";
import { EntryPoint as EntryPointV8 } from "account-abstraction-v8/contracts/core/EntryPoint.sol";
import { SenderCreator } from "account-abstraction-v8/contracts/core/SenderCreator.sol";
import { IShMonad } from "../../../src/shmonad/interfaces/IShMonad.sol";
import { AddressHub } from "../../../src/common/AddressHub.sol";
import { Directory } from "../../../src/common/Directory.sol";
import { TestConstants } from "../TestConstants.sol";
import { TaskManagerEntrypoint } from "../../../src/task-manager/core/Entrypoint.sol";

contract SetupPaymaster is Test {
    using UpgradeUtils for VmSafe;

    Paymaster public paymaster; // The upgradeable proxy for Paymaster
    ProxyAdmin public paymasterProxyAdmin; // The ProxyAdmin to control upgrades to Paymaster
    address public paymasterImpl; // The current implementation of Paymaster
    EntryPointV7 public entryPointV7;
    EntryPointV8 public entryPointV8;
    address public paymasterOwner;

    function __setUpPaymaster(
        address deployer,
        address proxyAdminAddress,
        address entryPointAddressV7,
        address entryPointAddressV8,
        AddressHub addressHub
    )
        internal
    {
        // First deploy EntryPoint at specific address
        __setupEntryPoint(entryPointAddressV7, entryPointAddressV8);

        // Then deploy implementation and upgrade the proxy
        __upgradeImplementationPaymaster(deployer, proxyAdminAddress, addressHub);
    }

    function __setupEntryPoint(address entryPointAddressV7, address entryPointAddressV8) internal {
        // Deploy EntryPoint at specific address
        EntryPointV7 originalEntryPointV7 = new EntryPointV7();
        EntryPointV8 originalEntryPointV8 = new EntryPointV8();
        address targetAddressV7 = entryPointAddressV7;
        address targetAddressV8 = entryPointAddressV8;
        vm.etch(targetAddressV7, address(originalEntryPointV7).code);
        vm.etch(targetAddressV8, address(originalEntryPointV8).code);
        entryPointV7 = EntryPointV7(payable(targetAddressV7));
        entryPointV8 = EntryPointV8(payable(targetAddressV8));

        // Ep v8 creates SenderCreator during deployment
        // SenderCreator functions can only be called by the EntryPoint
        // Considering above pattern, we need to mock SenderCreator.createSender
        vm.prank(targetAddressV8);
        SenderCreator senderCreatorV8 = new SenderCreator();

        vm.mockFunction(
            address(entryPointV8.senderCreator()),
            address(senderCreatorV8),
            abi.encodeWithSelector(SenderCreator.createSender.selector)
        );
    }

    function __deployProxyPaymaster(address deployer, AddressHub addressHub) internal {
        vm.startPrank(deployer);

        // Deploy a real temporary implementation first
        address tempImplementation = address(new MockProxyImplementation());

        bytes memory initCalldata = abi.encodeWithSignature("initialize(address)", deployer);

        (TransparentUpgradeableProxy _proxy, ProxyAdmin _proxyAdmin) =
            VmSafe(vm).deployProxy(address(tempImplementation), deployer, initCalldata);

        // Use the proxy contract with the Paymaster interface
        paymaster = Paymaster(payable(address(_proxy)));
        paymasterProxyAdmin = _proxyAdmin;

        // Add paymaster to AddressHub
        addressHub.addPointerAddress(Directory._PAYMASTER_4337, address(paymaster), "Paymaster");

        vm.stopPrank();
        vm.label(address(paymaster), "Paymaster");
    }

    function __upgradeImplementationPaymaster(
        address deployer,
        address proxyAdminAddress,
        AddressHub addressHub
    )
        internal
    {
        vm.deal(deployer, 100 ether);

        // Get addresses from AddressHub
        IShMonad shMonad = IShMonad(addressHub.getAddressFromPointer(Directory._SHMONAD));
        address taskManager = addressHub.getAddressFromPointer(Directory._TASK_MANAGER);
        paymaster = Paymaster(payable(addressHub.getAddressFromPointer(Directory._PAYMASTER_4337)));

        // Get policy ID from Paymaster
        uint64 policyId = paymaster.POLICY_ID();
        require(policyId != 0, "Paymaster policy ID is 0");

        // Deploy Paymaster Implementation
        vm.startPrank(deployer);
        paymasterImpl = address(
            new Paymaster(
                address(shMonad), address(taskManager), address(entryPointV7), address(entryPointV8), 10, policyId
            )
        );
        require(paymasterImpl != address(0), "Paymaster implementation address is 0");

        bytes memory paymasterInitCalldata = abi.encodeWithSignature("initialize(address)", deployer);

        paymasterProxyAdmin = ProxyAdmin(proxyAdminAddress);
        // Upgrade the proxy to the new implementation
        paymasterProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(paymaster)), paymasterImpl, paymasterInitCalldata
        );
        // Deposit initial funds
        paymaster.deposit{ value: 9.9 ether }(address(entryPointV7));
        paymaster.deposit{ value: 9.9 ether }(address(entryPointV8));
        paymasterOwner = deployer;
        vm.stopPrank();
    }
}
