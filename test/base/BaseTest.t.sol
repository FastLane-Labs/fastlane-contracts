// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";
// Lib imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

// Protocol Setup imports
import { SetupAtlas } from "./setup/SetupAtlas.t.sol";
import { SetupTaskManager } from "./setup/SetupTaskManager.t.sol";
import { SetupShMonad } from "./setup/SetupShMonad.t.sol";
import { SetupPaymaster } from "./setup/SetupPaymaster.t.sol";

// Other local imports
import { TestConstants } from "./TestConstants.sol";
import { AddressHub } from "../../src/common/AddressHub.sol";
import { Linked } from "../../src/common/Linked.sol";
import { Directory } from "../../src/common/Directory.sol";
import { UpgradeUtils } from "../../script/upgradeability/UpgradeUtils.sol";
import { SponsoredExecutor } from "../../src/common/SponsoredExecutor.sol";

contract BaseTest is
    SetupAtlas,
    SetupTaskManager,
    SetupShMonad,
    SetupPaymaster,
    TestConstants
{
    using UpgradeUtils for VmSafe;

    uint256 constant SCALE = 1e18;
    address internal user = makeAddr("User");
    address deployer = TESTNET_FASTLANE_DEPLOYER; // owner of the shMonad, taskManager, paymaster, etc
    address _shMonadProxyAdmin = TESTNET_SHMONAD_PROXY_ADMIN;
    address _taskManagerProxyAdmin = TESTNET_TASK_MANAGER_PROXY_ADMIN;
    address _paymasterProxyAdmin = TESTNET_PAYMASTER_PROXY_ADMIN;
    address _rpcPolicyProxyAdmin = TESTNET_RPC_POLICY_PROXY_ADMIN;

    // The upgradable proxy of the AddressHub
    AddressHub internal addressHub;
    ProxyAdmin internal addressHubProxyAdmin;
    address internal addressHubImpl;
    address internal networkEntryPointV07Address = MONAD_TESTNET_ENTRY_POINT_V07;
    address internal networkEntryPointV08Address = MONAD_TESTNET_ENTRY_POINT_V08;

    // Network configuration
    string internal networkRpcUrl = "MONAD_TESTNET_RPC_URL";
    uint256 internal forkBlock = MONAD_TESTNET_FORK_BLOCK;
    bool internal isMonad = true;

    function setUp() public virtual {
        _configureNetwork();

        if (forkBlock != 0) {
            vm.createSelectFork(vm.envString(networkRpcUrl), forkBlock);
        } else {
            vm.createSelectFork(vm.envString(networkRpcUrl));
        }

        // Deploy AddressHub and migrate pointers
        __setUpAddressHub();

        // if (isMainnet) {
        //     SetupClearingHouse.__setUpClearingHouse(deployer, addressHub);
        // }

        // Upgrade implementations to the latest version
        SetupShMonad.__setUpShMonad(deployer, _shMonadProxyAdmin, addressHub);
        SetupTaskManager.__setUpTaskManager(deployer, _taskManagerProxyAdmin, addressHub);
        SetupAtlas.__setUpAtlas(deployer, addressHub, shMonad, address(taskManager)); // Needs to be after shMonad and taskManager are set up
        SetupPaymaster.__setUpPaymaster(
            deployer,
            _paymasterProxyAdmin,
            networkEntryPointV07Address,
            networkEntryPointV08Address,
            addressHub
        );
    }

    // Virtual function to configure network - can be overridden by test contracts
    function _configureNetwork() internal virtual {
        // Default configuration is mainnet
        networkRpcUrl = "MONAD_TESTNET_RPC_URL";
        forkBlock = 0; // 0 means latest block
        isMonad = true;
    }

    // Uses cheatcodes to deploy AddressHub at preset address, and modifies storage to make deployer an owner.
    function __setUpAddressHub() internal {
        // Deploy AddressHub implementation
        addressHubImpl = address(new AddressHub());

        TransparentUpgradeableProxy proxy;
        bytes memory initCalldata = abi.encodeWithSignature("initialize(address)", deployer);

        // Deploy AddressHub's Proxy contract
        (proxy, addressHubProxyAdmin) = VmSafe(vm).deployProxy(addressHubImpl, deployer, initCalldata);

        // Set addressHub var to the proxy
        addressHub = AddressHub(address(proxy));

        // Verify deployer is owner
        require(addressHub.isOwner(deployer), "Deployer should be AddressHub owner");
        __migratePointers();
    }

    // Migrates pointers to new AddressHub
    function __migratePointers() internal {
        AddressHub oldAddressHub = AddressHub(address(TESTNET_ADDRESS_HUB));

        address _taskManager = oldAddressHub.getAddressFromPointer(Directory._TASK_MANAGER);
        address _paymaster = oldAddressHub.getAddressFromPointer(Directory._PAYMASTER_4337);
        address _rpcPolicy = oldAddressHub.getAddressFromPointer(Directory._RPC_POLICY);
        address _shmonad = oldAddressHub.getAddressFromPointer(Directory._SHMONAD);

        // Migrate pointers to new AddressHub
        vm.startPrank(deployer);
        addressHub.addPointerAddress(Directory._SHMONAD, _shmonad, "ShMonad");
        addressHub.addPointerAddress(Directory._TASK_MANAGER, _taskManager, "TaskManager");
        addressHub.addPointerAddress(Directory._PAYMASTER_4337, _paymaster, "Paymaster");
        addressHub.addPointerAddress(Directory._RPC_POLICY, _rpcPolicy, "RpcPolicy");
        vm.stopPrank();
    }
}
