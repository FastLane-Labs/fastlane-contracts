// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { VmSafe } from "forge-std/Vm.sol";

// Lib imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { MockProxyImplementation } from "./MockProxyImplementation.sol";
import { UpgradeUtils } from "../../../script/upgradeability/UpgradeUtils.sol";
import { AddressHub } from "../../../src/common/AddressHub.sol";
import { Directory } from "../../../src/common/Directory.sol";
import { ShMonad } from "../../../src/shmonad/ShMonad.sol";
import { UnbondingTask } from "../../../src/shmonad/tasks/UnbondingTask.sol";

contract SetupShMonad is Test {
    using UpgradeUtils for VmSafe;

    uint64 constant DEFAULT_SHMONAD_ESCROW_DURATION = 64;
    ShMonad shMonad; // The upgradeable proxy for ShMonad
    ProxyAdmin shMonadProxyAdmin; // The ProxyAdmin to control upgrades to ShMonad
    address shMonadImpl; // The current implementation of ShMonad
    
    /**
     * @notice Sets up the SHMONAD contract.
     * @dev This function upgrades the SHMONAD implementation and initializes it with the deployer address.
     * @param deployer The address of the deployer for proxy admin and shmonad owner.
     * @param proxyAdmin The address of the proxy admin for the SHMONAD contract.
     * @param addressHub The AddressHub contract instance.
     * @notice This function is used to upgrade the SHMONAD implementation to the latest version.
     */
    function __setUpShMonad(address deployer, address proxyAdmin, AddressHub addressHub) internal {
        __upgradeImplementationShMonad(deployer, proxyAdmin, addressHub);

        // set shmonad
        shMonad = ShMonad(addressHub.getAddressFromPointer(Directory._SHMONAD));

        // Label the shMonad proxy as ShMonad
        vm.label(address(shMonad), "ShMonad");
    }

    /**
     * @notice Deploys the SHMONAD proxy contract.
     * @dev This function deploys the SHMONAD proxy contract and initializes it with the deployer address.
     * @param deployer The address of the deployer.
     * @param addressHub The AddressHub contract instance.
     * @notice This function is used to deploy a vanilla proxy contract.
     */
    function __deployProxyShMonad(address deployer, AddressHub addressHub) internal {
        vm.startPrank(deployer);

        // Deploy a real temporary mock proxy implementation first to avoid initialization issues for other proxies (TaskManager, SponsoredExecutor, etc.)
        address tempImplementation = address(new MockProxyImplementation());

        // Empty data for now - we'll initialize during the upgrade
        bytes memory initCalldata = abi.encodeWithSignature(
            "initialize(address)",
            deployer
        );

        (TransparentUpgradeableProxy _proxy, ProxyAdmin _proxyAdmin) =
            VmSafe(vm).deployProxy(address(tempImplementation), deployer, initCalldata);

        // Use the proxy contract with the ShMonad interface
        shMonad = ShMonad(address(_proxy));
        shMonadProxyAdmin = _proxyAdmin;

        // Set shMonad address in AddressHub
        addressHub.addPointerAddress(Directory._SHMONAD, address(shMonad), "shMonad");

        vm.stopPrank();
    }

    /**
     * @notice Upgrades the SHMONAD implementation.
     * @dev This function upgrades the SHMONAD implementation and initializes it with the deployer address.
     * @param proxyAdmin The address of the proxy admin for the SHMONAD contract.
     * @param deployer The address of the deployer for proxy admin and shmonad owner.
     * @param addressHub The AddressHub contract instance.
     * @notice This function is used to upgrade the SHMONAD implementation.
     */
    function __upgradeImplementationShMonad(address deployer, address proxyAdmin, AddressHub addressHub) internal {
        // Check if we're on a fork and have access to the address

        address sponsorExecutor = addressHub.getAddressFromPointer(Directory._SPONSORED_EXECUTOR);
        address taskManager = addressHub.getAddressFromPointer(Directory._TASK_MANAGER);
        // Get actual ShMonad address from AddressHub
        address shMonadProxy = addressHub.getAddressFromPointer(Directory._SHMONAD);

        vm.startPrank(deployer);
        // Deploy UnbondingTask implementation
        address unbondingTask = address(new UnbondingTask(shMonadProxy));

        // Deploy ShMonad implementation
        shMonadImpl = address(new ShMonad(sponsorExecutor, taskManager, unbondingTask));        

        vm.stopPrank();
        // Initialize ShMonad with just the deployer address
        bytes memory initCalldata = abi.encodeWithSignature(
            "initialize(address)", 
            deployer
        );

        // Get proxy admin and upgrade
        shMonadProxyAdmin = ProxyAdmin(proxyAdmin);
        vm.startPrank(deployer);
        // Try to upgrade the proxy
        shMonadProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(shMonadProxy),
            shMonadImpl,
            initCalldata
        );
        
        vm.stopPrank();
    }
}
