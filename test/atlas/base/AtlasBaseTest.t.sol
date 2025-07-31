// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "../../base/BaseTest.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TestAtlas } from "../helpers/TestAtlas.sol";
import { TestAtlasVerification } from "../helpers/TestAtlasVerification.sol";
import { TestSimulator } from "../helpers/TestSimulator.sol";
import { MockERC20 } from "../helpers/MockERC20.sol";

/// @title AtlasBaseTest
/// @notice Base test contract for Atlas protocol tests, extending BaseTest for Monad fork
contract AtlasBaseTest is BaseTest {
    // Keep WETH/DAI naming for compatibility, but use Monad-appropriate names
    MockERC20 WETH; // Actually WMON (Wrapped Monad)
    MockERC20 DAI;  // Actually USDC
    address WETH_ADDRESS;
    address DAI_ADDRESS;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Deploy mock tokens for testing
        // Using Monad-native token names
        WETH = new MockERC20("Wrapped Monad", "WMON");
        DAI = new MockERC20("USD Coin", "USDC");
        
        WETH_ADDRESS = address(WETH);
        DAI_ADDRESS = address(DAI);
        
        // Label tokens for better debugging
        vm.label(WETH_ADDRESS, "WMON");
        vm.label(DAI_ADDRESS, "USDC");
    }
}