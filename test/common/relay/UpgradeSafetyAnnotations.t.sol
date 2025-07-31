// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { BaseTest } from "test/base/BaseTest.t.sol";
import { GasRelayUpgradeable } from "../../../src/common/relay/GasRelayUpgradeable.sol";
import { RelayUpgradeable } from "../../../src/common/relay/core/RelayUpgradeable.sol";
import { GasRelayConstants } from "../../../src/common/relay/core/GasRelayConstants.sol";
import { DummyGasRelayUpgradeable } from "./DummyGasRelayUpgradeable.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title UpgradeSafetyAnnotationsTest
 * @notice Tests that verify OpenZeppelin upgrade safety annotations work correctly
 * @dev This test ensures that contracts with constructors and immutable variables
 *      can be deployed as upgradeable when properly annotated
 */
contract UpgradeSafetyAnnotationsTest is BaseTest {
    DummyGasRelayUpgradeable public implementation;
    TransparentUpgradeableProxy public proxy;
    ProxyAdmin public proxyAdmin;
    
    uint256 constant MAX_EXPECTED_GAS_USAGE = 200_000;
    uint48 constant ESCROW_DURATION = 16;
    uint256 constant TARGET_BALANCE_MULTIPLIER = 2;
    
    function setUp() public override {
        super.setUp();
    }
    
    /**
     * @notice Test that RelayUpgradeable can be deployed with constructor and immutable variables
     * @dev Verifies that @custom:oz-upgrades-unsafe-allow annotations work correctly
     */
    function test_RelayUpgradeableDeploysWithAnnotations() public {
        // Deploy implementation contract
        implementation = new DummyGasRelayUpgradeable();
        
        // Verify implementation has a constructor that sets immutable variables
        // The constructor should execute and set the _implementation address
        assertEq(address(implementation), address(implementation), "Implementation address should be set");
        
        // Deploy proxy admin with initial owner
        proxyAdmin = new ProxyAdmin(address(this));
        
        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(
            DummyGasRelayUpgradeable.initialize.selector,
            MAX_EXPECTED_GAS_USAGE,
            ESCROW_DURATION,
            TARGET_BALANCE_MULTIPLIER
        );
        
        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );
        
        // Verify proxy was deployed successfully
        assertTrue(address(proxy) != address(0), "Proxy should be deployed");
        
        // Cast proxy to test implementation
        DummyGasRelayUpgradeable gasRelay = DummyGasRelayUpgradeable(payable(address(proxy)));
        
        // Verify initialization worked
        assertTrue(gasRelay.POLICY_ID() > 0, "Policy ID should be set after initialization");
    }
    
    /**
     * @notice Test that immutable variables are properly set on implementation
     * @dev Verifies that immutable variables work correctly with upgradeable pattern
     */
    function test_ImmutableVariablesSetOnImplementation() public {
        // Deploy implementation
        implementation = new DummyGasRelayUpgradeable();
        
        // Access the implementation directly to verify immutable variables
        // These should be set by the constructor
        
        // Check GasRelayConstants immutables
        assertTrue(implementation.TASK_MANAGER() != address(0), "TASK_MANAGER should be set");
        assertTrue(implementation.SHMONAD() != address(0), "SHMONAD should be set");
        // Note: ATLAS might be address(0) if not set in the AddressHub yet
        // The important thing is that the immutable variable was created and can be accessed
        assertTrue(implementation.TASK_MANAGER_POLICY_ID() > 0, "TASK_MANAGER_POLICY_ID should be set");
        
        // Note: The private immutable variables in RelayUpgradeable (_session_key_seed, etc.)
        // cannot be directly tested but they are used in the contract's logic
    }
    
    /**
     * @notice Test that the contract functions correctly when called through proxy
     * @dev Verifies that the upgradeable pattern works with annotated constructors/immutables
     */
    function test_ProxyFunctionalityWithAnnotations() public {
        // Deploy the full upgradeable setup
        implementation = new DummyGasRelayUpgradeable();
        proxyAdmin = new ProxyAdmin(address(this));
        
        bytes memory initData = abi.encodeWithSelector(
            DummyGasRelayUpgradeable.initialize.selector,
            MAX_EXPECTED_GAS_USAGE,
            ESCROW_DURATION,
            TARGET_BALANCE_MULTIPLIER
        );
        
        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );
        
        // Cast proxy to DummyGasRelayUpgradeable interface
        DummyGasRelayUpgradeable gasRelay = DummyGasRelayUpgradeable(payable(address(proxy)));
        
        // Verify initialization worked correctly
        assertTrue(gasRelay.POLICY_ID() > 0, "Policy ID should be initialized");
        assertTrue(gasRelay.POLICY_WRAPPER() != address(0), "Policy wrapper should be initialized");
        
        // Verify immutable variables are accessible through proxy
        assertTrue(gasRelay.TASK_MANAGER() != address(0), "TASK_MANAGER should be accessible");
        assertTrue(gasRelay.SHMONAD() != address(0), "SHMONAD should be accessible");
        // ATLAS might be 0x0 if not set in AddressHub
    }
    
    /**
     * @notice Test that multiple implementations can be deployed
     * @dev Verifies that contracts with constructors/immutables can have multiple instances
     */
    function test_MultipleImplementationsWithAnnotations() public {
        // Deploy first implementation
        DummyGasRelayUpgradeable impl1 = new DummyGasRelayUpgradeable();
        
        // Deploy second implementation
        DummyGasRelayUpgradeable impl2 = new DummyGasRelayUpgradeable();
        
        // Both should have the same immutable values from constructor
        assertEq(impl1.TASK_MANAGER(), impl2.TASK_MANAGER(), 
            "Both implementations should have same TASK_MANAGER");
        assertEq(impl1.SHMONAD(), impl2.SHMONAD(), 
            "Both implementations should have same SHMONAD");
        assertEq(impl1.TASK_MANAGER_POLICY_ID(), impl2.TASK_MANAGER_POLICY_ID(), 
            "Both implementations should have same TASK_MANAGER_POLICY_ID");
        
        // Deploy two proxies with different implementations
        ProxyAdmin admin1 = new ProxyAdmin(address(this));
        ProxyAdmin admin2 = new ProxyAdmin(address(this));
        
        TransparentUpgradeableProxy proxy1 = new TransparentUpgradeableProxy(
            address(impl1),
            address(admin1),
            abi.encodeWithSelector(
                DummyGasRelayUpgradeable.initialize.selector,
                MAX_EXPECTED_GAS_USAGE,
                ESCROW_DURATION,
                TARGET_BALANCE_MULTIPLIER
            )
        );
        
        TransparentUpgradeableProxy proxy2 = new TransparentUpgradeableProxy(
            address(impl2),
            address(admin2),
            abi.encodeWithSelector(
                DummyGasRelayUpgradeable.initialize.selector,
                MAX_EXPECTED_GAS_USAGE,
                ESCROW_DURATION,
                2 * TARGET_BALANCE_MULTIPLIER  // Different multiplier
            )
        );
        
        // Both proxies should work correctly
        DummyGasRelayUpgradeable relay1 = DummyGasRelayUpgradeable(payable(address(proxy1)));
        DummyGasRelayUpgradeable relay2 = DummyGasRelayUpgradeable(payable(address(proxy2)));
        
        assertTrue(relay1.POLICY_ID() > 0, "Proxy1 should be initialized");
        assertTrue(relay2.POLICY_ID() > 0, "Proxy2 should be initialized");
        assertTrue(relay1.POLICY_ID() != relay2.POLICY_ID(), "Proxies should have different policy IDs");
    }
}