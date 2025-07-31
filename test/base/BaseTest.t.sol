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
import { JsonHelper } from "../../script/utils/JsonHelper.sol";
import { SponsoredExecutor } from "../../src/common/SponsoredExecutor.sol";
import { UserOperation } from "../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../src/atlas/types/SolverOperation.sol";

contract BaseTest is
    SetupAtlas,
    SetupTaskManager,
    SetupShMonad,
    SetupPaymaster,
    TestConstants
{
    using UpgradeUtils for VmSafe;
    using JsonHelper for VmSafe;

    uint256 constant SCALE = 1e18;
    address internal user = makeAddr("User");
    address deployer = TESTNET_FASTLANE_DEPLOYER; // owner of the shMonad, taskManager, paymaster, etc
    address _shMonadProxyAdmin = TESTNET_SHMONAD_PROXY_ADMIN;
    address _taskManagerProxyAdmin = TESTNET_TASK_MANAGER_PROXY_ADMIN;
    address _paymasterProxyAdmin = TESTNET_PAYMASTER_PROXY_ADMIN;

    // The upgradable proxy of the AddressHub
    AddressHub internal addressHub;
    ProxyAdmin internal addressHubProxyAdmin;
    address internal addressHubImpl;
    address internal networkEntryPointV07Address = MONAD_TESTNET_ENTRY_POINT_V07;
    address internal networkEntryPointV08Address = MONAD_TESTNET_ENTRY_POINT_V08;

    // Network configuration
    string internal rpcUrl = vm.envString("MONAD_TESTNET_RPC_URL");
    uint256 internal forkBlock;
    bytes32 internal forkTxHash; // NEW: Support forking from transaction hash

    function setUp() public virtual {

        // Set up the environment - Enhanced fork logic
        if (forkTxHash != bytes32(0)) {
            // Priority 1: Fork from specific transaction hash if set
            vm.createSelectFork(rpcUrl, forkTxHash);
        } else if (forkBlock != 0) {
            // Priority 2: If forkBlock set to a specific block number, attempt to fork at that block
            vm.createSelectFork(rpcUrl, forkBlock);
        } else {
            // Priority 3: Otherwise (indicated by forkBlock == 0) use daily block update strategy
            forkAtLastDeployOrDailyStart();
        }

        // Deploy AddressHub and migrate pointers
        __setUpAddressHub();

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

    function forkAtLastDeployOrDailyStart() internal {
        uint256 lastDeployPlus1 = VmSafe(vm).getLastDeployBlock({isMainnet: false}) + 1;

        vm.createSelectFork(rpcUrl);
        uint256 head = block.number;

         // start of current 24 hr window
        uint256 dailyStart = head - (head % BLOCKS_PER_DAY);
        forkBlock = dailyStart > lastDeployPlus1 ? dailyStart : lastDeployPlus1;

        vm.createSelectFork(rpcUrl, uint64(forkBlock));
    }
}
