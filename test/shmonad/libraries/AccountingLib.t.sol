// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { AccountingLib } from "../../../src/shmonad/libraries/AccountingLib.sol";
import {
    WorkingCapital,
    AtomicCapital,
    CurrentLiabilities,
    AdminValues,
    StakingEscrow,
    CashFlows
} from "../../../src/shmonad/Types.sol";

/// @title AccountingLibTest
/// @notice Comprehensive tests for ShMonad's double-entry accounting library
/// @dev Tests verify the core accounting equation: ASSETS = EQUITY + LIABILITIES
contract AccountingLibTest is Test {
    // Test constants
    uint128 internal constant MOCK_STAKED = 100 ether;
    uint128 internal constant MOCK_RESERVED = 20 ether;
    uint128 internal constant MOCK_ALLOCATED = 30 ether;
    uint128 internal constant MOCK_DISTRIBUTED = 10 ether;
    uint128 internal constant MOCK_REDEMPTIONS = 15 ether;
    uint128 internal constant MOCK_REWARDS = 5 ether;
    uint128 internal constant MOCK_ZERO_YIELD = 8 ether;
    uint256 internal constant MOCK_BALANCE = 60 ether;

    // ================================
    // currentLiabilities Tests
    // ================================

    function test_AccountingLib_currentLiabilities_sumsCorrectly() public pure {
        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: MOCK_REDEMPTIONS, rewardsPayable: MOCK_REWARDS });

        uint256 _total = AccountingLib.currentLiabilities(_liabilities);

        assertEq(_total, MOCK_REDEMPTIONS + MOCK_REWARDS, "Should sum redemptions and rewards");
    }

    function test_AccountingLib_currentLiabilities_handlesZeros() public pure {
        CurrentLiabilities memory _liabilities = CurrentLiabilities({ redemptionsPayable: 0, rewardsPayable: 0 });

        uint256 _total = AccountingLib.currentLiabilities(_liabilities);

        assertEq(_total, 0, "Zero liabilities should return zero");
    }

    function testFuzz_AccountingLib_currentLiabilities(uint128 redemptions, uint128 rewards) pure public {
        // Bound to prevent overflow when adding as uint128
        redemptions = uint128(bound(redemptions, 0, type(uint128).max / 2));
        rewards = uint128(bound(rewards, 0, type(uint128).max / 2));

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: redemptions, rewardsPayable: rewards });

        uint256 _total = AccountingLib.currentLiabilities(_liabilities);

        assertEq(_total, uint256(redemptions) + uint256(rewards), "Fuzz: sum should match");
    }

    // ================================
    // totalLiabilities Tests
    // ================================

    function test_AccountingLib_totalLiabilities_includesZeroYield() public pure {
        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: MOCK_REDEMPTIONS, rewardsPayable: MOCK_REWARDS });

        AdminValues memory _admin = _mockAdmin(MOCK_ZERO_YIELD);

        uint256 _total = AccountingLib.totalLiabilities(_liabilities, _admin);

        assertEq(
            _total, MOCK_REDEMPTIONS + MOCK_REWARDS + MOCK_ZERO_YIELD, "Should include all three liability components"
        );
    }

    function testFuzz_AccountingLib_totalLiabilities(
        uint128 redemptions,
        uint128 rewards,
        uint128 zeroYield
    )
        public
        pure
    {
        // Bound to prevent overflow when adding three uint128 values
        redemptions = uint128(bound(redemptions, 0, type(uint128).max / 3));
        rewards = uint128(bound(rewards, 0, type(uint128).max / 3));
        zeroYield = uint128(bound(zeroYield, 0, type(uint128).max / 3));

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: redemptions, rewardsPayable: rewards });

        AdminValues memory _admin = _mockAdmin(zeroYield);

        uint256 _total = AccountingLib.totalLiabilities(_liabilities, _admin);

        assertEq(_total, uint256(redemptions) + uint256(rewards) + uint256(zeroYield), "Fuzz: total should match");
    }

    // ================================
    // atomicAssets Tests
    // ================================

    function test_AccountingLib_atomicAssets_contraAssetLogic() public pure {
        // RULE: ASSET = UNADJUSTED ASSET - CONTRA ASSET
        // atomicAssets = allocatedAmount - distributedAmount
        AtomicCapital memory _atomic =
            AtomicCapital({ allocatedAmount: MOCK_ALLOCATED, distributedAmount: MOCK_DISTRIBUTED });

        uint256 _available = AccountingLib.atomicAssets(_atomic);

        assertEq(_available, MOCK_ALLOCATED - MOCK_DISTRIBUTED, "Should apply contra-asset logic correctly");
    }

    function test_AccountingLib_atomicAssets_saturatingSubWhenDistributedExceedsAllocated() public pure {
        // Edge case: distributed > allocated (shouldn't happen, but test saturating sub)
        AtomicCapital memory _atomic = AtomicCapital({ allocatedAmount: 10 ether, distributedAmount: 15 ether });

        uint256 _available = AccountingLib.atomicAssets(_atomic);

        assertEq(_available, 0, "Should saturate to zero when distributed exceeds allocated");
    }

    function test_AccountingLib_atomicAssets_zeroWhenFullyDistributed() public pure {
        AtomicCapital memory _atomic = AtomicCapital({ allocatedAmount: 50 ether, distributedAmount: 50 ether });

        uint256 _available = AccountingLib.atomicAssets(_atomic);

        assertEq(_available, 0, "Should be zero when fully distributed");
    }

    function testFuzz_AccountingLib_atomicAssets(uint128 allocated, uint128 distributed) public pure {
        AtomicCapital memory _atomic =
            AtomicCapital({ allocatedAmount: allocated, distributedAmount: distributed });

        uint256 _available = AccountingLib.atomicAssets(_atomic);

        if (allocated >= distributed) {
            assertEq(_available, uint256(allocated) - uint256(distributed), "Fuzz: normal subtraction");
        } else {
            assertEq(_available, 0, "Fuzz: saturates to zero");
        }
    }

    // ================================
    // currentAssets Tests
    // ================================

    function test_AccountingLib_currentAssets_calculatesCorrectly() public pure {
        // RULE: totalCurrent = MON balance - totalAllocated - totalReserved
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: MOCK_STAKED, reservedAmount: MOCK_RESERVED });

        AtomicCapital memory _atomic =
            AtomicCapital({ allocatedAmount: MOCK_ALLOCATED, distributedAmount: MOCK_DISTRIBUTED });

        uint256 _atomicAssets = MOCK_ALLOCATED - MOCK_DISTRIBUTED; // 20 ether
        uint256 _expected = MOCK_BALANCE - _atomicAssets - MOCK_RESERVED; // 60 - 20 - 20 = 20 ether

        uint256 _currentAssets = AccountingLib.currentAssets(_capital, _atomic, MOCK_BALANCE);

        assertEq(_currentAssets, _expected, "Should calculate current assets correctly");
    }

    function test_AccountingLib_currentAssets_saturatesWhenInsufficientBalance() public pure {
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 100 ether, reservedAmount: 50 ether });

        AtomicCapital memory _atomic = AtomicCapital({ allocatedAmount: 60 ether, distributedAmount: 10 ether });

        // balance = 40, atomic = 50, reserved = 50
        // 40 - 50 - 50 would be negative, should saturate to 0
        uint256 _currentAssets = AccountingLib.currentAssets(_capital, _atomic, 40 ether);

        assertEq(_currentAssets, 0, "Should saturate to zero when balance insufficient");
    }

    function testFuzz_AccountingLib_currentAssets(
        uint128 allocated,
        uint128 distributed,
        uint128 reserved,
        uint128 balance
    )
        public
        pure
    {
        vm.assume(allocated >= distributed); // Valid contra-asset state

        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 100 ether, reservedAmount: reserved });

        AtomicCapital memory _atomic = AtomicCapital({ allocatedAmount: allocated, distributedAmount: distributed });

        uint256 _atomicAssets = uint256(allocated) - uint256(distributed);
        uint256 _currentAssets = AccountingLib.currentAssets(_capital, _atomic, balance);

        if (balance >= _atomicAssets + reserved) {
            assertEq(_currentAssets, balance - _atomicAssets - reserved, "Fuzz: normal calculation");
        } else {
            assertEq(_currentAssets, 0, "Fuzz: saturates to zero");
        }
    }

    // ================================
    // totalEquity Tests (Core Accounting Equation)
    // ================================

    function test_AccountingLib_totalEquity_accountingEquation() public pure {
        // RULE: EQUITY = ASSETS - LIABILITIES
        // ASSETS = stakedAmount + nativeBalance
        // LIABILITIES = redemptions + rewards + zeroYield

        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: MOCK_STAKED, reservedAmount: MOCK_RESERVED });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: MOCK_REDEMPTIONS, rewardsPayable: MOCK_REWARDS });

        AdminValues memory _admin = _mockAdmin(MOCK_ZERO_YIELD);

        uint256 _totalAssets = MOCK_STAKED + MOCK_BALANCE; // 100 + 60 = 160
        uint256 _totalLiabilities = MOCK_REDEMPTIONS + MOCK_REWARDS + MOCK_ZERO_YIELD; // 15 + 5 + 8 = 28
        uint256 _expectedEquity = _totalAssets - _totalLiabilities; // 160 - 28 = 132

        uint256 _equity = AccountingLib.totalEquity(_capital, _liabilities, _admin, MOCK_BALANCE);

        assertEq(_equity, _expectedEquity, "Equity should equal Assets minus Liabilities");
    }

    function test_AccountingLib_totalEquity_validEdgeCase() public pure {
        // Edge case: very small equity
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 30 ether, reservedAmount: 5 ether });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: 10 ether, rewardsPayable: 10 ether });

        AdminValues memory _admin = _mockAdmin(9 ether);

        // assets = 30 + 10 = 40, liabilities = 10 + 10 + 9 = 29
        // equity = 40 - 29 = 11
        uint256 _equity = AccountingLib.totalEquity(_capital, _liabilities, _admin, 10 ether);

        assertEq(_equity, 11 ether, "Should calculate small positive equity");
    }

    function test_AccountingLib_totalEquity_scenario1() public pure {
        // Scenario: moderate staked with balance
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 100 ether, reservedAmount: 0 });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: 10 ether, rewardsPayable: 5 ether });

        AdminValues memory _admin = _mockAdmin(5 ether);

        uint256 _assets = 100 ether + 50 ether;
        uint256 _totalLiabilities = 10 ether + 5 ether + 5 ether;
        uint256 _expectedEquity = _assets - _totalLiabilities;

        uint256 _equity = AccountingLib.totalEquity(_capital, _liabilities, _admin, 50 ether);

        assertEq(_equity, _expectedEquity, "Scenario 1 should match accounting equation");
    }

    function test_AccountingLib_totalEquity_scenario2() public pure {
        // Scenario: high staked with balance
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 1000 ether, reservedAmount: 0 });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: 100 ether, rewardsPayable: 50 ether });

        AdminValues memory _admin = _mockAdmin(50 ether);

        uint256 _assets = 1000 ether + 200 ether;
        uint256 _totalLiabilities = 100 ether + 50 ether + 50 ether;
        uint256 _expectedEquity = _assets - _totalLiabilities;

        uint256 _equity = AccountingLib.totalEquity(_capital, _liabilities, _admin, 200 ether);

        assertEq(_equity, _expectedEquity, "Scenario 2 should match accounting equation");
    }

    function test_AccountingLib_totalEquity_scenario3() public pure {
        // Scenario: zero staked, only balance
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 0, reservedAmount: 0 });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: 20 ether, rewardsPayable: 10 ether });

        AdminValues memory _admin = _mockAdmin(10 ether);

        uint256 _assets = 0 + 100 ether;
        uint256 _totalLiabilities = 20 ether + 10 ether + 10 ether;
        uint256 _expectedEquity = _assets - _totalLiabilities;

        uint256 _equity = AccountingLib.totalEquity(_capital, _liabilities, _admin, 100 ether);

        assertEq(_equity, _expectedEquity, "Scenario 3 should match accounting equation");
    }

    function testFuzz_AccountingLib_totalEquity(
        uint128 staked,
        uint128 balance,
        uint128 redemptions,
        uint128 rewards,
        uint128 zeroYield
    )
        public
        pure
    {
        // Bound liability components to prevent overflow
        redemptions = uint128(bound(redemptions, 0, type(uint128).max / 4));
        rewards = uint128(bound(rewards, 0, type(uint128).max / 4));
        zeroYield = uint128(bound(zeroYield, 0, type(uint128).max / 4));

        // Ensure assets can cover liabilities (add 1 to handle rounding)
        uint256 _totalLiabilities = uint256(redemptions) + uint256(rewards) + uint256(zeroYield);
        uint256 _minAsset = (_totalLiabilities / 2) + 1;
        staked = uint128(bound(staked, _minAsset, type(uint128).max / 2));
        balance = uint128(bound(balance, _minAsset, type(uint128).max / 2));

        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: staked, reservedAmount: 0 });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: redemptions, rewardsPayable: rewards });

        AdminValues memory _admin = _mockAdmin(zeroYield);

        uint256 _equity = AccountingLib.totalEquity(_capital, _liabilities, _admin, balance);
        uint256 _totalAssets = uint256(staked) + uint256(balance);

        assertEq(_equity, _totalAssets - _totalLiabilities, "Fuzz: accounting equation must hold");
    }

    // ================================
    // maximumNewGlobalRedemptionAmount Tests
    // ================================

    function test_AccountingLib_maximumNewGlobalRedemptionAmount_excludesPendingStaking() public pure {
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 100 ether, reservedAmount: 20 ether });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: 10 ether, rewardsPayable: 5 ether });

        AdminValues memory _admin = _mockAdmin(5 ether);

        StakingEscrow memory _pending = StakingEscrow({ pendingStaking: 30 ether, pendingUnstaking: 0, alwaysTrue: true });

        // equity = (100 + 60) - (10 + 5 + 5) = 140
        // max redemption = equity - pendingStaking = 140 - 30 = 110
        uint256 _maxRedemption =
            AccountingLib.maximumNewGlobalRedemptionAmount(_capital, _liabilities, _admin, _pending, 60 ether);

        assertEq(_maxRedemption, 110 ether, "Should exclude pending staking from redeemable amount");
    }

    function test_AccountingLib_maximumNewGlobalRedemptionAmount_saturatesWhenPendingExceedsEquity() public pure {
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 10 ether, reservedAmount: 5 ether });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: 5 ether, rewardsPayable: 2 ether });

        AdminValues memory _admin = _mockAdmin(3 ether);

        StakingEscrow memory _pending =
            StakingEscrow({ pendingStaking: 100 ether, pendingUnstaking: 0, alwaysTrue: true });

        // equity = (10 + 20) - (5 + 2 + 3) = 20
        // max redemption = 20 - 100 = saturates to 0
        uint256 _maxRedemption =
            AccountingLib.maximumNewGlobalRedemptionAmount(_capital, _liabilities, _admin, _pending, 20 ether);

        assertEq(_maxRedemption, 0, "Should saturate to zero when pending exceeds equity");
    }

    // ================================
    // goodwill Tests
    // ================================

    function test_AccountingLib_goodwill_unpurposedMON() public pure {
        // goodwill = currentAssets - queueToStake
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 100 ether, reservedAmount: 20 ether });

        AtomicCapital memory _atomic = AtomicCapital({ allocatedAmount: 30 ether, distributedAmount: 10 ether });

        CashFlows memory _cashFlows = CashFlows({ queueToStake: 5 ether, queueForUnstake: 0, alwaysTrue: true });

        // currentAssets = 60 - (30-10) - 20 = 20
        // goodwill = 20 - 5 = 15
        uint256 _goodwill = AccountingLib.goodwill(_capital, _atomic, _cashFlows, 60 ether);

        assertEq(_goodwill, 15 ether, "Goodwill should be unpurposed MON");
    }

    function test_AccountingLib_goodwill_zeroWhenQueueExceedsCurrent() public pure {
        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: 100 ether, reservedAmount: 50 ether });

        AtomicCapital memory _atomic = AtomicCapital({ allocatedAmount: 40 ether, distributedAmount: 10 ether });

        CashFlows memory _cashFlows = CashFlows({ queueToStake: 100 ether, queueForUnstake: 0, alwaysTrue: true });

        // currentAssets = 60 - 30 - 50 = saturates to 0
        // goodwill = 0 - 100 = saturates to 0
        uint256 _goodwill = AccountingLib.goodwill(_capital, _atomic, _cashFlows, 60 ether);

        assertEq(_goodwill, 0, "Goodwill should saturate to zero");
    }

    // ================================
    // Invariant Tests
    // ================================

    function testFuzz_AccountingLib_invariant_assetsEqualEquityPlusLiabilities(
        uint128 staked,
        uint128 balance,
        uint128 redemptions,
        uint128 rewards,
        uint128 zeroYield
    )
        public
        pure
    {
        // CORE INVARIANT: ASSETS = EQUITY + LIABILITIES

        // Bound liability components to prevent overflow
        redemptions = uint128(bound(redemptions, 0, type(uint128).max / 4));
        rewards = uint128(bound(rewards, 0, type(uint128).max / 4));
        zeroYield = uint128(bound(zeroYield, 0, type(uint128).max / 4));

        // Ensure assets can cover liabilities (add 1 to handle rounding)
        uint256 _totalLiabilities = uint256(redemptions) + uint256(rewards) + uint256(zeroYield);
        uint256 _minAsset = (_totalLiabilities / 2) + 1;
        staked = uint128(bound(staked, _minAsset, type(uint128).max / 2));
        balance = uint128(bound(balance, _minAsset, type(uint128).max / 2));

        WorkingCapital memory _capital = WorkingCapital({ stakedAmount: staked, reservedAmount: 0 });

        CurrentLiabilities memory _liabilities =
            CurrentLiabilities({ redemptionsPayable: redemptions, rewardsPayable: rewards });

        AdminValues memory _admin = _mockAdmin(zeroYield);

        uint256 _equity = AccountingLib.totalEquity(_capital, _liabilities, _admin, balance);
        uint256 _computedLiabilities = AccountingLib.totalLiabilities(_liabilities, _admin);
        uint256 _totalAssets = uint256(staked) + uint256(balance);

        // ASSETS = EQUITY + LIABILITIES
        assertEq(_totalAssets, _equity + _computedLiabilities, "Invariant: ASSETS = EQUITY + LIABILITIES");
        assertEq(_totalLiabilities, _computedLiabilities, "Pre-computed should match library function");
    }

    function testFuzz_AccountingLib_invariant_contraAssetLogic(uint128 allocated, uint128 distributed) public pure {
        // CONTRA ASSET INVARIANT: ASSET = UNADJUSTED ASSET - CONTRA ASSET
        vm.assume(allocated >= distributed);

        AtomicCapital memory _atomic = AtomicCapital({ allocatedAmount: allocated, distributedAmount: distributed });

        uint256 _atomicAssets = AccountingLib.atomicAssets(_atomic);

        assertEq(_atomicAssets, allocated - distributed, "Invariant: ASSET = UNADJUSTED - CONTRA");
    }

    // ================================
    // Helper Functions
    // ================================

    function _mockAdmin(uint128 zeroYield) internal pure returns (AdminValues memory) {
        return AdminValues({
            internalEpoch: 1,
            targetLiquidityPercentage: 0,
            incentiveAlignmentPercentage: 0,
            stakingCommission: 0,
            boostCommissionRate: 0,
            totalZeroYieldPayable: zeroYield
        });
    }
}
