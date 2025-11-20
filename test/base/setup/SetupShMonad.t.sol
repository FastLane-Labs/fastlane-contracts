// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { VmSafe } from "forge-std/Vm.sol";

// Lib imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { MockProxyImplementation } from "../../common/mocks/MockProxyImplementation.sol";
import { UpgradeUtils } from "../../../script/upgradeability/UpgradeUtils.sol";
import { AddressHub } from "../../../src/common/AddressHub.sol";
import { Directory } from "../../../src/common/Directory.sol";
import { ShMonad } from "../../../src/shmonad/ShMonad.sol";
import { TestShMonad } from "../helpers/TestShMonad.sol";

import { MockMonadStakingPrecompile } from "../../../src/shmonad/mocks/MockMonadStakingPrecompile.sol";
import { MIN_VALIDATOR_DEPOSIT } from "../../../src/shmonad/Constants.sol";

contract SetupShMonad is Test {
    using UpgradeUtils for VmSafe;

    uint48 constant DEFAULT_SHMONAD_ESCROW_DURATION = 64;
    uint48 constant RPC_POLICY_ESCROW_DURATION = 20;
    
    ShMonad public shMonad; // The upgradeable proxy for ShMonad
    ProxyAdmin public shMonadProxyAdmin; // The ProxyAdmin to control upgrades to ShMonad
    address public shMonadImpl; // The current implementation of ShMonad

    // Precompile address for Monad staking onchain
    address internal constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000001000;
    MockMonadStakingPrecompile staking;
    
    // Policy IDs for downstream tests
    uint64 public taskManagerPolicyId;
    uint64 public rpcPolicyId;
    uint64 public paymasterPolicyId;
    
    /**
     * @notice Sets up the ShMonad proxy contract (does NOT upgrade).
     * @dev For local mode: deploys proxy with mock. For fork mode: just stores references.
     * @param deployer The address of the deployer.
     * @param proxyAdmin The address of the proxy admin (for fork mode).
     * @param addressHub The AddressHub contract instance.
     * @param isLocal Whether this is local or fork mode.
     */
    function __setUpShMonad(
        address deployer,
        address proxyAdmin,
        AddressHub addressHub,
        bool isLocal
    ) internal {
        // Deploy the mock precompile and etch its code to the precompile address
        MockMonadStakingPrecompile tempStakingMock = new MockMonadStakingPrecompile();
        vm.etch(STAKING_PRECOMPILE, address(tempStakingMock).code);
        vm.label(STAKING_PRECOMPILE, "MonadStakingPrecompile");

        // Make the Staking Contract Mock accessible in tests as `staking`
        staking = MockMonadStakingPrecompile(payable(STAKING_PRECOMPILE));

        // Immediately advance to epoch 6
        _advanceMockEpoch();
        _advanceMockEpoch();
        _advanceMockEpoch();
        _advanceMockEpoch();
        _advanceMockEpoch();
        _advanceMockEpoch();

        if (isLocal) {
            // Local mode: Deploy proxy with mock implementation
            __deployShMonadProxyWithMock(deployer, addressHub);
        } else {
            // Fork mode: Just store references to existing contracts
            shMonad = ShMonad(payable(addressHub.getAddressFromPointer(Directory._SHMONAD)));
            shMonadProxyAdmin = ProxyAdmin(proxyAdmin);
        }
        
        // Label for debugging
        vm.label(address(shMonad), "ShMonad");
    }
    
    /**
     * @notice Upgrades ShMonad to real implementation.
     * @dev Handles both local and fork modes. For local, also sets up policies.
     * @param deployer The address of the deployer.
     * @param proxyAdmin The address of the proxy admin (for fork mode, ignored in local).
     * @param addressHub The AddressHub contract instance.
     * @param isLocal Whether this is local or fork mode.
     */
    function __upgradeShMonad(
        address deployer,
        address proxyAdmin,
        AddressHub addressHub,
        bool isLocal
    ) internal {
        // Get dependencies from AddressHub
        address sponsorExecutor = addressHub.getAddressFromPointer(Directory._SPONSORED_EXECUTOR);
        address taskManager = addressHub.getAddressFromPointer(Directory._TASK_MANAGER);
        address shMonadProxy = addressHub.getAddressFromPointer(Directory._SHMONAD);
        
        // Deploy real ShMonad implementation with mock MonadStaking
        vm.startPrank(deployer);
        // Deploy ShMonad implementation
        shMonadImpl = address(new TestShMonad());

        // Initialize ShMonad with just the deployer address
        bytes memory initCalldata = abi.encodeWithSignature(
            "initialize(address)", 
            deployer
        );
        
        // Perform the upgrade
        if (isLocal) {
            // Local mode: use the ProxyAdmin we created
            require(address(shMonadProxyAdmin) != address(0), "ProxyAdmin not set for local mode");
        } else {
            // Fork mode: use the provided ProxyAdmin
            shMonadProxyAdmin = ProxyAdmin(proxyAdmin);
        }
        
        shMonadProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(shMonadProxy),
            shMonadImpl,
            initCalldata
        );
        vm.stopPrank();
        
        if (isLocal) {
            // Local mode gets a fresh deployment and manual policy wiring.
            __setupPoliciesAndAgents(deployer, addressHub, isLocal);
        } else {
            // Fork mode: inject a minimal validator set so accounting tests observe live staking behavior.
            _seedBaselineValidators(deployer, false);
            // Then normalize any residual queues from the upgrade snapshot.
            _normalizeForkShMonadState(deployer);
        }

        // Update reference to ensure we have the latest
        shMonad = ShMonad(payable(shMonadProxy));
    }

    function _normalizeForkShMonadState(address deployer) internal {
        vm.startPrank(deployer);
        for (uint256 i = 0; i < 4; ++i) {
            TestShMonad shMonadView = TestShMonad(payable(address(shMonad)));
            (uint128 queueToStakeCurr, uint128 queueForUnstakeCurr) = shMonadView.exposeGlobalAssetsCurrent();
            (uint128 queueToStakeLast, uint128 queueForUnstakeLast) = shMonadView.exposeGlobalAssetsLast();

            if (
                queueToStakeCurr == 0 && queueForUnstakeCurr == 0 && queueToStakeLast == 0
                    && queueForUnstakeLast == 0
            ) {
                break;
            }

            _advanceMockEpoch();
            while (!shMonad.crank()) {}
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Internal function to deploy proxy with mock implementation.
     * @dev Only used in local mode.
     */
    function __deployShMonadProxyWithMock(address deployer, AddressHub addressHub) private {
        // Deploy proxy with mock implementation
        address mockImpl = address(new MockProxyImplementation());
        bytes memory initData = abi.encodeWithSignature("initialize(address)", deployer);
        
        (TransparentUpgradeableProxy proxy, ProxyAdmin proxyAdmin) = 
            VmSafe(vm).deployProxy(mockImpl, deployer, initData);
        
        shMonad = ShMonad(payable(address(proxy)));
        shMonadProxyAdmin = proxyAdmin;
        
        // Add to AddressHub
        addressHub.addPointerAddress(Directory._SHMONAD, address(shMonad), "shMonad");
    }
    
    /**
     * @notice Sets up policies and agents for local mode.
     * @dev Creates policies for TaskManager and RpcPolicy, adds them as agents.
     */
    function __setupPoliciesAndAgents(address deployer, AddressHub addressHub, bool isLocal) private {
        address taskManager = addressHub.getAddressFromPointer(Directory._TASK_MANAGER);
        address rpcPolicyAddress = addressHub.getAddressFromPointer(Directory._RPC_POLICY);
        address paymasterAddress = addressHub.getAddressFromPointer(Directory._PAYMASTER_4337);

        // Need to prank as deployer for owner-only functions
        vm.startPrank(deployer);
        
        // Deposit initial MON to avoid division by zero
        uint256 initialDeposit = 1 ether;
        vm.deal(deployer, initialDeposit);

        shMonad.deposit{value: initialDeposit}(initialDeposit, deployer);

        // Create policy with ID 1 for TaskManager (64 blocks escrow)
        taskManagerPolicyId = shMonad.createPolicy(DEFAULT_SHMONAD_ESCROW_DURATION);
        require(taskManagerPolicyId == 1, "Policy ID should be 1 for TaskManager");

        // Add TaskManager as an agent for policy 1
        shMonad.addPolicyAgent(taskManagerPolicyId, taskManager);
        
        // Create policy with ID 2 for RpcPolicy (20 blocks escrow)
        rpcPolicyId = shMonad.createPolicy(RPC_POLICY_ESCROW_DURATION);
        require(rpcPolicyId == 2, "Policy ID should be 2 for RpcPolicy");
        
        // Add RpcPolicy as an agent for policy 2
        shMonad.addPolicyAgent(rpcPolicyId, rpcPolicyAddress);

        // Create policy with ID 3 for Paymaster (use default escrow duration)
        paymasterPolicyId = shMonad.createPolicy(DEFAULT_SHMONAD_ESCROW_DURATION);
        require(paymasterPolicyId == 3, "Policy ID should be 3 for Paymaster");

        // If Paymaster already registered in AddressHub, add as agent now; otherwise it will be added during its upgrade
        if (paymasterAddress != address(0)) {
            shMonad.addPolicyAgent(paymasterPolicyId, paymasterAddress);
        }

        _seedBaselineValidators(deployer, isLocal);

        vm.stopPrank();
    }

    /// @dev Mirrors the precompile's epoch roll logic so activation and withdrawals progress.
    function _advanceMockEpoch() internal {
        vm.roll(block.number + 50_000);
        staking.harnessSyscallOnEpochChange(false);
    }

    function _seedBaselineValidators(address deployer, bool isLocal) internal {
        TestShMonad shMonadView = TestShMonad(payable(address(shMonad)));
        (uint128 stakedAmount,) = shMonadView.exposeGlobalCapitalRaw();
        if (isLocal && stakedAmount > 0) {
            return;
        }

        string memory labelPrefix = isLocal ? "LocalValidator" : "ForkValidator";
        address sentinelValidator = makeAddr(string.concat(labelPrefix, "_0"));
        if (shMonad.getValidatorIdForCoinbase(sentinelValidator) != 0) {
            staking.harnessSyscallOnEpochChange(false);
            while (!shMonad.crank()) {}
            return;
        }

        uint256 validatorCount = 4;

        vm.stopPrank();
        for (uint64 i = 0; i < validatorCount; ++i) {
            string memory label = string.concat(labelPrefix, "_", vm.toString(i));
            address validator = makeAddr(label);

            uint64 validatorId = staking.harnessValidatorId(validator);
            bool validatorNewlyRegistered = validatorId == 0;
            if (validatorNewlyRegistered) {
                validatorId = staking.registerValidator(validator);
            }

            vm.startPrank(deployer);
            bool validatorAlreadyLinked = shMonad.getValidatorIdForCoinbase(validator) != 0;
            if (!validatorAlreadyLinked) {
                shMonad.addValidator(validatorId, validator);
            }
            vm.stopPrank();

            vm.label(validator, label);
            staking.harnessEnsureDelegator(validatorId, address(shMonad));

            (uint256 stake,, , , , ,) = staking.getDelegator(validatorId, address(shMonad));
            if (stake == 0) {
                vm.deal(validator, MIN_VALIDATOR_DEPOSIT);
                vm.startPrank(validator);
                staking.delegate{ value: MIN_VALIDATOR_DEPOSIT }(validatorId);
                vm.stopPrank();
            }
        }

        vm.startPrank(deployer);
        staking.harnessSyscallOnEpochChange(false);
        while (!shMonad.crank()) {}
    }
}
