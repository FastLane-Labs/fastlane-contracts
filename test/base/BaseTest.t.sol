// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";

// Lib imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

// Protocol Setup imports (for fork mode)
import { SetupShMonad } from "./setup/SetupShMonad.t.sol";
// Protocol imports
import { AddressHub } from "../../src/common/AddressHub.sol";
import { Directory } from "../../src/common/Directory.sol";
import { ShMonad } from "../../src/shmonad/ShMonad.sol";
// Other imports
import { TestConstants } from "./TestConstants.sol";
import { UpgradeUtils } from "../../script/upgradeability/UpgradeUtils.sol";
import { JsonHelper } from "../../script/utils/JsonHelper.sol";

/**
 * @title BaseTest
 * @notice Base test contract that supports both local and fork modes
 */
contract BaseTest is
    SetupShMonad,
    TestConstants
{
    using UpgradeUtils for VmSafe;
    using JsonHelper for VmSafe;

    // Constants
    uint256 constant SCALE = 1e18;
    uint256 constant PAYMASTER_FEE = 100; // 1% fee

    // Test accounts
    address internal user = makeAddr("User");
    address internal deployer = TESTNET_FASTLANE_DEPLOYER;
    
    // Fork mode proxy admin addresses (prefix to avoid conflicts with Setup contracts)
    address internal forkShMonadProxyAdmin = TESTNET_SHMONAD_PROXY_ADMIN;
    address internal forkRpcPolicyProxyAdmin = TESTNET_RPC_POLICY_PROXY_ADMIN;

    // Core contracts
    AddressHub internal addressHub;
    ProxyAdmin internal addressHubProxyAdmin;
    address internal addressHubImpl;

    uint256 internal governancePK;
    address governanceEOA;

    // Network configuration
    string internal rpcUrl;
    uint256 internal forkBlock;
    bytes32 internal forkTxHash;
    bool internal useLocalMode;

    // Additional implementation addresses for local mode
    address internal unbondingTask;

    function setUp() public virtual {
        // Determine test mode
        _determineTestMode();

        if (useLocalMode) {
            _setUpLocally();
        } else {
            _setUpFork();
        }
        // Set up governance EOA
        (governanceEOA, governancePK) = makeAddrAndKey("governanceEOA");
    }

    function _determineTestMode() internal {
        // Check FOUNDRY_PROFILE first
        try vm.envString("FOUNDRY_PROFILE") returns (string memory profile) {
            if (keccak256(bytes(profile)) == keccak256(bytes("default")) ||
                keccak256(bytes(profile)) == keccak256(bytes("local"))) {
                useLocalMode = true;
                return;
            } else if (keccak256(bytes(profile)) == keccak256(bytes("fork")) ||
                       keccak256(bytes(profile)) == keccak256(bytes("ci"))) {
                // CI profile should run in fork mode with the RPC URL
                useLocalMode = false;
                return;
            }
        } catch {}
        
        // Default to local mode
        useLocalMode = true;
    }

    /**
     * @dev Setup for local mode - deploys everything fresh
     */
    function _setUpLocally() internal {
        vm.startPrank(deployer);
        vm.deal(deployer, 1000 ether);
        
        // Set base fee for local testing (required for TaskManager pricing)
        // TaskManager's estimateCost depends on block.basefee being non-zero
        vm.fee(1 gwei);
        
        // Deploy AddressHub
        __setUpAddressHub();

        // Deploy core contracts using their setup functions
        
        // Stage 1: Deploy proxies with mock implementations
        SetupShMonad.__setUpShMonad(deployer, address(0), addressHub, true);
        
        // Stage 2: Upgrade to real implementations (resolves circular dependencies)
        SetupShMonad.__upgradeShMonad(deployer, address(0), addressHub, true);
        
        // Get deployed contracts from AddressHub
        shMonad = ShMonad(payable(addressHub.getAddressFromPointer(Directory._SHMONAD)));
        
        vm.stopPrank();
    }

    /**
     * @dev Setup for fork mode - uses existing contracts and upgrades
     */
    function _setUpFork() internal {
        // Original fork setup
        try vm.envString("MONAD_TESTNET_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            revert("Fork mode requires MONAD_TESTNET_RPC_URL");
        }
        
        if (forkTxHash != bytes32(0)) {
            vm.createSelectFork(rpcUrl, forkTxHash);
        } else if (forkBlock != 0) {
            vm.createSelectFork(rpcUrl, forkBlock);
        } else {
            forkAtLastDeployOrDailyStart();
        }

        // Set consistent gas price for fork mode too
        vm.fee(1 gwei);

        // Deploy AddressHub and migrate pointers
        __setUpAddressHub();

        // Stage 1: Store references to existing proxies (fork mode)
        SetupShMonad.__setUpShMonad(deployer, forkShMonadProxyAdmin, addressHub, false);
        // Stage 2: Upgrade implementations to the latest version
        SetupShMonad.__upgradeShMonad(deployer, forkShMonadProxyAdmin, addressHub, false);
    }


    // Original fork setup functions
    function __setUpAddressHub() internal {
        // Deploy AddressHub implementation
        addressHubImpl = address(new AddressHub());

        TransparentUpgradeableProxy proxy;
        bytes memory initCalldata = abi.encodeWithSignature("initialize(address)", deployer);

        // Deploy AddressHub's Proxy contract
        (proxy, addressHubProxyAdmin) = VmSafe(vm).deployProxy(addressHubImpl, deployer, initCalldata);

        // Set addressHub var to the proxy
        addressHub = AddressHub(address(proxy));

        // No special handling needed here for local mode
        // The mocking will be done in individual test setups that need it

        // Verify deployer is owner
        require(addressHub.isOwner(deployer), "Deployer should be AddressHub owner");
        
        // Only migrate pointers in fork mode
        if (!useLocalMode) {
            __migratePointers();
        }
    }

    function __migratePointers() internal {
        AddressHub oldAddressHub = AddressHub(address(TESTNET_ADDRESS_HUB));

        address _rpcPolicy = oldAddressHub.getAddressFromPointer(Directory._RPC_POLICY);
        address _shmonad = oldAddressHub.getAddressFromPointer(Directory._SHMONAD);

        // Migrate pointers to new AddressHub
        vm.startPrank(deployer);
        addressHub.addPointerAddress(Directory._SHMONAD, _shmonad, "ShMonad");
        addressHub.addPointerAddress(Directory._RPC_POLICY, _rpcPolicy, "RpcPolicy");
        vm.stopPrank();
    }

    function forkAtLastDeployOrDailyStart() internal {
        uint256 lastDeployPlus1 = VmSafe(vm).getLastDeployBlock({isMainnet: false}) + 1;

        vm.createSelectFork(rpcUrl);
        uint256 head = block.number;

        // start of current 24 hr window
        uint256 dailyStart = head - (head % BLOCK_PIN_DURATION);
        forkBlock = dailyStart > lastDeployPlus1 ? dailyStart : lastDeployPlus1;

        vm.createSelectFork(rpcUrl, uint64(forkBlock));
    }

    /**
     * @dev Helper to skip tests that require forking
     */
    modifier skipIfLocal() {
        if (useLocalMode) {
            vm.skip(true);
        }
        _;
    }

    /**
     * @dev Helper to skip tests that require local setup
     */
    modifier skipIfFork() {
        if (!useLocalMode) {
            vm.skip(true);
        }
        _;
    }

    function _currentAtomicLiquidity() internal view returns (uint256 liq) {
        try shMonad.getCurrentLiquidity() returns (uint256 value) {
            liq = value;
        } catch {
            liq = 0;
        }
    }

    function _ensureAtomicLiquidity(uint256 minLiquidity, uint256 targetPercent, uint256 depositAmount) internal {
        uint256 currentLiquidity = _currentAtomicLiquidity();
        if (currentLiquidity >= minLiquidity) return;

        uint256 requiredDeposit = depositAmount;
        if (requiredDeposit == 0 && minLiquidity > currentLiquidity) {
            requiredDeposit = minLiquidity - currentLiquidity;
        }

        if (targetPercent > 0 || requiredDeposit > 0) {
            vm.startPrank(deployer);
            if (targetPercent > 0) shMonad.setPoolTargetLiquidityPercentage(targetPercent);
            if (requiredDeposit > 0) {
                if (deployer.balance < requiredDeposit) {
                    vm.deal(deployer, requiredDeposit);
                }
                shMonad.deposit{ value: requiredDeposit }(requiredDeposit, deployer);
            }
            vm.stopPrank();
        }

        _advanceMockEpoch();
        vm.prank(governanceEOA);
        shMonad.crank();

        require(_currentAtomicLiquidity() >= minLiquidity, "Atomic pool liquidity seeding failed");
    }
}

// ============================================
// Mock Contracts
// ============================================

// Mock implementation for circular dependencies
contract MockImpl is OwnableUpgradeable {
    function initialize(address owner) public reinitializer(1) {
        __Ownable_init(owner);
    }
}

// Mock EntryPoint implementation for local testing
contract MockEntryPoint {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
    
    // Add minimal functions needed by Paymaster
    function getUserOpHash(bytes memory) external pure returns (bytes32) {
        return keccak256("mock");
    }
    
    // Fallback to handle any other calls
    fallback() external payable {}
    receive() external payable {}
}
