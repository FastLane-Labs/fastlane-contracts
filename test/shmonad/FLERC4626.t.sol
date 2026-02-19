// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ShMonad} from "../../src/shmonad/ShMonad.sol";
import {ShMonadEvents} from "../../src/shmonad/Events.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import {BaseTest} from "../base/BaseTest.t.sol";
import { TestShMonad } from "../base/helpers/TestShMonad.sol";
import { FeeLib } from "../../src/shmonad/libraries/FeeLib.sol";
import { FeeParams } from "../../src/shmonad/Types.sol";
import { IERC4626Custom } from "../../src/shmonad/interfaces/IERC4626Custom.sol";
import {
    MONAD_EPOCH_LENGTH,
    SCALE,
    RAY,
    UNSTAKE_BLOCK_DELAY,
    MIN_VALIDATOR_DEPOSIT,
    ATOMIC_MIN_FEE_WEI,
    BPS_SCALE,
    OWNER_COMMISSION_ACCOUNT
} from "../../src/shmonad/Constants.sol";

contract FLERC4626Test is BaseTest, ShMonadEvents {
    using Math for uint256;

    address public alice;
    address public bob;
    address public charlie;
    TestShMonad internal shmonad;
    uint256 public constant INITIAL_BALANCE = 100 ether;

    // Mirror ERC4626 events for expectEmit matching
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    function setUp() public override {
        super.setUp();

        // Setup accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Fund accounts
        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
        vm.deal(deployer, INITIAL_BALANCE);
        vm.deal(charlie, INITIAL_BALANCE);

        // Default coinbase to the "pool/unknown" path for deterministic event expectations.
        // Individual tests can override this when they explicitly want validator attribution.
        vm.coinbase(address(0));

        shmonad = TestShMonad(payable(address(shMonad)));
    }

    function _assetsForBoostFromShares(uint256 shares) internal view returns (uint256 assets) {
        // Keep expectations aligned with `FLERC4626.boostYield(shares, ...)`, which uses:
        // `_convertToAssets(..., deductRecentRevenue: false, rounding: Floor)`.
        uint256 totalAssets = shmonad.exposeTotalAssets(false);
        uint256 supply = shmonad.totalSupply();
        if (supply == 0) return 0;
        assets = Math.mulDiv(shares, totalAssets, supply);
    }

    // ------------------------------------------------------------ //
    // boostYield(shares, from, originator) - accounting branches   //
    // ------------------------------------------------------------ //
    // Scenario: Sender burns their own shares; active validator attribution; no commission; no clamp.
    // Expectation:
    // - Global earnedRevenue increases by full asset value of burned shares
    // - Active validator current earnedRevenue increases by same amount
    // - Unknown validator bucket unchanged; commission bucket unchanged
    function test_FLERC4626_boostYieldFromShares_self_active_noCommission_noClamp() public {
        // Ensure commission is disabled (exercise commission==0 path).
        vm.prank(deployer);
        shmonad.updateBoostCommission(0);

        // Register and activate a validator; set the block coinbase so attribution is to this validator.
        address validator = _ensureActiveValidator(address(0), "val-active-nc");
        vm.coinbase(validator);

        // Deposit so share<->asset rate is ~1:1.
        uint256 depositAmount = 10 ether;
        vm.deal(alice, depositAmount);
        vm.prank(alice);
        uint256 minted = shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        // Move equity fully into atomic pool so available >= any reasonable burn here (no clamp).
        this._ensureNoStakedFundsExternal();

        uint256 sharesToBurn = minted / 4; // 25%
        uint256 expectedAssetValue = _assetsForBoostFromShares(sharesToBurn);

        uint256 ownerZeroYieldBefore = shmonad.balanceOfZeroYieldTranche(OWNER_COMMISSION_ACCOUNT);
        this._snapshotActiveBoostNoCommissionBaselineToStorageExternal(validator);
        uint256 expectedBoostAmount = expectedAssetValue;
        if (!useLocalMode) {
            uint256 atomicLiquidityAvailable =
                uint256(t_allocatedAtomicBefore) - uint256(t_distributedAtomicBefore);
            if (atomicLiquidityAvailable < expectedBoostAmount) {
                expectedBoostAmount = atomicLiquidityAvailable;
            }
        }

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit BoostYield(alice, bob, 0, expectedAssetValue, true);
        shmonad.boostYield(sharesToBurn, alice, bob);
        vm.stopPrank();

        assertEq(shmonad.balanceOf(alice), minted - sharesToBurn, "Alice shares must decrease by burned amount");
        assertEq(
            shmonad.balanceOfZeroYieldTranche(OWNER_COMMISSION_ACCOUNT),
            ownerZeroYieldBefore,
            "Owner commission stays unchanged when disabled"
        );

        this._assertBoostNoCommissionSupplyExternal(sharesToBurn);
        this._assertBoostNoCommissionEarnedRevenueExternal(validator, expectedBoostAmount);
        this._assertBoostNoCommissionAtomicExternal(expectedBoostAmount);
        this._assertBoostNoCommissionQueuesExternal();
        this._assertBoostNoCommissionEquityExternal();
        this._assertBoostNoCommissionLiquidityExternal();
        this._assertBoostNoCommissionWorkingCapitalExternal();
    }

    // Scenario: Sender burns their own shares; active validator attribution; commission applied; and clamp occurs.
    // Setup: Limit atomic pool target so available liquidity is below the assets implied by burned shares.
    // Expectation:
    // - Earned revenue added equals min(assetsAfterCommission, atomicLiquidityAvailable)
    // - Owner's zero-yield tranche increases by the commission amount
    // - Unknown validator/global buckets reflect only the clamped value and no double counting
    function test_FLERC4626_boostYieldFromShares_self_active_commission_and_clamp() public {
        // Register and activate a validator; attribute to it.
        address validator = _ensureActiveValidator(address(0), "val-active-clamp");
        vm.coinbase(validator);

        // Deposit and then set a small target liquidity percentage so clamp is reachable.
        uint256 depositAmount = 10 ether;
        vm.deal(alice, depositAmount);
        vm.prank(alice);
        uint256 minted = shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        // Lower target liquidity to 20% and apply via crank.
        vm.prank(deployer);
        shmonad.setPoolTargetLiquidityPercentage(2e17); // 20%
        _advanceEpochAndCrank();

        // Enable a 1% commission on boost yield from shares.
        uint16 commissionBps = 100; // 1%
        vm.prank(deployer);
        shmonad.updateBoostCommission(commissionBps);

        // Choose a burn large enough to exceed available liquidity so clamping triggers.
        uint256 sharesToBurn = minted / 2; // ~50% of equity.
        uint256 assetsGross = _assetsForBoostFromShares(sharesToBurn);
        uint256 commissionTaken = assetsGross * commissionBps / BPS_SCALE;
        uint256 netAssetsAfterCommission = assetsGross - commissionTaken;

        // Snapshot after applying the pool target and commission config.
        // Use external helpers to avoid via-ir stack-too-deep from large local variable counts.
        this._snapshotActiveBoostCommissionClampBaselineToStorageExternal(validator);

        uint256 atomicLiquidityAvailable = uint256(t_allocatedAtomicBefore) - uint256(t_distributedAtomicBefore);
        uint256 expectedRevenueIncrease =
            netAssetsAfterCommission > atomicLiquidityAvailable ? atomicLiquidityAvailable : netAssetsAfterCommission;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit BoostYield(alice, bob, 0, assetsGross, true);
        shmonad.boostYield(sharesToBurn, alice, bob);

        this._assertBoostNoCommissionSupplyExternal(sharesToBurn);
        this._assertBoostCommissionClampEarnedRevenueExternal(validator, expectedRevenueIncrease);
        this._assertBoostCommissionOwnerZeroYieldExternal(commissionTaken);
        this._assertBoostCommissionClampAtomicExternal(expectedRevenueIncrease);
        this._assertBoostNoCommissionQueuesExternal();
        this._assertBoostNoCommissionLiquidityExternal();
        this._assertBoostNoCommissionWorkingCapitalExternal();
        this._assertBoostCommissionEquityDeltaExternal(commissionTaken);
    }

    // Scenario: Third party attempts to burn someone else's shares without prior approval
    // Expectation: Reverts due to insufficient allowance
    function test_FLERC4626_boostYieldFromShares_thirdPartyWithoutApproval_reverts() public {
        uint256 depositAmount = 6 ether;
        vm.deal(alice, depositAmount);
        vm.prank(alice);
        uint256 minted = shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        uint256 sharesToBurn = minted / 3;
        vm.prank(bob);
        vm.expectRevert(); // ERC20InsufficientAllowance
        shmonad.boostYield(sharesToBurn, alice, bob);
    }

    
    // Scenario: Third party burns someone else's shares with sufficient allowance; active validator attribution
    // Expectation: Succeeds; allowance is spent; earned revenue attributed to active validator and global
    function test_FLERC4626_boostYieldFromShares_thirdPartyWithApproval_active() public {
        // Ensure commission is disabled (exercise commission==0 path).
        vm.prank(deployer);
        shmonad.updateBoostCommission(0);

        // Activate validator and attribute to it via coinbase.
        address validator = _ensureActiveValidator(address(0), "val-active-3p");
        vm.coinbase(validator);

        uint256 depositAmount = 9 ether;
        vm.deal(alice, depositAmount);
        vm.prank(alice);
        uint256 minted = shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        uint256 sharesToBurn = minted / 3;
        uint256 assetsExpected = _assetsForBoostFromShares(sharesToBurn);

        // Ensure sufficient atomic liquidity so boost revenue is not clamped.
        this._ensureNoStakedFundsExternal();

        // Approve Bob to burn on behalf of Alice.
        vm.prank(alice);
        shmonad.approve(bob, sharesToBurn);

        this._snapshotActiveBoostNoCommissionBaselineToStorageExternal(validator);
        uint256 expectedBoostAmount = assetsExpected;
        if (!useLocalMode) {
            uint256 atomicLiquidityAvailable =
                uint256(t_allocatedAtomicBefore) - uint256(t_distributedAtomicBefore);
            if (atomicLiquidityAvailable < expectedBoostAmount) {
                expectedBoostAmount = atomicLiquidityAvailable;
            }
        }

        // Execute as Bob; burn Alice's shares.
        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit BoostYield(alice, bob, 0, assetsExpected, true);
        shmonad.boostYield(sharesToBurn, alice, bob);

        // Assertions (use small external calls to avoid via-ir stack-too-deep).
        assertEq(shmonad.balanceOf(alice), minted - sharesToBurn, "Alice shares reduced by third-party burn");
        assertEq(shmonad.allowance(alice, bob), 0, "Allowance should be fully spent");

        this._assertBoostNoCommissionSupplyExternal(sharesToBurn);
        this._assertBoostNoCommissionEarnedRevenueExternal(validator, expectedBoostAmount);
        this._assertBoostNoCommissionAtomicExternal(expectedBoostAmount);
        this._assertBoostNoCommissionQueuesExternal();
        this._assertBoostNoCommissionEquityExternal();
        this._assertBoostNoCommissionLiquidityExternal();
        this._assertBoostNoCommissionWorkingCapitalExternal();
    }

    // Scenario: Inactive/placeholder validator attribution path
    // Setup: Leave coinbase unset or set to address(0) so _getCurrentValidatorId() resolves to UNKNOWN_VAL_ID.
    // Expectation:
    // - Commission (if any) is credited to owner's zero-yield; remainder credited to UNKNOWN validator bucket only
    // - Global earnedRevenue does not increase in this path
    function test_FLERC4626_boostYieldFromShares_inactivePlaceholder_commissionOnlyToUnknown() public {
        // Ensure coinbase maps to UNKNOWN; do not register/activate a validator for this test.
        vm.coinbase(address(0));

        // Configure commission at 2%.
        uint16 commissionBps = 200;
        vm.prank(deployer);
        shmonad.updateBoostCommission(commissionBps);

        // Deposit to get shares.
        uint256 depositAmount = 8 ether;
        vm.deal(alice, depositAmount);
        vm.prank(alice);
        uint256 minted = shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        // Burn half; compute expected commission and revenue.
        uint256 sharesToBurn = minted / 2;
        uint256 assetsGross = _assetsForBoostFromShares(sharesToBurn);
        uint256 commissionTaken = assetsGross * commissionBps / BPS_SCALE;
        uint256 expectedUnknownRevenue = assetsGross - commissionTaken;
        this._snapshotActiveBoostCommissionClampBaselineToStorageExternal(address(0));

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit BoostYield(alice, bob, 0, assetsGross, true);
        shmonad.boostYield(sharesToBurn, alice, bob);

        // Assertions (use small external calls to avoid via-ir stack-too-deep).
        this._assertBoostNoCommissionSupplyExternal(sharesToBurn);
        this._assertBoostPlaceholderEarnedRevenueExternal(expectedUnknownRevenue);
        this._assertBoostCommissionOwnerZeroYieldExternal(commissionTaken);
        this._assertBoostPlaceholderAtomicUnchangedExternal();
        this._assertBoostNoCommissionQueuesExternal();
        this._assertBoostNoCommissionLiquidityExternal();
        this._assertBoostNoCommissionWorkingCapitalExternal();
        this._assertBoostCommissionEquityDeltaExternal(commissionTaken);
    }

    
    // --------------------------------------------- //
    //                    Helpers                    //
    // --------------------------------------------- //

    // Snapshot state into transient storage vars to avoid `via-ir` stack-too-deep errors
    // from returning/passing large memory structs in tests.
    uint120 internal t_globalEarnedBefore;
    uint120 internal t_activeEarnedBefore;
    uint120 internal t_unknownEarnedBefore;
    uint128 internal t_allocatedAtomicBefore;
    uint128 internal t_distributedAtomicBefore;
    uint120 internal t_qToStakeBefore;
    uint120 internal t_qForUnstakeBefore;
    uint128 internal t_stakedBefore;
    uint128 internal t_reservedBefore;
    uint256 internal t_equityBefore;
    uint256 internal t_liquidityBefore;
    uint256 internal t_supplyBefore;
    uint256 internal t_ownerZeroYieldBefore;

    function _snapshotActiveBoostNoCommissionBaselineToStorage(address validator) internal {
        (, t_globalEarnedBefore) = shmonad.exposeGlobalRevenueCurrent();
        (, t_activeEarnedBefore) = shmonad.exposeValidatorRewardsCurrent(validator);
        (, t_unknownEarnedBefore) = shmonad.exposeValidatorRewardsCurrent(address(0));
        (t_allocatedAtomicBefore, t_distributedAtomicBefore) = shmonad.exposeGlobalAtomicCapital();
        (t_qToStakeBefore, t_qForUnstakeBefore) = shmonad.exposeGlobalAssetsCurrent();
        (t_stakedBefore, t_reservedBefore) = shmonad.exposeGlobalCapitalRaw();
        t_equityBefore = shmonad.exposeTotalAssets(false);
        t_liquidityBefore = shmonad.getCurrentLiquidity();
        t_supplyBefore = shmonad.totalSupply();
    }

    function _snapshotActiveBoostCommissionClampBaselineToStorage(address validator) internal {
        _snapshotActiveBoostNoCommissionBaselineToStorage(validator);
        t_ownerZeroYieldBefore = shmonad.balanceOfZeroYieldTranche(OWNER_COMMISSION_ACCOUNT);
    }

    function _assertBoostNoCommissionSupply(uint256 sharesBurned) internal view {
        assertEq(shmonad.totalSupply(), t_supplyBefore - sharesBurned);
    }

    function _assertBoostNoCommissionEarnedRevenue(address validator, uint256 expectedAssetValue) internal view {
        (, uint120 globalEarnedAfter) = shmonad.exposeGlobalRevenueCurrent();
        (, uint120 activeEarnedAfter) = shmonad.exposeValidatorRewardsCurrent(validator);
        (, uint120 unknownEarnedAfter) = shmonad.exposeValidatorRewardsCurrent(address(0));

        assertEq(uint256(globalEarnedAfter) - uint256(t_globalEarnedBefore), expectedAssetValue);
        assertEq(uint256(activeEarnedAfter) - uint256(t_activeEarnedBefore), expectedAssetValue);
        assertEq(uint256(unknownEarnedAfter) - uint256(t_unknownEarnedBefore), 0);
    }

    function _assertBoostNoCommissionAtomic(uint256 expectedAssetValue) internal view {
        (uint128 allocatedAfter, uint128 distributedAfter) = shmonad.exposeGlobalAtomicCapital();
        assertEq(uint256(distributedAfter) - uint256(t_distributedAtomicBefore), expectedAssetValue);
        assertEq(allocatedAfter, t_allocatedAtomicBefore);
    }

    function _snapshotActiveBoostNoCommissionBaselineToStorageExternal(address validator) external {
        _snapshotActiveBoostNoCommissionBaselineToStorage(validator);
    }

    function _snapshotActiveBoostCommissionClampBaselineToStorageExternal(address validator) external {
        _snapshotActiveBoostCommissionClampBaselineToStorage(validator);
    }

    function _assertBoostNoCommissionSupplyExternal(uint256 sharesBurned) external view {
        _assertBoostNoCommissionSupply(sharesBurned);
    }

    function _assertBoostNoCommissionEarnedRevenueExternal(address validator, uint256 expectedAssetValue) external view {
        _assertBoostNoCommissionEarnedRevenue(validator, expectedAssetValue);
    }

    function _assertBoostNoCommissionAtomicExternal(uint256 expectedAssetValue) external view {
        _assertBoostNoCommissionAtomic(expectedAssetValue);
    }

    function _assertBoostNoCommissionQueuesExternal() external view {
        _assertBoostNoCommissionQueues();
    }

    function _assertBoostNoCommissionWorkingCapitalExternal() external view {
        _assertBoostNoCommissionWorkingCapital();
    }

    function _assertBoostNoCommissionEquityExternal() external view {
        _assertBoostNoCommissionEquity();
    }

    function _assertBoostNoCommissionLiquidityExternal() external view {
        _assertBoostNoCommissionLiquidity();
    }

    function _assertBoostCommissionClampEarnedRevenueExternal(address validator, uint256 expectedRevenueIncrease) external view {
        (, uint120 globalEarnedAfter) = shmonad.exposeGlobalRevenueCurrent();
        (, uint120 activeEarnedAfter) = shmonad.exposeValidatorRewardsCurrent(validator);
        (, uint120 unknownEarnedAfter) = shmonad.exposeValidatorRewardsCurrent(address(0));

        assertEq(uint256(globalEarnedAfter) - uint256(t_globalEarnedBefore), expectedRevenueIncrease);
        assertEq(uint256(activeEarnedAfter) - uint256(t_activeEarnedBefore), expectedRevenueIncrease);
        assertEq(uint256(unknownEarnedAfter) - uint256(t_unknownEarnedBefore), 0);
    }

    function _assertBoostCommissionClampAtomicExternal(uint256 expectedRevenueIncrease) external view {
        (uint128 allocatedAfter, uint128 distributedAfter) = shmonad.exposeGlobalAtomicCapital();
        assertEq(uint256(distributedAfter) - uint256(t_distributedAtomicBefore), expectedRevenueIncrease);
        assertEq(allocatedAfter, t_allocatedAtomicBefore);
    }

    function _assertBoostCommissionOwnerZeroYieldExternal(uint256 commissionTaken) external view {
        uint256 ownerZeroYieldAfter = shmonad.balanceOfZeroYieldTranche(OWNER_COMMISSION_ACCOUNT);
        assertEq(ownerZeroYieldAfter - t_ownerZeroYieldBefore, commissionTaken);
    }

    function _assertBoostCommissionEquityDeltaExternal(uint256 commissionTaken) external view {
        uint256 equityAfter = shmonad.exposeTotalAssets(false);
        assertEq(t_equityBefore - equityAfter, commissionTaken);
    }

    function _assertBoostPlaceholderEarnedRevenueExternal(uint256 expectedUnknownRevenue) external view {
        (, uint120 globalEarnedAfter) = shmonad.exposeGlobalRevenueCurrent();
        (, uint120 unknownEarnedAfter) = shmonad.exposeValidatorRewardsCurrent(address(0));

        assertEq(uint256(globalEarnedAfter) - uint256(t_globalEarnedBefore), 0);
        assertEq(uint256(unknownEarnedAfter) - uint256(t_unknownEarnedBefore), expectedUnknownRevenue);
    }

    function _assertBoostPlaceholderAtomicUnchangedExternal() external view {
        (uint128 allocatedAfter, uint128 distributedAfter) = shmonad.exposeGlobalAtomicCapital();
        assertEq(allocatedAfter, t_allocatedAtomicBefore);
        assertEq(distributedAfter, t_distributedAtomicBefore);
    }

    function _assertBoostNoCommissionQueues() internal view {
        (uint120 qToStakeAfter, uint120 qForUnstakeAfter) = shmonad.exposeGlobalAssetsCurrent();
        assertEq(qToStakeAfter, t_qToStakeBefore);
        assertEq(qForUnstakeAfter, t_qForUnstakeBefore);
    }

    function _assertBoostNoCommissionWorkingCapital() internal view {
        (uint128 stakedAfter, uint128 reservedAfter) = shmonad.exposeGlobalCapitalRaw();
        assertEq(stakedAfter, t_stakedBefore);
        assertEq(reservedAfter, t_reservedBefore);
    }

    function _assertBoostNoCommissionEquity() internal view {
        assertEq(shmonad.exposeTotalAssets(false), t_equityBefore);
    }

    function _assertBoostNoCommissionLiquidity() internal view {
        assertEq(shmonad.getCurrentLiquidity(), t_liquidityBefore);
    }

    function _ensureNoStakedFundsExternal() external {
        _ensureNoStakedFunds();
    }

    function _ensureNoStakedFunds() internal {
        // On mainnet forks, "unstake everything" is not a realistic or cheap operation.
        // This helper exists to put the system in a predictable “fully liquid” posture for unit tests.
        // In fork mode, we instead just ensure there's ample atomic liquidity for small test operations.
        if (!useLocalMode) {
            _ensureAtomicLiquidity(50 ether, SCALE, 0);
            return;
        }

        // Local-mode: advance epochs so pending queueToStake is processed.
        for (uint256 i = 0; i < 4; i++) {
            _advanceEpochAndCrank();
        }

        // Now set the pool target to 100% so all equity migrates into the atomic pool.
        vm.startPrank(deployer);
        shmonad.setPoolTargetLiquidityPercentage(SCALE);
        vm.stopPrank();

        // Continue advancing epochs until all equity sits in the atomic pool.
        for (uint256 i = 0; i < 32; i++) {
            _advanceEpochAndCrank();

            uint256 _totalAssets = shmonad.totalAssets();
            uint256 _currentLiquidity = shmonad.getCurrentLiquidity();
            if (_totalAssets == _currentLiquidity) {
                return;
            }
        }

        // Final assert if convergence failed within the iteration budget.
        uint256 totalAssets = shmonad.totalAssets();
        uint256 currentLiquidity = shmonad.getCurrentLiquidity();
        assertEq(totalAssets, currentLiquidity, "totalAssets must equal current liquidity");
    }

    function _advanceEpochAndCrank() internal {
        vm.roll(block.number + UNSTAKE_BLOCK_DELAY + 1);
        staking.harnessSyscallOnEpochChange(false);
        if (!useLocalMode) {
            // Fork-mode optimization:
            // `while(!crank()) {}` iterates the entire active validator set on mainnet forks (dozens of validators),
            // which makes this file's tests painfully slow. For ERC-4626 semantics we primarily need the *global* crank
            // effects (target liquidity updates, smoother updates, internal epoch bump) and not per-validator settlement.
            uint64 internalEpochBefore = shmonad.getInternalEpoch();
            for (uint256 i = 0; i < 4; i++) {
                shmonad.harnessCrankGlobalOnly();
                if (shmonad.getInternalEpoch() > internalEpochBefore) {
                    return;
                }
            }
            revert("fork: crank did not advance internal epoch");
        }

        while (!shmonad.crank()) {}
    }

    function _ensureActiveValidator(address validator, string memory tag) internal returns (address) {
        // Fork-mode: do not register new validators into the forked mainnet ShMonad / precompile mirror.
        // Use an existing active validator from the onchain registry.
        if (!useLocalMode) {
            (uint64[] memory ids, address[] memory coinbases) = shmonad.listActiveValidators();
            require(ids.length != 0, "no active validators on fork");
            require(coinbases[0] != address(0), "active validator coinbase is zero");
            staking.harnessSetProposerValId(ids[0]);
            return coinbases[0];
        }

        address val = validator == address(0) ? makeAddr(tag) : validator;
        vm.startPrank(deployer);
        uint64 valId = staking.registerValidator(val);
        shMonad.addValidator(valId, val);
        vm.stopPrank();

        staking.harnessEnsureDelegator(valId, address(shMonad));
        vm.deal(val, MIN_VALIDATOR_DEPOSIT);
        vm.startPrank(val);
        staking.delegate{ value: MIN_VALIDATOR_DEPOSIT }(valId);
        vm.stopPrank();

        bool active;
        for (uint256 i = 0; i < 3; ++i) {
            _advanceEpochAndCrank();
            if (shMonad.isValidatorActive(valId)) {
                active = true;
                break;
            }
        }
        require(active, "validator should be active");
        return val;
    }

    // ------------------------------------------------------------ //
    // Extreme amount previews: demonstrate no overflow at ~1.14e32 //
    // 1e32 = 100 trillion MON, far more than total supply          //
    // ------------------------------------------------------------ //
    /// The FeeLib tail-branch mulDiv thresholds imply safe operation up to:
    /// - Forward (redeem/previewRedeem): (gross - gross1) <= floor(type(uint256).max / RAY) ≈ 1.1579e32
    /// - Inverse (withdraw/previewWithdraw): (net - net1) <= floor(type(uint256).max / (RAY + rMax)) ≈ 1.146e32
    /// Using 1.14e32 falls below both thresholds for the default fee curve.
    function test_FLERC4626_withdraw_extreme_noOverflow_100TrillionMon() public {
        // Seed a small deposit so share<->asset rate is ~1:1 and pool is initialized.
        uint256 seed = 1 ether;
        vm.startPrank(alice);
        shmonad.deposit{ value: seed }(seed, alice);
        vm.stopPrank();

        // Move all equity into the atomic pool so previews use a consistent (R0, L).
        this._ensureNoStakedFundsExternal();

        // 1.14e32 assets target — below the inverse tail threshold.
        uint256 extremeNet = 114e30;

        // Expect no revert: previewWithdraw computes gross given net via FeeLib inverse path.
        uint256 shares = shmonad.previewWithdraw(extremeNet);
        // Basic sanity: non-zero shares for a non-zero ask.
        assertGt(shares, 0);

        // Also exercise the actual withdraw path with a realistic amount within the seed deposit.
        uint256 withdrawAssets = 0.25 ether;
        uint256 expectedShares = shmonad.previewWithdraw(withdrawAssets);
        uint256 aliceNativeBefore = alice.balance;
        uint256 aliceSharesBefore = shmonad.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit Withdraw(alice, alice, alice, withdrawAssets, expectedShares);
        uint256 burned = shmonad.withdraw(withdrawAssets, alice, alice);
        vm.stopPrank();

        assertEq(burned, expectedShares, "withdraw burned shares must match preview");
        assertEq(shmonad.balanceOf(alice), aliceSharesBefore - expectedShares, "shares reduced by burned amount");
        assertEq(alice.balance, aliceNativeBefore + withdrawAssets, "receiver got net assets");
    }

    function test_FLERC4626_redeem_extreme_noOverflow_100TrillionMon() public {
        // Seed initial state for stable preview math.
        uint256 seed = 1 ether;
        vm.startPrank(alice);
        shmonad.deposit{ value: seed }(seed, alice);
        vm.stopPrank();

        this._ensureNoStakedFundsExternal();

        // Pass 1.14e32 shares so that grossAssets computed in previewRedeem is ~1.14e32 as well
        // (share<->asset rate ~1:1 after the seed deposit).
        uint256 extremeShares = 114e30;

        // Expect no revert: previewRedeem runs the forward fee path with mulDiv on (gross - gross1) * RAY
        // which is safe at this magnitude.
        uint256 assets = shmonad.previewRedeem(extremeShares);
        // Sanity: preview should return a positive net for default rMax < 100%.
        assertGt(assets, 0);

        // Also exercise the actual redeem path with the seed shares held by Alice.
        uint256 aliceShares = shmonad.balanceOf(alice);
        uint256 redeemShares = aliceShares / 2;
        if (redeemShares == 0) redeemShares = 1; // in case rounding left 0

        uint256 expectedAssets = shmonad.previewRedeem(redeemShares);
        uint256 aliceNativeBefore = alice.balance;

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit Withdraw(alice, alice, alice, expectedAssets, redeemShares);
        uint256 netOut = shmonad.redeem(redeemShares, alice, alice);
        vm.stopPrank();

        assertEq(netOut, expectedAssets, "redeem returned net must match preview");
        assertEq(shmonad.balanceOf(alice), aliceShares - redeemShares, "shares reduced by redeemed amount");
        assertEq(alice.balance, aliceNativeBefore + expectedAssets, "receiver got net assets");
    }

    // --------------------------------------------- //
    //              ERC4626 Basic Tests              //
    // --------------------------------------------- //

    function test_FLERC4626_boostYield_Payable_EmitsEvent() public {
        uint256 boostValue = 1 ether;
        address originator = bob; // distinct from sender to verify yieldOriginator
        uint256 initialContractBalance = address(shmonad).balance;
        uint256 initialPoolLiq = shmonad.getCurrentLiquidity();

        vm.startPrank(alice);
        // Expect: sender=alice, yieldOriginator=bob, validatorId=0, amount=boostValue, sharesBurned=false
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit BoostYield(alice, originator, 0, boostValue, false);

        shmonad.boostYield{value: boostValue}(originator);
        vm.stopPrank();

        // Contract balance holds the received MON
        assertEq(
            address(shmonad).balance,
            initialContractBalance + boostValue,
            "Contract balance should increase by boostValue"
        );
        // Pool liquidity should not change as yield is only realized on epoch change
        assertEq(
            shmonad.getCurrentLiquidity(),
            initialPoolLiq,
            "Pool liquidity should not change"
        );
    }

    function test_FLERC4626_boostYield_BurnShares_EmitsEvent() public {
        uint256 depositAmount = 10 ether;
        uint256 sharesToBurn = 2 ether;

        // Alice deposits to get shares
        vm.deal(alice, depositAmount); // Fund Alice for deposit
        vm.startPrank(alice);
        uint256 sharesReceived = shmonad.deposit{value: depositAmount}(depositAmount, alice);
        // For the first depositor, shares received should equal assets deposited due to ERC4626 logic
        // and our _convertToShares with +1 logic for empty supply/assets.
        uint256 expectedSharesViaPreview = shmonad.previewDeposit(depositAmount);
        assertEq(sharesReceived, expectedSharesViaPreview, "Shares received should match public previewDeposit output");
        vm.stopPrank();

        uint256 contractBalanceAfterDeposit = address(shmonad).balance;
        uint256 poolLiquidityBefore = shmonad.getCurrentLiquidity();
        uint256 totalSupplyBeforeBurn = shmonad.totalSupply();

        // Calculate the expected asset value for the BoostYield event.
        // boostYield(shares) uses the gross value without applying any unstake fee,
        // so the expected amount equals convertToAssets(sharesToBurn).
        uint256 expectedAssetValue = _assetsForBoostFromShares(sharesToBurn);

        vm.startPrank(alice);
        // Expect BoostYield(alice, expectedAssetValue)
        vm.expectEmit(true, true, true, true, address(shmonad));
        emit BoostYield(alice, bob, 0, expectedAssetValue, true); // validatorId=0 when routed to pool

        shmonad.boostYield(sharesToBurn, alice, bob);
        vm.stopPrank();

        // Assertions
        assertEq(shmonad.balanceOf(alice), sharesReceived - sharesToBurn, "Alice's shares should be reduced");
        assertEq(shmonad.totalSupply(), totalSupplyBeforeBurn - sharesToBurn, "Total supply should be reduced");
        // The boostYield(shares, from) function does not itself change the contract's ETH balance.
        assertEq(address(shmonad).balance, contractBalanceAfterDeposit, "Contract ETH balance should remain unchanged by this type of boost");
        // current pool liquidity should also not change as yield is realized on epoch change
        assertEq(
            shmonad.getCurrentLiquidity(),
            poolLiquidityBefore,
            "Pool liquidity should not change"
        );
    }

    function test_FLERC4626_atomicPoolReachesFullLiquidityAfterLargeDeposit() public {
        // This test asserts strict "fully liquid" invariants that are only true in a fresh/local deployment.
        // On a mainnet fork, ShMonad already has large staked capital and the atomic pool won't equal totalAssets.
        if (!useLocalMode) vm.skip(true);

        this._ensureNoStakedFundsExternal();
        uint256 baselineAssets = shmonad.totalAssets();
        uint256 baselineLiquidity = shmonad.getCurrentLiquidity();
        assertEq(baselineAssets, baselineLiquidity, "baseline must be fully liquid");

        uint256 smallDeposit = 60 ether;
        vm.deal(alice, smallDeposit);
        vm.prank(alice);
        shmonad.deposit{ value: smallDeposit }(smallDeposit, alice);

        for (uint256 i = 0; i < 2; i++) _advanceEpochAndCrank();

        uint256 largeDeposit = 100_000 ether;
        vm.deal(bob, largeDeposit);
        vm.prank(bob);
        shmonad.deposit{ value: largeDeposit }(largeDeposit, bob);

        vm.prank(deployer);
        shmonad.setPoolTargetLiquidityPercentage(SCALE);

        for (uint256 i = 0; i < 8; i++) {
            _advanceEpochAndCrank();
            if (shmonad.totalAssets() == shmonad.getCurrentLiquidity()) {
                break;
            }
        }

        uint256 expectedTotalAssets = baselineAssets + smallDeposit + largeDeposit;
        assertEq(shmonad.totalAssets(), expectedTotalAssets, "total assets should include both deposits");
        assertEq(
            shmonad.getCurrentLiquidity(),
            expectedTotalAssets,
            "atomic pool should hold the entire equity at 100% target"
        );

        uint256 deltaLiquidity = shmonad.getCurrentLiquidity() - baselineLiquidity;
        assertEq(deltaLiquidity, smallDeposit + largeDeposit, "available liquidity should grow by 100060 MON");
    }

    // Basic deposit happy path: shares == previewDeposit; totals and balances updated
    function test_FLERC4626_deposit_HappyPath() public {
        uint256 assets = 10 ether;
        vm.deal(alice, assets);

        vm.startPrank(alice);
        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 totalAssetsBefore = shMonad.totalAssets();
        uint256 previewShares = shMonad.previewDeposit(assets);
        // Expect Deposit event (sender=alice, owner=alice)
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Deposit(alice, alice, assets, previewShares);

        uint256 shares = shMonad.deposit{ value: assets }(assets, alice);

        // Shares equal preview; supply/assets increase; wallet balances reflect changes
        assertEq(shares, previewShares);
        assertEq(shMonad.totalSupply(), totalSupplyBefore + shares);
        assertEq(shMonad.totalAssets(), totalAssetsBefore + assets);
        assertEq(shMonad.balanceOf(alice), shares);

        // With fees enabled, redeeming the freshly minted shares should be assets minus the fee
        // predicted by the fee curve (previews ignore liquidity caps by design).
        uint256 gross = shMonad.convertToAssets(shares);
        (uint256 mRay, uint256 cRay) = shMonad.getFeeCurveParams();
        FeeParams memory p = FeeParams({ mRay: uint128(mRay), cRay: uint128(cRay) });
        uint256 R0 = shMonad.getCurrentLiquidity();
        uint256 L = shMonad.getTargetLiquidity();
        (uint256 fee, uint256 net) = FeeLib.solveNetGivenGross(gross, R0, L, p);
        fee;
        // ERC-4626 previews ignore liquidity caps but apply fees. For L==0, treat full utilization fee.
        if (L == 0) {
            uint256 rMax = uint256(p.cRay) + uint256(p.mRay);
            uint256 expected = rMax >= 1e27 ? 0 : gross - Math.mulDiv(gross, rMax, 1e27);
            assertEq(shMonad.previewRedeem(shares), expected, "previewRedeem reflects fee (no-liquidity)");
        } else {
            assertEq(shMonad.previewRedeem(shares), net, "previewRedeem equals FeeLib net (no-liquidity)");
        }
        vm.stopPrank();
    }

    // Using previewMint amount in deposit should mint exactly the target shares
    function test_FLERC4626_depositUsingPreviewMintAmount_exactShares() public {
        uint256 targetShares = 1_010_003_000_000_000; // arbitrary non-round number
        uint256 assets = shMonad.previewMint(targetShares);
        vm.deal(alice, assets);

        vm.startPrank(alice);
        uint256 minted = shMonad.deposit{ value: assets }(assets, alice);
        vm.stopPrank();
        assertEq(minted, targetShares);
    }

    // Deposit should revert if msg.value != assets
    function test_FLERC4626_deposit_msgValueMismatch_reverts() public {
        uint256 assets = 20 ether;
        vm.prank(alice);
        vm.expectRevert(ShMonadErrors.IncorrectNativeTokenAmountSent.selector);
        shmonad.deposit{ value: assets - 1 }(assets, alice);
    }

    // Mint should revert if msg.value != required assets
    function test_FLERC4626_mint_msgValueMismatch_reverts() public {
        uint256 shares = 3 ether;
        uint256 requiredAssets = shmonad.previewMint(shares);
        vm.prank(alice);
        vm.expectRevert(ShMonadErrors.IncorrectNativeTokenAmountSent.selector);
        shmonad.mint{ value: requiredAssets - 1 }(shares, alice);
    }

    // Mint happy path: assets == previewMint and Deposit event emitted
    function test_FLERC4626_mint_HappyPath() public {
        uint256 targetShares = 5 ether;
        uint256 requiredAssets = shmonad.previewMint(targetShares);
        vm.deal(alice, requiredAssets);

        vm.startPrank(alice);
        uint256 totalSupplyBefore = shMonad.totalSupply();
        uint256 totalAssetsBefore = shMonad.totalAssets();
        // Expect Deposit event from mint as per ERC4626
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Deposit(alice, alice, requiredAssets, targetShares);
        uint256 paidAssets = shmonad.mint{ value: requiredAssets }(targetShares, alice);
        vm.stopPrank();

        assertEq(paidAssets, requiredAssets, "mint returns assets paid");
        assertEq(shmonad.balanceOf(alice), targetShares);
        assertEq(shMonad.totalSupply(), totalSupplyBefore + targetShares);
        assertEq(shMonad.totalAssets(), totalAssetsBefore + requiredAssets);
    }

    // Withdraw should revert when receiver is address(0)
    function test_FLERC4626_withdraw_ZeroReceiver_reverts() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        shmonad.deposit{value: depositAmount}(depositAmount, alice);
        vm.stopPrank();

        this._ensureNoStakedFundsExternal();

        uint256 withdrawAmount = 1 ether;

        vm.prank(alice);
        vm.expectRevert(ShMonadErrors.ZeroAddress.selector);
        shmonad.withdraw(withdrawAmount, address(0), alice);
    }

    // Withdraw path (no staked funds): deposit then withdraw a portion; verify shares burned equals previewWithdraw
    function test_FLERC4626_withdraw_HappyPath_NoStakedFunds() public {
        uint256 depositAmount = 12 ether;

        // 1) Alice deposits
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Deposit(alice, alice, depositAmount, shmonad.previewDeposit(depositAmount));
        uint256 minted = shmonad.deposit{ value: depositAmount }(depositAmount, alice);
        vm.stopPrank();

        // 2) Ensure all equity sits in the atomic pool so maxWithdraw > 0
        this._ensureNoStakedFundsExternal();

        // 3) Alice withdraws a portion; event and burn should match preview
        uint256 withdrawAssets = 4 ether;
        uint256 expectedShares = shmonad.previewWithdraw(withdrawAssets);
        uint256 aliceBalBefore = alice.balance;

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true, address(shMonad));
        emit Withdraw(alice, alice, alice, withdrawAssets, expectedShares);
        uint256 burned = shmonad.withdraw(withdrawAssets, alice, alice);
        vm.stopPrank();

        assertEq(burned, expectedShares, "burned shares should match previewWithdraw");
        assertEq(alice.balance, aliceBalBefore + withdrawAssets, "assets transferred to receiver");
        assertEq(shmonad.balanceOf(alice), minted - burned, "remaining shares reduced");
    }

    // Max functions semantics when fees are disabled
    function test_FLERC4626_maxFunctions_noFees_NoStakedFunds() public {
        vm.prank(deployer);
        shmonad.setUnstakeFeeCurve(0, 0); // Disable fees

        uint256 amount = 10 ether;
        vm.prank(alice);
        uint256 minted = shmonad.deposit{ value: amount }(amount, alice);

        // Ensure ample liquidity so maxWithdraw > 0 in fork runs.
        this._ensureNoStakedFundsExternal();

        // maxDeposit/maxMint are unbounded (type(uint128).max)
        assertEq(shmonad.maxDeposit(alice), type(uint128).max);
        assertEq(shmonad.maxMint(alice), type(uint128).max);

        // With no fees, the only constraint is liquidity caps.
        uint256 maxW = shmonad.maxWithdraw(alice);
        uint256 gross = shmonad.convertToAssets(minted);
        uint256 R0 = shmonad.getCurrentLiquidity();
        uint256 expectedMaxWithdraw = Math.min(gross, R0);
        assertEq(maxW, expectedMaxWithdraw, "maxWithdraw should be gross capped by liquidity when fees disabled");

        uint256 maxRedeemShares = shmonad.maxRedeem(alice);
        if (gross <= R0) {
            assertEq(maxRedeemShares, minted, "maxRedeem should equal balance when liquidity doesn't bind");
        } else {
            uint256 expectedMaxRedeem = shmonad.convertToShares(expectedMaxWithdraw);
            assertEq(maxRedeemShares, expectedMaxRedeem, "maxRedeem should match capped gross in shares");
        }
        assertLe(
            shmonad.previewRedeem(maxRedeemShares),
            maxW,
            "previewRedeem(maxRedeem) should not exceed maxWithdraw"
        );
    }

    // Previews should never revert and ignore liquidity caps
    function test_FLERC4626_previewsIgnoreLiquidity_largeRequests() public view {
        // No deposit needed; previews must not revert
        uint256 hugeAssets = 1_000_000 ether;
        uint256 hugeShares = 1_000_000 ether;
        // Should not revert
        shmonad.previewWithdraw(hugeAssets);
        shmonad.previewRedeem(hugeShares);
    }

    // Stateful vs preview consistency for withdraw: shares burned matches preview
    function test_FLERC4626_statefulMatchesPreview_forWithdraw_NoStakedFunds() public {
        uint256 amount = 7 ether;
        vm.prank(alice);
        shmonad.deposit{ value: amount }(amount, alice);

        // Ensure liquidity is available so maxWithdraw > 0
        this._ensureNoStakedFundsExternal();

        uint256 ask = 2 ether;
        uint256 previewShares = shmonad.previewWithdraw(ask);
        vm.prank(alice);
        uint256 burned = shmonad.withdraw(ask, alice, alice);
        assertEq(burned, previewShares, "stateful burn equals previewWithdraw");
    }

    // Redeem should revert when receiver is address(0)
    function test_FLERC4626_redeem_ZeroReceiver_reverts() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        shmonad.deposit{value: depositAmount}(depositAmount, alice);
        vm.stopPrank();

        this._ensureNoStakedFundsExternal();

        uint256 redeemShares = 1 ether;

        vm.prank(alice);
        vm.expectRevert(ShMonadErrors.ZeroAddress.selector);
        shmonad.redeem(redeemShares, address(0), alice);
    }

    // Redeem path (no staked funds): deposit then redeem chosen shares; verify assets match previewRedeem
    function test_FLERC4626_redeem_HappyPath_NoStakedFunds() public {
        uint256 depositAmount = 9 ether;

        // 1) Alice deposits
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Deposit(alice, alice, depositAmount, shmonad.previewDeposit(depositAmount));
        shmonad.deposit{ value: depositAmount }(depositAmount, alice);
        vm.stopPrank();

        // 2) Ensure all equity sits in the atomic pool so maxRedeem is unconstrained by liquidity
        this._ensureNoStakedFundsExternal();

        // 3) Alice redeems selected shares
        uint256 shares = 3 ether;
        uint256 expectedAssets = shmonad.previewRedeem(shares);

        vm.startPrank(alice);
        uint256 balBefore = alice.balance;
        uint256 assetsOut = shmonad.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(assetsOut, expectedAssets, "actual assets out != previewRedeem assets out");
        assertEq(alice.balance, balBefore + expectedAssets, "assets delivered");
    }

    // Stateful vs preview consistency for redeem: assets match previewRedeem
    function test_FLERC4626_statefulMatchesPreview_forRedeem_NoStakedFunds() public {
        uint256 amount = 8 ether;
        vm.prank(alice);
        shmonad.deposit{ value: amount }(amount, alice);

        // Ensure liquidity is available so maxRedeem > 0
        this._ensureNoStakedFundsExternal();

        uint256 shares = 2 ether;
        uint256 previewAssets = shmonad.previewRedeem(shares);
        vm.prank(alice);
        uint256 assetsOut = shmonad.redeem(shares, alice, alice);
        assertEq(assetsOut, previewAssets, "stateful assets equals previewRedeem");
    }

    // --------------------------------------------- //
    //              View Function Tests              //
    // --------------------------------------------- //

    function test_FLERC4626_previewRedeemDetailed_and_previewWithdrawDetailed() public {
        // Seed with a deposit so previews are meaningful
        uint256 dep = 12 ether;
        vm.prank(alice);
        shmonad.deposit{ value: dep }(dep, alice);

        // Ensure some liquidity is available to avoid zero-division paths
        this._ensureNoStakedFundsExternal();

        // previewRedeemDetailed
        uint256 shares = 2 ether;
        (uint256 gross, uint256 fee, uint256 net) = shmonad.previewRedeemDetailed(shares);
        assertEq(gross - fee, net, "previewRedeem: gross - fee should equal net");
        // previewRedeem returns net
        assertEq(shmonad.previewRedeem(shares), net, "previewRedeem should equal detailed net");

        // previewWithdrawDetailed
        uint256 askNet = 1 ether;
        (uint256 sharesOut, uint256 grossOut, uint256 feeOut) = shmonad.previewWithdrawDetailed(askNet);
        // NOTE: there is a small 6 wei overestimate in returned net vs askNet given 
        assertApproxEqAbs(grossOut - feeOut, askNet, 6, "previewWithdraw: gross - fee should equal target net");
        assertEq(shmonad.previewWithdraw(askNet), sharesOut, "previewWithdraw should match detailed shares");
    }

    // When fees are enabled, previewRedeem should return less than convertToAssets for same shares
    function test_FLERC4626_previewRedeemLessThanConvertToAssets_whenFeesEnabled() public {
        // Seed pool liquidity with a deposit
        uint256 depositAmount = 20 ether;
        vm.prank(alice);
        shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        // Pick a shares amount to redeem
        uint256 shares = 3 ether;
        uint256 assets = shmonad.convertToAssets(shares);
        uint256 preview = shmonad.previewRedeem(shares);

        // With fees enabled and liquidity present, preview should apply a fee > 0
        assertLt(preview, assets, "previewRedeem should apply fee when enabled");
    }

    // Scenario: revenue smoothing keeps `convertToShares` more conservative than `previewDeposit`
    // until the smoothing window expires.
    // Steps:
    // 1) Inject artificial revenue into the smoother while a user deposit exists.
    // 2) Validate mid-epoch that `convertToShares` >= `previewDeposit` due to smoothing.
    // 3) Advance past the smoothing window and ensure the two values converge again.
    function test_FLERC4626_smoothing_convertToShares_gtPreviewDepositMidEpoch() public {
        vm.deal(user, 20 ether);
        vm.prank(user);
        shMonad.deposit{ value: 20 ether }(20 ether, user);

        // Step 1: manipulate the revenue smoother so convertToShares sees pending revenue.
        uint256 tip = 5 ether;
        bytes32 rewardsSlot = bytes32(uint256(40));
        uint256 rewardsPacked = uint256(vm.load(address(shMonad), rewardsSlot));
        uint256 maskEarned = ((uint256(1) << 120) - 1) << 120;
        uint256 alwaysTrueMask = uint256(1) << 240;
        rewardsPacked = (rewardsPacked & ~maskEarned) | (tip << 120) | alwaysTrueMask;
        vm.store(address(shMonad), rewardsSlot, bytes32(rewardsPacked));

        uint256 epochBlock = block.number;
        uint256 smootherPacked = tip | (uint256(uint64(epochBlock)) << 120);
        vm.store(address(shMonad), bytes32(uint256(23)), bytes32(smootherPacked));

        uint256 assets = 20 ether;
        // 2) Smoothing should push the stateful conversion above the preview path mid-epoch.
        uint256 convertShares = shMonad.convertToShares(assets);
        uint256 previewShares = shMonad.previewDeposit(assets);
        assertGe(convertShares, previewShares, "convertToShares should not be lower than previewDeposit under smoothing");

        uint256 equityWithoutDeduct = shmonad.exposeTotalAssets(false);
        uint256 equityWithDeduct = shmonad.exposeTotalAssets(true);
        uint256 deltaEquity =
            equityWithoutDeduct > equityWithDeduct ? equityWithoutDeduct - equityWithDeduct : 0;
        assertGt(deltaEquity, 0, "recent revenue offset should reduce equity for convertToShares path");

        // 3) After the smoothing window expires both views should realign.
        vm.roll(epochBlock + MONAD_EPOCH_LENGTH + 1);
        rewardsPacked = uint256(vm.load(address(shMonad), rewardsSlot));
        rewardsPacked = (rewardsPacked & ~maskEarned) | alwaysTrueMask;
        vm.store(address(shMonad), rewardsSlot, bytes32(rewardsPacked));
        uint256 stalePacked = tip | (uint256(uint64(epochBlock)) << 120);
        vm.store(address(shMonad), bytes32(uint256(23)), bytes32(stalePacked));

        uint256 convertAfterDecay = shMonad.convertToShares(assets);
        uint256 previewAfterDecay = shMonad.previewDeposit(assets);
        if (useLocalMode) {
            assertEq(convertAfterDecay, previewAfterDecay, "smoothing offset should fully decay after one epoch length");
        } else {
            assertApproxEqAbs(convertAfterDecay, previewAfterDecay, 2e15, "smoothing offset should decay after one epoch length");
        }
    }

    // Scenario: zero target liquidity should clamp both maxWithdraw and maxRedeem to zero.
    // Steps:
    // 1) Deposit funds, set target liquidity to zero, and crank once.
    // 2) Assert `maxWithdraw` and `maxRedeem` both report zero while liquidity is zeroed.
    function test_FLERC4626_targetZero_clampsMaxWithdrawAndRedeemToZero() public {
        // Fork mode runs against existing mainnet state with non-trivial atomic pool utilization.
        // In that environment, setting a 0% target can only reduce allocated liquidity down to the utilized floor,
        // so the "allocated == 0" assertions from local mode do not hold.
        if (!useLocalMode) vm.skip(true);
        vm.deal(user, 10 ether);
        vm.prank(user);
        shMonad.deposit{ value: 10 ether }(10 ether, user);

        // Step 1: zero-out target liquidity and process an epoch.
        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);
        _advanceEpochAndCrank();

        // Step 2: both withdraw/redemption limits clamp to zero under zero liquidity.
        assertEq(shMonad.getCurrentLiquidity(), 0, "liquidity should be zero when target is zero");
        assertEq(shMonad.maxWithdraw(user), 0, "maxWithdraw must clamp to zero without liquidity");
        assertEq(shMonad.maxRedeem(user), shMonad.previewWithdraw(0), "maxRedeem must clamp to zero without liquidity");
    }

    // Scenario: with zero liquidity and a 100% utilization fee cap, previewRedeem should output zero.
    // Steps:
    // 1) Deposit shares, set liquidity target to zero, configure fee curve to full utilization.
    // 2) After cranking, confirm previewRedeem returns zero while gross assets remain positive.
    function test_FLERC4626_fullFeeCapAtZeroTarget_makesPreviewRedeemZero() public {
        // Fork mode runs against existing mainnet state with non-trivial atomic pool utilization.
        // Zeroing the target percent cannot force the pool allocation to zero, so this "zero-liquidity" test is local-only.
        if (!useLocalMode) vm.skip(true);
        vm.deal(user, 12 ether);
        vm.prank(user);
        uint256 minted = shMonad.deposit{ value: 12 ether }(12 ether, user);

        // Step 1: configure zero target and 100% utilization fee.
        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);
        shMonad.setUnstakeFeeCurve(RAY / 2, RAY - (RAY / 2));
        vm.stopPrank();

        _advanceEpochAndCrank();

        // Step 2: previewRedeem should report zero net output while gross assets remain positive.
        uint256 shares = minted / 3;
        assertGt(shMonad.convertToAssets(shares), 0, "gross assets should remain positive");
        assertEq(shMonad.previewRedeem(shares), 0, "previewRedeem should return zero under full fee cap and zero liquidity");
    }

    // Scenario: setUnstakeFeeCurve enforces RAY bounds for intercept, slope, and their sum.
    // Steps:
    // 1) y-intercept > RAY → revert.
    // 2) slope > RAY → revert.
    // 3) slope + intercept > RAY → revert.
    function test_FLERC4626_setUnstakeFeeCurve_revertsForInvalidParams() public {
        vm.startPrank(deployer);

        vm.expectRevert(ShMonadErrors.YInterceptExceedsRay.selector);
        shMonad.setUnstakeFeeCurve(0, RAY + 1);

        vm.expectRevert(ShMonadErrors.SlopeRateExceedsRay.selector);
        shMonad.setUnstakeFeeCurve(RAY + 1, 0);

        vm.expectRevert(ShMonadErrors.FeeCurveFullUtilizationExceedsRay.selector);
        shMonad.setUnstakeFeeCurve(RAY, 1);

        vm.stopPrank();
    }

    function test_FLERC4626_accountForWithdraw_shortfallQueuesAndGrowsAllocated() public {
        vm.startPrank(deployer);
        // Ensure deterministic fee/revenue behavior
        shmonad.setUnstakeFeeCurve(0, 0);
        shmonad.updateBoostCommission(0);
        vm.stopPrank();

        vm.deal(user, 100 ether);
        vm.prank(user);
        shmonad.deposit{ value: 100 ether }(100 ether, user);

        // Step 1: verify user holds shares and pool liquidity matches the configured target.
        uint256 userSharesSeeded = shmonad.balanceOf(user);
        require(userSharesSeeded > 0, "S1: User must hold shares before withdrawal sequence");

        this._ensureNoStakedFundsExternal();

        vm.prank(deployer);
        shmonad.setPoolTargetLiquidityPercentage(3e17); // 30% atomic liq target
        _advanceEpochAndCrank();
        _ensureAtomicLiquidity(1 ether, 3e17, 0);

        (uint128 allocBefore, uint128 distrBefore) = shmonad.getAtomicCapital();
        assertGt(uint256(allocBefore), 0, "S1: allocated should initialize above zero");
        uint256 distrBaseline = uint256(distrBefore);

        // Step 2: withdraw within liquidity to set distributedAmount.
        uint256 maxBefore = shmonad.maxWithdraw(user);
        // Withdraw less than full capacity so the user retains withdraw capacity for step 4
        uint256 net1 = maxBefore / 2;
        if (!useLocalMode && net1 == 0) {
            (, uint120 queueForUnstakeCurr) = shmonad.getGlobalCashFlows(0);
            assertGt(queueForUnstakeCurr, 0, "S2 [fork mode]: zero liquidity must correspond to active unstake queue");
            return;
        }
        require(net1 > 0, "S2: maxWithdraw should accommodate initial withdraw");

        vm.prank(user);
        shmonad.withdraw(net1, user, user);

        (uint128 allocAfterFirst, uint128 distrAfterFirst) = shmonad.getAtomicCapital();
        assertEq(uint256(allocAfterFirst), uint256(allocBefore), "S2: allocated should stay constant with sufficient liquidity");
        assertEq(uint256(distrAfterFirst), distrBaseline + net1, "S2: distributed should include first withdrawal");
        // Ensure user retains withdraw capacity and shares after the first withdraw
        uint256 remainingMaxAfterFirst = shmonad.maxWithdraw(user);
        assertGt(remainingMaxAfterFirst, 0, "S2: user must retain withdraw capacity after first withdraw");
        assertGt(shmonad.balanceOf(user), 0, "S2: user must retain shMON shares after first withdraw");

        // Step 3: inject validator revenue and roll forward one epoch.
        address validator = _ensureActiveValidator(address(0), "val-shortfall");

        _advanceEpochAndCrank();

        vm.coinbase(validator);
        // Ensure validator is marked in the active set in shmonad before attributing boost
        uint64 _valId = uint64(shmonad.getValidatorIdForCoinbase(validator));
        bool _inActiveSet = shmonad.isValidatorActive(_valId);
        assertTrue(_inActiveSet, "S3: validator must be in active set prior to boost");

        // Baseline earned revenue before boost
        (, uint120 earnedActiveBeforeBoost) = shmonad.exposeValidatorRewardsCurrent(validator);
        (, uint120 earnedGlobalBeforeBoost) = shmonad.exposeGlobalRevenueCurrent();

        uint256 tip = net1 * 2;
        address briber = makeAddr("briber-shortfall");
        vm.deal(briber, tip);
        vm.prank(briber);
        shmonad.boostYield{ value: tip }(briber);

        // Assert attribution to active validator and global earned revenue increase
        (, uint120 earnedActiveAfterBoost) = shmonad.exposeValidatorRewardsCurrent(validator);
        (, uint120 earnedGlobalAfterBoost) = shmonad.exposeGlobalRevenueCurrent();
        assertGt(earnedActiveAfterBoost, earnedActiveBeforeBoost, "S3: boost must attribute to active validator");
        assertGt(earnedGlobalAfterBoost, earnedGlobalBeforeBoost, "S3: global earnedRevenue must increase on boost");

        _advanceEpochAndCrank();

        (uint128 allocBeforeSecond, uint128 distrBeforeSecond) = shmonad.getAtomicCapital();

        uint256 liquidityBefore = shmonad.getCurrentLiquidity();
        assertGt(liquidityBefore, 0, "S3: liquidity should be positive after revenue realization");

        // Step 4: withdraw the post-revenue max and validate the shortfall propagation.
        uint256 net2 = shmonad.maxWithdraw(user);
        if (!useLocalMode && net2 == 0) {
            (, uint120 queueForUnstakeAfterRevenue) = shmonad.getGlobalCashFlows(0);
            assertGt(queueForUnstakeAfterRevenue, 0, "S4 [fork mode]: zero liquidity after revenue must correspond to queue");
            return;
        }
        assertGt(net2, 0, "S4: maxWithdraw should be positive after revenue");

        (, uint120 queueForUnstakeBeforeSecond) = shmonad.getGlobalCashFlows(0);

        vm.prank(user);
        shmonad.withdraw(net2, user, user);

        (uint128 allocAfter, uint128 distrAfter) = shmonad.getAtomicCapital();
        (, uint120 queueForUnstakeAfter) = shmonad.getGlobalCashFlows(0);

        uint256 expectedShortfall =
            uint256(distrBeforeSecond) + net2 > uint256(allocBeforeSecond)
                ? uint256(distrBeforeSecond) + net2 - uint256(allocBeforeSecond)
                : 0;

        assertEq(
            uint256(allocAfter),
            uint256(allocBeforeSecond) + expectedShortfall,
            "S4: allocated should grow by shortfall"
        );
        assertEq(uint256(distrAfter), uint256(distrBeforeSecond) + net2, "S4: distributed should include second withdrawal");
        assertEq(
            uint256(queueForUnstakeAfter),
            uint256(queueForUnstakeBeforeSecond) + expectedShortfall,
            "S4: queueForUnstake should increase by shortfall amount"
        );
    }

    /// @notice Settles carryover using earnedRevenue minus allocatedRevenue.
    function test_FLERC4626_carryOverAtomicUnstake_usesAvailableRevenue() public {
        uint128 allocated = 200 ether;
        uint128 distributed = 80 ether;
        uint120 earnedRevenue = 100 ether;
        uint120 allocatedRevenue = 30 ether;
        uint120 queueForUnstakeBefore = 10 ether;

        shmonad.harnessSetAtomicCapital(allocated, distributed);
        shmonad.harnessSetGlobalRevenue(allocatedRevenue, earnedRevenue);
        shmonad.harnessSetGlobalCashFlows(0, queueForUnstakeBefore);

        shmonad.harnessCarryOverAtomicUnstakeIntoQueue();

        (, uint128 distributedAfter) = shmonad.getAtomicCapital();
        (, uint120 queueForUnstakeAfter) = shmonad.getGlobalCashFlows(0);

        uint256 availableRevenue = uint256(earnedRevenue - allocatedRevenue);
        uint256 expectedSettlement = Math.min(availableRevenue, uint256(distributed));

        assertEq(
            distributedAfter,
            distributed - uint128(expectedSettlement),
            "carryover should settle only available revenue"
        );
        assertEq(
            queueForUnstakeAfter,
            queueForUnstakeBefore + uint120(expectedSettlement),
            "carryover should enqueue settled amount"
        );
    }

    /// @notice Skips settlement when all earned revenue is already allocated.
    function test_FLERC4626_carryOverAtomicUnstake_zeroAvailableRevenue_noSettlement() public {
        uint128 allocated = 200 ether;
        uint128 distributed = 40 ether;
        uint120 earnedRevenue = 30 ether;
        uint120 allocatedRevenue = 30 ether;
        uint120 queueForUnstakeBefore = 12 ether;

        shmonad.harnessSetAtomicCapital(allocated, distributed);
        shmonad.harnessSetGlobalRevenue(allocatedRevenue, earnedRevenue);
        shmonad.harnessSetGlobalCashFlows(0, queueForUnstakeBefore);

        shmonad.harnessCarryOverAtomicUnstakeIntoQueue();

        (, uint128 distributedAfter) = shmonad.getAtomicCapital();
        (, uint120 queueForUnstakeAfter) = shmonad.getGlobalCashFlows(0);

        assertEq(distributedAfter, distributed, "carryover should not settle with zero available revenue");
        assertEq(
            queueForUnstakeAfter,
            queueForUnstakeBefore,
            "carryover should not enqueue without available revenue"
        );
    }

    // --------------------------------------------- //
    //            Property & Fuzz Tests             //
    // --------------------------------------------- //

    // Monotonicity of conversions with a seeded vault state
    function testFuzz_FLERC4626_monotonicity(uint256 a, uint256 b) public {
        // Seed state
        vm.deal(alice, 50 ether);
        vm.prank(alice);
        shMonad.deposit{ value: 50 ether }(50 ether, alice);

        a = bound(a, 0, 20 ether);
        b = bound(b, a, 40 ether);

        uint256 sa = shMonad.previewDeposit(a);
        uint256 sb = shMonad.previewDeposit(b);
        assertLe(sa, sb, "convertToShares monotonic");

        uint256 aa = shMonad.previewRedeem(sa);
        uint256 ab = shMonad.previewRedeem(sb);
        assertLe(aa, ab, "convertToAssets monotonic");
    }

    // Monotonicity: previewWithdraw should be non-decreasing with assets
    function test_FLERC4626_previewWithdraw_monotonic() public {
        // Seed
        vm.deal(alice, 40 ether);
        vm.prank(alice);
        shmonad.deposit{ value: 40 ether }(40 ether, alice);

        uint256 a = 3 ether;
        uint256 b = 7 ether;
        uint256 pa = shmonad.previewWithdraw(a);
        uint256 pb = shmonad.previewWithdraw(b);
        assertLe(pa, pb, "previewWithdraw monotonic in assets");
    }

    function testFuzz_FLERC4626_inversePreviewConsistency(uint256 depositAssets, uint256 pick) public {
        depositAssets = bound(depositAssets, 5 ether, 200 ether);
        vm.deal(alice, depositAssets);
        vm.prank(alice);
        uint256 minted = shMonad.deposit{ value: depositAssets }(depositAssets, alice);
        if (minted <= 1) return;

        // Step 1: choose a fuzzed share amount within the minted supply.
        pick = bound(pick, 1, minted - 1);
        uint256 assets = shMonad.previewRedeem(pick);
        uint256 sharesBack = shMonad.previewWithdraw(assets);
        // Step 2: round-trip should not undershoot by more than three shares (rounding creep).
        if (sharesBack < pick) {
            uint256 minFeeShares = shMonad.convertToShares(ATOMIC_MIN_FEE_WEI);
            if (minFeeShares == 0 && ATOMIC_MIN_FEE_WEI > 0) {
                minFeeShares = 1; // keep at least 1-share slack when fee translates to sub-wei shares
            }
            uint256 tolerance = 3 + minFeeShares;
            assertLe(pick - sharesBack, tolerance, "inverse previews should undershoot by at most the min-fee shares");
        }
    }

    function testFuzz_FLERC4626_feeUpperBound_whenTargetZero(uint256 depositAssets, uint256 rMax) public {
        depositAssets = bound(depositAssets, 10 ether, 200 ether);
        vm.deal(alice, depositAssets);
        vm.prank(alice);
        uint256 minted = shMonad.deposit{ value: depositAssets }(depositAssets, alice);

        // Step 1: configure zero-liquidity with randomized fee curve parameters summing to rMax.
        rMax = bound(rMax, 0, RAY);
        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);
        uint256 m = rMax / 3;
        uint256 c = rMax - m;
        shMonad.setUnstakeFeeCurve(m, c);
        vm.stopPrank();

        _advanceEpochAndCrank();

        uint256 shares = minted / 2;
        if (shares == 0) {
            shares = minted;
        }

        // Step 2: ensure previewRedeem stays within the rMax * gross upper bound (allowing 1 wei slack).
        uint256 gross = shMonad.convertToAssets(shares);
        uint256 net = shMonad.previewRedeem(shares);
        uint256 fee = gross - net;
        uint256 boundFee = gross.mulDiv(rMax, RAY);
        // since we're using the min-fee solver, we need to add the min-fee to the bound fee
        uint256 minFee = ATOMIC_MIN_FEE_WEI;
        assertLe(fee, boundFee + minFee, "fee must respect rMax bound at zero liquidity (plus min fee)");
    }

    // Max functions semantics when fees are enabled (no staked funds)
    function test_FLERC4626_maxFunctions_withFeesEnabled_NoStakedFunds() public {
        uint256 amount = 10 ether;
        vm.prank(alice);
        uint256 minted = shMonad.deposit{ value: amount }(amount, alice);

        // Ensure ample liquidity so maxWithdraw > 0 in fork runs.
        this._ensureNoStakedFundsExternal();

        uint256 mw = shMonad.maxWithdraw(alice);
        uint256 shares = shMonad.balanceOf(alice);
        assertEq(shares, minted, "post-deposit balance should equal minted shares");
        uint256 gross = shMonad.convertToAssets(shares);

        (uint256 slopeRateRay, uint256 yInterceptRay) = shMonad.getFeeCurveParams();
        FeeParams memory p = FeeParams({ mRay: uint128(slopeRateRay), cRay: uint128(yInterceptRay) });

        uint256 R0 = shMonad.getCurrentLiquidity();
        uint256 gCapped = Math.min(gross, R0);
        (, uint256 feeLibNet) = FeeLib.solveNetGivenGross(
            gCapped,
            R0,
            shMonad.getTargetLiquidity(),
            p
        );

        assertEq(mw, feeLibNet, "maxWithdraw should match FeeLib net");
        // Previews ignore liquidity caps. If unclamped, previewRedeem(balance) == maxWithdraw; otherwise previewRedeem
        // will be >= maxWithdraw.
        if (gross <= R0) {
            assertEq(shMonad.previewRedeem(shares), mw, "previewRedeem(balance) == maxWithdraw when unclamped");
        } else {
            assertGe(shMonad.previewRedeem(shares), mw, "previewRedeem ignores liquidity caps");
        }

        // maxRedeem should be a safe share-bound at the liquidity boundary.
        uint256 maxRedeemShares = shMonad.maxRedeem(alice);
        assertLe(maxRedeemShares, shMonad.balanceOf(alice), "maxRedeem should not exceed balance");
        assertLe(shMonad.previewRedeem(maxRedeemShares), mw, "previewRedeem(maxRedeem) should not exceed maxWithdraw");
    }

    function test_FLERC4626_maxRedeem_roundingClampsAtLiquidityBoundary() public {
        if (!useLocalMode) return;

        vm.prank(deployer);
        shMonad.setUnstakeFeeCurve(0, 0); // disable fees to isolate rounding

        uint256 amount = 100 ether;
        vm.prank(alice);
        shMonad.deposit{ value: amount }(amount, alice);

        uint256 burnShares = shMonad.balanceOf(alice) / 2;
        vm.prank(alice);
        shMonad.boostYield(burnShares, alice, alice);

        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(9e16); // 9% target liquidity
        _advanceEpochAndCrank();

        uint256 mw = shMonad.maxWithdraw(alice);
        if (mw == 0) return;

        uint256 gross = shMonad.convertToAssets(shMonad.balanceOf(alice));
        uint256 R0 = shMonad.getCurrentLiquidity();
        assertLt(R0, gross, "liquidity cap should bind");

        uint256 oldStyleShares = shMonad.previewWithdraw(mw);
        uint256 oldStyleNet = shMonad.previewRedeem(oldStyleShares);
        assertGt(oldStyleNet, mw, "old maxRedeem rounding would overshoot liquidity");

        uint256 maxRedeemShares = shMonad.maxRedeem(alice);
        assertLe(shMonad.previewRedeem(maxRedeemShares), mw, "maxRedeem must stay within liquidity cap");
    }

    // Max enforcement: withdraw exceeding max should revert with custom error
    function test_FLERC4626_withdraw_exceedsMax_reverts() public {
        uint256 amount = 11 ether;
        vm.prank(alice);
        shmonad.deposit{ value: amount }(amount, alice);

        uint256 mw = shmonad.maxWithdraw(alice);
        if (mw == 0) return; // degenerate
        uint256 ask = mw + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            IERC4626Custom.ERC4626ExceededMaxWithdraw.selector,
            alice,
            ask,
            mw
        ));
        shmonad.withdraw(ask, alice, alice);
    }

    // Max enforcement: redeem exceeding max should revert with custom error
    function test_FLERC4626_redeem_exceedsMax_reverts() public {
        uint256 amount = 12 ether;
        vm.prank(alice);
        shmonad.deposit{ value: amount }(amount, alice);

        uint256 mr = shmonad.maxRedeem(alice);
        uint256 balanceShares = shmonad.balanceOf(alice);
        if (mr == 0) return; // degenerate
        uint256 askShares = mr + 1;
        if (askShares > balanceShares) return; // avoid ERC20InsufficientBalance, we want the ERC4626 max error
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            IERC4626Custom.ERC4626ExceededMaxRedeem.selector,
            alice,
            askShares,
            mr
        ));
        shmonad.redeem(askShares, alice, alice);
    }

    // With targetLiquidity = 0 and fees disabled, no fee applies
    function test_FLERC4626_targetLiquidityZero_noFee_whenFeesDisabled() public {
        vm.startPrank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(0);
        shMonad.setUnstakeFeeCurve(0, 0); // disable fees
        vm.stopPrank();

        vm.prank(alice);
        shMonad.deposit{ value: 10 ether }(10 ether, alice);

        uint256 shares = 2 ether;
        uint256 assets = shMonad.convertToAssets(shares);
        uint256 preview = shMonad.previewRedeem(shares);
        assertEq(preview, assets, "no fee should apply when fees disabled, regardless of target");
    }

    // Zero preview edge cases must not revert and return zero
    function test_FLERC4626_previewZeroes() public view {
        assertEq(shmonad.previewWithdraw(0), 0);
        assertEq(shmonad.previewRedeem(0), 0);
        assertEq(shmonad.previewDeposit(0), 0);
        assertEq(shmonad.previewMint(0), 0);
    }

    // User mints 1 wei of shMON, tries to redeem, but reverts as due to fees rounding up, 1 wei redeem is impossible.
    function test_FLERC4626_firstDepositorOneWei_ZeroRedeemableAfterFees() public {
        if (!useLocalMode) {
            return; // Fork/CI configuration has non-zero atomic liquidity; scenario not meaningful.
        }

        vm.prank(deployer);
        shmonad.setPoolTargetLiquidityPercentage(1e18); // 100%

        vm.deal(alice, 1);
        vm.prank(alice);
        uint256 minted = shmonad.deposit{value: 1}(1, alice);

        this._ensureNoStakedFundsExternal(); // ensures nothing is staked; allocation for atomic pool is still zero

        // Previews ignore liquidity limits (ERC-4626), may show >0
        uint256 previewNet = shmonad.previewRedeem(minted);
        assertGe(previewNet, 0);

        // Runtime maxes respect atomic allocation & net-cap clamp; with L==0 => max == 0
        assertEq(shmonad.maxWithdraw(alice), 0);
        assertEq(shmonad.maxRedeem(alice), 0);

        // Redeem should revert because shares (1) > maxRedeem (0)
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Custom.ERC4626ExceededMaxRedeem.selector,
                alice,
                minted,
                0
            )
        );
        shmonad.redeem(minted, alice, alice);
        vm.stopPrank();
    }

    // --------------------------------------------- //
    //                 Fuzz Variants                //
    // --------------------------------------------- //

    // Fuzz deposit path: shares == previewDeposit and balances/supply adjust
    function testFuzz_FLERC4626_deposit_HappyPath(uint256 assets) public {
        assets = bound(assets, 1 wei, 100 ether);
        vm.deal(alice, assets);

        vm.startPrank(alice);
        uint256 supplyBefore = shmonad.totalSupply();
        uint256 taBefore = shmonad.totalAssets();
        uint256 preview = shmonad.previewDeposit(assets);
        uint256 shares = shmonad.deposit{ value: assets }(assets, alice);
        vm.stopPrank();

        assertEq(shares, preview);
        assertEq(shmonad.totalSupply(), supplyBefore + shares);
        assertEq(shmonad.totalAssets(), taBefore + assets);
        assertEq(shmonad.balanceOf(alice), shares);
    }

    // Fuzz withdraw path: choose target shares, derive a feasible net ask, and validate stateful vs preview
    function testFuzz_FLERC4626_withdraw_HappyPath(uint256 depositAmount, uint256 sharesTarget) public {
        depositAmount = bound(depositAmount, 1 ether, 100 ether);
        vm.deal(alice, depositAmount);
        vm.prank(alice);
        shmonad.deposit{ value: depositAmount }(depositAmount, alice);

        uint256 balanceShares = shmonad.balanceOf(alice);
        if (balanceShares <= 1) return;

        // Pick a share amount strictly less than the full balance to avoid boundary rounding
        sharesTarget = bound(sharesTarget, 1, balanceShares - 1);

        // Compute a candidate net ask using previewRedeem on those shares
        uint256 askNet = shmonad.previewRedeem(sharesTarget);
        if (askNet == 0) return;

        // Ensure the ask respects maxWithdraw and fits the current share balance after inverse rounding
        uint256 mw = shmonad.maxWithdraw(alice);
        if (mw == 0) return;
        if (askNet > mw) askNet = mw - 1; // keep a buffer from the edge

        uint256 burnPreview = shmonad.previewWithdraw(askNet);
        while (burnPreview > balanceShares) {
            unchecked { --askNet; }
            if (askNet == 0) return;
            burnPreview = shmonad.previewWithdraw(askNet);
        }

        // Execute and validate
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 burned = shmonad.withdraw(askNet, alice, alice);

        assertEq(burned, burnPreview, "burned == previewWithdraw");
        assertEq(alice.balance, balBefore + askNet, "assets delivered");
        assertEq(shmonad.balanceOf(alice), balanceShares - burned, "shares decreased by burned");
    }

    // Fuzz msg.value mismatch cases for deposit/mint
    function testFuzz_FLERC4626_deposit_msgValueMismatch(uint256 assets) public {
        assets = bound(assets, 1 wei, 100 ether);
        vm.prank(alice);
        vm.expectRevert(ShMonadErrors.IncorrectNativeTokenAmountSent.selector);
        shmonad.deposit{ value: assets - 1 }(assets, alice);
    }

    function testFuzz_FLERC4626_mint_msgValueMismatch(uint256 shares) public {
        shares = bound(shares, 1 wei, 50 ether);
        uint256 required = shmonad.previewMint(shares);
        if (required == 0) return;
        vm.prank(alice);
        vm.expectRevert(ShMonadErrors.IncorrectNativeTokenAmountSent.selector);
        shmonad.mint{ value: required - 1 }(shares, alice);
    }

    // Fuzz max functions with fees enabled across random deposit sizes
    function testFuzz_FLERC4626_maxFunctions_withFees(uint256 amount) public {
        amount = bound(amount, 1 ether, 100 ether);
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 minted = shmonad.deposit{ value: amount }(amount, alice);

        uint256 mw = shmonad.maxWithdraw(alice);
        uint256 shares = shmonad.balanceOf(alice);
        assertEq(shares, minted, "post-deposit balance should equal minted shares");
        uint256 gross = shmonad.convertToAssets(shares);

        (uint256 slopeRateRay, uint256 yInterceptRay) = shmonad.getFeeCurveParams();
        FeeParams memory p = FeeParams({ mRay: uint128(slopeRateRay), cRay: uint128(yInterceptRay) });

        uint256 R0 = shmonad.getCurrentLiquidity();
        (uint256 feeF, uint256 netF) = FeeLib.solveNetGivenGross(
            gross,        // NOTE: not min(gross, R0)
            R0,
            shmonad.getTargetLiquidity(),
            p
        );
        feeF;
        uint256 expectedNet = netF > R0 ? R0 : netF;
        assertEq(mw, expectedNet);
        // Previews ignore liquidity limits: previewRedeem(balance) should be >= maxWithdraw
        assertGe(shmonad.previewRedeem(shares), mw);

        uint256 maxRedeemShares = shmonad.maxRedeem(alice);
        assertLe(maxRedeemShares, shmonad.balanceOf(alice), "maxRedeem should not exceed balance");
        assertLe(shmonad.previewRedeem(maxRedeemShares), mw, "previewRedeem(maxRedeem) should not exceed maxWithdraw");
    }

    // Liquidity clamp: staking out of pool should reduce currentLiq and clamp maxWithdraw accordingly
    function test_FLERC4626_liquidityClamp_affectsMaxWithdraw_and_MaxRedeem() public {
        // Seed pool
        uint256 amount = 60 ether;
        vm.prank(alice);
        uint256 minted = shmonad.deposit{ value: amount }(amount, alice);

        // Setup a validator and stake part of the pool to reduce current liquidity
        vm.startPrank(deployer);
        address validator = makeAddr("val-1");
        uint64 valId = staking.registerValidator(validator);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();

        // Compute expected clamp and fee-based net
        uint256 shares = shmonad.balanceOf(alice);
        assertEq(shares, minted, "post-deposit balance should equal minted shares");
        uint256 gross = shmonad.convertToAssets(shares);
        (uint256 mRay, uint256 cRay) = shmonad.getFeeCurveParams();
        FeeParams memory p = FeeParams({ mRay: uint128(mRay), cRay: uint128(cRay) });
        uint256 R0 = shmonad.getCurrentLiquidity();
        (uint256 feeF, uint256 netF) = FeeLib.solveNetGivenGross(
            gross,        // NOTE: not min(gross, R0)
            R0,
            shmonad.getTargetLiquidity(),
            p
        );
        feeF;
        uint256 expectedNet = netF > R0 ? R0 : netF;
        uint256 mw = shmonad.maxWithdraw(alice);
        assertEq(mw, expectedNet, "maxWithdraw reflects clamp and fee");
        uint256 maxRedeemShares = shmonad.maxRedeem(alice);
        assertLe(maxRedeemShares, shmonad.balanceOf(alice), "maxRedeem <= balance");
        assertLe(shmonad.previewRedeem(maxRedeemShares), mw, "previewRedeem(maxRedeem) <= maxWithdraw");

        // Withdrawing max should succeed and burn previewed shares
        if (mw > 0) {
            uint256 burnPreview = shmonad.previewWithdraw(mw);
            vm.prank(alice);
            uint256 burned = shmonad.withdraw(mw, alice, alice);
            assertEq(burned, burnPreview, "burn matches preview after clamp");
        }
    }

    // --------------------------------------------- //
    //               Adversarial Tests              //
    // --------------------------------------------- //

    // Scenario: a malicious fallback calling `withdraw(0)` must not double spend shares or receive extra funds.
    // Steps:
    // 1) Seed user and attacker deposits while pushing the pool fully liquid.
    // 2) Execute an attacking withdraw that reenters via fallback.
    // 3) Assert the attacker receives exactly `ask` assets and loses the burned shares.
    function test_FLERC4626_reentrancy_withdrawZeroInFallback_safe() public {
        vm.deal(user, 8 ether);
        vm.prank(user);
        shMonad.deposit{ value: 8 ether }(8 ether, user);

        // Step 1: attacker deposits after pool target saturates the atomic path.
        vm.prank(deployer);
        shMonad.setPoolTargetLiquidityPercentage(SCALE);
        for (uint256 i = 0; i < 6; i++) {
            _advanceEpochAndCrank();
        }

        MaliciousWithdrawZero attacker = new MaliciousWithdrawZero(shMonad);
        vm.deal(address(attacker), 4 ether);
        vm.prank(address(attacker));
        shMonad.deposit{ value: 4 ether }(4 ether, address(attacker));

        _advanceEpochAndCrank();

        uint256 ask = 1 ether;
        uint256 maxWithdrawAttacker = shMonad.maxWithdraw(address(attacker));
        assertGe(maxWithdrawAttacker, ask, "attacker must be able to withdraw requested amount");

        uint256 balBefore = address(attacker).balance;
        uint256 sharesBefore = shMonad.balanceOf(address(attacker));

        // Step 2: perform withdraw which triggers the fallback attack.
        vm.prank(address(attacker));
        uint256 burned = shMonad.withdraw(ask, address(attacker), address(attacker));

        // Step 3: ensure payout and share accounting are unchanged by reentrancy.
        assertEq(address(attacker).balance, balBefore + ask, "attacker receives exact requested assets");
        assertGt(burned, 0, "withdraw must burn shares");
        assertEq(
            shMonad.balanceOf(address(attacker)),
            sharesBefore - burned,
            "share balance should decrease by burned amount"
        );
    }

    // Malicious receiver reenters during withdraw; cannot double-spend beyond
    // available shares. We assert payout within [ask, ask+1] and shares drop
    // by at least the outer preview.
    function test_FLERC4626_withdraw_reentrancy_noDoubleSpend_NoStakedFunds() public {
        MaliciousReceiver recv = new MaliciousReceiver(shMonad);

        // Fund malicious owner with shares
        vm.deal(address(recv), 5 ether);
        vm.prank(address(recv));
        shMonad.deposit{ value: 5 ether }(5 ether, address(recv));

        // Ensure liquidity available so withdraw won’t be clamped to zero
        this._ensureNoStakedFundsExternal();

        // Perform withdraw which triggers reentrancy attempt in fallback
        uint256 ask = 1 ether;
        uint256 balBefore = address(recv).balance;
        uint256 minBurn = shMonad.previewWithdraw(ask); // compute before state changes
        vm.startPrank(address(recv));
        uint256 sharesBefore = shMonad.balanceOf(address(recv));
        uint256 burned = shMonad.withdraw(ask, address(recv), address(recv));
        vm.stopPrank();

        uint256 paid = address(recv).balance - balBefore;
        assertEq(paid, ask, "exact outer ask paid");
        uint256 sharesAfter = shMonad.balanceOf(address(recv));
        assertLe(sharesAfter, sharesBefore - minBurn, "shares decreased by outer withdraw");
        assertGt(burned, 0, "outer withdraw burned shares");
    }

    function test_FLERC4626_withdrawWithSlippage_slippageExceeded() public {
        // Seed Alice and Bob with shares
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        shMonad.deposit{ value: 10 ether }(10 ether, alice);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        shMonad.deposit{ value: 1 ether }(1 ether, bob);

        uint256 ask = 0.01 ether;

        // Alice previews required shares before any front-run
        uint256 previewBurnBefore = shMonad.previewWithdraw(ask);

        // Bob front-runs with a tiny withdrawal to push utilization up
        uint256 bobAsk = 0.01 ether;
        vm.prank(bob);
        shMonad.withdraw(bobAsk, bob, bob);

        // Execution should now require more shares than previewBurnBefore
        uint256 previewBurnAfter = shMonad.previewWithdraw(ask);
        // Route funds to a simple receiver contract instead of EOA
        SimpleReceiver recv = new SimpleReceiver();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Custom.ERC4626WithdrawSlippageExceeded.selector,
                alice,
                previewBurnAfter,
                previewBurnBefore
            )
        );
        vm.prank(alice);
        shMonad.withdrawWithSlippageProtection(ask, address(recv), alice, previewBurnBefore);
    }

    function test_FLERC4626_redeemWithSlippage_slippageExceeded() public {
        // Seed Alice and Bob with shares
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        shMonad.deposit{ value: 10 ether }(10 ether, alice);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        shMonad.deposit{ value: 1 ether }(1 ether, bob);

        uint256 askShares = 0.01 ether;
        // Preview expected assets out before any front-run
        uint256 minAssetsOut = shMonad.previewRedeem(askShares);

        // Bob front-runs to increase utilization and fee
        uint256 bobAsk = 0.01 ether;
        vm.prank(bob);
        shMonad.withdraw(bobAsk, bob, bob);

        // Now Alice's redeem should yield less than minAssetsOut and revert on slippage
        uint256 netAfter = shMonad.previewRedeem(askShares);
        // Route funds to a simple receiver contract instead of EOA
        SimpleReceiver recv = new SimpleReceiver();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Custom.ERC4626RedeemSlippageExceeded.selector,
                alice,
                netAfter,
                minAssetsOut
            )
        );
        vm.prank(alice);
        shMonad.redeemWithSlippageProtection(askShares, address(recv), alice, minAssetsOut);
    }

    function test_FLERC4626_withdrawWithSlippage_slippageNotExceeded() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        shMonad.deposit{ value: 10 ether }(10 ether, alice);

        uint256 ask = shMonad.maxWithdraw(alice) / 2;
        uint256 previewBurn = shMonad.previewWithdraw(ask);

        vm.prank(alice);
        uint256 burned = shMonad.withdrawWithSlippageProtection(ask, alice, alice, previewBurn);
        assertEq(burned, previewBurn, "burned matches previewBurn");
    }

    function test_FLERC4626_redeemWithSlippage_slippageNotExceeded() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        shMonad.deposit{ value: 10 ether }(10 ether, alice);

        uint256 askShares = shMonad.maxRedeem(alice) / 2; // keep below max
        uint256 minAssetsOut = shMonad.previewRedeem(askShares);

        vm.prank(alice);
        uint256 redeemed = shMonad.redeemWithSlippageProtection(askShares, alice, alice, minAssetsOut);
        assertEq(redeemed, minAssetsOut, "redeemed matches preview minAssetsOut");
    }

    // ------------------------------------------------------------ //
    //                    Audit Fix POCs                            //
    // ------------------------------------------------------------ //
    // Regression for previously-exploitable pattern where repeated instant
    // withdrawals could exceed the intended cap by inflating allocatedAmount
    // during shortfall coverage from earnedRevenue. The fixed logic maintains
    // an invariant using earnedRevenue - allocatedRevenue, preventing replay.
    //
    // Scenario outline mirrors the historical PoC (adjusted to this repo):
    // 1) Attacker deposits 9 ETH (has large share balance to withdraw from)
    // 2) Victim deposits 2 ETH, requests a partial unstake (0.9 ETH worth of shares)
    // 3) Advance epoch + crank once to settle state transitions
    // 4) Third party deposits 1 ETH to vary pool utilization
    // 5) Protocol receives validator rewards (adds to earnedRevenue)
    // 6) Attacker repeatedly withdraws up to maxWithdraw(owner) until capped
    // 7) Assert total net withdrawn does NOT exceed the theoretical cap:
    //    (allocated - distributed) + (earnedRevenue - allocatedRevenue)
    function test_AuditFixPOC_repeatedWithdraw_cannotExceedAllocatedPlusEarnedRevenue() public {
        // Ensure no commission on validator revenue so "earnedRevenue" equals the sent amount
        vm.prank(deployer);
        shmonad.updateBoostCommission(0);

        // Create an active validator to attribute MEV/rewards (fee credited as earnedRevenue)
        address validator = _ensureActiveValidator(address(0), "auditfix-validator");
        uint256 validatorId = shMonad.getValidatorIdForCoinbase(validator);

        // 1) Attacker (alice) deposits 9 ETH
        vm.deal(alice, 9 ether);
        vm.prank(alice);
        shmonad.deposit{ value: 9 ether }(9 ether, alice);

        // 2) Victim (bob) deposits 2 ETH and requests unstake of ~0.9 ETH worth of shares
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        shmonad.deposit{ value: 2 ether }(2 ether, bob);

        // Request 0.9 ETH worth of shares (initial exchange rate ~1:1 after early deposits)
        vm.prank(bob);
        shmonad.requestUnstake(0.9 ether);

        // 3) Advance epoch and crank once so accounting state reflects the request
        _advanceEpochAndCrank();

        // 4) Third party (charlie) deposits 1 ETH to perturb utilization slightly
        vm.deal(charlie, 1 ether);
        vm.prank(charlie);
        shmonad.deposit{ value: 1 ether }(1 ether, charlie);

        // 5) Send validator rewards to increase earnedRevenue (100% feeRate → all credited as earnedRevenue)
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        shmonad.sendValidatorRewards{ value: 1 ether }(uint64(validatorId), SCALE);

        // Snapshot pool state right before the replay-style withdraw loop
        (uint128 allocatedAmount, uint128 distributedAmount) = shmonad.getAtomicCapital();
        (uint120 allocatedRevenue, uint120 earnedRevenue) = shmonad.getGlobalRevenue(0);

        // The theoretical upper bound for net instant withdrawals from this point is:
        // availableAtomic + availableRevenue = (allocated - distributed) + (earned - allocatedRevenue)
        uint256 theoreticalMaxNet =
            (uint256(allocatedAmount) - uint256(distributedAmount)) + (uint256(earnedRevenue) - uint256(allocatedRevenue));

        // 6) Attacker repeatedly withdraws up to the available maxWithdraw
        uint256 attackerBalanceBefore = alice.balance;
        // Safety cap on iterations to avoid accidental infinite loops in tests
        for (uint256 i = 0; i < 64; ++i) {
            uint256 maxNet = shmonad.maxWithdraw(alice);
            if (maxNet == 0) break;
            // If contract balance is lower than reported net (e.g., transient conditions), halt
            if (maxNet > address(shmonad).balance) break;

            vm.prank(alice);
            shmonad.withdraw(maxNet, alice, alice);
        }

        uint256 withdrawnNet = alice.balance - attackerBalanceBefore;

        // 7) The fix prevents replay: total net withdrawn must be <= theoretical cap
        assertLe(
            withdrawnNet,
            theoreticalMaxNet,
            "replay withdraw should not exceed (allocated - distributed) + (earned - allocatedRevenue)"
        );
    }
}

contract MaliciousWithdrawZero {
    ShMonad public immutable shMonad;
    bool internal entered;

    constructor(ShMonad _shMonad) {
        shMonad = _shMonad;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try shMonad.withdraw(0, address(this), address(this)) returns (uint256) { } catch { }
        entered = false;
    }
}

// Receiver that tries to reenter during ETH receipt
contract MaliciousReceiver {
    ShMonad public immutable shMonad;
    bool internal entered;

    constructor(ShMonad _shMonad) { shMonad = _shMonad; }

    receive() external payable {
        if (entered) return; // prevent infinite loop
        entered = true;
        // Attempt benign reentrancy via a view call to ensure no state corruption
        try shMonad.previewWithdraw(1) returns (uint256) { } catch { }
        entered = false;
    }
}

// Simple receiver used in tests to receive native MON on withdraw/redeem
contract SimpleReceiver {
    receive() external payable {}
}
