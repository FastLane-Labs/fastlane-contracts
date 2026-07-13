# ShMonad Events And Errors

Use this reference to interpret ShMonad receipts, verify state after writes, and diagnose reverts. Decode logs only from the verified ShMonad proxy address and decode data with the bundled concrete ABI.

## Contents

- [Units used below](#units-used-below)
- [Holder and vault events](#holder-and-vault-events)
- [Policy events](#policy-events)
- [Yield, validator, and admin events](#yield-validator-and-admin-events)
- [Emission gaps and misleading log patterns](#emission-gaps-and-misleading-log-patterns)
- [Authoritative post-state](#authoritative-post-state)
- [Revert diagnosis](#revert-diagnosis)
- [Runtime ABI and interface hazards](#runtime-abi-and-interface-hazards)

## Units Used Below

- **MON** means native-token wei; `1 MON = 1e18` wei.
- **shares** means shMON share subunits; `1 shMON = 1e18` share subunits.
- **WAD** means `1e18 = 100%`.
- **RAY** means `1e27 = 100%`.
- **BPS** means `10_000 = 100%`.
- Epoch, block, validator-ID, and policy-ID values are identifiers or counters, not token amounts.

Use `shmonad-abi.json` for the exact topic hash and indexed layout. The signatures below show indexed fields explicitly.

## Holder And Vault Events

| Exact event signature | Units and meaning |
| --- | --- |
| `Transfer(indexed address from,indexed address to,uint256 value)` | `value` is shares. Covers ordinary ERC-20 movement and mint/burn, plus synthetic policy bookkeeping described below. |
| `Approval(indexed address owner,indexed address spender,uint256 value)` | `value` is a share allowance. Finite allowance consumption does not emit another `Approval`. |
| `Deposit(indexed address sender,indexed address owner,uint256 assets,uint256 shares)` | `assets` is gross MON paid or zero-yield principal converted; `shares` is shMON minted. `owner` is the share receiver. |
| `Withdraw(indexed address sender,indexed address receiver,indexed address owner,uint256 assets,uint256 shares)` | Atomic holder exit. `assets` is net MON delivered after fee; `shares` is the gross share burn. |
| `RequestUnstake(indexed address owner,uint256 shares,uint256 amountMon,uint256 completionEpoch)` | Traditional exit request. `shares` burns immediately; `amountMon` is the fixed, fee-free MON claim; completion is gated by ShMonad epoch. |
| `CompleteUnstake(indexed address owner,uint256 amountMon)` | `amountMon` is MON delivered to the request owner. |
| `DepositToZeroYieldTranche(indexed address sender,indexed address receiver,uint256 assets)` | `assets` is MON principal credited to the receiver's non-transferable zero-yield balance; no shMON is minted. |
| `ZeroYieldBalanceConvertedToShares(indexed address from,indexed address to,uint256 assets,uint256 shares)` | `assets` is consumed zero-yield MON principal and `shares` is minted shMON. A companion `Deposit` is also emitted. |
| `AdminCommissionClaimedAsShares(indexed address recipient,uint256 assets,uint256 shares)` | Owner commission conversion: MON-denominated liability consumed and shMON minted. |

Do not infer a Solidity function return from these events. For example, `deposit` returns shares during simulation, but the receipt exposes only status and logs.

## Policy Events

| Exact event signature | Units and meaning |
| --- | --- |
| `CreatePolicy(indexed uint64 policyID,indexed address creator,uint48 escrowDuration)` | `escrowDuration` is blocks. |
| `AddPolicyAgent(indexed uint64 policyID,indexed address agent)` | Agent added to the policy. |
| `RemovePolicyAgent(indexed uint64 policyID,indexed address agent)` | Agent removed from the policy. |
| `DisablePolicy(indexed uint64 policyID)` | Policy permanently disabled for new commits and agent spend. |
| `Commit(indexed uint64 policyID,indexed address account,uint256 amount)` | `amount` is shares credited to the committed bucket. |
| `RequestUncommit(indexed uint64 policyID,indexed address account,uint256 amount,uint256 expectedUncommitCompleteBlock)` | `amount` is shares moved to uncommitting; completion uses block number. A later request resets the start for the entire uncommitting bucket. |
| `CompleteUncommit(indexed uint64 policyID,indexed address account,uint256 amount)` | `amount` is shares returned to the free bucket. |
| `UncommitApprovalUpdated(indexed uint64 policyID,indexed address account,indexed address completor,uint96 shares)` | `shares` is the delegated completion limit and is stored as `uint96`. |
| `SetTopUp(indexed uint64 policyID,indexed address account,uint128 minCommitted,uint128 maxTopUpPerPeriod,uint32 topUpPeriodDuration)` | Share target, share limit per period, and period length in blocks. |
| `AgentTransferFromCommitted(indexed uint64 policyID,indexed address from,indexed address to,uint256 amount)` | `amount` is shares credited committed-to-committed, even when the call input was expressed as MON. |
| `AgentTransferToUncommitted(indexed uint64 policyID,indexed address from,indexed address to,uint256 amount)` | `amount` is shares credited to the destination's free balance, even when the call input was expressed as MON. |
| `AgentWithdrawFromCommitted(indexed uint64 policyID,indexed address from,indexed address to,uint256 amount)` | `amount` is net MON delivered by the direct atomic exit, not shares. |

Policy `commit` emits a synthetic `Transfer(accountFrom, proxy, shares)` and completion emits `Transfer(proxy, account, shares)`. The proxy does not gain or lose a normal `balanceOf`; these logs visualize bucket movement. Do not reconcile policy balances from `Transfer` logs.

## Yield, Validator, And Admin Events

| Exact event signature | Units and meaning |
| --- | --- |
| `BoostYield(indexed address sender,indexed address yieldOriginator,indexed uint256 validatorId,uint256 amount,bool sharesBurned)` | `amount` is gross MON value before owner commission. `yieldOriginator` is attribution only. Both public boost paths use validator ID `0`; `sharesBurned` identifies the share-funded path. |
| `SendValidatorRewards(address sender,uint64 valId,uint256 validatorPayout,uint256 feeTaken)` | Both amounts are MON. `validatorPayout` is the delayed validator liability. `feeTaken` is all value not paid to the validator: gross configured fee when eligible, entire value when ineligible. |
| `InactiveValidatorRewardsRedirected(indexed uint64 validatorId,uint256 amount)` | `amount` is unpaid validator MON redirected to shMON yield after the validator becomes ineligible. |
| `FeeCurveUpdated(uint256 oldSlopeRateRay,uint256 oldYInterceptRay,uint256 newSlopeRateRay,uint256 newYInterceptRay)` | All four fee-curve parameters are RAY. |
| `ValidatorAdded(uint256 validatorId,address coinbase)` | Registry addition; `coinbase` is ShMonad's per-validator payout/processing address, not necessarily `block.coinbase`. |
| `ValidatorDeactivated(uint256 validatorId)` | Delayed removal queued; reward eligibility ends immediately. |
| `ValidatorMarkedInactive(uint64 validatorId,address coinbase,uint64 internalEpoch)` | Validator marked inactive during runtime active-set reconciliation. |
| `ValidatorNotFoundInActiveSet(uint64 validatorId,address coinbase,uint64 internalEpoch,uint256 detectionIndex)` | Current-set reconciliation could not find the validator. |
| `CoinbaseContractUpdated(uint64 valId,address oldCoinbase,address newCoinbase)` | Stored Coinbase relinked. Verify both forward and reverse registry mappings. |
| `OwnershipTransferred(indexed address previousOwner,indexed address newOwner)` | ShMonad application ownership changed; this is not the transparent proxy-admin role. |

Cranking can emit additional staking, queue, settlement, and anomaly events from the ABI. Their presence describes work attempted in that transaction, but the accounting views remain authoritative for the resulting state.

## Emission Gaps And Misleading Log Patterns

- Agent withdrawal changes balance buckets and supplies but emits neither ERC-20 `Transfer` nor ERC-4626 `Withdraw` for its own burn/payout. Its `AgentWithdrawFromCommitted.amount` is net MON.
- Agent transfer events always report resulting shares. Their call input may instead have been a MON-denominated amount when `inUnderlying == true`.
- An agent spend can pull shares from the source account's uncommitting bucket without an event. Re-read `getUncommittingData`.
- Automatic free-balance top-up during an agent spend emits `Commit` plus a synthetic `Transfer`, even though those were supporting effects rather than the requested action.
- Zero-yield conversion, including owner commission conversion, emits both `ZeroYieldBalanceConvertedToShares` and the ERC-4626-style `Deposit`/mint logs. Owner commission conversion additionally emits `AdminCommissionClaimedAsShares`.
- `BoostYield.amount` is gross, not holder net yield, and does not identify shares burned numerically.
- `SendValidatorRewards.feeTaken` changes meaning with eligibility as described above; do not recompute it as `value * feeRate` without first checking validator state.
- Status and commission setters have no dedicated ShMonad events. The pool-target setter also has no emitted target-change event.

The following ABI-declared ShMonad events have no emission site in this implementation and must not be awaited as completion signals:

```text
AgentExecuteWithSponsor
ManualUnstakeInitiation
ManualUnstakeRedemption
NewEpoch
PoolLiquidityUpdated
PoolTargetLiquidityPercentageSet
StakeFromPoolLiquidity
UnexpectedSurplusOnUnstakeSettle
UnstakeFeeEnabledSet
ValidatorRegisteredByAuth
ValidatorRemoved
ValidatorStakeAdded
ValidatorUnstakeRequested
ValidatorWeightsUpdated
```

## Authoritative Post-State

After a successful write, use the receipt to identify effects and then verify the state specific to the operation:

| Operation | Required post-state reads |
| --- | --- |
| Deposit, mint, transfer, atomic exit | `balanceOf`, `totalSupply`, allowance when delegated, and atomic liquidity for exits |
| Traditional request/completion | `getUnstakeRequest(account)` and `getInternalEpoch()` |
| Commit/uncommit | `getCommittedData`, `getUncommittingData`, `balanceOf`, and `getUncommitApproval` when delegated |
| Policy top-up or agent spend | `getTopUpSettings`, both policy balance buckets, free `balanceOf`, and current-transaction hold only when composition occurs in the same transaction |
| Zero-yield action | `balanceOfZeroYieldTranche`, receiver `balanceOf`, and `globalLiabilities()` |
| Yield boost or validator rewards | `totalAssets`, `getGlobalRevenue`, validator rewards when applicable, owner commission, and liabilities |
| Crank | `getInternalEpoch`, `getNextValidatorToCrank`, global pending/cash-flow/revenue views, capital, and affected validator records |
| Pool target or fee curve | Applied and pending target views, pool utilization/liquidity, or `getFeeCurveParams()` |
| Validator lifecycle or Coinbase update | `getValidatorData`, active count/list, Coinbase forward/reverse mappings, and neighbors |
| Status or commission update | `getGlobalStatus(0)` or `getAdminValues()` |

Use finalized state when reporting settlement. Use current state again when it feeds a new quote or execution decision.

## Revert Diagnosis

Decode revert data against `shmonad-abi.json`. Custom-error arguments often carry the exact available, requested, current-epoch, completion-block, or caller value needed to correct the ShMonad call.

### Holder, Vault, And Zero-Yield Errors

| Error | Diagnosis and ShMonad-specific correction |
| --- | --- |
| `IncorrectNativeTokenAmountSent` | Payable value does not exactly equal the deposit, mint quote, or zero-yield assets required by that entrypoint. Refresh the quote and simulate the same value. |
| `ERC20InsufficientBalance` | The operation uses free `balanceOf`; committed and uncommitting shares are not ERC-20 spendable. |
| `ERC20InsufficientAllowance` | Caller needs more free-share allowance for `transferFrom`, delegated atomic exit, or delegated share-funded boost. |
| `ERC20InvalidReceiver` / `ERC20InvalidSender` | A standard ERC-20/4626 path used an invalid zero endpoint. Nonstandard agent and zero-yield paths need their own caller-side zero checks. |
| `ERC4626ExceededMaxWithdraw` / `ERC4626ExceededMaxRedeem` | The preview ignored current liquidity or state moved. Re-read the liquidity-aware maximum and reduce the atomic exit. |
| `ERC4626WithdrawSlippageExceeded` | Required shares exceed `maxBurntShares`; obtain a fresh detailed quote or a new bound. |
| `ERC4626RedeemSlippageExceeded` | Net MON is below `minNetAssets`; obtain a fresh detailed quote or a new bound. |
| `InsufficientPoolLiquidity` / `InsufficientBalanceAtomicUnstakingPool` | Atomic pool cannot execute the requested payout/accounting at current state. Reduce size or use traditional unstake. |
| `CannotUnstakeZeroShares` | Traditional request must burn a positive number of free shares. |
| `InsufficientBalanceForUnstake` | Request exceeds caller's free shares; committed, uncommitting, and aggregate supply do not qualify. |
| `NoUnstakeRequestFound` | No positive MON request exists. A dust request can burn into zero and remain indistinguishable from no request. |
| `CompletionEpochNotReached(currentEpoch,completionEpoch)` | Wait for `getInternalEpoch()` to reach the stored completion epoch. |
| `InsufficientReservedLiquidity(requested,availableReserved)` | Epoch maturity was reached but reserve settlement is incomplete; inspect crank/accounting state and retry later. |
| `InsufficientZeroYieldBalance(available,requested)` | Conversion exceeds caller's zero-yield MON principal. |
| `InsufficientAccumulatedCommission(requested,available)` | Owner commission conversion exceeds `unclaimedOwnerCommission()`. |

### Policy Errors

| Error | Diagnosis and ShMonad-specific correction |
| --- | --- |
| `CommitRecipientCannotBeZeroAddress` | Use a nonzero committed-share recipient. |
| `PolicyInactive(policyID)` | New commitment and agent spend are disabled; holder request/completion of uncommit remains available. |
| `NotPolicyAgent(policyID,caller)` | Caller is not a configured agent of that active policy. |
| `PolicyAgentAlreadyExists` / `PolicyAgentNotFound` | Re-read `getPolicyAgents` before owner management. |
| `PolicyNeedsAtLeastOneAgent` | Removal would leave no configured agent. Also reject adding zero before it can become the only remaining entry. |
| `InsufficientUncommittedBalance` | Commitment/top-up exceeds free shares. |
| `InsufficientUnheldCommittedBalance` / `InsufficientCommittedForHold` | Requested uncommit/hold exceeds committed shares after same-transaction holds. |
| `InsufficientFunds` | Agent spend exceeds committed plus eligible uncommitting/top-up capacity after holds. |
| `InsufficientUncommittingBalance` | Completion or agent pull exceeds the policy's uncommitting bucket. |
| `UncommittingPeriodIncomplete(completionBlock)` | Wait for `block.number >= completionBlock`. |
| `InvalidUncommitCompletor` / `InsufficientUncommitApproval` | Re-read the `uint96` approval tuple and use the approved caller/amount. |
| `AgentInstantUncommittingDisallowed` | The source account is itself a policy agent and cannot be spent through an agent call. |
| `TopUpPeriodDurationTooShort(requested,min)` | A nonzero duration is below 216,000 blocks. Use zero or at least the reported minimum. To disable top-up, set min, maximum, and duration all to zero. |
| `BatchHoldAccountAmountLengthMismatch` / `BatchReleaseAccountAmountLengthMismatch` | Account and amount arrays differ in length. |

### Validator, Status, And Administration Errors

| Error | Diagnosis and ShMonad-specific correction |
| --- | --- |
| `NotWhenClosed` | The selected holder workflow is blocked by `closed`; do not assume all exits are blocked because atomic exits remain available. |
| `NotWhenFrozen` | Crank or Coinbase processing is blocked until owner clears `frozen`. |
| `InvalidFeeRate(feeRate)` | Validator-reward fee rate exceeds WAD (`1e18`). |
| `InvalidValidatorId` | ID is zero, a sentinel, absent from required registry state, or otherwise invalid for the selected validator call. |
| `ValidatorNotFoundInPrecompile` | The validator ID cannot be added because Monad staking does not report it. |
| `ValidatorAlreadyAdded` / `ValidatorNotFullyRemoved` | Validator is registered or still in delayed-removal state. |
| `ValidatorAlreadyDeactivated` / `ValidatorDeactivationNotQueued` / `ValidatorDeactivationQueuedIncomplete` | Lifecycle action does not match the current deactivation state or seven-epoch delay. |
| `CustomCoinbaseCantBeContract` | The explicit-address `addValidator` overload accepts only an address with no current code. Use the deterministic-contract overload when appropriate. |
| `CoinbaseAlreadyDeployed` | Coinbase update resolved to the address already linked. |
| `InvalidValidatorAddress` | Coinbase is zero, lacks required code, reports an invalid ID, or reports a different ShMonad proxy. |
| `OnlyCoinbaseAuth` | Caller is neither the registered Coinbase's auth address nor ShMonad owner. |
| `CommissionMustBeBelow100Percent` / `PercentageMustBeBelow100Percent` | BPS input must be below `10_000`. |
| `TargetLiquidityCannotExceed100Percent` | Pool target WAD exceeds `1e18`; remember input `1` is the no-update sentinel. |
| `SlopeRateExceedsRay` / `YInterceptExceedsRay` / `FeeCurveFullUtilizationExceedsRay` | Fee inputs or their sum exceed RAY (`1e27`). |
| `OwnableUnauthorizedAccount` | Caller is not live ShMonad `owner()`; proxy admin is a different role. |
| `ReentrancyGuardReentrantCall` | Coinbase, receiver, or composed callback attempted to reenter a guarded ShMonad path. |
| `SafeCastOverflowedUintDowncast` | Input or accumulated value exceeds the narrower stored type, notably `uint96` uncommit approval or `uint128` balance/accounting fields. |
| `InvalidInitialization` / `NotInitializing` / `UnauthorizedInitializer` | An upgrade-initialization path was invoked from the wrong role or state; it is not a holder workflow. |

## Runtime ABI And Interface Hazards

- Use `shmonad-abi.json` only after the network-specific implementation-address gate. A shared selector or matching token metadata is not compatibility proof.
- Encode overloaded calls by full signature, especially both `boostYield` forms, both `balanceOfCommitted` forms, both `addValidator` forms, and both `processCoinbaseByAuth` forms.
- `IShMonad` is not a complete runtime ABI. It omits zero-yield entrypoints and balance view, `unclaimedOwnerCommission`, `updateCoinbaseForExistingValidator`, `getGlobalPendingLast`, inherited ownership/EIP-5267 functions, and `receive()`.
- ShMonad's ERC-4626 `deposit` and `mint` are payable native-MON functions, while a canonical ERC-4626 interface commonly marks them nonpayable. `asset()` returns the native-token sentinel, not an ERC-20 contract.
- `getGlobalRevenue(offset)` decodes as `(allocatedRevenue, earnedRevenue)`.
- `globalLiabilities()` and the last field of `getAdminValues()` decode as `totalZeroYieldPayable`, not owner commission alone.
- `getEpochInfo()` returns `(epochNumber, 0)`; the second value is not a start block.
- `isGlobalCrankAvailable()` and `getEpochInfo()` are ABI `nonpayable` because the Monad staking precompile rejects `STATICCALL`; top-level `eth_call` remains valid.
- A receipt never carries a Solidity return value. Preserve the simulated result separately, then verify execution through status, exact events, and post-state.
