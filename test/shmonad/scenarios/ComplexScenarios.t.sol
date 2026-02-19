// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";

import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

import { Epoch } from "src/shmonad/Types.sol";
import { IShMonad } from "src/shmonad/interfaces/IShMonad.sol";
import { IMonadStaking } from "src/shmonad/interfaces/IMonadStaking.sol";
import { BaseTest } from "../../base/BaseTest.t.sol";
import { TestShMonad } from "../../base/helpers/TestShMonad.sol";
import { MockMonadStakingPrecompile } from "src/shmonad/mocks/MockMonadStakingPrecompile.sol";
import { MONAD_EPOCH_LENGTH, TARGET_FLOAT, SCALE, RAY, UNKNOWN_VAL_ADDRESS, MIN_VALIDATOR_DEPOSIT, UNKNOWN_VAL_ID } from "src/shmonad/Constants.sol";

contract MaliciousCoinbaseReentrantDeposit {
    address public immutable SHMONAD;
    uint64 public immutable VAL_ID;
    address public immutable AUTH_ADDRESS;
    uint256 public immutable depositAmount;

    bytes public lastRevertData;
    bool public reentryBlocked;

    constructor(address shmonad, uint64 valId, address authAddress, uint256 amount) {
        SHMONAD = shmonad;
        VAL_ID = valId;
        AUTH_ADDRESS = authAddress;
        depositAmount = amount;
    }

    function process() external returns (bool) {
        (bool ok, bytes memory revertData) = SHMONAD.call{ value: depositAmount }(
            abi.encodeWithSignature("deposit(uint256,address)", depositAmount, AUTH_ADDRESS)
        );
        if (!ok) {
            reentryBlocked = true;
            lastRevertData = revertData;
        }

        return true;
    }

    receive() external payable { }
}

contract ComplexScenarios is BaseTest {
    using Math for uint256;

    TestShMonad internal scenarioShMonad;
    MockMonadStakingPrecompile internal stakingMock;

    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000001000;

    address[] internal users;
    address[] internal validatorCoinbases;
    uint64[] internal validatorIds;

    uint256 internal baselinePoolLiquidity;
    uint256 internal baselineTargetLiquidity;
    uint256 internal constant START_BAL = 1_000_000 ether;
    uint128 internal constant VALIDATOR_FEE_RATE = uint128(SCALE / 10); // 10% (1e17)
    bytes4 internal constant REENTRANCY_SELECTOR = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function setUp() public override {
        super.setUp();

        scenarioShMonad = TestShMonad(payable(address(shMonad)));

        if (PRECOMPILE.code.length == 0) {
            MockMonadStakingPrecompile implementation = new MockMonadStakingPrecompile();
            vm.etch(PRECOMPILE, address(implementation).code);
        }

        stakingMock = MockMonadStakingPrecompile(PRECOMPILE);

        vm.startPrank(deployer);
        // Fees are enabled by default. If a test requires disabling fees,
        // it should use setUnstakeFeeCurve(0, 0).
        vm.stopPrank();

        _seedUsers(4);
        _initValidators(10);

        // Prime allocator with the initial epoch transition so sentinel math is stabilized.
        _advanceEpoch(false);

        baselinePoolLiquidity = scenarioShMonad.getCurrentLiquidity();
        baselineTargetLiquidity = scenarioShMonad.getTargetLiquidity();
    }

    function _initValidators(uint256 count) internal {
        if (useLocalMode) {
            _registerValidators(count);
        } else {
            _useExistingValidators(count);
        }
    }

    function _useExistingValidators(uint256 desiredCount) internal {
        (uint64[] memory ids, address[] memory coinbases) = scenarioShMonad.listActiveValidators();

        uint256 filled;
        for (uint256 i = 0; i < ids.length && filled < desiredCount; i++) {
            uint64 valId = ids[i];
            address coinbase = coinbases[i];
            if (valId == 0 || coinbase == address(0)) continue;

            validatorIds.push(valId);
            validatorCoinbases.push(coinbase);
            unchecked {
                ++filled;
            }
        }

        require(filled == desiredCount, "insufficient active validators in fork");
    }

    function _seedUsers(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            address user = makeAddr(string.concat("User", vm.toString(i)));
            users.push(user);
            vm.deal(user, START_BAL);
            vm.label(user, string.concat("User", vm.toString(i)));
        }
    }

    function _registerValidators(uint256 count) internal {
        uint256 baseIndex = validatorCoinbases.length;
        for (uint256 i = 0; i < count; i++) {
            uint256 idx = baseIndex + i;
            address coinbase = makeAddr(string.concat("Validator", vm.toString(idx)));
            uint64 valId = stakingMock.registerValidator(coinbase);
            vm.deal(coinbase, START_BAL);
            vm.prank(coinbase);
            stakingMock.delegate{ value: START_BAL }(valId);

            validatorCoinbases.push(coinbase);
            validatorIds.push(valId);
            vm.label(coinbase, string.concat("ValCoinbase", vm.toString(idx)));        

            vm.prank(deployer);
            scenarioShMonad.addValidator(valId, coinbase);
        }
    }

    function _advanceEpoch(bool inDelay) internal {
        vm.roll(block.number + MONAD_EPOCH_LENGTH + 1);
        stakingMock.harnessSyscallOnEpochChange(inDelay);
        while (!scenarioShMonad.crank()) { }
    }

    // Sends validator rewards (e.g., MEV) to the contract, attributing to a specific validator.
    function _sendValidatorRewards(uint256 validatorIndex, uint256 amount, address originator) internal {
        address coinbase = validatorCoinbases[validatorIndex];
        vm.coinbase(coinbase);
        if (originator.balance < amount) {
            vm.deal(originator, amount);
        }
        vm.prank(originator);
        scenarioShMonad.sendValidatorRewards{ value: amount }(validatorIds[validatorIndex], VALIDATOR_FEE_RATE);
        vm.coinbase(address(0));
    }

    // True yield boost helper: donate MON directly as extra yield (no validator attribution).
    function _boostYieldTo(uint256 amount, address originator) internal {
        if (originator.balance < amount) {
            vm.deal(originator, amount);
        }
        vm.prank(originator);
        scenarioShMonad.boostYield{ value: amount }(originator);
    }

    function _deposit(address from, uint256 assets) internal returns (uint256 sharesMinted) {
        vm.prank(from);
        sharesMinted = scenarioShMonad.deposit{ value: assets }(assets, from);
    }

    function _withdraw(address who, uint256 assets) internal returns (uint256 sharesBurned) {
        vm.prank(who);
        sharesBurned = scenarioShMonad.withdraw(assets, who, who);
    }

    function _mint(address from, uint256 shares) internal returns (uint256 assetsIn) {
        assetsIn = scenarioShMonad.previewMint(shares);
        vm.prank(from);
        scenarioShMonad.mint{ value: assetsIn }(shares, from);
    }

    function _advanceEpochs(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            _advanceEpoch(i % 4 == 3);
        }
    }

    // Attempts a gas-limited partial crank that leaves validators[3] and [4] uncranked while ensuring [0..2] cranked.
    // Uses a snapshot + binary search to calibrate a single crank call that processes exactly N among the first five.
    function _ensureExactlyFirstNCrankedAmongFirstFive(uint256 n) internal {
        require(n <= 5, "n must be <= 5");

        // Take a snapshot before the partial crank so we can calibrate safely.
        uint256 baseSnap = vm.snapshot();

        // Binary search helper defined below.

        // Binary search gas to achieve exactly `n` processed among the first five.
        uint256 low = 1_300_000;
        uint256 high = 5_000_000;
        uint256 foundGas;
        bool found;
        for (uint256 it = 0; it < 20; ++it) {
            uint256 mid = (low + high) / 2;
            uint256 cnt = _attemptPartialCrankWithGas(baseSnap, mid);
            if (cnt == n) {
                found = true;
                foundGas = mid;
                break;
            } else if (cnt < n) {
                low = mid + 50_000; // step up slowly to avoid overshoot
            } else {
                if (mid <= low + 50_000) {
                    high = mid - 1;
                } else {
                    high = mid - 50_000;
                }
            }
        }

        require(found, "failed to calibrate partial crank gas");

        // Re-apply the found gas setting to commit the desired state.
        // Commit the calibrated state
        _attemptPartialCrankWithGas(baseSnap, foundGas);

        // Final assertions: first `n` cranked; others within first five not cranked.
        for (uint256 i = 0; i < n; i++) {
            Epoch memory eLast = scenarioShMonad.exposeValidatorEpochLast(validatorCoinbases[i]);
            assertTrue(eLast.wasCranked, "expected early validators to be cranked");
        }
        for (uint256 i = n; i < 5; i++) {
            Epoch memory eLast = scenarioShMonad.exposeValidatorEpochLast(validatorCoinbases[i]);
            assertFalse(eLast.wasCranked, "expected later validators to remain uncranked");
        }
    }

    // Performs a single partial-crank attempt from the given snapshot:
    // - Reverts to snapshot
    // - Advances epoch and runs a global-tick-only crank
    // - Runs a partial crank with the given gas limit
    // Returns the number of validators among the first five with last.wasCranked = true
    function _attemptPartialCrankWithGas(uint256 baseSnap, uint256 gas2) internal returns (uint256 cnt) {
        vm.revertTo(baseSnap);
        vm.roll(block.number + MONAD_EPOCH_LENGTH + 1);
        stakingMock.harnessSyscallOnEpochChange(false);
        {
            (bool ok1, bytes memory data1) = address(scenarioShMonad).call{ gas: 1_200_000 }(
                abi.encodeWithSelector(IShMonad.crank.selector)
            );
            require(ok1, "global tick call failed");
            data1;
        }
        {
            (bool ok2, bytes memory data2) = address(scenarioShMonad).call{ gas: gas2 }(
                abi.encodeWithSelector(IShMonad.crank.selector)
            );
            require(ok2, "partial crank call failed");
            data2;
        }

        for (uint256 i = 0; i < 5; i++) {
            Epoch memory eLast = scenarioShMonad.exposeValidatorEpochLast(validatorCoinbases[i]);
            if (eLast.wasCranked) cnt++;
        }
    }

    function _feeInfoForShares(uint256 shares)
        internal
        view
        returns (uint256 grossAssets, uint256 netAssets, uint256 feeBps)
    {
        if (shares == 0) return (0, 0, 0);
        grossAssets = scenarioShMonad.convertToAssets(shares);
        netAssets = scenarioShMonad.previewRedeem(shares);
        uint256 feeAssets = grossAssets - netAssets;
        feeBps = grossAssets == 0 ? 0 : feeAssets * 10_000 / grossAssets;
    }

    function _feeBpsFromGross(uint256 grossAssets) internal view returns (uint256) {
        if (grossAssets == 0) return 0;
        uint256 fee = scenarioShMonad.quoteFeeFromGrossAssetsNoLiquidityLimit(grossAssets);
        return fee * 10_000 / grossAssets;
    }

    function test_ShMonad_processCoinbaseByAuth_reentrancyBlocked() public {
        address attacker = makeAddr("reentryAttacker");
        uint256 depositAmount = 1 ether;
        MaliciousCoinbaseReentrantDeposit coinbase =
            new MaliciousCoinbaseReentrantDeposit(address(scenarioShMonad), 123_456, attacker, depositAmount);

        vm.deal(address(this), depositAmount);
        (bool funded,) = address(coinbase).call{ value: depositAmount }("");
        assertTrue(funded, "funding coinbase should succeed");

        // processCoinbaseByAuth(address) is onlyOwner, so call as deployer
        vm.prank(deployer);
        scenarioShMonad.processCoinbaseByAuth(address(coinbase));

        assertTrue(coinbase.reentryBlocked(), "reentry should be blocked");
        bytes memory revertData = coinbase.lastRevertData();
        assertGe(revertData.length, 4, "missing revert selector");

        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 0x20))
        }

        assertEq(selector, REENTRANCY_SELECTOR, "unexpected revert");
    }

    function test_ShMonad_NormalOps() public {
        // Fork mode uses an existing mainnet ShMonad state; this scenario assumes a fresh environment.
        if (!useLocalMode) vm.skip(true);

        // Scenario: multi-user deposits → validator boosts → instant withdraw.
        // Confirms pool/target adjustments, earned-revenue weighting, preview accuracy,
        // and post-fee liquidity deltas in a single end-to-end flow.
        // Step 1: multi-user deposits establish pool baseline.
        uint256 deposit0 = 10_000 ether;
        uint256 deposit1 = 5000 ether;
        uint256 deposit2 = 20_000 ether;
        uint256 initialTotalAssets = scenarioShMonad.totalAssets();

        _deposit(users[0], deposit0);
        _deposit(users[1], deposit1);
        _deposit(users[2], deposit2);

        // Step 2: basic accounting after deposits. The allocator only shifts targets on crank,
        // so observe the pending state before and after the epoch transition.
        uint256 targetLiquidityPending = scenarioShMonad.getTargetLiquidity();
        uint256 poolLiquidityPending = scenarioShMonad.getCurrentLiquidity();

        _advanceEpoch(false);

        uint256 depositTotal = deposit0 + deposit1 + deposit2;
        uint256 targetLiquidity = scenarioShMonad.getTargetLiquidity();
        uint256 poolLiquidity = scenarioShMonad.getCurrentLiquidity();
        uint256 expectedDelta = (depositTotal * TARGET_FLOAT) / SCALE;
        // allocator delta also folds in queued stake, prior epoch rounding dust, and 1-wei adjustments,
        // so expect a ~0.06 MON drift instead of insisting on exact proportionality.
        uint256 targetDelta = targetLiquidity - targetLiquidityPending;
        uint256 targetTolerance = expectedDelta / 10_000;
        if (targetTolerance < 1e16) targetTolerance = 1e16;
        assertApproxEqAbs(
            targetDelta,
            expectedDelta,
            targetTolerance,
            "target liquidity delta should track deposits after crank"
        );
        assertEq(poolLiquidityPending, baselinePoolLiquidity, "pool should not adjust prior to crank");
        assertEq(poolLiquidity, targetLiquidity, "pool liquidity should equal target when utilization is zero post-crank");
        uint256 totalAssetsAfterDeposits = scenarioShMonad.totalAssets();
        assertEq(
            totalAssetsAfterDeposits,
            initialTotalAssets + deposit0 + deposit1 + deposit2,
            "total assets should reflect deposits"
        );

        // Step 3: skew earned revenue weights.
        uint256 totalAssetsBeforeBoost = scenarioShMonad.totalAssets();
        uint120[3] memory validatorRewardsBefore;
        for (uint256 i = 0; i < 3; i++) {
            uint64 valIdLoop = uint64(scenarioShMonad.getValidatorIdForCoinbase(validatorCoinbases[i]));
            (,, validatorRewardsBefore[i],) = scenarioShMonad.getValidatorRewards(valIdLoop);
        }
        (,, uint120 unknownRewardsBefore, uint120 unknownEarnedBefore) = scenarioShMonad.getValidatorRewards(UNKNOWN_VAL_ID);
        uint256 contractBalanceBeforeBoost = address(scenarioShMonad).balance;

        _sendValidatorRewards(0, 3 ether, users[0]);
        _sendValidatorRewards(1, 1 ether, users[1]);
        _sendValidatorRewards(2, 2 ether, users[2]);

        uint256 contractBalanceAfterBoost = address(scenarioShMonad).balance;
        uint256 boostTotal = 3 ether + 1 ether + 2 ether;
        assertEq(
            contractBalanceAfterBoost - contractBalanceBeforeBoost,
            boostTotal,
            "contract balance should receive boosted amount"
        );
        uint256 deferredRewardsDelta;
        for (uint256 i = 0; i < 3; i++) {
            uint64 valIdLoop = uint64(scenarioShMonad.getValidatorIdForCoinbase(validatorCoinbases[i]));
            (,, uint120 rewardsAfter,) = scenarioShMonad.getValidatorRewards(valIdLoop);
            deferredRewardsDelta += uint256(rewardsAfter - validatorRewardsBefore[i]);
        }
        (,, uint120 unknownRewardsAfter, uint120 unknownEarnedAfter) = scenarioShMonad.getValidatorRewards(UNKNOWN_VAL_ID);
        uint256 realizedBoostNow =
            uint256(unknownRewardsAfter - unknownRewardsBefore) + uint256(unknownEarnedAfter - unknownEarnedBefore);
        uint256 totalAssetsAfterBoost = scenarioShMonad.exposeTotalAssets({treatAsWithdrawal: true});
        assertEq(
            totalAssetsAfterBoost,
            totalAssetsBeforeBoost + realizedBoostNow,
            "total assets should only recognize the instantly realized portion of boosts"
        );

        // Step 4: run several epochs so allocator ingests boosts.
        _advanceEpochs(10);
        uint256 totalAssetsAfterBoostEpochs = scenarioShMonad.exposeTotalAssets({treatAsWithdrawal: true});
        // Only the protocol fee portion of boosts (net of any boost commission) ultimately accretes to equity.
        // Compute the expected recognized revenue from the three boost events and assert conservation accordingly.
        ( , , , , uint16 boostCommissionBps, ) = scenarioShMonad.getAdminValues();
        uint256 fee0 = (3 ether) * VALIDATOR_FEE_RATE / SCALE;
        uint256 fee1 = (1 ether) * VALIDATOR_FEE_RATE / SCALE;
        uint256 fee2 = (2 ether) * VALIDATOR_FEE_RATE / SCALE;
        uint256 com0 = fee0 * boostCommissionBps / 10_000;
        uint256 com1 = fee1 * boostCommissionBps / 10_000;
        uint256 com2 = fee2 * boostCommissionBps / 10_000;
        uint256 expectedProtocolRevenue = (fee0 + fee1 + fee2) - (com0 + com1 + com2);
        assertEq(
            totalAssetsAfterBoostEpochs,
            totalAssetsBeforeBoost + realizedBoostNow + expectedProtocolRevenue,
            "epochs should realize deferred validator payouts"
        );

        // Step 5: preview/execute redeem to confirm fees apply.
        uint256 holderShares = scenarioShMonad.balanceOf(users[2]);
        uint256 totalSupply = scenarioShMonad.totalSupply();
        uint256 cappedRedeem = totalSupply * 2 / 1000; // 0.5%
        if (holderShares > cappedRedeem) holderShares = cappedRedeem;
        uint256 assetsBeforeFee = scenarioShMonad.convertToAssets(holderShares);
        uint256 previewAfterFee = scenarioShMonad.previewRedeem(holderShares);
        assertLt(previewAfterFee, assetsBeforeFee, "withdraw previews must include fee");
        uint256 user2BalanceBefore = users[2].balance;
        vm.prank(users[2]);
        scenarioShMonad.redeem(holderShares, users[2], users[2]);
        uint256 redeemedNet = users[2].balance - user2BalanceBefore;
        assertEq(redeemedNet, previewAfterFee, "redeem should deliver preview amount");

        // Step 6: execute an instant withdraw and verify pool delta.
        uint256 targetNet = 1000 ether;
        totalSupply = scenarioShMonad.totalSupply();
        cappedRedeem = totalSupply * 2 / 1000; // 0.5%
        if (targetNet > cappedRedeem) targetNet = cappedRedeem;

        uint256 mintedShares = _deposit(users[3], 2000 ether);
        uint256 previewShares = scenarioShMonad.previewWithdraw(targetNet);
        require(mintedShares >= previewShares, "deposit must cover withdrawal preview");

        _advanceEpoch(false);

        uint256 grossAssets = scenarioShMonad.convertToAssets(previewShares);
        uint256 netFee = scenarioShMonad.quoteFeeFromGrossAssetsNoLiquidityLimit(grossAssets);
        uint256 netAssets = grossAssets - netFee;

        uint256 poolLiquidityBefore = scenarioShMonad.getCurrentLiquidity();
        uint256 balanceBefore = users[3].balance;

        vm.prank(users[3]);
        scenarioShMonad.withdraw(targetNet, users[3], users[3]);
        assertEq(users[3].balance - balanceBefore, targetNet, "net withdrawal should equal requested assets");

        _advanceEpoch(false);

        uint256 poolLiquidityAfter = scenarioShMonad.getCurrentLiquidity();
        uint256 poolDelta = poolLiquidityBefore - poolLiquidityAfter;
    
        assertApproxEqAbs(poolDelta, netAssets, netAssets * 2 / 100, "pool liquidity should drop by net withdrawn amount");
    }

    function test_ShMonad_BlackSwanDeposit() public {
        // Fork mode uses an existing mainnet ShMonad state; this scenario assumes a fresh environment.
        if (!useLocalMode) vm.skip(true);

        // Scenario: a single large deposit arrives mid-epoch. Verifies the allocator
        // absorbs capital exactly once via the global target stake tracker.
        // Step 1: modest activity sets the pre-spike baseline.
        _advanceEpoch(false);

        _deposit(users[0], 2000 ether);
        _deposit(users[1], 2000 ether);

    
        _advanceEpoch(false);
        _sendValidatorRewards(0, 0.5 ether, users[0]);


        _advanceEpoch(false);
        _advanceEpoch(false);

        uint256 assetsBefore = scenarioShMonad.totalAssets();
        (, uint128 globalRevenueBefore) = scenarioShMonad.exposeGlobalRevenueCurrent();

        // Step 2: apply the oversized deposit in a single block.
        uint256 massiveDeposit = 200_000 ether;
        _deposit(users[2], massiveDeposit);


        _advanceEpoch(false);
        _advanceEpoch(false);
        _advanceEpoch(false);


        uint256 targetAfter = scenarioShMonad.getTargetLiquidity();
        uint256 poolAfter = scenarioShMonad.getCurrentLiquidity();
        uint256 assetsAfter = scenarioShMonad.totalAssets();
        (, uint128 globalRevenueAfter) = scenarioShMonad.exposeGlobalRevenueCurrent();
        uint256 expectedTargetAfter = (assetsAfter * TARGET_FLOAT) / SCALE;

        assertApproxEqAbs(
            targetAfter,
            expectedTargetAfter,
            1e15,
            "target liquidity should increase at configured ratio"
        );
        assertEq(poolAfter, targetAfter, "pool should mirror target when unused");

        uint256 realizedRevenue = uint256(globalRevenueAfter) - uint256(globalRevenueBefore);
        uint256 actualAssetDelta = assetsAfter - assetsBefore;
        uint256 expectedAssetDelta = massiveDeposit + realizedRevenue;

        emit log_named_uint("realizedRevenue", realizedRevenue);
        emit log_named_uint("actualAssetDelta", actualAssetDelta);
        emit log_named_uint("expectedAssetDelta", expectedAssetDelta);

        assertApproxEqAbs(
            actualAssetDelta,
            expectedAssetDelta,
            1e17,
            "total assets should move by deposit plus realized revenue"
        );
    }

    function test_ShMonad_FeeBoundsAcrossUtilization() public {
        // Scenario: compare fee quotes at low vs high utilisation by executing actual withdraws.
        // Step 1: neutral pool → sample a small withdraw to measure the low-util fee.
        _deposit(users[0], 40_000 ether);
        _advanceEpoch(false);

        uint256 pool = scenarioShMonad.getCurrentLiquidity();
        require(pool >= baselinePoolLiquidity, "pool should not shrink below baseline");

        uint256 poolDelta = pool - baselinePoolLiquidity;
        require(poolDelta > 0, "pool delta should be positive");

        uint256 netLow = poolDelta / 10;
        if (netLow == 0) netLow = poolDelta;

        uint256 maxNetUser0 = scenarioShMonad.maxWithdraw(users[0]);
        if (netLow > maxNetUser0) netLow = maxNetUser0;

        require(netLow > 0, "withdraw sample must be positive");
        // Preview the shares that will be burned to deliver `netLow` (no-liquidity-limit semantics per ERC-4626 preview).
        uint256 sharesLow = scenarioShMonad.previewWithdraw(netLow);
        // Precompute the before-fee "gross" value of those shares. We do this BEFORE executing the withdraw
        // to avoid exchange-rate drift; this gross is the correct denominator for the fee paid on this tx.
        uint256 grossLow = scenarioShMonad.convertToAssets(sharesLow);
        // Execute the actual withdraw and capture how many shares were burned.
        vm.prank(users[0]);
        uint256 sharesBurnedLow = scenarioShMonad.withdraw(netLow, users[0], users[0]);
        // Sanity: runtime burns the same shares as preview suggested; ensures our gross denominator matches execution.
        assertEq(sharesBurnedLow, sharesLow, "withdraw should burn the previewed shares");

        // Effective fee the user paid on this tx = before-fee gross - delivered net.
        uint256 feeLow = grossLow - netLow;
        uint256 feeLowBps = feeLow * 10_000 / grossLow;

        // Compute the base rate in bps (floor), and require the observed low-util fee to be at least that.
        (, uint256 yInterceptRayOut) = scenarioShMonad.getFeeCurveParams();
        uint256 baseBpsFloor = yInterceptRayOut.mulDiv(10_000, RAY); // floor to nearest bps
        assertGe(feeLowBps, baseBpsFloor, "fee should be at least the base rate at low util");

        // Step 2: add fresh liquidity, then withdraw most of it to sample the high-util fee.
        _deposit(users[1], 60_000 ether);
        _advanceEpoch(false);
        uint256 maxNetUser1 = scenarioShMonad.maxWithdraw(users[1]);
        require(maxNetUser1 > 0, "max withdraw should be positive");
        uint256 netHigh = (maxNetUser1 * 95) / 100;
        if (netHigh == 0) netHigh = maxNetUser1;
        uint256 sharesHigh = scenarioShMonad.previewWithdraw(netHigh);
        // As above, lock in the before-fee gross prior to execution to avoid any drift.
        uint256 grossHigh = scenarioShMonad.convertToAssets(sharesHigh);
        vm.prank(users[1]);
        uint256 sharesBurnedHigh = scenarioShMonad.withdraw(netHigh, users[1], users[1]);
        assertEq(sharesBurnedHigh, sharesHigh, "withdraw should burn the previewed shares");
        uint256 feeHigh = grossHigh - netHigh;
        uint256 feeHighBps = feeHigh * 10_000 / grossHigh;

        assertGe(feeHighBps, feeLowBps, "fee should not decline as util increases");
    }

    function test_ShMonad_FeeMonotonicWithUtilization() public {
        // Scenario: consume liquidity then re-sample fees; values must stay flat or increase.
        // Step 1: seed pool, then measure fee before and after utilisation climb.
        _deposit(users[0], 20_000 ether);
        _advanceEpoch(false);

        uint256 poolBefore = scenarioShMonad.getCurrentLiquidity();
        uint256 feeBpsStart = _feeBpsFromGross(poolBefore / 10);

        uint256 cappedWithdraw = scenarioShMonad.totalSupply() * 2 / 1000; 
        uint256 sharesHalf = scenarioShMonad.balanceOf(users[0]) / 2;
        if (sharesHalf > cappedWithdraw) sharesHalf = cappedWithdraw;
        uint256 previewNet = scenarioShMonad.previewRedeem(sharesHalf);
        uint256 userBalanceBefore = users[0].balance;
        vm.prank(users[0]);
        scenarioShMonad.redeem(sharesHalf, users[0], users[0]);
        uint256 netRedeemed = users[0].balance - userBalanceBefore;
        assertEq(netRedeemed, previewNet, "redeem should deliver preview amount");

        uint256 poolAfter = scenarioShMonad.getCurrentLiquidity();
        require(poolAfter > 0, "pool should remain funded");
        uint256 feeBpsAfter = _feeBpsFromGross(poolAfter / 10);
        assertGe(feeBpsAfter, feeBpsStart, "fee should not decrease when utilization rises");
    }

    function test_ShMonad_FeeContinuityAroundFiftyPercent() public {
        // Scenario: evaluate fee continuity across the 50% utilisation segment boundary by executing withdraws.
        // Step 1: populate the pool, then sample just below the boundary.
        _deposit(users[0], 100_000 ether);
        _advanceEpoch(false);
        uint256 pool = scenarioShMonad.getCurrentLiquidity();
        require(pool >= baselinePoolLiquidity, "pool should not shrink below baseline");
        uint256 poolDelta = pool - baselinePoolLiquidity;
        require(poolDelta > 0, "pool delta should be positive");

        uint256 halfPool = poolDelta / 2;
        uint256 buffer = halfPool / 100;
        if (buffer < 1 ether) buffer = 1 ether;
        if (buffer > halfPool) buffer = halfPool;

        uint256 netBelow = halfPool > buffer ? halfPool - buffer : halfPool;
        uint256 sharesBelow = scenarioShMonad.previewWithdraw(netBelow);
        uint256 grossBelow = scenarioShMonad.convertToAssets(sharesBelow);
        uint256 snapshotId = vm.snapshotState();
        vm.prank(users[0]);
        scenarioShMonad.withdraw(netBelow, users[0], users[0]);
        uint256 feeBelow = grossBelow - netBelow;
        uint256 feeBelowBps = feeBelow * 10_000 / grossBelow;

        bool reverted = vm.revertToState(snapshotId);
        require(reverted, "snapshot revert failed");

        // Step 2: sample just above the boundary and compare.
        uint256 netAbove = halfPool + buffer;
        uint256 maxNet = scenarioShMonad.maxWithdraw(users[0]);
        require(maxNet > 0, "max withdraw should be positive");
        if (netAbove > maxNet) netAbove = maxNet;
        if (netBelow > maxNet) netBelow = maxNet;
        if (netBelow >= netAbove) {
            netBelow = netAbove > buffer ? netAbove - buffer : (netAbove > 1 ? netAbove - 1 : 0);
        }
        require(netBelow > 0 && netAbove > netBelow, "withdraw samples must be positive");
        uint256 sharesAbove = scenarioShMonad.previewWithdraw(netAbove);
        uint256 grossAbove = scenarioShMonad.convertToAssets(sharesAbove);
        vm.prank(users[0]);
        scenarioShMonad.withdraw(netAbove, users[0], users[0]);
        uint256 feeAbove = grossAbove - netAbove;
        uint256 feeAboveBps = feeAbove * 10_000 / grossAbove;

        uint256 delta = feeAboveBps > feeBelowBps ? feeAboveBps - feeBelowBps : feeBelowBps - feeAboveBps;
        assertLe(delta, 15, "fee should be continuous across 50% util");
    }

    function test_ShMonad_FlatMaxFeeWhenTargetZero() public {
        // Scenario: target liquidity forced to zero should clamp the fee near the configured max.
        // Step 1: measure a baseline withdraw while the target buffer is enabled.
        _deposit(users[0], 10_000 ether);
        _advanceEpoch(false);
        uint256 pool = scenarioShMonad.getCurrentLiquidity();
        require(pool > 0, "pool should be funded");
        uint256 netSample = (scenarioShMonad.maxWithdraw(users[0]) * 99) / 100;
        uint256 sharesBaseline = scenarioShMonad.previewWithdraw(netSample);
        uint256 grossBaseline = scenarioShMonad.convertToAssets(sharesBaseline);
        uint256 snapshotId = vm.snapshotState();
        vm.prank(users[0]);
        scenarioShMonad.withdraw(netSample, users[0], users[0]);
        uint256 feeBaseline = grossBaseline - netSample;
        uint256 feeBaselineBps = feeBaseline * 10_000 / grossBaseline;

        bool reverted = vm.revertToState(snapshotId);
        require(reverted, "snapshot revert failed");

        // Step 2: disable the target buffer and confirm the fee jumps higher.
        vm.prank(deployer);
        scenarioShMonad.setPoolTargetLiquidityPercentage(0);
        uint256 maxNetAfterToggle = scenarioShMonad.maxWithdraw(users[0]);
        if (netSample > maxNetAfterToggle) netSample = maxNetAfterToggle;
        uint256 sharesMax = scenarioShMonad.previewWithdraw(netSample);
        uint256 grossMax = scenarioShMonad.convertToAssets(sharesMax);
        vm.prank(users[0]);
        scenarioShMonad.withdraw(netSample, users[0], users[0]);
        uint256 feeMax = grossMax - netSample;
        uint256 feeMaxBps = feeMax * 10_000 / grossMax;

        assertGe(feeMaxBps, feeBaselineBps, "flat max fee should be higher when target is zero");
    }

    // Scenario: previously overflowed when atomic float target exceeded equity; crank should now succeed.
    function test_ShMonad_crank_AtomicFloatOutgrowsEquity() public {
        // Specific conditions required to replicate issue - run only in local mode.
        if(!useLocalMode) return;

        uint256 depositAmount = 50_000 ether;
        vm.prank(deployer);
        scenarioShMonad.setPoolTargetLiquidityPercentage(2e16); // 2%
        _deposit(users[0], depositAmount);

        _advanceEpoch(false);
        _advanceEpoch(false);

        uint256 expectedWithdrawAmount = depositAmount * 2 / 100; // 2% of deposit (total assets)

        // NOTE: The overflow only occurs if the user withdraws via the Atomic Unstake Pool first
        uint256 withdrawAmount = scenarioShMonad.maxWithdraw(users[0]);
        assertApproxEqRel(
            withdrawAmount,
            expectedWithdrawAmount,
            1e16, // 1% relative tolerance, due to max 1% unstake fee
            "User's max withdraw should approximate 2% of deposit"
        );
        _withdraw(users[0], withdrawAmount);

        _advanceEpoch(false);
        _advanceEpoch(false);

        uint256 userShares = scenarioShMonad.balanceOf(users[0]);

        vm.prank(users[0]);
        scenarioShMonad.requestUnstake(userShares);

        // Do all the stuff required to get a global crank going
        vm.roll(block.number + MONAD_EPOCH_LENGTH + 1);
        stakingMock.harnessSyscallOnEpochChange(false);

        bool crankComplete = scenarioShMonad.crank();
        assertTrue(crankComplete, "crank should complete when atomic float exceeds equity");
    }

    function test_ShMonad_AccountingConservation() public {
        // Fork mode uses an existing mainnet ShMonad state; this scenario assumes a fresh environment.
        if (!useLocalMode) vm.skip(true);

        uint256 totalAssetsBefore = scenarioShMonad.totalAssets();

        _deposit(users[0], 12_000 ether);
        _deposit(users[1], 5000 ether);
        _advanceEpoch(false);
        assertEq(
            scenarioShMonad.totalAssets(), totalAssetsBefore + 17_000 ether, "deposits should increase total assets"
        );

        _advanceEpoch(false);
        assertEq(
            scenarioShMonad.totalAssets(),
            totalAssetsBefore + 17_000 ether,
            "no-change epoch should leave assets untouched"
        );

        uint256 boostAmount = 0.75 ether;
        uint64 valIdConservation = uint64(scenarioShMonad.getValidatorIdForCoinbase(validatorCoinbases[0]));
        (,, uint120 rewardsBefore,) = scenarioShMonad.getValidatorRewards(valIdConservation);
        // Track unknown (placeholder) revenue, plus global revenue for conservation check
        (,, uint120 unknownRewardsBefore, uint120 unknownEarnedBeforeRaw) = scenarioShMonad.getValidatorRewards(UNKNOWN_VAL_ID);
        (, uint120 globalEarnedBeforeRaw) = scenarioShMonad.getGlobalRevenue(0);
        uint256 unknownEarnedBefore = uint256(unknownEarnedBeforeRaw);
        uint256 contractBalanceBeforeBoost = address(scenarioShMonad).balance;
        _sendValidatorRewards(0, boostAmount, users[0]);
        uint256 contractBalanceAfterBoost = address(scenarioShMonad).balance;
        assertEq(
            contractBalanceAfterBoost - contractBalanceBeforeBoost, boostAmount, "boost should fund contract balance"
        );
        (,, uint120 rewardsAfter,) = scenarioShMonad.getValidatorRewards(valIdConservation);
        uint256 validatorPayoutDelta = uint256(rewardsAfter) - uint256(rewardsBefore);
        (,, uint120 unknownRewardsAfter, uint120 unknownEarnedAfterRaw) = scenarioShMonad.getValidatorRewards(UNKNOWN_VAL_ID);
        (, uint120 globalEarnedAfterRaw) = scenarioShMonad.getGlobalRevenue(0);
        uint256 unknownEarnedAfter = uint256(unknownEarnedAfterRaw);
        uint256 unknownRewardsDelta = uint256(unknownRewardsAfter) - uint256(unknownRewardsBefore);
        uint256 untrackedRevenueDelta = unknownEarnedAfter - unknownEarnedBefore;
        uint256 globalEarnedDelta = uint256(globalEarnedAfterRaw) - uint256(globalEarnedBeforeRaw);
        assertEq(
            validatorPayoutDelta + unknownRewardsDelta + untrackedRevenueDelta + globalEarnedDelta,
            boostAmount,
            "boost should split between validator payouts and global revenue"
        );
        uint256 totalAssetsAfterBoost = scenarioShMonad.exposeTotalAssets({treatAsWithdrawal: true});
        assertEq(
            totalAssetsAfterBoost,
            totalAssetsBefore + 17_000 ether + unknownRewardsDelta + untrackedRevenueDelta,
            "boost should only realize the portion not gated as earned revenue"
        );

        uint256 redeemCap = scenarioShMonad.totalSupply() * 2 / 1000; // 0.2%
        uint256 sharesToRedeem = scenarioShMonad.balanceOf(users[0]) / 8;
        if (sharesToRedeem > redeemCap) sharesToRedeem = redeemCap;
        uint256 expectedRedeemNet = scenarioShMonad.previewRedeem(sharesToRedeem);
        uint256 userBalanceBefore = users[0].balance;
        vm.prank(users[0]);
        scenarioShMonad.redeem(sharesToRedeem, users[0], users[0]);
        uint256 redeemedNet = users[0].balance - userBalanceBefore;
        assertEq(redeemedNet, expectedRedeemNet, "redeem should match preview");

        uint256 assetsAfterRedeem = scenarioShMonad.exposeTotalAssets({treatAsWithdrawal: true});
        assertLe(assetsAfterRedeem, totalAssetsBefore + 17_000 ether, "redeem should not increase total assets");

        _advanceEpochs(2);
        uint256 assetsAfterEpochs = scenarioShMonad.exposeTotalAssets({treatAsWithdrawal: true});
        if (validatorPayoutDelta > 0) {
            assertGt(assetsAfterEpochs, assetsAfterRedeem, "epochs should realize previously gated boosts");
        } else {
            assertEq(
                assetsAfterEpochs,
                assetsAfterRedeem,
                "epochs should not change total assets when no validator payout was deferred"
            );
        }
    }

    function test_ShMonad_ValidatorRewardsRespectMinPayout() public {
        // Fork mode uses an existing mainnet ShMonad state; this scenario assumes a fresh environment.
        if (!useLocalMode) vm.skip(true);

        address coinbase = validatorCoinbases[0];
        uint64 valId = validatorIds[0];

        uint256 activeStakeTopUp = stakingMock.ACTIVE_VALIDATOR_STAKE();
        vm.deal(coinbase, activeStakeTopUp);
        vm.prank(coinbase);
        stakingMock.delegate{ value: activeStakeTopUp }(valId);
        _advanceEpochs(3);

        // Step 1: send a reward that nets below the payout floor (1 MON) so it should roll forward.
        uint256 subFloorGross = MIN_VALIDATOR_DEPOSIT;
        _sendValidatorRewards(0, subFloorGross, users[0]);

        (,, uint120 pendingSubFloorBefore,) = scenarioShMonad.getValidatorRewards(valId);
        assertGt(pendingSubFloorBefore, 0, "reward queued");
        assertLt(pendingSubFloorBefore, MIN_VALIDATOR_DEPOSIT, "net reward sits below payout floor");

        _advanceEpoch(false);

        (,, uint120 pendingSubFloorAfter,) = scenarioShMonad.getValidatorRewards(valId);
        assertEq(pendingSubFloorAfter, pendingSubFloorBefore, "sub-threshold reward remains queued");

        // Step 2: send enough extra so the combined payout exceeds the floor and is forwarded on crank.
        (, , , , uint16 boostCommissionBps, ) = scenarioShMonad.getAdminValues();
        uint256 netFactor = SCALE - VALIDATOR_FEE_RATE - (VALIDATOR_FEE_RATE * boostCommissionBps) / 10_000;
        require(netFactor > 0, "net factor must be positive");
        uint256 grossForMinPayout = Math.mulDiv(MIN_VALIDATOR_DEPOSIT, SCALE, netFactor) + 1;

        _sendValidatorRewards(0, grossForMinPayout, users[1]);

        (,, uint120 pendingBeforePayout,) = scenarioShMonad.getValidatorRewards(valId);
        uint256 expectedPayout = uint256(pendingBeforePayout);
        assertGe(expectedPayout, MIN_VALIDATOR_DEPOSIT, "combined rewards cross the payout floor");

        vm.expectCall(
            PRECOMPILE,
            expectedPayout,
            abi.encodeWithSelector(IMonadStaking.externalReward.selector, valId)
        );
        _advanceEpoch(false);

        (,, uint120 pendingAfterPayout,) = scenarioShMonad.getValidatorRewards(valId);
        assertEq(pendingAfterPayout, 0, "payout clears validator rewards");
    }

    function test_ShMonad_DelayWindowDelegationSchedulesTwoEpochsOut() public {
        uint64 valId = validatorIds[0];

        _advanceEpoch(false);
        stakingMock.harnessSyscallSnapshot();
        _advanceEpoch(true);

        (uint64 epochBeforeExternal,) = stakingMock.getEpoch();
        uint64 epochBefore = epochBeforeExternal - stakingMock.INITIAL_INTERNAL_EPOCH();

        address delegator = users[0];
        uint256 amount = 25 ether;
        vm.deal(delegator, START_BAL);
        vm.prank(delegator);
        stakingMock.delegate{ value: amount }(valId);

        ( , , , uint256 deltaStake, , uint64 deltaEpoch, ) = stakingMock.getDelegator(valId, delegator);
        assertEq(deltaStake, amount, "delegation should remain scheduled");
        assertEq(deltaEpoch, epochBefore + 2, "delay window bumps activation by two epochs");
    }

    function test_ShMonad_DelayWindowUndelegateRequiresExtraEpochs() public {
        uint64 valId = validatorIds[1];
        address delegator = users[1];
        uint256 amount = 18 ether;

        vm.deal(delegator, START_BAL);
        vm.prank(delegator);
        stakingMock.delegate{ value: amount }(valId);
        _advanceEpoch(false);

        stakingMock.harnessSyscallSnapshot();
        _advanceEpoch(true);
        (uint64 delayEpochExternal,) = stakingMock.getEpoch();
        uint64 delayEpoch = delayEpochExternal - stakingMock.INITIAL_INTERNAL_EPOCH();

        uint8 withdrawalId = 7;
        vm.prank(delegator);
        stakingMock.undelegate(valId, amount, withdrawalId);

        (uint256 wAmount,, uint64 wEpoch) = stakingMock.getWithdrawalRequest(valId, delegator, withdrawalId);
        assertEq(wAmount, amount, "withdrawal request should capture full position");
        assertEq(wEpoch, delayEpoch + 2, "deactivation epoch should skip an extra round during delay");

        vm.prank(delegator);
        vm.expectRevert(MockMonadStakingPrecompile.WithdrawalNotReady.selector);
        stakingMock.withdraw(valId, withdrawalId);

        _advanceEpoch(false);
        vm.prank(delegator);
        vm.expectRevert(MockMonadStakingPrecompile.WithdrawalNotReady.selector);
        stakingMock.withdraw(valId, withdrawalId);

        _advanceEpoch(false);
        vm.prank(delegator);
        vm.expectRevert(MockMonadStakingPrecompile.WithdrawalNotReady.selector);
        stakingMock.withdraw(valId, withdrawalId);

        _advanceEpoch(false);
        vm.prank(delegator);
        stakingMock.withdraw(valId, withdrawalId);
    }

    function test_ShMonad_ScheduledStakeDoesNotEarnPriorRewards() public {
        // Fork mode uses an existing mainnet ShMonad state; this scenario assumes a fresh environment.
        if (!useLocalMode) vm.skip(true);

        uint64 valId = validatorIds[2];
        address delegator = users[2];
        uint256 baseAmount = 12 ether;

        vm.deal(delegator, START_BAL);
        vm.prank(delegator);
        stakingMock.delegate{ value: baseAmount }(valId);
        _advanceEpoch(false);

        uint256 reward = 6 ether;
        vm.deal(address(this), reward);
        stakingMock.harnessSyscallReward{ value: reward }(valId, reward);

        (,,,,,, uint256 consensusStake,,,,,) = stakingMock.getValidator(valId);
        uint256 expectedReward = reward * baseAmount / consensusStake;

        uint256 scheduledAmount = 4 ether;
        vm.deal(delegator, START_BAL);
        vm.prank(delegator);
        stakingMock.delegate{ value: scheduledAmount }(valId);

        uint256 balanceBefore = delegator.balance;
        vm.prank(delegator);
        stakingMock.claimRewards(valId);
        uint256 realized = delegator.balance - balanceBefore;
        assertEq(realized, expectedReward, "scheduled stake should not dilute prior rewards");
    }

    function test_ShMonad_ExternalRewardRequiresConsensus() public {
        address coinbase = makeAddr("ScenarioNoStake");
        uint64 valId = stakingMock.registerValidator(coinbase);

        uint256 rewardUnit = 1 ether;
        vm.deal(address(this), rewardUnit);
        vm.expectRevert(MockMonadStakingPrecompile.NotInValidatorSet.selector);
        stakingMock.externalReward{ value: rewardUnit }(valId);

        uint256 stakeAmount = stakingMock.ACTIVE_VALIDATOR_STAKE();
        vm.deal(coinbase, stakeAmount);
        vm.prank(coinbase);
        stakingMock.delegate{ value: stakeAmount }(valId);
        _advanceEpoch(false);

        vm.deal(address(this), rewardUnit);
        stakingMock.externalReward{ value: rewardUnit }(valId);
    }

    function test_ShMonad_AuthWithdrawnClearsNextEpoch() public {
        address coinbase = makeAddr("ScenarioAuth");
        uint64 valId = stakingMock.registerValidator(coinbase);

        (, uint64 flags,, , , , , , , , ,) = stakingMock.getValidator(valId);
        assertEq(flags & 2, 2, "new validator starts withdrawn");

        uint256 authStake = stakingMock.MIN_VALIDATE_STAKE();
        vm.deal(coinbase, authStake);
        vm.prank(coinbase);
        stakingMock.delegate{ value: authStake }(valId);

        _advanceEpoch(false);
        (, flags,, , , , , , , , ,) = stakingMock.getValidator(valId);
        assertEq(flags & 2, 0, "flag stays cleared after activation");
    }

    function test_ShMonad_CompoundSettlesRewardsBeforeRedelegation() public {
        uint64 valId = validatorIds[3];
        address delegator = users[3];
        uint256 amount = 9 ether;

        vm.deal(delegator, START_BAL);
        vm.prank(delegator);
        stakingMock.delegate{ value: amount }(valId);
        _advanceEpoch(false);

        uint256 reward = 3 ether;
        vm.deal(address(this), reward);
        stakingMock.harnessSyscallReward{ value: reward }(valId, reward);

        (uint64 epochBeforeExternal,) = stakingMock.getEpoch();
        uint64 epochBefore = epochBeforeExternal - stakingMock.INITIAL_INTERNAL_EPOCH();

        vm.prank(delegator);
        stakingMock.compound(valId);

        ( uint256 stake, , , uint256 deltaStake2, , uint64 deltaEpoch2, ) = stakingMock.getDelegator(valId, delegator);
        assertEq(stake, amount, "principal should remain while rewards are scheduled");
        assertGt(deltaStake2, 0, "redelegated rewards should be scheduled");
        assertEq(deltaEpoch2, epochBefore + 1, "compound should target the next epoch");
    }

    function test_ShMonad_PartialCrank_MixedRewards_AtomicAndTraditionalUnstake() public {
        // Scenario outline
        // - 3 shMON holders A/B/C with 65%/30%/5% holdings
        // - Focus on first 5 validators (conceptually 60/20/10/8/2 split for commentary)
        // - Begin a new epoch, then do a PARTIAL crank using a gas-limited call so validators 4 and 5 are not cranked
        // - Inject mixed rewards: boostYield to validators 1 and 5, sendValidatorRewards to 2 and 4
        // - B performs an atomic unstake that consumes the pool liquidity
        // - A requests a large traditional unstake (30% of TVL)
        // - Finish cranking validators 4 and 5; then advance epochs until A can completeUnstake
        // - Assert accounting, balances, and exchange rate consistency along the way

        if(!useLocalMode) vm.skip(true);

        address A = users[0];
        address B = users[1];
        address C = users[2];

        // 1) Seed initial share distribution: A=65%, B=30%, C=5%
        // Using clean vault state, deposit ratios directly translate to share ratios.
        uint256 aDeposit = 6_500 ether;
        uint256 bDeposit = 3_000 ether;
        uint256 cDeposit = 500 ether;
        uint256 aShares = _deposit(A, aDeposit);
        uint256 bShares = _deposit(B, bDeposit);
        uint256 cShares = _deposit(C, cDeposit);

        uint256 supply = scenarioShMonad.totalSupply();
        // Sanity: holder share distribution approximately matches intended percentages
        assertApproxEqRel(aShares * 1e18 / supply, 0.65e18, 1e15, "A ~65% of shares");
        assertApproxEqRel(bShares * 1e18 / supply, 0.30e18, 1e15, "B ~30% of shares");
        assertApproxEqRel(cShares * 1e18 / supply, 0.05e18, 1e15, "C ~5% of shares");

        // 2) Seed revenue weights so staking allocations follow 60/20/10/8/2 for validators 1..5.
        // We do two epochs of proportional rewards so smoothing uses the intended distribution.
        uint256[5] memory weights = [uint256(60), 20, 10, 8, 2];
        uint256 unit = 5 ether; // base unit per weight point
        for (uint256 epochBoost = 0; epochBoost < 2; ++epochBoost) {
            for (uint256 i = 0; i < 5; ++i) {
                uint256 amt = weights[i] * unit;
                // Use a 10% fee rate in 1e18 scale so earnedRevenue exceeds dust and contributes to smoothing.
                uint256 feeRate = 1e17; // 10% in 1e18 scale
                address coinbase = validatorCoinbases[i];
                vm.coinbase(coinbase);
                if (users[0].balance < amt) vm.deal(users[0], amt);
                vm.prank(users[0]);
                scenarioShMonad.sendValidatorRewards{ value: amt }(validatorIds[i], feeRate);
                vm.coinbase(address(0));
            }
            // Roll to next epoch and crank fully to record rewards and advance smoothing windows.
            vm.roll(block.number + MONAD_EPOCH_LENGTH + 1);
            stakingMock.harnessSyscallOnEpochChange(false);
            while (!scenarioShMonad.crank()) {}
        }

        // After two boosted epochs, run one more full crank to distribute queued deposits based on revenue weights.
        vm.roll(block.number + MONAD_EPOCH_LENGTH + 1);
        stakingMock.harnessSyscallOnEpochChange(false);
        while (!scenarioShMonad.crank()) {}

        // Capture baseline working capital for later comparison (to verify net withdraw from validators later)
        (uint128 stakedBefore, ) = scenarioShMonad.getWorkingCapital();
        assertGt(stakedBefore, 0, "expect non-zero staked capital before partial-crank scenario");

        // Assert per-validator target stake proportionality across the first five validators (~60/20/10/8/2)
        {
            uint256[5] memory weightsCheck = [uint256(60), 20, 10, 8, 2];
            uint256 totalWeight = 100;
            uint256 totalTarget;
            uint256[5] memory targets;
            for (uint256 i = 0; i < 5; i++) {
                Epoch memory eLast = scenarioShMonad.exposeValidatorEpochLast(validatorCoinbases[i]);
                targets[i] = eLast.targetStakeAmount;
                totalTarget += eLast.targetStakeAmount;
            }

            assertGt(totalTarget, 0, "total target stake should be positive");

            for (uint256 i = 0; i < 5; i++) {
                // 5% tolerance for rounding/escrow effects
                uint256 ratioScaled = targets[i] * 1e18 / totalTarget;
                uint256 expectedScaled = weightsCheck[i] * 1e18 / totalWeight;
                assertApproxEqRel(ratioScaled, expectedScaled, 5e16, "stake ratio should follow weighted rewards");
            }
        }

        // 3) Start a new epoch then crank partially in multiple gas-limited calls:
        //  - First call with ~1.05M gas triggers only the global tick (validators not processed)
        //  - Then three calls with ~1.1M gas each to process some (but not all) validators
        // The validator loop runs while gasleft() > 1_000_000, so these budgets keep it partial.
        _ensureExactlyFirstNCrankedAmongFirstFive(3);

        // 4) Inject mixed rewards while 4 and 5 are still pending this epoch
        // - Boost overall yield (donations via ShMonad) attributed to A and C
        // - Send validator rewards for validators 2 and 4 via sendValidatorRewards (increases rewardsPayable/reserved)
        uint256 boost1 = 0.9 ether;
        uint256 boost5 = 0.7 ether;
        uint256 reward2 = 1.1 ether;
        uint256 reward4 = 0.6 ether;

        // Snapshot liabilities/reserves to observe immediate deltas from reward injections.
        (uint128 liabRewardsBefore, , ) = scenarioShMonad.globalLiabilities();
        (, uint128 reservedBeforeRewardsSnapshot) = scenarioShMonad.getWorkingCapital();

        // Boost yield donations sit as goodwill until the next epoch settlement (do not affect rewardsPayable/reserved)
        _boostYieldTo(boost1, A);
        _boostYieldTo(boost5, C);

        // Send validator rewards for validators 2 and 4 (affects rewardsPayable and reserved immediately)
        vm.deal(address(this), reward2 + reward4);
        _sendValidatorRewards(1, reward2, address(this)); // validator 2
        _sendValidatorRewards(3, reward4, address(this)); // validator 4

        // Assert: global liabilities (rewardsPayable) and reserved increased by the validator payouts from
        // sendValidatorRewards only. Boost donations do not impact rewardsPayable until epoch settlement.
        // Payout math per sendValidatorRewards:
        //  - feeTaken = amount * feeRate (1e18 scale)
        //  - commissionTaken = feeTaken * boostCommissionBps / 10_000
        //  - validatorPayout = amount - feeTaken - commissionTaken
        (uint128 liabRewardsAfterInj, , ) = scenarioShMonad.globalLiabilities();
        (, uint128 reservedAfterRewardsSnapshot) = scenarioShMonad.getWorkingCapital();
        uint256 deltaLiab = uint256(liabRewardsAfterInj) - uint256(liabRewardsBefore);
        uint256 deltaRes = uint256(reservedAfterRewardsSnapshot) - uint256(reservedBeforeRewardsSnapshot);

        ( , , , , uint16 boostCommissionBps, ) = scenarioShMonad.getAdminValues();
        // Calculate expected validator payouts for rewards to validators 2 and 4
        uint256 fee1 = reward2 * VALIDATOR_FEE_RATE / SCALE;
        uint256 com1 = fee1 * boostCommissionBps / 10_000;
        uint256 payout1 = reward2 - fee1 - com1;
        uint256 fee5 = reward4 * VALIDATOR_FEE_RATE / SCALE;
        uint256 com5 = fee5 * boostCommissionBps / 10_000;
        uint256 payout5 = reward4 - fee5 - com5;
        uint256 expectedLiabDelta = payout1 + payout5;

        // Tolerance: 1e12 wei to account for any rounding in integer division
        assertApproxEqAbs(deltaLiab, expectedLiabDelta, 1e12, "rewards payable should reflect injected payouts");
        assertEq(deltaLiab, deltaRes, "reserved amount tracks rewards payable 1:1 immediately");

        // 5) B performs an atomic withdraw equal to current pool liquidity (net, after fee)
        // Note: maxWithdraw(owner) already caps by available atomic liquidity and the owner’s share balance.
        uint256 liqBefore = scenarioShMonad.getCurrentLiquidity();
        uint256 maxNetForB = scenarioShMonad.maxWithdraw(B);
        require(maxNetForB > 0, "atomic pool must expose some liquidity for B");
        uint256 targetNet = maxNetForB; // full pool liquidity from B perspective
        uint256 bBalBefore = B.balance;
        vm.prank(B);
        scenarioShMonad.withdraw(targetNet, B, B);
        assertEq(B.balance - bBalBefore, targetNet, "B receives the requested net assets");
        // Pool liquidity should decline by roughly the pre-fee gross used for this withdraw.
        // We compare after the next epoch when the atomic pool shift is fully accounted.

        // 6) A requests traditional unstake of 30% of TVL
        //    Snapshot stake before the request to compare later and confirm net withdrawal from validators.
        (uint128 stakedBeforeRequest, ) = scenarioShMonad.getWorkingCapital();
        uint256 tvlNow = scenarioShMonad.totalAssets();
        uint256 aRequestedNet = tvlNow * 30 / 100; // 30% of current TVL
        uint256 aRequestedShares = scenarioShMonad.convertToShares(aRequestedNet);
        // Fix the request at a clean conversion boundary (avoid dust surprises)
        aRequestedNet = scenarioShMonad.convertToAssets(aRequestedShares);
        (, uint128 creditsBefore) = scenarioShMonad.exposeGlobalAssetsCurrent();
        (, uint128 redemptionsBefore,) = scenarioShMonad.globalLiabilities();

        // A does the requestUnstake.
        vm.prank(A);
        uint64 completionEpoch = scenarioShMonad.requestUnstake(aRequestedShares);

        uint64 internalEpochAfterRequest = scenarioShMonad.getInternalEpoch();
        assertGe(completionEpoch, internalEpochAfterRequest + 1, "completion epoch should be in the future");
        (, uint128 creditsAfter) = scenarioShMonad.exposeGlobalAssetsCurrent();
        (, uint128 redemptionsAfter,) = scenarioShMonad.globalLiabilities();
        assertEq(
            uint256(creditsAfter) - creditsBefore,
            aRequestedNet,
            "queueForUnstake increases by requested net"
        );
        assertEq(
            uint256(redemptionsAfter) - uint256(redemptionsBefore),
            aRequestedNet,
            "redemptions payable increases by requested net"
        );

        // 7) Finish cranking validators 4 and 5 (and the rest) with an unbounded loop
        // Note: payment of validator rewards uses the N-1 slot; these rewards were posted to N, so they do not pay
        // out in this epoch even though we finish cranking. They will mature and be handled in the next epoch (and
        // only if amounts meet MIN_VALIDATOR_DEPOSIT).
        while (!scenarioShMonad.crank()) {}

        // All validators cranked now (complete == true in loop termination). Per-validator checks aren’t needed here,
        // but we assert the injected rewards were not paid within the same epoch.
        (uint128 liabRewardsAfterFinish, , ) = scenarioShMonad.globalLiabilities();
        (, uint128 reservedAfterFinish) = scenarioShMonad.getWorkingCapital();
        assertEq(liabRewardsAfterFinish, liabRewardsAfterInj, "rewards payable should not change within same epoch");
        assertEq(reservedAfterFinish, reservedAfterRewardsSnapshot, "reserved unchanged within same epoch");

        // 8) Advance a few epochs to allow the system to settle queues, rebalancing stake vs reserves
        // and to reach A completion epoch. Also check that atomic pool reflected B withdrawal.
        _advanceEpoch(false); // settle atomic pool delta used for B withdraw
        uint256 liqAfter = scenarioShMonad.getCurrentLiquidity();
        assertLt(liqAfter, liqBefore, "atomic pool liquidity should decrease after Bs withdraw");

        // March to A completion epoch and perform final checks
        while (scenarioShMonad.getInternalEpoch() < completionEpoch) {
            _advanceEpoch(false);
        }

        (uint128 stakedAtCompletion, uint128 reservedAtCompletion) = scenarioShMonad.getWorkingCapital();
        (, uint128 redemptionsAtCompletion,) = scenarioShMonad.globalLiabilities();
        (uint128 allocC, uint128 distC) = scenarioShMonad.getAtomicCapital();

        assertGe(
            reservedAtCompletion,
            redemptionsAtCompletion,
            "reserves should be sufficient to cover pending redemptions at completion"
        );

        // By the completion epoch, stake should be at or below the pre-request level; the final decrease is
        // validated after the user completes unstake.
        assertLe(stakedAtCompletion, stakedBeforeRequest, "stake should not exceed pre-request level at completion");

        // 9) A completes the traditional unstake and receives the requested assets
        uint256 aBalBefore = A.balance;

        // Pre-call state dumps to diagnose reserved vs required
        {
            (uint128 stNow, uint128 resNow) = scenarioShMonad.getWorkingCapital();
            (, uint128 redNow,) = scenarioShMonad.globalLiabilities();
            (uint256 utilNow, uint256 allocNow, uint256 availNow, uint256 uWadNow) = scenarioShMonad
                .getAtomicPoolUtilization();
            (uint120 q2sNow, uint120 q2uNow) = scenarioShMonad.getGlobalCashFlows(0);
        }
        vm.prank(A);
        scenarioShMonad.completeUnstake();


        uint256 aNetOut = A.balance - aBalBefore;
        assertEq(aNetOut, aRequestedNet, "A receives the requested net assets upon completion");

        // Final accounting sanity: reserves and liabilities move by the redemption amount
        (uint128 stakedAfter, uint128 reservedAfter) = scenarioShMonad.getWorkingCapital();
        (, uint128 redemptionsAfterFinal,) = scenarioShMonad.globalLiabilities();
        assertEq(redemptionsAfterFinal, redemptionsAtCompletion - uint128(aRequestedNet), "liabilities reduced");
        assertEq(reservedAtCompletion - reservedAfter, aRequestedNet, "reserves consumed by redemption");
        assertLt(stakedAfter, stakedBeforeRequest, "staked capital should decrease net after large withdrawal");

        // Holder balances reflect: B consumed atomic pool liquidity; A exited via traditional path; C unchanged
        assertEq(scenarioShMonad.balanceOf(C), cShares, "Cs shares unchanged");
        assertLt(scenarioShMonad.balanceOf(A), aShares, "A burned shares on requestUnstake");
        assertLt(scenarioShMonad.balanceOf(B), bShares, "B burned shares on atomic withdraw");
    }
}
