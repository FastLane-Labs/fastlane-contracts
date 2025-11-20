// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ShMonad } from "../../src/shmonad/ShMonad.sol";
import { ShMonadEvents } from "../../src/shmonad/Events.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import { FeeLib } from "../../src/shmonad/libraries/FeeLib.sol";
import { BPS_SCALE, SCALE } from "../../src/shmonad/Constants.sol";
import { TestShMonad } from "../base/helpers/TestShMonad.sol";

contract AtomicUnstakePoolTest is BaseTest, ShMonadEvents {
    address public alice;
    address public bob;
    address public charlie;

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant RAY = 1e27;

    function _bpsToRay(uint256 bps) internal pure returns (uint256) {
        return (bps * RAY) / BPS_SCALE;
    }

    function setUp() public override {
        // Setup accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Fund accounts
        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
        vm.deal(charlie, INITIAL_BALANCE);

        super.setUp();
        
    }

    function test_AtomicUnstakePool_setPoolTargetLiquidityPercentage_revertAbove100() public {
        vm.prank(deployer);
        vm.expectRevert(ShMonadErrors.TargetLiquidityCannotExceed100Percent.selector);
        shMonad.setPoolTargetLiquidityPercentage(SCALE + 1);
    }

    function test_AtomicUnstakePool_setPoolTargetLiquidityPercentage_accepts100AndBelow() public {
        vm.startPrank(deployer);
        // Exactly 100%
        shMonad.setPoolTargetLiquidityPercentage(SCALE);
        // Below 100%
        shMonad.setPoolTargetLiquidityPercentage(SCALE - 1);
        vm.stopPrank();
    }

    function test_AtomicUnstakePool_baseAndSlopeAccessors() public {
        uint256 slopeRay = 12e24; // 1.2%
        uint256 interceptRay = 3e24; // 0.3%

        vm.prank(deployer);
        shMonad.setUnstakeFeeCurve(slopeRay, interceptRay);

        assertEq(shMonad.yInterceptRay(), interceptRay, "y intercept accessor must expose intercept");
        assertEq(shMonad.slopeRateRay(), slopeRay, "slope accessor must expose slope");

        (uint256 storedSlope, uint256 storedIntercept) = shMonad.getFeeCurveParams();
        assertEq(storedSlope, slopeRay, "stored slope mismatch");
        assertEq(storedIntercept, interceptRay, "stored intercept mismatch");
    }

    // --------------------------------------------- //
    //           Core Atomic Unstaking Tests         //
    // --------------------------------------------- //

    // function test_AtomicUnstakePool_feeLibIntegration() public {
    //     uint256 depositAmount = 100 ether;
    //     uint256 withdrawAmount = 50 ether;

    //     // Setup initial pool liquidity
    //     _setupPoolLiquidity(200 ether, 100 ether);

    //     vm.prank(deployer);
    //     shMonad.setUnstakeFeeEnabled(true);
    //     assertGt(shMonad.yInterceptRay(), 0, "yInterceptRay should be configured");
    //     assertTrue(shMonad.unstakeFeeEnabled(), "unstake fee should be enabled");

    //     vm.startPrank(alice);

    //     // Deposit
    //     uint256 sharesMinted = shMonad.deposit{value: depositAmount}(depositAmount, alice);
    //     assertGt(sharesMinted, 0, "Should mint shares");
    //     assertEq(shMonad.balanceOf(alice), sharesMinted, "Should have correct shares");

    //     // Test FeeLib functions directly
    //     (uint256 currentLiq, uint256 targetLiq) = _getPoolLiquidity();
    //     uint128 R = uint128(currentLiq);
    //     uint128 L = uint128(targetLiq);
    //     uint256 baseRateRay = _bpsToRay(100); // 1% base fee
    //     uint256 slopeRateRay = _bpsToRay(200); // 2% slope

    //     // Test forward fee calculation
    //     (uint256 fee, uint256 net) = FeeLib.feeAndNetGivenGrossAffine(
    //         withdrawAmount, R, L, baseRateRay, slopeRateRay
    //     );

    //     // Verify fee calculation makes sense
    //     assertTrue(fee > 0, "Fee should be positive");
    //     assertEq(fee + net, withdrawAmount, "Fee + net should equal gross");
    //     assertTrue(net < withdrawAmount, "Net should be less than gross due to fee");

    //     // Test inverse calculation
    //     (uint256 grossOut, uint256 feeOut, uint256 netMax) = FeeLib.solveGrossGivenPostFeeOutAffine(
    //         net, R, L, baseRateRay, slopeRateRay
    //     );

    //     // Verify inverse calculation
    //     assertTrue(net <= netMax, "Target net should be feasible");
    //     assertEq(grossOut - feeOut, net, "Inverse should return exact net");
    //     uint256 tol = withdrawAmount / 10_000;
    //     if (tol == 0) tol = 1;
    //     assertApproxEqAbs(grossOut, withdrawAmount, tol, "Gross should be close to original");

    //     // Test utilization calculation
    //     uint256 utilization = FeeLib.utilRay(R, L);
    //     if (R < L) {
    //         assertTrue(utilization > 0, "Utilization should be positive when below target");
    //     } else {
    //         assertEq(utilization, 0, "Utilization should be zero when at/above target");
    //     }
    //     assertTrue(utilization < RAY, "Utilization should be less than 100%");

    //     // Test headroom calculation
    //     (uint256 u0, uint256 xMax) = FeeLib.headroomAndUtil(R, L);
    //     assertEq(u0, utilization, "Utilization should match");
    //     assertTrue(xMax > 0, "Headroom should be positive");

    //     vm.stopPrank();
    // }

    // --------------------------------------------- //
    //              View Function Tests              //
    // --------------------------------------------- //

    function test_AtomicUnstakePool_atomicUtilization_and_FeeRate() public {
        // Query utilization + fee; assert basic invariants
        uint256 util = shMonad.getAtomicUtilizationWad();
        assertLe(util, 1e18, "utilization must be <= 1e18");

        (uint256 mRay, uint256 cRay) = shMonad.getFeeCurveParams();
        uint256 feeRate = shMonad.getCurrentUnstakeFeeRateRay();
        uint256 yMax = cRay + mRay;
        if (yMax > 1e27) yMax = 1e27;
        assertLe(feeRate, yMax, "fee rate must be <= capped max");
        // Lower bound is base intercept unless over-capped to zero-liquidity case
        assertGe(feeRate, cRay, "fee rate must be >= intercept");
    }

    function test_AtomicUnstakePool_atomicPoolUtilization_tuple() public {
        (uint256 utilized, uint256 allocated, uint256 available, uint256 utilWad) =
            shMonad.getAtomicPoolUtilization();
        if (allocated == 0) {
            assertEq(utilized, 0, "no allocation implies zero utilized");
            assertEq(available, 0, "no allocation implies zero available");
            assertEq(utilWad, 0, "no allocation implies zero utilization");
        } else {
            assertEq(allocated, utilized + available, "allocated must split into utilized + available");
            assertLe(utilWad, 1e18, "utilization must be <= 1e18");
        }
    }

    // function test_AtomicUnstakePool_feeLibRoundTripConsistency() public {
    //     // Setup pool: target = 100% of total, current liquidity L
    //     uint256 L = 300 ether;
    //     _setupPoolLiquidity(L, L);

    //     // Get current liquidity state
    //     (uint256 currentLiq, uint256 targetLiq) = _getPoolLiquidity();
    //     uint128 R = uint128(currentLiq);
    //     uint128 L_actual = uint128(targetLiq);
    //     uint256 baseRateRay = _bpsToRay(100); // 1% base fee
    //     uint256 slopeRateRay = _bpsToRay(200); // 2% slope

    //     // Choose several net targets under capacity
    //     uint256[5] memory asks = [uint256(1 ether), 5 ether, 25 ether, 100 ether, 250 ether];

    //     for (uint256 i = 0; i < asks.length; ++i) {
    //         uint256 targetNet = asks[i];
            
    //         // Use FeeLib for inverse calculation
    //         (uint256 grossOut, uint256 feeOut, uint256 netMax) = FeeLib.solveGrossGivenPostFeeOutAffine(
    //             targetNet, R, L_actual, baseRateRay, slopeRateRay
    //         );

    //         // Forward check using FeeLib
    //         (uint256 feeFwd, uint256 netFwd) = FeeLib.feeAndNetGivenGrossAffine(
    //             grossOut, R, L_actual, baseRateRay, slopeRateRay
    //         );

    //         // No under-delivery
    //         assertGe(netFwd, targetNet, "forward(net) under-delivered target");
            
    //         // Overshoot tolerance: allow up to 1 bp of target (covers integer sqrt/mulDiv rounding)
    //         uint256 overshoot = netFwd - targetNet;
    //         uint256 tol = targetNet / 10_000; // 1 basis point
    //         if (tol == 0) tol = 1;
    //         assertLe(overshoot, tol, "forward(net) overshoot too large");

    //         // Fee consistency: implied fee ~= quoted fee (±1 wei)
    //         uint256 implied = grossOut - targetNet;
    //         uint256 feeDiff = implied > feeOut ? implied - feeOut : feeOut - implied;
    //         assertLe(feeDiff, 1, "fee mismatch between inverse and implied");
    //     }
    // }

    // function test_AtomicUnstakePool_feeLibCapacityLimits() public {
    //     // Setup pool liquidity
    //     uint256 L = 200 ether;
    //     _setupPoolLiquidity(L, L);

    //     // Get current liquidity state
    //     (uint256 currentLiq, uint256 targetLiq) = _getPoolLiquidity();
    //     uint128 R = uint128(currentLiq);
    //     uint128 L_actual = uint128(targetLiq);
    //     uint256 baseRateRay = _bpsToRay(100); // 1% base fee
    //     uint256 slopeRateRay = _bpsToRay(200); // 2% slope

    //     // Compute cap using FeeLib
    //     (uint256 u0, uint256 xMax) = FeeLib.headroomAndUtil(R, L_actual);
    //     (uint256 feeAtCap, uint256 netAtCap) = FeeLib.feeAndNetGivenGrossAffine(
    //         xMax, R, L_actual, baseRateRay, slopeRateRay
    //     );

    //     // Ask for slightly more than netMax
    //     uint256 ask = netAtCap + 1;

    //     // Test soft inverse with infeasible target
    //     (uint256 grossOut, uint256 feeOut, uint256 netMax, bool feasible) = 
    //         FeeLib.solveGrossGivenPostFeeOutAffineSoft(ask, R, L_actual, baseRateRay, slopeRateRay);

    //     // Should be infeasible beyond capacity
    //     assertFalse(feasible, "should be infeasible beyond capacity");
    //     assertEq(netMax, netAtCap, "netMax must equal net at cap");
    //     assertEq(grossOut, xMax, "grossOut must clamp to xMax");
    //     assertEq(feeOut, feeAtCap, "feeOut must match fee at cap");
    // }

    // function test_AtomicUnstakePool_feeLibFlatFeeBranch() public {
    //     // Setup pool
    //     uint256 L = 100 ether;
    //     _setupPoolLiquidity(L, L);

    //     // Get current liquidity state
    //     (uint256 currentLiq, uint256 targetLiq) = _getPoolLiquidity();
    //     uint128 R = uint128(currentLiq);
    //     uint128 L_actual = uint128(targetLiq);
    //     uint256 baseRateRay = _bpsToRay(100); // 1% base fee
    //     uint256 slopeRateRay = 0; // 0% slope (flat fee)

    //     uint256[] memory grossVals = new uint256[](4);
    //     grossVals[0] = 1 ether;
    //     grossVals[1] = 10 ether;
    //     grossVals[2] = 50 ether;
    //     grossVals[3] = 100 ether;

    //     for (uint256 i = 0; i < grossVals.length; ++i) {
    //         uint256 g = grossVals[i];
            
    //         // Test forward calculation with FeeLib
    //         (uint256 fee, uint256 net) = FeeLib.feeAndNetGivenGrossAffine(
    //             g, R, L_actual, baseRateRay, slopeRateRay
    //         );
            
    //         uint256 expected = Math.mulDiv(g, baseRateRay, RAY); // 1%
    //         assertEq(fee, expected, "flat fee mismatch at slope=0");
    //         assertEq(net, g - expected, "net should equal gross minus fee");

    //         // Inverse check: net = g - fee; quote gross to achieve that net
    //         (uint256 gInv, uint256 fInv, uint256 netMax) = FeeLib.solveGrossGivenPostFeeOutAffine(
    //             net, R, L_actual, baseRateRay, slopeRateRay
    //         );
            
    //         assertEq(gInv, g, "inverse gross mismatch with flat fee");
    //         assertEq(fInv, fee, "inverse fee mismatch with flat fee");
    //     }
    // }

    // function test_AtomicUnstakePool_depositThenRedeem() public {
    //     uint256 depositAmount = 100 ether;
    //     uint256 sharesToRedeem = 50 ether; // This will be converted to shares

    //     // Setup initial pool liquidity
    //     _setupPoolLiquidity(200 ether, 100 ether);

    //     vm.prank(deployer);
    //     shMonad.setUnstakeFeeEnabled(true);
    //     assertTrue(shMonad.unstakeFeeEnabled(), "unstake fee should be enabled");
    //     assertGt(shMonad.yInterceptRay(), 0, "yInterceptRay should be configured");

    //     vm.startPrank(alice);
    //     // Deposit to get shares
    //     shMonad.deposit{value: depositAmount}(depositAmount, alice);
    //     uint256 aliceShares = shMonad.balanceOf(alice);
    //     assertGt(aliceShares, 0, "Alice should have shares after deposit");

    //     // Redeem some shares
    //     shMonad.redeem(sharesToRedeem, alice, alice);
    //     vm.stopPrank();

    //     // Verify Alice's balance decreased
    //     assertLt(shMonad.balanceOf(alice), aliceShares, "Alice's shares should decrease after redeem");
    // }

    // function test_AtomicUnstakePool_redeem_matchesPreviewAndFee() public {
    //     uint256 depositAmount = 100 ether;
    //     uint256 sharesToRedeem = 50 ether; // This will be converted to shares

    //     // Setup initial pool liquidity
    //     _setupPoolLiquidity(200 ether, 100 ether);

    //     vm.prank(deployer);
    //     shMonad.setUnstakeFeeEnabled(true);
    //     assertTrue(shMonad.unstakeFeeEnabled(), "unstake fee should be enabled");
    //     assertGt(shMonad.yInterceptRay(), 0, "yInterceptRay should be configured");

    //     vm.startPrank(alice);

    //     // Deposit
    //     uint256 sharesMinted = shMonad.deposit{value: depositAmount}(depositAmount, alice);
    //     assertGt(sharesMinted, 0, "Should mint shares");
    //     assertEq(shMonad.balanceOf(alice), sharesMinted, "Should have correct shares");

    //     // Before calling redeem, get the expected assets for the shares being redeemed
    //     uint256 expectedAssets = shMonad.previewRedeem(sharesToRedeem);

    //     // Conversion-price aware proof of fee: value of shares being redeemed minus assets received
    //     uint256 valueOfSharesToRedeem = shMonad.convertToAssets(sharesToRedeem);

    //     (uint256 currentLiq, uint256 targetLiq) = _getPoolLiquidity();
    //     (uint256 feeLibFee, uint256 feeLibNet) = FeeLib.feeAndNetGivenGrossAffine(
    //         valueOfSharesToRedeem,
    //         uint128(currentLiq),
    //         uint128(targetLiq),
    //         shMonad.yInterceptRay(),
    //         shMonad.slopeRateRay()
    //     );
    //     assertGt(feeLibFee, 0, "FeeLib should compute a positive fee");

    //     // value of shares being redeemed should exceed the preview amount when fees apply
    //     assertGt(valueOfSharesToRedeem, expectedAssets, "valueOfSharesToRedeem should account for fee");

    //     // Calculate the fee that would be charged on the gross amount
    //     uint256 contractFee = shMonad.getCurrentFee(valueOfSharesToRedeem);
    //     assertEq(valueOfSharesToRedeem - contractFee, expectedAssets, "gross - fee != expectedAssets");

    //     // redeem() parameter is the shares to burn. Use the calculated shares amount here.
    //     uint256 balBefore = alice.balance;
    //     uint256 assetsReceived = shMonad.redeem(sharesToRedeem, alice, alice);
    //     uint256 actualAssetsReceived = alice.balance - balBefore;

    //     // Sanity: assets received should match preview
    //     assertEq(assetsReceived, expectedAssets, "assetsReceived != previewRedeem");
    //     assertEq(actualAssetsReceived, assetsReceived, "actualAssetsReceived != assetsReceived");

    //     // Verify fee was taken: pro-rata value of shares redeemed > assets received (fee retained in pool)
    //     uint256 impliedFee = valueOfSharesToRedeem - assetsReceived;
    //     assertEq(impliedFee, contractFee, "impliedFee != fee");

    //     // And also: assets received < value of shares redeemed (fee-based check)
    //     assertLt(assetsReceived, valueOfSharesToRedeem, "Fee should be deducted from shares value");
    //     assertGt(assetsReceived, 0, "Should receive some assets");
        
    //     // Verify shares were burned
    //     assertEq(shMonad.balanceOf(alice), sharesMinted - sharesToRedeem, "Should have remaining shares");
        
    //     vm.stopPrank();
    // }

    // // Event coverage: PoolLiquidityUpdated emitted on deposit
    // function test_AtomicUnstakePool_deposit_emitsPoolLiquidityUpdatedEvent() public {
    //     vm.startPrank(alice);
    //     vm.expectEmit(false, false, false, false, address(shMonad));
    //     emit PoolLiquidityUpdated(0, 0);
    //     shMonad.deposit{ value: 10 ether }(10 ether, alice);
    //     vm.stopPrank();
    // }

    // // Event coverage: PoolLiquidityUpdated emitted on withdraw
    // function test_AtomicUnstakePool_withdraw_emitsPoolLiquidityUpdatedEvent() public {
    //     vm.startPrank(alice);
    //     // Ensure balance to withdraw
    //     shMonad.deposit{ value: 10 ether }(10 ether, alice);
    //     vm.expectEmit(false, false, false, false, address(shMonad));
    //     emit PoolLiquidityUpdated(0, 0);
    //     shMonad.withdraw(2 ether, alice, alice);
    //     vm.stopPrank();
    // }

    // function test_AtomicUnstakePool_setPoolTargetLiquidityPercentage_overMax_reverts() public {
    //     vm.prank(deployer);
    //     vm.expectRevert(ShMonadErrors.TargetLiquidityPercentageExceedsMax.selector);
    //     shMonad.setPoolTargetLiquidityPercentage(10001);
    // }

    // --------------------------------------------- //
    //                Helper Functions               //
    // --------------------------------------------- //

    function _setupPoolLiquidity(uint256 targetLiq, uint256 currentLiq) internal {
        vm.startPrank(deployer);
        
        // Calculate target percentage based on desired liquidity and total assets
        // targetLiq is the desired absolute amount, we need to convert to percentage
        // If we want targetLiq and will deposit currentLiq, total assets will be currentLiq
        // So percentage = (targetLiq / currentLiq) * 10000 (basis points)
        if (currentLiq > 0) {
            // Fund deployer first
            vm.deal(deployer, currentLiq);
            
            // First deposit as deployer
            shMonad.deposit{value: currentLiq}(currentLiq, deployer);
            
            // Now set target as percentage of total assets
            // If we want targetLiq out of currentLiq total, that's (targetLiq * 10000) / currentLiq basis points
            uint256 targetPercentage = targetLiq > 0 ? (targetLiq * 10000) / currentLiq : 0;
            if (targetPercentage > 10000) targetPercentage = 10000; // Cap at 100%
            
            shMonad.setPoolTargetLiquidityPercentage(targetPercentage);
        } else if (targetLiq == 0) {
            // If no liquidity wanted, set percentage to 0
            shMonad.setPoolTargetLiquidityPercentage(0);
        }
        
        vm.stopPrank();
    }


    function _getPoolLiquidity() internal view returns (uint256 current, uint256 target) {
        current = shMonad.getCurrentLiquidity();
        target = shMonad.getTargetLiquidity();
    }
}
