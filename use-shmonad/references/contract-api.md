# ShMonad Contract API And Semantics

This reference describes the currently deployed ShMonad v1.1 proxy surface represented by repository commit `2cf37b4`, not only `IShMonad`. The bundled ABI was generated from `out/ShMonad.sol/ShMonad.json`. It is valid only when the proxy's EIP-1967 implementation is mainnet `0x856a4019228c265dee336df705277607c4a18e1b` or testnet `0xbc123976c241873541eabff550724a9adfc4651d` on the corresponding chain. Live verified-ABI checks on 2026-07-10 matched the bundle exactly on both implementations: 141 functions, 79 events, and 79 errors.

Do not apply this API reference to any other implementation, including any future implementation version, even when a function selector or token metadata is unchanged. Pass the exact implementation-address gate in `SKILL.md` before using this reference.

## Contents

- [Contract model](#contract-model)
- [Access and status model](#access-and-status-model)
- [ERC-20, permit, ownership, and proxy surface](#erc-20-permit-ownership-and-proxy-surface)
- [Vault, withdrawal, yield, and zero-yield surface](#vault-withdrawal-yield-and-zero-yield-surface)
- [Conversion, rounding, and fee semantics](#conversion-rounding-and-fee-semantics)
- [Policy and commitment surface](#policy-and-commitment-surface)
- [Atomic pool, accounting, and crank surface](#atomic-pool-accounting-and-crank-surface)
- [Validator and operator surface](#validator-and-operator-surface)
- [Core events](#core-events)
- [Errors and revert diagnosis](#errors-and-revert-diagnosis)
- [Known interface and documentation hazards](#known-interface-and-documentation-hazards)

## Contract Model

Inheritance is:

```text
ShMonad
  -> Policies
  -> AtomicUnstakePool
  -> StakeTracker
  -> ValidatorRegistry
  -> FastLaneERC4626
  -> FastLaneERC20
  -> ShMonadHolds
  -> ShMonadStorage
```

It also inherits OpenZeppelin upgradeable ownership, EIP-712/nonces, and a transient reentrancy guard.

The contract represents native MON with sentinel address `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`, not WMON. `1 MON` is `10^18` wei and `1 shMON` is `10^18` share subunits; their economic value is not 1:1 and must be obtained from live previews.

shMON is non-rebasing. Yield changes MON value per share, not wallet share count. An account can have:

- uncommitted shares, returned by `balanceOf`;
- committed shares, tracked by policy and in aggregate; and
- uncommitting shares, tracked separately per policy during block-based escrow.

`totalSupply`/`realTotalSupply` includes all issued share states. `committedTotalSupply` includes only committed state, not uncommitting state.

## Access And Status Model

| Role/state | Effect |
| --- | --- |
| Any account | ERC-20 actions on its uncommitted balance, deposits, exits, zero-yield actions, policy creation/commitment, donations, and permissionless crank |
| Approved spender | ERC-20 `transferFrom`; third-party atomic exit or share-funded boost from owner's uncommitted balance |
| Policy agent | Transient holds and agent spend calls for one active policy; can disable that policy |
| ShMonad owner | Pool/fee/status/validator administration, policy-agent changes, commission conversion |
| Validator auth | May process its registered Coinbase by validator ID |
| Transparent proxy admin | Upgrade/initialize machinery; cannot fall through proxy as an ordinary ShMonad caller |
| `closed` | Blocks deposit, mint, depositAndCommit (routes through deposit), traditional request/complete unstake, zero-yield deposit, and zero-yield conversion |
| `frozen` | Blocks crank and Coinbase processing; can indirectly delay traditional unstake readiness |

`closed` and `frozen` are not universal pauses. ERC-20 transfers and atomic `withdraw`/`redeem` have neither modifier in this implementation.

## ERC-20, Permit, Ownership, And Proxy Surface

| Signature | Selector | Mutability/access | Meaning |
| --- | --- | --- | --- |
| `name()` | `0x06fdde03` | view | Returns `ShMonad` |
| `symbol()` | `0x95d89b41` | view | Returns `shMON` |
| `decimals()` | `0x313ce567` | view | Returns `18` |
| `totalSupply()` | `0x18160ddd` | view | All issued share states |
| `realTotalSupply()` | `0xef356a79` | view | Alias of real issued supply |
| `committedTotalSupply()` | `0xcc34b8f6` | view | Shares currently committed across policies |
| `balanceOf(address)` | `0x70a08231` | view | Uncommitted/free shares only |
| `balanceOfCommitted(address)` | `0x647a4772` | view | Aggregate committed shares for account |
| `balanceOfCommitted(uint64,address)` | `0xaff94332` | view | Policy-specific committed shares |
| `balanceOfUncommitting(uint64,address)` | `0xbf39ed93` | view | Policy-specific uncommitting shares |
| `allowance(address,address)` | `0xdd62ed3e` | view | Standard share allowance |
| `approve(address,uint256)` | `0x095ea7b3` | caller | Set exact share allowance |
| `transfer(address,uint256)` | `0xa9059cbb` | caller | Transfer caller's uncommitted shares |
| `transferFrom(address,address,uint256)` | `0x23b872dd` | allowance | Transfer uncommitted shares; no Approval event on decrement |
| `nonces(address)` | `0x7ecebe00` | view | EIP-2612 nonce |
| `DOMAIN_SEPARATOR()` | `0x3644e515` | view | Current EIP-712 domain separator |
| `eip712Domain()` | `0x84b0196e` | view | EIP-5267 domain fields |
| `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)` | `0xd505accf` | signed owner | Set allowance with EIP-2612 signature |
| `owner()` | `0x8da5cb5b` | view | ShMonad application owner, not proxy admin |
| `transferOwnership(address)` | `0xf2fde38b` | owner | Transfer application ownership |
| `renounceOwnership()` | `0x715018a6` | owner | Irreversibly remove application owner; high risk |
| `initialize(address)` | `0xc4d66de8` | proxy admin only | Upgrade initialization (`reinitializer(11)`); never a holder action |
| `receive()` | n/a | payable | Accept plain MON as goodwill/donation; mints no shares |

Maximum `uint256` allowance is infinite and is not decremented. Finite allowance is consumed by `transferFrom`, delegated `withdraw`/`redeem`, and share-funded `boostYield` when caller differs from `from`/`owner`.

Permit domain fields are name `ShMonad`, version `3`, live chain ID, and the proxy as verifying contract. For an EOA owner, `v` must be `27` or `28`; the implementation does not normalize `0` or `1`. Permit falls back to ERC-1271 for a contract owner. The fallback passes exactly `abi.encodePacked(r,s,v)`, so only contract wallets that validate that 65-byte representation are compatible; the ABI cannot carry arbitrary-length contract-wallet signatures. Deadline equal to current block timestamp is valid; a past deadline is not.

## Vault, Withdrawal, Yield, And Zero-Yield Surface

### Standard And Detailed Views

| Signature | Selector | Returns/meaning |
| --- | --- | --- |
| `asset()` | `0x38d52e0f` | Native-token sentinel, not an ERC-20 |
| `totalAssets()` | `0x01e1d114` | Full equity attributable to issued shMON |
| `convertToShares(uint256)` | `0xc6e6f592` | Floor share conversion with recent-revenue deduction |
| `convertToAssets(uint256)` | `0x07a2d13a` | Floor asset conversion with recent-revenue deduction |
| `maxDeposit(address)` | `0x402d267d` | Always `uint128.max`; does not reflect closed status |
| `maxMint(address)` | `0xc63d75b6` | Always `uint128.max`; does not reflect closed status |
| `maxWithdraw(address)` | `0xce96cb77` | Maximum executable net MON given free shares, fee, and pool liquidity |
| `maxRedeem(address)` | `0xd905777e` | Maximum executable free shares given pool liquidity |
| `previewDeposit(uint256)` | `0xef8b30f7` | Floor shares for MON deposit |
| `previewMint(uint256)` | `0xb3d7f6b9` | Ceil MON required for exact shares |
| `previewWithdraw(uint256)` | `0x0a28a477` | Ceil shares for exact net MON, fee included, liquidity ignored |
| `previewRedeem(uint256)` | `0x4cdad506` | Net MON for exact shares, fee included, liquidity ignored |
| `previewWithdrawDetailed(uint256)` | `0x7fbee515` | `(shares,grossAssets,feeAssets)` for target net MON |
| `previewRedeemDetailed(uint256)` | `0xcbd2d522` | `(grossAssets,feeAssets,netAssets)` for shares |
| `previewUnstake(uint256)` | `0x91767552` | Fee-free, floor MON locked by traditional request |

### State-Changing Holder Calls

| Signature | Selector | Value/access | Effects and return |
| --- | --- | --- | --- |
| `deposit(uint256,address)` | `0x6e553f65` | payable; `value == assets`; not closed | Mint floor-quoted shares to nonzero receiver; can return zero for a positive dust input |
| `mint(uint256,address)` | `0x94bf804d` | payable; exact calculated value; not closed | Mint exact positive shares to nonzero receiver; return assets paid |
| `withdraw(uint256,address,address)` | `0xb460af94` | allowance if caller != owner | Deliver exact net MON; burn fee-inclusive shares; return shares |
| `withdrawWithSlippageProtection(uint256,address,address,uint256)` | `0xbe1d8e1c` | same | Revert when shares burned exceed `maxBurntShares` |
| `redeem(uint256,address,address)` | `0xba087652` | allowance if caller != owner | Burn exact shares; deliver net MON; return assets |
| `redeemWithSlippageProtection(uint256,address,address,uint256)` | `0x421c885d` | same | Revert when net MON is below `minAssetsOut` |
| `requestUnstake(uint256)` | `0x23095721` | caller free shares; not closed | Burn now, lock fee-free MON, return completion epoch; require positive previewed MON first |
| `completeUnstake()` | `0x63803b23` | request owner; not closed | Pay entire matured request to caller and clear it |
| `getUnstakeRequest(address)` | `0x64a6c194` | view | `(amountMon,completionEpoch)` |
| `boostYield(address)` | `0x4dc4993a` | payable | Donate MON minus owner boost commission; originator is event attribution; no shares |
| `boostYield(uint256,address,address)` | `0x5357a136` | allowance when caller != from | Burn free shares and leave their asset value, minus owner boost commission, as yield |
| `sendValidatorRewards(uint64,uint256)` | `0xe5cdc7c7` | payable; feeRate <= `1e18` | Validator payout only for active, non-placeholder current-set validator; otherwise value becomes yield/commission |
| `depositToZeroYieldTranche(uint256,address)` | `0x8d01c5c8` | payable; exact value; not closed | Credit non-yield MON liability; mint no shMON; caller must reject zero receiver |
| `convertZeroYieldTrancheToShares(uint256,address)` | `0xbc3ec4c2` | caller's zero-yield balance; not closed | Consume caller principal and mint shares; can return zero after floor rounding |
| `balanceOfZeroYieldTranche(address)` | `0x1d07c5cf` | view | Account's zero-yield principal in MON |
| `unclaimedOwnerCommission()` | `0x41faf0a7` | view | Owner commission liability in MON |
| `claimOwnerCommissionAsShares(uint256,address)` | `0x73e45bae` | owner; callable even when closed | Convert owner commission liability to shares |

Deposit/mint require exact native value. No MON token approval or WMON wrapping is involved. A plain native transfer, `boostYield`, `sendValidatorRewards`, and zero-yield deposit all accept MON but do not perform the standard share-minting deposit. Both `boostYield` variants take the owner's boost commission (`getAdminValues().boostCommissionRate`, in basis points, credited to the owner's zero-yield commission account); only the remainder becomes holder yield. `BoostYield.amount` is gross before that commission, `yieldOriginator` is attribution only, and the public boost paths always emit `validatorId = 0`.

Share-funded boost values shares against full equity without the recent-revenue deduction used by public `convertToAssets`: `floor(shares * (totalAssets() + 1) / (realTotalSupply() + 1))`. It then burns the shares even if that amount rounds to zero, so require a positive accepted gross effect before using it.

For every operation that consumes MON or an existing MON liability in exchange for shares, require a positive and accepted simulated share result. In particular, `deposit`, `depositAndCommit`, `convertZeroYieldTrancheToShares`, and `claimOwnerCommissionAsShares` can complete with zero newly minted shares after floor rounding. Standard minting rejects a zero receiver through `_mint`, but `depositToZeroYieldTranche` does not reject `receiver == address(0)` and would create an unusable zero-address balance.

Atomic exit receivers cannot be zero. `previewWithdraw`/`previewRedeem` can quote an unexecutable size because previews ignore current liquidity; runtime calls compare against `maxWithdraw`/`maxRedeem`. Use the slippage wrappers for user funds.

For a positive-share redeem, require `previewRedeemDetailed(shares).netAssets > 0` and a positive `minAssetsOut`. Otherwise a positive share amount can be burned for zero MON in an extreme rounding or fee case. Apply the same positive-output check before `completeUncommitAndRedeem` and share-mode `agentWithdrawFromCommitted`, which have no on-chain minimum-MON parameter.

Traditional request is caller-only, free-balance-only, nonzero, fee-free, and irreversible. Require `previewUnstake(shares) > 0`: the implementation otherwise burns the shares, stores a zero MON amount, and later treats the request as absent; if a nonzero request is already pending, the zero-amount request instead merges into it, adding no MON while still extending its completion epoch. It fixes MON when shares burn. Repeated requests merge into one record and take the furthest completion epoch. Normal quote is internal epoch `N+5`, extended to `N+7` when additional capital activation is needed. Maturity does not absolutely guarantee reserves; `completeUnstake` can still revert with `InsufficientReservedLiquidity`. There is no cancel, partial completion, receiver, approval, or third-party completion. A contract caller must be able to accept native MON from its own later `completeUnstake()` call or the request cannot be recovered. The internal epoch advances at most once per Monad staking epoch (`MONAD_EPOCH_LENGTH` = 50,000 blocks, about 5.5 hours at 400 ms), so `N+5` is roughly 27 hours and `N+7` roughly 38 hours of wall-clock time; poll `getInternalEpoch()` rather than a clock.

Zero-yield balances cannot be transferred and have no direct MON withdrawal function. Convert to shares, requiring a positive simulated output, then use an exit path.

## Conversion, Rounding, And Fee Semantics

Ignoring named recent-revenue options, the virtual-offset math is:

```text
shares = assets * (realTotalSupply + 1) / (equity + 1)
assets = shares * (equity + 1) / (realTotalSupply + 1)
```

- Deposit and redeem-style conversions round down.
- Mint and withdraw-style conversions round up where needed to avoid underpayment.
- A positive floor-rounded input can produce zero output. The contract does not universally reject that result; callers must guard irreversible deposit, zero-yield conversion, commission conversion, and traditional-unstake paths.
- Deposits price against full equity. Conversions and exits deduct a smoothed recent-revenue amount to discourage just-in-time reward capture.
- A same-epoch deposit then exit can return less than deposited even before an atomic fee.
- `totalAssets` uses full equity; it therefore need not imply the exact exchange rate used by every preview.

Atomic fees use a utilization-integrated affine curve:

```text
marginal fee rate = intercept + slope * utilization
```

- Fee parameters use RAY (`1e27`).
- Utilization uses WAD (`1e18`).
- Source defaults are intercept `0.005%` and slope `1%`, reaching `1.005%` marginal rate at full utilization.
- Owner can change the curve; never hardcode the defaults.
- A nonzero enabled curve enforces a 1-gwei per-call minimum fee, capped by gross amount.
- Setting both curve values to zero disables curve fee and minimum fee.
- `getCurrentUnstakeFeeRateRay` is the current marginal rate, not necessarily the effective fee over a large withdrawal that changes utilization.

## Policy And Commitment Surface

### User And Management Calls

| Signature | Selector | Access/effect |
| --- | --- | --- |
| `createPolicy(uint48)` | `0x321677f2` | Permissionless; creator is first/primary agent; IDs begin at 1 |
| `addPolicyAgent(uint64,address)` | `0x462fff96` | ShMonad owner only; caller must reject zero agent |
| `removePolicyAgent(uint64,address)` | `0x13788fe5` | ShMonad owner only; policy must retain an agent |
| `disablePolicy(uint64)` | `0x4d28a646` | Any active agent; irreversible |
| `commit(uint64,address,uint256)` | `0xf0881442` | Active policy; move caller free shares to recipient committed balance |
| `depositAndCommit(uint64,address,uint256)` | `0x9e1844c6` | Payable/active; routes through deposit, so blocked when closed; deposit to caller then commit requested shares |
| `requestUncommit(uint64,uint256,uint256)` | `0x417b7e51` | Move caller unheld committed to uncommitting; set new min; return completion block |
| `requestUncommitWithApprovedCompletor(uint64,uint256,uint256,address)` | `0x67070c95` | Same; accumulate approval shares and replace completor |
| `completeUncommit(uint64,uint256)` | `0x6a610788` | After escrow; return caller's shares to free balance |
| `completeUncommitWithApproval(uint64,uint256,address)` | `0x4e4ed7fc` | Approved/open caller; credit account, never completor; decrement finite approval |
| `completeUncommitAndRedeem(uint64,uint256)` | `0x3664f7af` | After escrow; atomic redeem with no explicit slippage bound |
| `completeUncommitAndRecommit(uint64,uint64,address,uint256)` | `0x9eaeb31a` | After source escrow; target must be active |
| `setUncommitApproval(uint64,address,uint256)` | `0x55e69124` | Replace caller approval; zero completor means anyone |
| `setMinCommittedBalance(uint64,uint128,uint128,uint32)` | `0x9b5e7cf2` | Active policy; configure min and automatic top-up |

`depositAndCommit` treats `sharesToCommit == uint256.max` as all newly minted shares. A finite value can consume the new shares plus caller's pre-existing uncommitted balance, so do not assume it is capped at shares minted.

Policy escrow is immutable `uint48` blocks and can be extremely long. Before commitment, inspect the policy and agents. Commitment gives agents actual transfer/withdraw authority over the balance; policy escrow restricts the user, not the agent.

Each uncommit request overwrites the account's single `uncommitStartBlock` for that policy, restarting escrow for the entire aggregate uncommitting bucket. This also occurs when `shares == 0`; reject a zero-share request unless the reset and `newMinBalance` change are explicitly intended. Requests and completions remain available after policy disable.

Completion is allowed at the exact returned completion block (`block.number >= completionBlock`). Uncommit approvals store shares as `uint96`. `address(0)` completor means open to anyone, not disabled. A finite approval decreases by shares completed; `uint96.max` is infinite and is not decremented. `setUncommitApproval` reverts for an input above `uint96.max`. The combined request method adds shares to the old allowance and overwrites completor, so it reverts if the addition overflows, including adding a positive amount to an already infinite approval; the setter overwrites both fields instead.

During an agent spend, ShMonad can pull from uncommitting shares first, then from free shares under top-up settings. This can effectively cancel some pending uncommit, and the uncommitting-bucket pull emits no event; only post-state reads such as `getUncommittingData` reveal it. `requestUncommit(..., newMinBalance)` changes only `minCommitted`; it does not clear the separate top-up settings. A nonzero top-up period must be at least 216,000 blocks, while a zero period with a nonzero `maxTopUpPerPeriod` passes validation and leaves top-up enabled with its period effectively restarting every block. While the policy is active, call `setMinCommittedBalance(policyID,0,0,0)` to disable free-balance top-up. This cannot disable pulls from uncommitting shares. `minCommitted` is a best-effort top-up target, not a guaranteed post-spend floor.

`addPolicyAgent` does not reject `address(0)`. The owner must do so, and must not remove the remaining real agent while zero is the only other configured agent, or the active policy becomes effectively agentless.

### Policy Views

| Signature | Selector | Returns |
| --- | --- | --- |
| `policyCount()` | `0xde54d429` | Last allocated policy ID/count |
| `getPolicy(uint64)` | `0x6d738773` | `(escrowDuration,active,primaryAgent)` |
| `isPolicyAgent(uint64,address)` | `0x6d20d833` | Agent flag |
| `getPolicyAgents(uint64)` | `0x6653bd41` | All configured agents |
| `uncommittingCompleteBlock(uint64,address)` | `0x822c6d6d` | Start block + escrow; does not prove a request/balance exists |
| `policyBalanceAvailable(uint64,address,bool)` | `0x7d05b18e` | Aggregate share capacity (committed + uncommitting + top-up − holds); does not reflect the agent-source ineligibility rule; `true` returns indicative `previewRedeem` quote |
| `topUpAvailable(uint64,address,bool)` | `0x97c76115` | Remaining share capacity; `true` returns an indicative `previewRedeem` quote |
| `getTopUpSettings(uint64,address)` | `0x7bca5126` | `(maxTopUpPerPeriod,topUpPeriodDuration)` |
| `getCommittedData(uint64,address)` | `0x584e3785` | `(committed,minCommitted)` |
| `getUncommittingData(uint64,address)` | `0x67f6007c` | `(uncommitting,uncommitStartBlock)` |
| `getUncommitApproval(uint64,address)` | `0x4cac8783` | `(completor,shares)` tuple |

### Holds And Agent Spend

| Signature | Selector | Access/effect |
| --- | --- | --- |
| `hold(uint64,address,uint256)` | `0xaba9598b` | Active agent; add transient hold |
| `release(uint64,address,uint256)` | `0xcc56a82a` | Active agent; saturating transient release |
| `batchHold(uint64,address[],uint256[])` | `0xba7c0e40` | Active agent; lengths must match |
| `batchRelease(uint64,address[],uint256[])` | `0x9292430b` | Active agent; lengths must match |
| `getHoldAmount(uint64,address)` | `0xda92ea0d` | Current transaction's transient hold |
| `agentTransferFromCommitted(uint64,address,address,uint256,uint256,bool)` | `0x402f1cd4` | Active agent; committed-to-committed |
| `agentTransferToUncommitted(uint64,address,address,uint256,uint256,bool)` | `0xbfece887` | Active agent; credit destination free shares |
| `agentWithdrawFromCommitted(uint64,address,address,uint256,uint256,bool)` | `0x74662009` | Active agent; burn committed shares for atomic MON |

Holds use EIP-1153 transient storage and vanish at transaction end. A standalone `hold` transaction provides no lock to a later transaction. Hold and protected action must compose inside the same transaction. Holds accumulate, cannot exceed committed balance, and over-release clears to zero.

All three agent spend calls reject `from` when it is itself an agent, preventing instant self-uncommit; `policyBalanceAvailable` does not account for that eligibility rule. The caller must reject an unintended or zero `to` address because these nonstandard paths do not consistently provide standard ERC-20/4626 recipient checks. `fromReleaseAmount` releases a same-transaction hold before spending. For transfer calls, `inUnderlying=true` interprets amount as MON and ceil-converts without atomic fee using `ceil(amount * (realTotalSupply()+1) / (totalAssets()+1))`; the calls return nothing and public `convertToShares` is not exact because it deducts recent revenue and rounds down instead of up. For agent withdrawal, `amountSpecifiedInUnderlying=true` means exact net MON and has no maximum-shares parameter; false means exact gross shares and has no minimum-MON parameter, so require positive accepted `previewRedeemDetailed(shares).netAssets`. Insufficient atomic liquidity reverts rather than clamps.

Agent withdrawal directly changes supplies and emits `AgentWithdrawFromCommitted`, but does not emit ERC-20 `Transfer` or ERC-4626 `Withdraw`. Its event amount is net MON. Agent transfer calls rely on agent-specific events, whose amount is shares even when the call input was expressed in underlying MON. An automatic top-up triggered inside the same agent spend does emit `Commit` plus a synthetic `Transfer` to the proxy, so those events can still appear in an agent-spend receipt.

## Atomic Pool, Accounting, And Crank Surface

### Configuration And Pool Views

| Signature | Selector | Access/meaning |
| --- | --- | --- |
| `setPoolTargetLiquidityPercentage(uint256)` | `0x9a7a039b` | Owner; WAD <= `1e18`; `1` is reserved sentinel; applied precision is BPS |
| `setUnstakeFeeCurve(uint256,uint256)` | `0x4f8da2a7` | Owner; slope/intercept RAY and sum <= `1e27` |
| `yInterceptRay()` | `0x2a743e0a` | Current intercept |
| `slopeRateRay()` | `0xdf19afcf` | Current slope |
| `getFeeCurveParams()` | `0xdb8a582b` | `(slopeRateRay,yInterceptRay)` |
| `getCurrentLiquidity()` | `0xd813f074` | Net MON currently available for atomic exits |
| `getTargetLiquidity()` | `0x602f41d1` | Current allocated target amount |
| `getPendingTargetLiquidity()` | `0xc8a505f0` | Amount implied by pending target setting |
| `getAtomicUtilizationWad()` | `0x8b5f6d52` | Current utilization, WAD |
| `getCurrentUnstakeFeeRateRay()` | `0x7710d4ff` | Current marginal fee rate, RAY |
| `getAtomicPoolUtilization()` | `0xe65f8087` | `(utilized,allocated,available,utilizationWad)` |

### Crank And Accounting Views

| Signature | Selector | Mutability/meaning |
| --- | --- | --- |
| `crank()` | `0x9c16a9e8` | Permissionless, not frozen; returns whether work completed |
| `isGlobalCrankAvailable()` | `0x9a292225` | ABI nonpayable; inspect with top-level `eth_call` |
| `isValidatorCrankAvailable(uint64)` | `0xf062f386` | view |
| `getWorkingCapital()` | `0x934c85d7` | `(stakedAmount,reservedAmount)` |
| `getAtomicCapital()` | `0x0fb6215a` | `(allocatedAmount,distributedAmount)` |
| `getGlobalPending()` | `0xba749daf` | `(pendingStaking,pendingUnstaking)` current |
| `getGlobalPendingLast()` | `0x4c9dd95d` | Prior epoch snapshot |
| `getGlobalCashFlows(int256)` | `0x1884fbda` | `(queueToStake,queueForUnstake)` at circular epoch pointer |
| `getGlobalRevenue(int256)` | `0x08cd7fad` | `(allocatedRevenue,earnedRevenue)` at pointer |
| `getGlobalEpoch(int256)` | `0x2d6d6b97` | Full epoch/status tuple |
| `getInternalEpoch()` | `0x29bb317c` | ShMonad internal epoch |
| `getGlobalStatus(int256)` | `0x424567eb` | `(frozen,closed)` at pointer |
| `getScaledTargetLiquidityPercentage()` | `0x6ec52fed` | Current liquidity target, WAD |
| `getGlobalAmountAvailableToUnstake()` | `0x365520db` | Current globally unstakable MON |
| `getCurrentAssets()` | `0xa250f825` | Liquid/current asset accounting value |
| `globalLiabilities()` | `0x79251e7e` | `(rewardsPayable,redemptionsPayable,totalZeroYieldPayable)` |
| `getAdminValues()` | `0x2c45d5dc` | `(internalEpoch,targetLiquidityPercentage,incentiveAlignmentPercentage,stakingCommission,boostCommissionRate,totalZeroYieldPayable)`; the percentage/commission fields are basis points |
| `STAKING_PRECOMPILE()` | `0x0cb9f3ad` | Returns `0x0000000000000000000000000000000000001000` |

`crank` can stop when gas left reaches 1,500,000 and resume from a validator cursor. Repeat tightly estimated transactions until it reports completion and state advances. Avoid `while (!crank())` inside an unbounded on-chain transaction.

`setPoolTargetLiquidityPercentage(1)` does not request a one-wei-WAD target: `1` is `FLOAT_PLACEHOLDER` and is interpreted as no pending update. Use `0` or multiples of `1e14` WAD for exact basis-point storage; finer precision is truncated. Every call overwrites the pending slot, so submitting a new value (including the `1` sentinel) cancels a pending, partially applied update. Updates can apply gradually when assets or existing utilization constrain the change. When the current applied target is zero, `getPendingTargetLiquidity()` can return zero even while a positive percentage is pending. Cranking can also write the pending slot autonomously to rebalance drift, so a pending value is not necessarily owner-initiated. The setter emits no dedicated target-change event; verify both percentage and amount views after cranking.

Epoch pointer storage wraps modulo eight. Use the documented small offsets (`-2`, `-1`, `0`, `1`) unless deliberately inspecting circular history.

`isGlobalCrankAvailable` is non-view because the Monad staking precompile rejects `STATICCALL`; a top-level JSON-RPC `eth_call` can still simulate it without committing state.

## Validator And Operator Surface

Monad validator ID is the primary identity. Do not infer validator identity from `block.coinbase`: multiple validator IDs can share a block-author address, while ShMonad's stored Coinbase address is a separate per-validator payout/processing address.

### Administrative And Processing Calls

| Signature | Selector | Access/effect |
| --- | --- | --- |
| `deactivateValidator(uint64)` | `0x8f289544` | Owner; begin delayed removal |
| `addValidator(uint64)` | `0x9fc758e1` | Owner; deploy/use deterministic Coinbase; return address |
| `addValidator(uint64,address)` | `0xb5965470` | Owner; register supplied non-contract Coinbase |
| `updateCoinbaseForExistingValidator(uint64)` | `0x0c017712` | Owner; deploy/link Coinbase; despite the name, it does not verify the validator is registered; return address |
| `updateStakingCommission(uint16)` | `0x9e6cb0bf` | Owner; value < 10,000 bps |
| `updateBoostCommission(uint16)` | `0x01b3bfa4` | Owner; value < 10,000 bps |
| `updateIncentiveAlignmentPercentage(uint16)` | `0x071c3626` | Owner; value < 10,000 bps |
| `setFrozenStatus(bool)` | `0x84aae4c9` | Owner; set current circular epoch's frozen flag |
| `setClosedStatus(bool)` | `0xc2006eaa` | Owner; set current circular epoch's closed flag |
| `processCoinbaseByAuth(uint64)` | `0xa1b6d59b` | Validator auth or owner; mapped Coinbase must have contract code; not frozen |
| `processCoinbaseByAuth(address)` | `0x41638da9` | Owner only; contract must return non-sentinel VAL_ID and this ShMonad; registration not required |

Validator deactivation makes reward eligibility inactive immediately, then removes the validator after seven cranked internal epochs. Some comments mention five epochs; the implementation constant/check is seven.

### Validator Views

| Signature | Selector | Returns/meaning |
| --- | --- | --- |
| `previewCoinbaseAddress(uint64)` | `0xa60232ad` | Deterministic Coinbase address |
| `getValidatorStats(uint64)` | `0xd3b9fd72` | `(isActive,coinbase,lastEpoch,targetStakeAmount,rewardsPayableLast,earnedRevenueLast,rewardsPayableCurrent,earnedRevenueCurrent)` |
| `isValidatorActive(uint64)` | `0x0e1e8f7d` | Registered/not fully removed flag |
| `getEpochInfo()` | `0xa9fd1a8f` | ABI nonpayable; Monad staking epoch from the precompile; second return value is always `0`, not a start block |
| `getValidatorCoinbase(uint256)` | `0x3bbc81d1` | Coinbase address |
| `getValidatorIdForCoinbase(address)` | `0xc84fef9f` | Validator ID |
| `getValidatorData(uint64)` | `0x6c91b101` | `(epoch,id,isPlaceholder,isActive,inActiveSet_Current,inActiveSet_Last,coinbase)` |
| `listActiveValidators()` | `0xd5dc7f75` | Parallel validator ID and Coinbase arrays |
| `getValidatorEpochs(uint64)` | `0xaeefe59d` | Last/current epoch and target stake values |
| `getValidatorPendingEscrow(uint64)` | `0x00601aaf` | Last/current pending staking and unstaking |
| `getValidatorRewards(uint64)` | `0x0b4c7141` | Last/current rewards payable and earned revenue |
| `getValidatorNeighbors(uint64)` | `0x29067fef` | Previous/next Coinbase in crank list |
| `getActiveValidatorCount()` | `0x37deea70` | Active count |
| `getNextValidatorToCrank()` | `0x44390e2f` | Next Coinbase, or zero when cursor is at end |

`isValidatorActive` is a registration/removal-state view. During delayed deactivation it can remain true while `getValidatorStats.isActive` and `getValidatorData.isActive` are already false. Reward eligibility additionally requires `getValidatorData.inActiveSet_Current`; use the complete `getValidatorData` tuple.

Before `sendValidatorRewards`, inspect `getValidatorData` and confirm the caller-selected `feeRate`; the function does not obtain it from validator configuration. A delayed validator payout is recorded only when the validator is not a placeholder, is active, and is in the current active set. For an eligible validator, `validatorPayout = value - floor(value * feeRate / 1e18)` and emitted `feeTaken` is that gross fee. Otherwise emitted `validatorPayout = 0` and `feeTaken = value`, with the value accounted as shMON yield plus owner commission. On either path the owner commission is the boost commission applied only to the fee portion `floor(value * feeRate / 1e18)`; with `feeRate = 0` no commission is taken.

`processCoinbaseByAuth(uint64)` requires the registered Coinbase to have contract code and therefore cannot process a validator registered with a plain EOA Coinbase. The owner-only address overload requires code, a `VAL_ID()` that is neither zero nor the unknown placeholder, and `SHMONAD()` equal to this proxy. It intentionally supports an old or unregistered Coinbase and does not validate current registry or staking-precompile membership.

## Core Events

Use the bundled ABI for exact indexed fields and topics.

| Event | Meaning |
| --- | --- |
| `Transfer(from,to,value)` | ERC-20 mint/burn/transfer plus synthetic policy commit/completion transfers |
| `Approval(owner,spender,value)` | Explicit allowance set; finite spending does not emit another Approval |
| `Deposit(sender,owner,assets,shares)` | Standard deposit/mint or zero-yield conversion to shares |
| `Withdraw(sender,receiver,owner,assets,shares)` | Atomic holder exit; `assets` is net MON delivered |
| `RequestUnstake(owner,shares,amountMon,completionEpoch)` | Traditional burn and locked MON quote |
| `CompleteUnstake(owner,amountMon)` | Traditional MON payout |
| `Commit(policyID,account,amount)` | Shares credited to policy committed bucket |
| `RequestUncommit(policyID,account,amount,expectedUncommitCompleteBlock)` | Block escrow started/restarted |
| `CompleteUncommit(policyID,account,amount)` | Shares returned to free bucket |
| `UncommitApprovalUpdated(policyID,account,completor,shares)` | Delegated completion configuration |
| `AgentTransferFromCommitted` | Agent committed-to-committed action; amount is shares |
| `AgentTransferToUncommitted` | Agent committed-to-free action; amount is shares |
| `AgentWithdrawFromCommitted` | Agent direct MON exit; amount is net MON; no Transfer/Withdraw companion event |
| `DepositToZeroYieldTranche(sender,receiver,assets)` | Zero-yield liability credit |
| `ZeroYieldBalanceConvertedToShares(from,to,assets,shares)` | Zero-yield conversion |
| `BoostYield(sender,yieldOriginator,validatorId,amount,sharesBurned)` | Gross pre-commission boost; originator is attribution; public paths use validator ID zero |
| `SendValidatorRewards(sender,valId,validatorPayout,feeTaken)` | `feeTaken` includes all value not paid to validator, including owner commission |
| `CreatePolicy`, `AddPolicyAgent`, `RemovePolicyAgent`, `DisablePolicy` | Policy lifecycle |
| `FeeCurveUpdated` | Atomic fee curve update |
| `OwnershipTransferred` | Application owner update |

Policy `commit` emits `Transfer(accountFrom,proxy,shares)` and completion emits the reverse for frontend tracking, but the proxy does not gain/lose a normal `balanceOf`. Do not reconstruct balance buckets from ERC-20 Transfer logs alone.

Many low-level validator/accounting events are also in the ABI. Some declared events are not currently emitted, including `PoolTargetLiquidityPercentageSet`, `PoolLiquidityUpdated`, `UnstakeFeeEnabledSet`, and `NewEpoch`. Status and commission setters also lack dedicated ShMonad events. Treat the corresponding post-state views as authoritative.

## Errors And Revert Diagnosis

Decode revert bytes with the bundled ABI. It contains all 79 implementation errors, including inherited ERC-20, ERC-4626, permit, ownership, initialization, cast, and reentrancy errors.

| Error/group | Likely correction |
| --- | --- |
| `IncorrectNativeTokenAmountSent` | Set payable value exactly to deposit/mint/zero-yield assets |
| `ERC4626ExceededMaxWithdraw` / `...MaxRedeem` | Re-read liquidity-aware max and reduce size |
| `ERC4626WithdrawSlippageExceeded` / `...RedeemSlippageExceeded` | Refresh detailed quote or obtain new user bound |
| `InsufficientPoolLiquidity` | Reduce atomic exit or choose traditional unstake |
| `CannotUnstakeZeroShares` | Use a positive traditional request |
| `InsufficientBalanceForUnstake` | Use caller's free `balanceOf`, not committed/uncommitting/aggregate |
| `NoUnstakeRequestFound` | Re-read request; it may be absent or completed |
| `CompletionEpochNotReached(current,required)` | Poll internal epoch; do not use wall-clock alone |
| `InsufficientReservedLiquidity` | Maturity reached but reserves not ready; crank/poll and retry later |
| `PolicyInactive` | Do not commit/agent-spend; user request/complete uncommit remains possible |
| `InsufficientUnheldCommittedBalance` | Reduce request or inspect same-transaction hold |
| `UncommittingPeriodIncomplete(block)` | Wait until returned completion block |
| `InvalidUncommitCompletor` / `InsufficientUncommitApproval` | Inspect approval tuple and use authorized caller/amount |
| `AgentInstantUncommittingDisallowed` | Policy agent cannot use agent spend on an agent source |
| `TopUpPeriodDurationTooShort` | The nonzero `topUpPeriodDuration` is below 216,000 blocks; set it to `0` or at least 216,000. `maxTopUpPerPeriod = 0` alone does not avoid this revert; to disable top-up set all three fields to zero |
| `NotWhenClosed` | Read global status; choose only an allowed exit if appropriate |
| `NotWhenFrozen` | Wait for owner unfreeze; crank/processing is blocked |
| `OwnableUnauthorizedAccount` | Confirm live `owner()` and signer |
| `ReentrancyGuardReentrantCall` | Remove callback/reentrant composition |

## Known Interface And Documentation Hazards

- `IShMonad` claims to contain every entrypoint but omits `depositToZeroYieldTranche`, `convertZeroYieldTrancheToShares`, `balanceOfZeroYieldTranche`, `unclaimedOwnerCommission`, `updateCoinbaseForExistingValidator`, `getGlobalPendingLast`, inherited Ownable/EIP-5267 methods, and `receive()`.
- Generate encoding from the concrete bundled ABI, not `IShMonad` alone.
- Source selector comments are wrong for three overloads: `boostYield(address)` is `0x4dc4993a`; `balanceOfCommitted(address)` is `0x647a4772`; `addValidator(uint64)` is `0x9fc758e1`.
- Concrete `getGlobalRevenue` returns `(allocatedRevenue,earnedRevenue)`; older interface naming can suggest a different first field.
- Concrete `globalLiabilities` and `getAdminValues` return `totalZeroYieldPayable` as their last field; older naming may call it commission.
- A scenario README's old fee table does not match current source or live fee parameters. Query on-chain.
- Tests upgrade a forked proxy to `TestShMonad`; they validate current source behavior but are not byte-for-byte live-deployment integration tests.
- The contracts are upgradeable. Any implementation address outside this skill's exact mainnet/testnet compatibility pair invalidates this API reference. Stop rather than attempting to infer compatibility from common selectors.
