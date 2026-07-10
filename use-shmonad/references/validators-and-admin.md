# ShMonad Validators And Administration

Use this reference for validator rewards, permissionless cranking, validator and global accounting, atomic-pool configuration, Coinbase processing, and owner-only administration. All calls target the verified ShMonad proxy.

## Contents

- [Roles and global status](#roles-and-global-status)
- [Validator reward submission](#validator-reward-submission)
- [Cranking](#cranking)
- [Accounting and status reads](#accounting-and-status-reads)
- [Atomic-pool target](#atomic-pool-target)
- [Atomic exit fee curve](#atomic-exit-fee-curve)
- [Validator identity and state](#validator-identity-and-state)
- [Validator lifecycle](#validator-lifecycle)
- [Coinbase processing](#coinbase-processing)
- [Commission, status, and ownership administration](#commission-status-and-ownership-administration)

## Roles And Global Status

| Role | Validator or administrative authority |
| --- | --- |
| Any account | Call permissionless `crank()` and submit payable `sendValidatorRewards` |
| Validator Coinbase auth | Call `processCoinbaseByAuth(uint64)` for its registered contract Coinbase |
| ShMonad `owner()` | Manage validators, process Coinbase contracts, configure pool, fee, commission, and status values, and convert accrued owner commission |
| Transparent proxy admin | Upgrade and initialization machinery only; it is distinct from `owner()` and cannot fall through the transparent proxy as an ordinary ShMonad caller |

Read current flags with:

```text
getGlobalStatus(0) -> (frozen, closed)
```

Neither flag is a universal pause:

- `closed` blocks `deposit`, `mint`, `depositAndCommit`, traditional `requestUnstake` and `completeUnstake`, zero-yield deposit, and zero-yield conversion.
- `closed` does not block holder atomic exits or ordinary ERC-20 transfers in this implementation.
- `frozen` blocks `crank()` and both Coinbase-processing overloads.
- `frozen` does not pause ordinary ERC-20 activity, deposits, or atomic exits, although blocked cranking can delay accounting and traditional-exit readiness.

## Validator Reward Submission

`sendValidatorRewards(uint64 validatorId, uint256 feeRate)` is payable. `feeRate` is caller supplied, WAD-scaled, and must be at most `1e18`. ShMonad does not load it from validator configuration. Confirm the chosen validator ID, fee rate, and MON value before the call.

Read:

```text
getValidatorData(validatorId)
  -> (epoch, id, isPlaceholder, isActive,
      inActiveSet_Current, inActiveSet_Last, coinbase)
```

A delayed validator payout is recorded only when all three conditions hold:

```text
isPlaceholder == false
isActive == true
inActiveSet_Current == true
```

At the selected state, calculate:

```text
grossFee       = floor(value * feeRate / 1e18)
ownerCommission = floor(grossFee * boostCommissionRateBps / 10_000)
holderRevenue   = grossFee - ownerCommission
```

For an eligible validator:

```text
validatorPayout                 = value - grossFee
SendValidatorRewards.feeTaken   = grossFee
```

The payout becomes a liability for delayed settlement, `holderRevenue` becomes shMON yield, and `ownerCommission` becomes the owner's zero-yield commission balance.

For a placeholder, inactive validator, or validator outside the current active set:

```text
validatorPayout                 = 0
SendValidatorRewards.feeTaken   = value
```

The full value stays in ShMonad: `ownerCommission` is still calculated only from `grossFee`, and the remainder benefits shMON holders. With `feeRate = 0`, owner commission is zero on either path. Do not infer eligibility from `isValidatorActive` alone.

After submission, decode `SendValidatorRewards` and re-read `getValidatorRewards(validatorId)`, `globalLiabilities()`, and the relevant revenue/accounting views. The event's `feeTaken` is every wei not allocated to the validator, not always the configured gross fee.

## Cranking

`crank()` is permissionless and nonpayable. It advances global epoch/accounting state and then validator state when work is available. It is blocked while frozen and returns whether the current crank work completed.

Validator processing stops when remaining gas reaches the internal 1,500,000-gas threshold. A large validator set can therefore require repeated transactions. Use these reads around each call:

```text
isGlobalCrankAvailable()             -> bool
isValidatorCrankAvailable(id)        -> bool
getNextValidatorToCrank()            -> next Coinbase, or address(0) at the end
getInternalEpoch()                   -> ShMonad internal epoch
```

`isGlobalCrankAvailable()` is ABI `nonpayable`, not `view`, because it reaches the Monad staking precompile. A top-level `eth_call` can evaluate it. Do not place an unbounded loop around `crank()` in one on-chain transaction; process bounded calls and verify the cursor and accounting state after each one.

## Accounting And Status Reads

| Read | Return or meaning |
| --- | --- |
| `getWorkingCapital()` | `(stakedAmount, reservedAmount)` in MON wei |
| `getAtomicCapital()` | `(allocatedAmount, distributedAmount)` in MON wei |
| `getGlobalPending()` | Current `(pendingStaking, pendingUnstaking)` in MON wei |
| `getGlobalPendingLast()` | Prior snapshot of pending staking and unstaking |
| `getGlobalCashFlows(offset)` | `(queueToStake, queueForUnstake)` at a circular epoch pointer |
| `getGlobalRevenue(offset)` | `(allocatedRevenue, earnedRevenue)` at a circular epoch pointer |
| `getGlobalEpoch(offset)` | Epoch number, withdrawal/deposit flags, crank flags, status, and target stake amount |
| `getGlobalStatus(offset)` | `(frozen, closed)` at a circular epoch pointer |
| `getGlobalAmountAvailableToUnstake()` | Current globally unstakable MON |
| `getCurrentAssets()` | Current liquid/accounted asset value in MON wei |
| `globalLiabilities()` | `(rewardsPayable, redemptionsPayable, totalZeroYieldPayable)` in MON wei |
| `getAdminValues()` | `(internalEpoch, targetLiquidityPercentage, incentiveAlignmentPercentage, stakingCommission, boostCommissionRate, totalZeroYieldPayable)` |

The four percentage/commission fields returned by `getAdminValues()` are basis points, including `targetLiquidityPercentage`; `getScaledTargetLiquidityPercentage()` returns the target in WAD. Epoch-pointer storage wraps modulo eight. Use offsets `-2`, `-1`, `0`, and `1` for ordinary current/history reads unless circular-slot inspection is explicitly intended.

## Atomic-Pool Target

The owner sets the target with `setPoolTargetLiquidityPercentage(uint256 newPercentageScaled)`. Its input is WAD and cannot exceed `1e18`, but its storage/application behavior has important edge cases:

- Input `1` is the internal `FLOAT_PLACEHOLDER`, not a one-wei-WAD target. It represents no pending update.
- Applied target precision is one basis point. Use `0` or a multiple of `1e14` WAD for an exact stored value; finer precision is truncated when applied.
- Every setter call overwrites the pending slot. A later value, including `1`, cancels an in-progress update.
- An update can apply gradually when assets or existing utilization prevent an immediate move.
- When the current applied target is zero, `getPendingTargetLiquidity()` can return zero even while a positive percentage is pending.
- Cranking can populate the pending slot itself to correct allocation drift, so pending state is not necessarily owner initiated.

Use all of these after a change and after subsequent cranks:

```text
getScaledTargetLiquidityPercentage() -> applied target percentage, WAD
getTargetLiquidity()                  -> applied target amount, MON wei
getPendingTargetLiquidity()           -> amount implied by pending state, MON wei
getCurrentLiquidity()                 -> currently available atomic liquidity, MON wei
getAtomicUtilizationWad()             -> current utilization, WAD
getAtomicPoolUtilization()            -> (utilized, allocated, available, utilizationWad)
```

The setter emits no reliable dedicated target-change event in this implementation. Treat the views as authoritative.

## Atomic Exit Fee Curve

The owner calls:

```text
setUnstakeFeeCurve(slopeRateRay, yInterceptRay)
```

Both parameters use RAY (`1e27`), each must be at most `1e27`, and their sum must be at most `1e27`. The marginal curve is:

```text
marginal fee rate = yInterceptRay + slopeRateRay * utilization
```

Utilization is WAD. When the curve is enabled, each atomic exit has a 1-gwei minimum fee capped by the gross withdrawal amount. Setting both parameters to zero disables both the curve fee and that minimum.

Verify `FeeCurveUpdated` and `getFeeCurveParams()`. `getCurrentUnstakeFeeRateRay()` is the current marginal rate; it is not necessarily the effective rate for a large exit that moves utilization.

## Validator Identity And State

Monad validator ID is the primary identity. `block.coinbase` is not unique to a validator: multiple validator IDs can share a block-author address. ShMonad's stored Coinbase is a separate, per-validator payout and processing address. Do not derive validator identity from `block.coinbase`.

| Read | Return or decision use |
| --- | --- |
| `getValidatorData(id)` | Epoch, ID, placeholder flag, active flag, current/last active-set flags, Coinbase |
| `getValidatorStats(id)` | Active state, Coinbase, epoch/target, and last/current reward and revenue values |
| `isValidatorActive(id)` | Registered/not-fully-removed state only |
| `getValidatorCoinbase(id)` | Stored Coinbase address |
| `getValidatorIdForCoinbase(coinbase)` | Stored validator ID mapping |
| `listActiveValidators()` | Parallel validator-ID and Coinbase arrays |
| `getValidatorEpochs(id)` | Last/current epoch and target stake values |
| `getValidatorPendingEscrow(id)` | Last/current pending stake and unstake values |
| `getValidatorRewards(id)` | Last/current rewards payable and earned revenue |
| `getValidatorNeighbors(id)` | Previous/next Coinbase in crank order |
| `getActiveValidatorCount()` | Active registry count |
| `getEpochInfo()` | Monad staking epoch; second ABI return value is always `0`, not an epoch start block |

During delayed deactivation, `isValidatorActive(id)` can remain true even though `getValidatorData(id).isActive` and `getValidatorStats(id).isActive` are false. Reward eligibility additionally requires `inActiveSet_Current`.

## Validator Lifecycle

All lifecycle calls are owner-only:

| Call | Behavior |
| --- | --- |
| `previewCoinbaseAddress(id)` | Predict the deterministic ShMonad Coinbase contract address |
| `addValidator(id)` | Deploy or reuse the deterministic Coinbase contract, register the validator, and return the Coinbase address |
| `addValidator(id, coinbase)` | Register a supplied nonzero address that currently has no contract code |
| `updateCoinbaseForExistingValidator(id)` | Deploy/link a new deterministic Coinbase contract and return it; despite the name, it does not verify that the validator is registered |
| `deactivateValidator(id)` | Mark reward eligibility inactive immediately and queue full removal |

Before adding, require a real, non-sentinel validator ID present in the staking precompile. It must not already be active, awaiting full removal, or mapped inconsistently. For the supplied-address overload, ShMonad rejects an address with code; operational control of that address and the risk of an undeployed deterministic contract must be established outside the contract.

Deactivation fully removes the validator after seven cranked ShMonad internal epochs. The immediate inactive flag redirects new and unpaid validator rewards to shMON yield during the delay.

## Coinbase Processing

Both processing calls are blocked while frozen and settle the Coinbase through the same accounting path used by cranking.

`processCoinbaseByAuth(uint64 validatorId)`:

- accepts the registered Coinbase auth address or ShMonad owner as caller;
- rejects zero, placeholder, and unregistered validator IDs;
- requires the mapped Coinbase to contain contract code; and
- therefore cannot process a validator registered with a plain EOA Coinbase.

`processCoinbaseByAuth(address coinbase)`:

- is owner-only;
- requires contract code;
- requires `VAL_ID()` to return neither zero nor the unknown placeholder;
- requires `SHMONAD()` to return this proxy; and
- intentionally does not require current ShMonad registration or staking-precompile membership, allowing an old or unlinked ShMonad Coinbase to be settled.

`updateCoinbaseForExistingValidator` attempts to settle a funded previous contract Coinbase before relinking it. Verify `CoinbaseContractUpdated`, both registry mappings, and validator accounting after the change.

## Commission, Status, And Ownership Administration

The owner-only commission setters take basis points and reject `10_000` or more:

```text
updateStakingCommission(stakingCommissionBps)
updateBoostCommission(boostCommissionBps)
updateIncentiveAlignmentPercentage(incentiveAlignmentBps)
```

The owner also controls:

```text
setFrozenStatus(bool)
setClosedStatus(bool)
```

These commission and status setters do not emit dedicated ShMonad configuration events. Re-read `getAdminValues()` or `getGlobalStatus(0)` after execution.

Owner commission is a MON-denominated zero-yield liability:

```text
unclaimedOwnerCommission() -> MON wei
claimOwnerCommissionAsShares(assets, receiver) -> shares
```

Commission conversion remains callable while closed. Require a nonzero receiver and a positive, acceptable simulated share result before consuming commission principal; floor rounding can otherwise consume positive MON liability for zero shares.

`owner()` is the application owner. `transferOwnership(newOwner)` changes that role, while `renounceOwnership()` removes it irreversibly and disables owner-only administration. `initialize(address)` is proxy-admin upgrade machinery (`reinitializer(11)`), not an owner or holder workflow.
