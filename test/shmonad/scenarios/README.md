# Complex Scenario Reference

This README documents the calculations and invariants verified by
`ComplexScenarios.t.sol`. The intent is that anyone can reproduce every number
the tests assert using the public getters on `TestShMonad` plus the mock stake
precompile.

## Test harness recap

* `BaseTest` wires up a `TestShMonad` proxy and etches the mock Monad staking
  precompile at `0x000...1000` before the vault is constructed (the constructor
  reads precompile constants).
* `scenarioShMonad` is a payable handle to the deployed proxy. After setup it
  records `baselinePoolLiquidity = getCurrentLiquidity()` and
  `baselineTargetLiquidity = getTargetLiquidity()`. These reflect the deployer
  priming plus the validator registration performed in `setUp`.
* `TestShMonad` exposes allocator internals (`s_globalCapital`,
  validator reward buckets, epoch tracking, etc.) so every assertion can be
  recomputed out of band.
* `_advanceEpoch(bool inDelay)` rolls the block by `MONAD_EPOCH_LENGTH + 1`,
  calls `harnessSyscallOnEpochChange(inDelay)` on the mock precompile, then
  invokes `startNextEpoch()` on the vault. This mirrors the chain transition that
  drains scheduled stake and materialises gated boosts.

### Sentinel values

The tracker structs store `1` in several fields to avoid division-by-zero on the
first crank. Whenever we compare earned revenue we subtract that sentinel (see
`_validatorEarned`). Apply the same adjustment when reading storage directly.

## Useful formulas

```text
pool'   = pool + deposit
stake'  = targetStake + deposit
```

Deposits route through `_afterDeposit`, which applies both adjustments.

```text
pool'   = pool + boost
earned' = earned + boost
```

`_handleBoostYield` credits both the pool liquidity and the earned-revenue
weighting for the targeted validator.

```text
shareAssets = convertToAssets(shares)
netAssets   = previewRedeem(shares)
feeAssets   = shareAssets - netAssets
feeBps      = feeAssets * 10_000 / shareAssets
pool'       = pool - netAssets
```

Instant withdraw burns the previewed shares and deducts the **net** assets from
liquidity. Use `quoteFeeFromGrossAssetsNoLiquidityLimit(gross)` to reverse-engineer
fees from a gross target.

`totalAssets()` equals:

```text
address(this).balance
+ s_stakeTotals.floating
- s_globalCapital.amountPayable
- s_yieldTotals.accumulated
```

We maintain an off-chain `ledger = Σ(deposits + boosts) − Σ(netWithdrawals +
completes)` and assert that `totalAssets_final ≈ totalAssets_initial + ledger`.

Fee segments (current config):

| Segment | Utilisation (%) | Fee (%)    |
|---------|-----------------|------------|
| #1      | 0 → 50          | 0.5 → 3.0  |
| #2      | 50 → 100        | 3.0 → 13.0 |

Target liquidity `0` forces fees near the top of segment #2.

## Scenario walkthroughs

### Normal ops

* Goal: multi-user deposits → validator boosts → instant withdraw. Confirms pool
  and target adjustments, earned-revenue weighting, preview accuracy, and
  post-fee liquidity deltas.
* Steps: deposits of `10k`, `5k`, `20k` → advance one epoch → boosts (`3`, `1`,
  `2` ether) spread across validators → advance 10 epochs so boosts are realised
  → redeem capped shares → deposit and immediately withdraw `1k` net after fees.
* Expectations: target liquidity increases by `(depositTotal * TARGET_FLOAT) /
  SCALE`, pool liquidity tracks the target when unused, boosted funds stay gated
  until the next epoch, and instant withdraw burns `previewWithdraw` shares while
  reducing pool liquidity by the realised net.

### Black swan deposit

* Goal: a single large deposit is absorbed exactly once by the allocator.
* Steps: seed modest deposits and boosts to establish a baseline → record
  `targetBefore`, `poolBefore`, and `totalAssetsBefore` → deposit `200_000 ether`
  in one call → advance a few epochs → compare `targetAfter`, `poolAfter`, and
  `totalAssetsAfter`.
* Expectations: `targetAfter = (totalAssetsAfter * TARGET_FLOAT) / SCALE`,
  `poolAfter = targetAfter` while utilisation is zero, and
  `totalAssetsAfter - totalAssetsBefore = massiveDeposit`.

### Fee curve probes

* `test_ShMonad_FeeBoundsAcrossUtilization`: samples a small withdraw at low
  utilisation, then a large withdraw near max utilisation. Confirms the fee in
  basis points does not shrink as the pool empties.
* `test_ShMonad_FeeMonotonicWithUtilization`: halves a position, then recomputes
  fees on the reduced liquidity to verify monotonicity.
* `test_ShMonad_FeeContinuityAroundFiftyPercent`: snapshots just below and just
  above the 50% utilisation boundary and asserts the fee delta stays within
  15 basis points.
* `test_ShMonad_FlatMaxFeeWhenTargetZero`: measures a baseline withdraw, toggles
  `setPoolTargetLiquidityPercentage(0)`, and confirms the fee climbs toward the
  configured maximum.

### Accounting conservation

* `test_ShMonad_AccountingConservation`: tracks deposits, boosts, and partial
  redeems against `totalAssets()` using `exposeTotalAssets({treatAsWithdrawal:
  true})`. Boosts remain gated until the next epoch transition, ensuring the
  ledger holds over multiple epochs.

### Delay window behaviour

* `test_ShMonad_DelayWindowDelegationSchedulesTwoEpochsOut`: after a delay-window
  epoch rollover, a fresh delegation stays scheduled with `deltaEpoch = epoch +
  2`.
* `test_ShMonad_DelayWindowUndelegateRequiresExtraEpochs`: requests an
  undelegation inside the delay window, verifies the withdrawal ticket is
  deferred by two additional epochs, and proves early withdrawals revert.

### Reward gating and validator state

* `test_ShMonad_ScheduledStakeDoesNotEarnPriorRewards`: schedules extra stake
  after rewards are posted and shows the scheduled amount does not dilute prior
  rewards when `claimRewards` runs.
* `test_ShMonad_ExternalRewardRequiresConsensus`: enforces that only validators
  already in the consensus set may call `externalReward`.
* `test_ShMonad_AuthWithdrawnClearsNextEpoch`: validates that a validator flagged
  as withdrawn clears the flag one epoch after meeting the minimum stake.
* `test_ShMonad_CompoundSettlesRewardsBeforeRedelegation`: when a delegator calls
  `compound`, the principal stays constant while the rewards are scheduled for
  the next epoch (`deltaEpoch = epoch + 1`).

## Boost size note

The mock precompile requires 50M MON stake to accept `externalReward`. Boosts in
these tests stay well below that so we focus on allocator behaviour; the real
path is exercised on chain.

## Running

```bash
make simulation-local
# or directly
forge test --match-path test/shmonad/scenarios/ComplexScenarios.t.sol
```

Set `SIMULATION_VALIDATOR_ASSERTS=false` (for example
`make simulation-local SIM_VALIDATOR_ASSERTS=false`) to skip the optional
per-validator assertions and focus purely on the global accounting invariants.

Inspect `TestShMonad` getters (or add temporary logs) to recompute any values
referenced above.
