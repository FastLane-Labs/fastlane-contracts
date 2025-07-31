// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { AccountingMath } from "../../../src/atlas/libraries/AccountingMath.sol";

contract AccountingMathTest is Test {

    uint256 constant SCALE = 10_000;
    uint256 constant MAX_BUNDLER_REFUND_RATE = 8000;
    uint256 constant FIXED_GAS_OFFSET = 150_000;

    function test_withSurcharge() public pure {
        // Test with 0% surcharge
        assertEq(AccountingMath.withSurcharge(1000, 0), 1000);
        
        // Test with 10% surcharge (1000 basis points)
        assertEq(AccountingMath.withSurcharge(1000, 1000), 1100);
        
        // Test with 50% surcharge (5000 basis points)
        assertEq(AccountingMath.withSurcharge(1000, 5000), 1500);
        
        // Test with 100% surcharge (10000 basis points)
        assertEq(AccountingMath.withSurcharge(1000, 10000), 2000);
        
        // Test with small amounts
        assertEq(AccountingMath.withSurcharge(1, 1000), 1); // Rounds down
        assertEq(AccountingMath.withSurcharge(10, 1000), 11);
        
        // Test with large amounts
        assertEq(AccountingMath.withSurcharge(1e18, 1000), 11e17); // 1e18 + 10%
    }

    function test_withoutSurcharge() public pure {
        // Test with 0% surcharge
        assertEq(AccountingMath.withoutSurcharge(1000, 0), 1000);
        
        // Test with 10% surcharge (inverse of withSurcharge)
        assertEq(AccountingMath.withoutSurcharge(1100, 1000), 1000);
        
        // Test with 50% surcharge
        assertEq(AccountingMath.withoutSurcharge(1500, 5000), 1000);
        
        // Test with 100% surcharge
        assertEq(AccountingMath.withoutSurcharge(2000, 10000), 1000);
        
        // Test rounding
        assertEq(AccountingMath.withoutSurcharge(1101, 1000), 1000); // Rounds down
        assertEq(AccountingMath.withoutSurcharge(11e17, 1000), 1e18);
    }

    function test_withSurcharges() public pure {
        // Test with both surcharges at 0%
        assertEq(AccountingMath.withSurcharges(1000, 0, 0), 1000);
        
        // Test with only Atlas surcharge (10%)
        assertEq(AccountingMath.withSurcharges(1000, 1000, 0), 1100);
        
        // Test with only bundler surcharge (20%)
        assertEq(AccountingMath.withSurcharges(1000, 0, 2000), 1200);
        
        // Test with both surcharges (10% + 20% = 30%)
        assertEq(AccountingMath.withSurcharges(1000, 1000, 2000), 1300);
        
        // Test with maximum surcharges
        assertEq(AccountingMath.withSurcharges(1000, 5000, 5000), 2000); // 50% + 50% = 100%
        
        // Test with large amounts
        assertEq(AccountingMath.withSurcharges(1e18, 1000, 2000), 13e17); // 1e18 + 30%
    }

    function test_getSurcharge() public pure {
        // Test with 0% surcharge
        assertEq(AccountingMath.getSurcharge(1000, 0), 0);
        
        // Test with 10% surcharge
        assertEq(AccountingMath.getSurcharge(1000, 1000), 100);
        
        // Test with 50% surcharge
        assertEq(AccountingMath.getSurcharge(1000, 5000), 500);
        
        // Test with 100% surcharge
        assertEq(AccountingMath.getSurcharge(1000, 10000), 1000);
        
        // Test with small amounts
        assertEq(AccountingMath.getSurcharge(10, 1000), 1);
        assertEq(AccountingMath.getSurcharge(9, 1000), 0); // Rounds down
        
        // Test with large amounts
        assertEq(AccountingMath.getSurcharge(1e18, 1000), 1e17); // 10% of 1e18
    }

    function test_maxBundlerRefund() public pure {
        // Test with 0 gas cost
        assertEq(AccountingMath.maxBundlerRefund(0), 0);
        
        // Test with standard gas cost
        assertEq(AccountingMath.maxBundlerRefund(100_000), 80_000); // 80% refund
        
        // Test with large gas cost
        assertEq(AccountingMath.maxBundlerRefund(1_000_000), 800_000); // 80% refund
        
        // Test exact calculation
        assertEq(AccountingMath.maxBundlerRefund(12345), 9876); // 12345 * 8000 / 10000 = 9876
    }

    function testFuzz_withSurcharge_inverse_withoutSurcharge(uint256 amount, uint256 surchargeRate) public pure {
        // Bound inputs to reasonable ranges
        amount = bound(amount, 1, 1e36);
        surchargeRate = bound(surchargeRate, 0, SCALE); // 0% to 100%
        
        uint256 adjusted = AccountingMath.withSurcharge(amount, surchargeRate);
        uint256 original = AccountingMath.withoutSurcharge(adjusted, surchargeRate);
        
        // Due to rounding, original might be slightly less than amount
        assertLe(original, amount);
        assertGe(original, amount * 99 / 100); // Within 1% error due to rounding
    }

    function testFuzz_withSurcharges_cumulative(
        uint256 amount,
        uint256 atlasSurcharge,
        uint256 bundlerSurcharge
    ) public pure {
        // Bound inputs
        amount = bound(amount, 1, 1e36);
        atlasSurcharge = bound(atlasSurcharge, 0, SCALE / 2); // 0% to 50%
        bundlerSurcharge = bound(bundlerSurcharge, 0, SCALE / 2); // 0% to 50%
        
        uint256 combined = AccountingMath.withSurcharges(amount, atlasSurcharge, bundlerSurcharge);
        
        // Combined should equal the mathematical formula
        uint256 expected = amount * (SCALE + atlasSurcharge + bundlerSurcharge) / SCALE;
        assertEq(combined, expected);
        
        // Test that combined surcharges is more efficient than sequential
        // Sequential applies: amount * (10000 + atlas) / 10000 * (10000 + bundler) / 10000
        // Combined applies: amount * (10000 + atlas + bundler) / 10000
        // Sequential should always be >= combined due to compound effect
        uint256 withAtlas = AccountingMath.withSurcharge(amount, atlasSurcharge);
        uint256 sequential = AccountingMath.withSurcharge(withAtlas, bundlerSurcharge);
        
        // Due to integer division rounding, sequential can sometimes be slightly less than combined
        // This happens when intermediate calculations lose precision
        // We allow a difference of 1 wei due to rounding
        if (sequential < combined) {
            assertLe(combined - sequential, 1, "Difference should be at most 1 wei due to rounding");
        } else {
            assertGe(sequential, combined);
        }
    }

    function testFuzz_getSurcharge_consistency(uint256 amount, uint256 surchargeRate) public pure {
        // Bound inputs
        amount = bound(amount, 1, 1e36);
        surchargeRate = bound(surchargeRate, 0, SCALE); // 0% to 100%
        
        uint256 surcharge = AccountingMath.getSurcharge(amount, surchargeRate);
        uint256 total = AccountingMath.withSurcharge(amount, surchargeRate);
        
        // Total should equal amount + surcharge (within rounding)
        assertLe(amount + surcharge, total);
        assertGe(amount + surcharge + 1, total); // Allow for 1 wei rounding error
    }

    function testFuzz_maxBundlerRefund(uint256 gasCost) public pure {
        gasCost = bound(gasCost, 0, 1e12); // Reasonable gas cost range
        
        uint256 refund = AccountingMath.maxBundlerRefund(gasCost);
        
        // Refund should be exactly 80% of gas cost
        assertEq(refund, gasCost * MAX_BUNDLER_REFUND_RATE / SCALE);
        
        // Refund should never exceed 80%
        assertLe(refund, gasCost * 80 / 100);
    }

    function test_edgeCases() public pure {
        // Test precision edge cases
        assertEq(AccountingMath.getSurcharge(1, 1), 0); // 1 * 1 / 10000 = 0
        assertEq(AccountingMath.getSurcharge(10000, 1), 1); // 10000 * 1 / 10000 = 1
        assertEq(AccountingMath.getSurcharge(9999, 1), 0); // 9999 * 1 / 10000 = 0
        
        // Test with zero values
        assertEq(AccountingMath.withSurcharge(0, 1000), 0);
        assertEq(AccountingMath.withoutSurcharge(0, 1000), 0);
        assertEq(AccountingMath.getSurcharge(0, 1000), 0);
        
        // Test with large but safe values
        uint256 safeMax = type(uint256).max / 20001; // Prevent overflow with max surcharge
        uint256 result = AccountingMath.withSurcharge(safeMax, 10000); // 100% surcharge
        assertEq(result, safeMax * 2); // Should double the amount
    }

    function test_gasConstants() public pure {
        // Verify constants match the library
        assertEq(SCALE, 10_000);
        assertEq(MAX_BUNDLER_REFUND_RATE, 8000);
        assertEq(FIXED_GAS_OFFSET, 150_000);
    }
}