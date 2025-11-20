//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import {
    PendingBoost,
    CashFlows,
    WorkingCapital,
    StakingEscrow,
    AtomicCapital,
    CurrentLiabilities,
    AdminValues
} from "../Types.sol";
import { SCALE } from "../Constants.sol";

/*

ShMonad Accounting 101:

Double-Entry Bookkeeping means that every ledger change must be consist of two journal entries: a DEBIT and a CREDIT. 
        
    RULE: for a single entry, DEBIT = CREDIT
    RULE: for all entries, sum of DEBITs = sum of CREDITs  

Ledgers fall into one of three types: ASSETS, EQUITY, LIABILITIES

    RULE: DEBIT (dr) entries cause ASSETS to *increase*, but EQUITY and LIABILITIES to *decrease*
    RULE: CREDIT (cr) entries cause ASSETS to *decrease*, but EQUITY and LIABILITIES to *increase*

And the most important rule of all:

    RULE: ASSETS = EQUITY + LIABILITIES 

Sometimes, ShMonad uses a CONTRA ASSET ledger to help track the correct balance in an ASSET

    RULE: ASSET = UNADJUSTED ASSET - CONTRA ASSET
    RULE: CREDIT entries cause CONTRA ASSETS to *increase*, DEBIT entries cause CONTRA ASSETS to *decrease*. 

NOTE: the ASSET "totalAllocated" is considered an UNADJUSTED ASSET and is offset by the "totalUtilized" CONTRA ASSET.

Enforcing these rules at all times ensures balances are tracked properly and *verifiable*. 

These are the ledger balances that ShMonad tracks:

    ASSETS:
        - totalStaked: includes active stake, pending staking, and pending unstaking
        - totalAllocated: (MON) the maximum MON allocated as liquidity for the atomic unstaking pool (UNADJUSTED)
        - totalCurrent: (MON) unassigned MON that will be assigned on the next crank
        - totalReserved: (MON) reserved, liquid MON intended to pay out to validators or to shMON redeemers

    CONTRA ASSETS:
        - totalUtilized: (-MON) the amount of totalAllocated that has already been paid out to atomic unstakers 

    LIABILITIES:
        - rewardsPayable: MEV payments owed to validators that are escrowed temporarily by ShMonad 
        - redemptionsPayable: withdrawals owed to those who have burned their shMON but not yet collected their MON.
        - totalZeroYieldPayable: the amount of MON that is held in the zero-yield tranche, includes owner commission.

NOTE: ShMonad does not directly track EQUITY (the total MON attributable to holders of shMON shares). Instead, we
calculate EQUITY via the following equation:

    RULE: EQUITY = ASSETS - CONTRA ASSETS - LIABILITIES

Regarding the timing: 
    - shMON shares are minted on deposit / mint and ASSETS are increased at the same time. 
    - shMON shares are burned at 'beginUnstake' rather than 'completeUnstake', but the ASSETS (either staked or
    unstaked) owed to the redeemer are held in the contract until the redemption is completed. To handle this,
    we add the future withdrawal amount to the redemptionsPayable liability.

Reconciling accounting principles with the values visible on-chain is not always easy. We must make special
accomodations in order to handle the native MON balance of a smart contract. Because there are only three 
assets that are denominated in liquid MON, we know the following is always true for the ShMonad contract:

    RULE: MON balance = totalAllocated + totalCurrent + totalReserved

Therefore,

    RULE: totalCurrent = MON balance - totalAllocated - totalReserved

The totalCurrent balance is tracked indirectly by starting with the MON balance and then subtracting out
the other two ASSETs that show in in the MON balance. This means that actions that increase ShMonad's
MON balance but that don't also increase either totalAllocated or totalReserved are therefore increasing
the totalCurrent balance.

NOTE: This means that the code will often not explicitly handle increases (debits) or decreases (credits)
intended for totalCurrent because the change to ShMonad's MON balance is already accounting for it. To
improve readability, many parts of the code that implicitly increase or decrease the totalCurrent ledger
have commented-out code for the totalCurrent entry placed directly above or below the offsetting entry. 

The "totalReserved" ASSET is intended to reserve (and thereby prevent from getting put into the staking queue) MON
intended to pay off the LIABILITIES. One of the LIABILITIES, "rewardsPayable," is always collected as MON and 
therefore *currently* does not need to go through the unstaking process. The other of the LIABILITIES, 
"redemptionsPayable", may have had some of its balance finish unstaking as MON but it's very likely that not all 
of the amounts intended for redemptions has completed the unstaking / waiting process yet:

    RULE: redemptionsPayable = redemptionsPayable(MON) + redemptionsPayable(staked / unstaking)

This leads to the following deduction:

    RULE: redemptionsPayable(MON) =  totalReserved - rewardsPayable

ShMonad also tracks other values. The two most in-tune with the accounting system are "queueToStake" and
"queueForUnstake". These values are NOT accounting values:
    -   "queueToStake" helps allocate portions of totalCurrent to be staked with the correct validator (or 
        the atomic unstaking pool), at which point that amount becomes credited from totalCurrent and debited 
        to either totalStaked or totalAllocated.
    -   "queueForUnstake" helps allocate portions of totalStaked to be unstaked from the correct validator 
        (or the atomic unstaking pool), at which point that amount becomes credited from totalStaked and 
        debited to totalReserved or totalCurrent.
    
NOTE: To make sure the "queueForUnstake" funds don't get reinserted into the staking cycle, when MON funds are received
during the completion of the unstaking process they are debited to totalReserved if totalReserved is less than
rewardsPayable+redemptionsPayable and debited to totalCurrent otherwise. 

ERC-4626 is a vault standard and interface used by many apps. As such, ShMonad is ERC-4626-compliant.

ERC-4626 has a function called "totalAssets()", the purpose of which is to show how much MON is owned by 
the holders of shMON. Unfortunately, the team that designed ERC-4626 is unfamiliar with accounting terminology,
because the value returned by their funcction "totalAssets()" matches the exact description of EQUITY.

ShMonad is constantly earning revenue and increasing the amount of MON available to holders of shMON. To 
prevent dilution attacks ("JIT Liquidity") in which a large amount of revenue is going to be earned and 
so new attackers mint new shMON in order to gain exposure to this revenue (thereby diluting the existing
holders), the ERC-4626 "totalAssets()" function returns a different value for depositors than for 
redeemers.

NOTE: Remember that ERC-4626's totalAssets() is improperly named in the context of accounting.
    
    RULE: When calculating the shMON / MON rate for depositors:
            ERC-4626's totalAssets() = totalEquity 
    NOTE: This is a higher rate that lowers the shMON per MON deposited.

    RULE: When calculating the shMON / MON rate for withdrawals:
            ERC-4626's totalAssets() = totalEquity - recentRevenue
     NOTE: This is a lower rate that lowers the MON per shMON withdrawn.
*/

library AccountingLib {
    /// @dev Saturating subtraction: returns a - b if a > b, else 0.
    function _saturatingSub(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function currentLiabilities(CurrentLiabilities memory liabilities) internal pure returns (uint256) {
        return liabilities.redemptionsPayable + liabilities.rewardsPayable;
    }

    function totalLiabilities(
        CurrentLiabilities memory liabilities,
        AdminValues memory admin
    )
        internal
        pure
        returns (uint256)
    {
        return liabilities.redemptionsPayable + liabilities.rewardsPayable + admin.totalZeroYieldPayable;
    }

    // Free-floating MON that isn't staked (illiquid), reserved for liability settlement, or allocated to atomic
    // unstaking.
    function currentAssets(
        WorkingCapital memory workingCapital,
        AtomicCapital memory atomicCapital,
        uint256 nativeTokenBalance
    )
        internal
        pure
        returns (uint256)
    {
        uint256 _atomicAssets = atomicAssets(atomicCapital);
        uint256 _reservedAssets = workingCapital.reservedAmount;
        return _saturatingSub(nativeTokenBalance, _atomicAssets + _reservedAssets);
    }

    // Assets available for atomic unstaking
    // NOTE: This is unadjusted by earnedRevenue and is meant to be used when calculating liquidity,
    // not when calculating the atomic unstaking fee
    function atomicAssets(AtomicCapital memory atomicCapital) internal pure returns (uint256) {
        uint256 _totalAllocated = atomicCapital.allocatedAmount;
        uint256 _totalDistributed = atomicCapital.distributedAmount;
        return _saturatingSub(_totalAllocated, _totalDistributed);
    }

    /*
    // Long form to show the full reasoning
    function totalEquity(WorkingCapital memory workingCapital, AtomicCapital memory atomicCapital, AdminValues memory
    admin, uint256
    nativeTokenBalance) internal pure returns (uint256) {
        // Contra Assets
        uint256 _totalDistributed = uint256(atomicCapital.distributedAmount); // cancels out: -B
        
        // Assets
        uint256 _totalStaked = uint256(workingCapital.stakedAmount);
        uint256 _totalAllocated = uint256(atomicCapital.allocatedAmount); // cancels out: +A
        uint256 _totalReserved = uint256(workingCapital.reservedAmount); // cancels out: +C
    uint256 _totalCurrent = nativeTokenBalance - _totalReserved - _totalAllocated + _totalDistributed; // cancels out:
    +_, -C, -A, +B,

        // Liabilities
        uint256 _redemptionsPayable = uint256(liabilities.redemptionsPayable);
        uint256 _rewardsPayable = uint256(liabilities.rewardsPayable);
        uint256 _totalZeroYieldPayable = uint256(admin.totalZeroYieldPayable);
    return _totalStaked + _totalAllocated + _totalReserved + _totalCurrent - _totalDistributed - _redemptionsPayable -
    _rewardsPayable - _totalZeroYieldPayable;

            the equation:

    totalEquity = _totalStaked + _totalAllocated + _totalReserved + _totalCurrent - _totalDistributed -
    _redemptionsPayable - _rewardsPayable - _totalZeroYieldPayable;

            can replace _totalCurrent with its unsimplified form and expand into:

    totalEquity = _totalStaked + _totalAllocated + _totalReserved + nativeTokenBalance - _totalReserved -
    _totalAllocated + _totalDistributed - _totalDistributed - _redemptionsPayable - _rewardsPayable -
    _totalZeroYieldPayable;
         
            which simplifies down to:

        totalEquity = _totalStaked + nativeTokenBalance - _totalLiabilities;
    }
    */

    /// @notice Total MON attributable to shMON holders (ERC-4626 totalAssets).
    /// @dev In this system, ERC-4626 "totalAssets" corresponds to equity, not on-balance-sheet assets.
    /// Excludes pending redemptions and rewards payable; includes native balance and staked.
    /// shMON burns occur at beginUnstake, so redemptions remain as liabilities until paid.
    /// Rewards are escrowed briefly before distribution, so they remain liabilities until paid.
    /// @param workingCapital Current working capital snapshot (staked + reserved).
    /// @param liabilities Current liabilities (redemptions, rewards).
    /// @param admin Admin values containing totalZeroYieldPayable.
    /// @param nativeTokenBalance `address(this).balance` passed in by caller.
    /// @return equity The computed equity value.
    function totalEquity(
        WorkingCapital memory workingCapital,
        CurrentLiabilities memory liabilities,
        AdminValues memory admin,
        uint256 nativeTokenBalance
    )
        internal
        pure
        returns (uint256 equity)
    {
        uint256 _totalStaked = workingCapital.stakedAmount;
        return _totalStaked + nativeTokenBalance - totalLiabilities(liabilities, admin);
    }

    function maximumNewGlobalRedemptionAmount(
        WorkingCapital memory globalCapital,
        CurrentLiabilities memory liabilities,
        AdminValues memory admin,
        StakingEscrow memory globalPending,
        uint256 nativeTokenBalance
    )
        internal
        pure
        returns (uint256)
    {
        // We should not add amounts to the unstakingQueue that are in excess of what is unstakable.
        // NOTE The atomic liquidity is technically available, but takes an epoch to have its target amount lowered
        // thereby releasing the allocated capital to be available for non-atomic redemptions. Withdrawals that
        // would use that liquidity pull it by increasing the contrasset amountUtilized when necessary.
        uint256 _illiquidAmount = globalPending.pendingStaking;
        uint256 _equity = totalEquity(globalCapital, liabilities, admin, nativeTokenBalance);
        return _saturatingSub(_equity, _illiquidAmount);
    }

    // MON balance that is "unpurposed"
    function goodwill(
        WorkingCapital memory workingCapital,
        AtomicCapital memory atomicCapital,
        CashFlows memory globalCashFlows_T0,
        uint256 nativeTokenBalance
    )
        internal
        pure
        returns (uint256)
    {
        uint256 _currentAssets = currentAssets(workingCapital, atomicCapital, nativeTokenBalance);
        uint256 _currentStakingQueue = globalCashFlows_T0.queueToStake;
        return _saturatingSub(_currentAssets, _currentStakingQueue);
    }
}
