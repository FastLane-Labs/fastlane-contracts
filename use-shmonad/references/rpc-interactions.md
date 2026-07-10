# ShMonad RPC Interactions

This reference describes ShMonad-specific call sequences using the bundled ABI and standard EVM JSON-RPC requests.

## Contents

- [RPC model](#rpc-model)
- [Compatibility gate](#compatibility-gate)
- [Read ShMonad state](#read-shmonad-state)
- [Deposit and mint](#deposit-and-mint)
- [Atomic exit](#atomic-exit)
- [Traditional unstake](#traditional-unstake)
- [ERC-20 and permit](#erc-20-and-permit)
- [Policies and agent operations](#policies-and-agent-operations)
- [Zero-yield tranche](#zero-yield-tranche)
- [Yield and validator rewards](#yield-and-validator-rewards)
- [Cranking and administration](#cranking-and-administration)
- [Events, errors, and post-state](#events-errors-and-post-state)

## RPC Model

The relevant standard methods are:

| Method | ShMonad use |
| --- | --- |
| `eth_chainId` | Select the network-specific proxy and implementation |
| `eth_getCode` | Require code at the proxy before ABI use |
| `eth_getStorageAt` | Read the EIP-1967 implementation slot |
| `eth_call` | Read views and simulate state-changing ShMonad calls |
| `eth_estimateGas` | Estimate the already selected ShMonad call |
| `eth_getTransactionReceipt` | Obtain status and ShMonad logs after submission |
| `eth_getLogs` | Query ShMonad events by proxy and topic |

An ABI-based read uses:

```text
eth_call([
  {
    to: SHMONAD_PROXY,
    data: ABI_ENCODE(functionSignature, arguments)
  },
  BLOCK_CONTEXT
])
```

A payable simulation adds the exact sender and native value:

```text
eth_call([
  {
    from: SENDER,
    to: SHMONAD_PROXY,
    data: ABI_ENCODE(functionSignature, arguments),
    value: HEX_MON_WEI
  },
  BLOCK_CONTEXT
])
```

Keep the ShMonad target, function, arguments, sender, receiver, and value identical across simulation, estimation, and execution.

## Compatibility Gate

Use the network table in `SKILL.md`. Before any bundled-ABI call:

1. `eth_chainId([])` must equal `0x8f` for mainnet or `0x279f` for testnet.
2. `eth_getCode([proxy, blockContext])` must return more than `0x`.
3. Read the implementation word:

```text
eth_getStorageAt([
  SHMONAD_PROXY,
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
  BLOCK_CONTEXT
])
```

4. Interpret the rightmost 40 hexadecimal characters as an address and require the network-specific implementation from `SKILL.md`.
5. Only after the exact match, call and require:

```text
name()     -> "ShMonad"
symbol()   -> "shMON"
decimals() -> 18
```

If the implementation differs, do not use the bundled ABI to probe for apparent compatibility. Stop and report that the skill does not support the observed implementation.

## Read ShMonad State

Common holder and vault reads:

```text
balanceOf(account)                              -> free shMON shares
balanceOfCommitted(account)                     -> aggregate committed shares
balanceOfCommitted(policyID, account)           -> policy committed shares
balanceOfUncommitting(policyID, account)         -> policy uncommitting shares
balanceOfZeroYieldTranche(account)               -> zero-yield MON principal
allowance(owner, spender)                        -> free-share allowance
totalSupply()                                    -> all issued share states
totalAssets()                                    -> full shMON-holder equity
getGlobalStatus(0)                               -> (frozen, closed)
getCurrentLiquidity()                            -> atomic-pool MON liquidity
getAtomicPoolUtilization()                       -> utilization breakdown
getInternalEpoch()                               -> ShMonad epoch
```

Do not add the three share buckets and compare them with `balanceOf`; `balanceOf` intentionally exposes only free shares. Do not use `totalAssets / totalSupply` as a substitute for the preview functions because recent-revenue treatment differs between paths.

`isGlobalCrankAvailable()` and `getEpochInfo()` are ABI `nonpayable`, not `view`, because they call the Monad staking precompile. They can still be evaluated with top-level `eth_call`; do not attempt to reach the precompile through Solidity `STATICCALL`.

## Deposit And Mint

### Deposit Exact MON

Preconditions:

```text
receiver != address(0)
assets > 0
getGlobalStatus(0).closed == false
previewDeposit(assets) > 0
```

Simulate:

```text
deposit(assets, receiver) -> shares
transaction value         = assets
```

Require `shares > 0` and require the output to be acceptable to the depositor. The contract has no `minShares` argument. After execution, decode:

```text
Deposit(sender, owner, assets, shares) // owner is the deposit receiver
Transfer(address(0), receiver, shares)
```

Then re-read `balanceOf(receiver)`.

### Mint Exact shMON

Preconditions:

```text
receiver != address(0)
shares > 0
getGlobalStatus(0).closed == false
assets = previewMint(shares)
```

Simulate `mint(shares, receiver)` with `value = assets`. ShMonad requires the native value to equal its live calculation exactly. After execution, verify `Deposit`, `Transfer`, and `balanceOf(receiver)`.

### Deposit And Commit

Apply all deposit preconditions, then inspect the policy as described below. `depositAndCommit(policyID, recipient, type(uint256).max)` commits all shares minted by that call. A finite `sharesToCommit` can consume both newly minted and pre-existing free shares.

## Atomic Exit

### Exact Net MON

Read:

```text
maxWithdraw(owner)
previewWithdrawDetailed(netAssets)
  -> (shares, grossAssets, feeAssets)
allowance(owner, caller) when caller != owner
```

Require `netAssets <= maxWithdraw(owner)`, a nonzero receiver able to accept MON, and an explicitly accepted maximum share burn. Simulate:

```text
withdrawWithSlippageProtection(
  netAssets,
  receiver,
  owner,
  maxBurntShares
) -> sharesBurned
```

### Exact shMON Burn

Read:

```text
maxRedeem(owner)
previewRedeemDetailed(shares)
  -> (grossAssets, feeAssets, netAssets)
allowance(owner, caller) when caller != owner
```

Require `shares <= maxRedeem(owner)`, a nonzero receiver able to accept MON, and an explicitly accepted minimum MON output. Simulate:

```text
redeemWithSlippageProtection(
  shares,
  receiver,
  owner,
  minAssetsOut
) -> assetsReceived
```

Require the detailed preview's `netAssets > 0`, choose `minAssetsOut > 0`, and require the simulation to return positive MON. Otherwise a positive share amount can be burned for zero MON in an extreme fee or rounding case.

Both detailed previews ignore the runtime liquidity cap. The plain `withdraw` and `redeem` functions have no caller-supplied slippage protection.

Expected holder-exit events are `Withdraw(sender,receiver,owner,assets,shares)` and `Transfer(owner,address(0),shares)`. `assets` is net MON delivered.

## Traditional Unstake

### Request

Read and require:

```text
shares > 0
shares <= balanceOf(caller)
amountMon = previewUnstake(shares)
amountMon > 0
getGlobalStatus(0).closed == false
```

If the caller is a contract, it must be able to receive native MON when it later calls `completeUnstake()`. There is no receiver override.

Simulate and call:

```text
requestUnstake(shares) -> completionEpoch
```

Record `RequestUnstake(owner,shares,amountMon,completionEpoch)` and read `getUnstakeRequest(owner)`. A later request merges into the same owner record: MON accumulates and the completion epoch becomes the later value.

### Complete

Read:

```text
getUnstakeRequest(account) -> (amountMon, completionEpoch)
getInternalEpoch()         -> currentEpoch
```

Require `amountMon > 0` and `currentEpoch >= completionEpoch`, then simulate `completeUnstake()` from that same account. It pays the full request to the caller and has no partial amount, receiver, approval, cancellation, or third-party completion parameter.

If simulation returns `InsufficientReservedLiquidity`, keep the existing request and retry after reserves/cranking advance. Do not create another request as a retry.

## ERC-20 And Permit

`transfer` and `transferFrom` can spend only free `balanceOf` shares. `approve` also supplies the allowance used when another caller performs an atomic exit or share-funded `boostYield` for an owner.

For permit, read:

```text
nonces(owner)
eip712Domain()
```

The required EIP-712 domain is:

```text
name              = "ShMonad"
version           = "3"
chainId           = selected live chain
verifyingContract = selected ShMonad proxy
```

The permit call is:

```text
permit(owner, spender, value, deadline, v, r, s)
```

For an EOA owner, provide `v` as `27` or `28`; the implementation does not normalize `0` or `1`.

The ERC-1271 fallback is limited to wallets that validate the exact packed 65-byte `r || s || v` representation. The ABI cannot carry an arbitrary-length contract-wallet signature.

## Policies And Agent Operations

### Inspect Before Commitment

Read:

```text
getPolicy(policyID)              -> (escrowDuration, active, primaryAgent)
getPolicyAgents(policyID)
isPolicyAgent(policyID, agent)
```

Require an active policy and a nonzero share recipient. Explain that agents can spend committed balances and that the user must wait the policy's block-based escrow to recover them.

### Commit And Uncommit

Use `commit(policyID, recipient, shares)` for existing free shares. For an uncommit request, first inspect:

```text
getCommittedData(policyID, account)
getUncommittingData(policyID, account)
getTopUpSettings(policyID, account)
```

`requestUncommit(policyID, shares, newMinBalance)` changes `minCommitted` only. It does not clear `maxTopUpPerPeriod` or `topUpPeriodDuration`. To disable future free-balance top-up while the policy is active, use:

```text
setMinCommittedBalance(policyID, 0, 0, 0)
```

This cannot disable an agent's ability to pull from the policy's uncommitting bucket. `minCommitted` is a best-effort top-up target rather than a hard post-spend floor.

Every request overwrites the start block for the account's entire existing uncommitting balance, even when `shares == 0`. Reject a zero-share request unless restarting the escrow and changing `newMinBalance` are both explicitly intended.

Record the completion block from `RequestUncommit`. `uncommittingCompleteBlock` alone does not prove a request exists, so also require a positive value from `getUncommittingData` or `balanceOfUncommitting`.

At maturity, prefer `completeUncommit(policyID, shares)`. `completeUncommitAndRedeem` immediately uses the atomic pool but has no minimum-MON bound; require a positive accepted `previewRedeem(shares)` and understand that execution still has no on-chain output floor.

Uncommit completion approvals are `uint96`. `setUncommitApproval` reverts when `shares > uint96.max`. `requestUncommitWithApprovedCompletor` adds the requested shares to the current approval and reverts if that addition overflows, including adding a positive amount to an existing `uint96.max` approval.

### Agent Capacity And Spending

`policyBalanceAvailable(policyID, account, false)` returns aggregate share capacity after committed, uncommitting, top-up, and hold accounting. With `true`, the result is passed through `previewRedeem`; it is an indicative fee-aware, liquidity-ignorant net-MON quote, not a universal executable limit. It also does not account for the rule that agent spend calls reject a source account that is itself a policy agent.

For all agent operations, require the intended `from` and `to` accounts and reject `to == address(0)`:

```text
agentTransferFromCommitted(policyID, from, to, amount, release, inUnderlying)
agentTransferToUncommitted(policyID, from, to, amount, release, inUnderlying)
agentWithdrawFromCommitted(policyID, from, to, amount, release, amountSpecifiedInUnderlying)
```

Transfer calls interpret underlying mode through the vault conversion without an atomic fee. Agent withdrawal uses the atomic pool.

The two transfer calls return no value. For `inUnderlying=true`, quote the exact shares at the selected state with:

```text
shares = ceil(
  amountMON * (realTotalSupply() + 1) /
  (totalAssets() + 1)
)
```

Public `convertToShares(amountMON)` is not exact for this path because it deducts recent revenue and rounds down instead of up.

Agent withdrawal provides no slippage parameter:

- underlying mode fixes net MON but has no maximum-shares bound;
- share mode fixes shares but has no minimum-MON bound; require `previewRedeemDetailed(shares).netAssets` to be positive and accepted, then simulate the no-return agent call.

The two agent transfer events report a share amount even when the input was specified in underlying MON. `AgentWithdrawFromCommitted.amount` reports net MON. Agent withdrawal emits no ERC-20 `Transfer` or ERC-4626 `Withdraw` event for its own burn, but an automatic top-up inside the same agent spend still emits `Commit` plus a synthetic `Transfer`, and the pull from the uncommitting bucket emits nothing; re-read `getUncommittingData` to detect it.

Holds are transaction-transient. A separate `hold` transaction has no effect on a later spend transaction.

Owner policy-agent management must reject `agent == address(0)` before `addPolicyAgent`; ShMonad does not. Otherwise the owner can remove the last real agent while zero remains configured, leaving an active policy with no usable agent.

## Zero-Yield Tranche

Deposit:

```text
receiver != address(0)
assets > 0
depositToZeroYieldTranche(assets, receiver)
transaction value = assets
```

The function credits MON principal in `balanceOfZeroYieldTranche(receiver)` and mints no shMON. Unlike standard deposit, it does not reject a zero receiver, so the caller must.

Convert only the caller's own balance:

```text
convertZeroYieldTrancheToShares(assets, receiver) -> shares
```

Require a nonzero receiver and require the simulated `shares` output to be positive and acceptable before consuming principal. Apply the same output guard to `claimOwnerCommissionAsShares(assets, receiver)`. There is no direct zero-yield MON withdrawal.

## Yield And Validator Rewards

### Yield Boost

```text
boostYield(originator)                         with MON value
boostYield(shares, from, originator)            with free shares/allowance
```

Both paths take the current owner boost commission. The event fields are `BoostYield(sender,yieldOriginator,validatorId,amount,sharesBurned)`: `validatorId` is always `0` for these public calls, `amount` is gross before commission, and `yieldOriginator` is attribution only. For the share-funded path, calculate the exact pre-commission gross effect at the selected state as:

```text
grossAssets = floor(
  shares * (totalAssets() + 1) /
  (realTotalSupply() + 1)
)
```

Require positive shares and `grossAssets > 0` before intentionally burning the shares. Public `convertToAssets(shares)` is not the exact quote for this function because it deducts recent revenue while share-funded boost does not.

A plain MON transfer to `receive()` is goodwill, not `deposit` or `boostYield`, and mints no shares.

### Validator Rewards

Before `sendValidatorRewards(validatorId, feeRate)`, require `feeRate <= 1e18`, confirm the caller-selected rate is intended, and read:

```text
getValidatorData(validatorId)
  -> (epoch, id, isPlaceholder, isActive,
      inActiveSet_Current, inActiveSet_Last, coinbase)
```

A delayed validator payout is recorded only when:

```text
isPlaceholder == false
isActive == true
inActiveSet_Current == true
```

Otherwise `validatorPayout` becomes zero and the value is treated as shMON yield plus owner commission accounting. In `SendValidatorRewards`, `feeTaken` includes every amount not paid to the validator, including owner commission. The owner commission on either path is the boost commission applied only to the fee portion; with `feeRate = 0` no commission is taken.

The contract does not obtain `feeRate` from validator configuration. Event math is:

```text
grossFee = floor(value * feeRate / 1e18)

eligible validator:
  validatorPayout = value - grossFee
  feeTaken        = grossFee

ineligible validator:
  validatorPayout = 0
  feeTaken        = value
```

## Cranking And Administration

`crank()` is permissionless, blocked while frozen, and may need multiple calls to process all validators. Inspect `isGlobalCrankAvailable`, `getNextValidatorToCrank`, validator-specific crank availability, and post-state.

Status is not a universal pause:

```text
getGlobalStatus(0) -> (frozen, closed)
```

- closed blocks deposit/mint, deposit-and-commit, traditional request/completion, and zero-yield deposit/conversion;
- closed does not block holder atomic exits;
- frozen blocks cranking and Coinbase processing, not ordinary ERC-20 use.

Owner-only `setPoolTargetLiquidityPercentage(newPercentageScaled)` accepts WAD up to `1e18`, with non-obvious rules:

- input `1` is the internal `FLOAT_PLACEHOLDER` and is treated as no pending target update;
- the applied target is stored at basis-point precision and truncates finer WAD precision; use `0` or multiples of `1e14` WAD for an exact stored percentage;
- every call overwrites the pending slot, so a new value (including the `1` sentinel) cancels an in-flight gradual update;
- updates can apply gradually when current assets or existing utilization prevent the full change;
- when the current applied target is zero, `getPendingTargetLiquidity()` can return zero even if a positive percentage is pending;
- cranking can autonomously write the pending slot to rebalance drift, so a pending value is not necessarily owner-initiated.

Read `getPendingTargetLiquidity`, `getTargetLiquidity`, and `getScaledTargetLiquidityPercentage` after changes. Several owner setters, including status and target setters, do not emit dedicated state-change events, so post-state is authoritative.

`processCoinbaseByAuth(uint64)` requires the validator's mapped Coinbase address to contain contract code. Validators registered with a plain EOA Coinbase cannot use that overload. The owner-only address overload requires contract code, a `VAL_ID()` that is neither zero nor the unknown placeholder, and `SHMONAD()` equal to this proxy; it intentionally does not require the validator or Coinbase to remain registered.

Validator identity is the Monad validator ID, not `block.coinbase`; multiple validator IDs can share the same block-author address. Use the staking precompile and ShMonad's validator-ID views rather than attempting an address-to-validator inference from block authorship.

Owner validator lifecycle calls are:

```text
previewCoinbaseAddress(validatorId)              -> deterministic ShMonad Coinbase address
addValidator(validatorId)                        -> deploy/link deterministic Coinbase contract
addValidator(validatorId, coinbase)              -> link a nonzero address with no contract code
updateCoinbaseForExistingValidator(validatorId)  -> deploy/link a new Coinbase contract; registration is not verified
deactivateValidator(validatorId)                 -> immediately end reward eligibility; delayed full removal
```

Before adding, require a real non-sentinel validator ID that exists in the staking precompile and is neither active nor awaiting full removal. The explicit-address overload rejects contract code and requires operator knowledge that the address is a controlled wallet rather than an undeployed deterministic contract. Deactivation completes after seven cranked ShMonad internal epochs despite older source comments that mention five.

Owner commission and status inputs are basis points or booleans, not WAD:

```text
updateStakingCommission(feeInBps)              // feeInBps < 10_000
updateBoostCommission(feeInBps)                // feeInBps < 10_000
updateIncentiveAlignmentPercentage(valueInBps) // valueInBps < 10_000
setFrozenStatus(isFrozen)
setClosedStatus(isClosed)
```

These setters do not emit dedicated ShMonad configuration events. Verify `getAdminValues()` or `getGlobalStatus(0)` afterward.

Atomic fee-curve administration uses RAY, not WAD or BPS:

```text
setUnstakeFeeCurve(slopeRateRay, yInterceptRay)

slopeRateRay <= 1e27
yInterceptRay <= 1e27
slopeRateRay + yInterceptRay <= 1e27
```

Setting both values to zero disables the curve and its 1-gwei minimum fee. Verify `FeeCurveUpdated` and `getFeeCurveParams()`.

## Events, Errors, And Post-State

Use the bundled ABI for event topics, indexed fields, and custom-error decoding. Query logs from the ShMonad proxy address, not the implementation.

Important event exceptions:

- policy commit/completion emits synthetic `Transfer` events involving the proxy, but the proxy does not own a normal `balanceOf`;
- agent withdrawal emits neither `Transfer` nor `Withdraw` for its own burn, though a same-call automatic top-up emits `Commit` plus a synthetic `Transfer`;
- the agent-spend pull from an account's uncommitting bucket emits no event; re-read `getUncommittingData` to detect it;
- `BoostYield.amount` is gross, `yieldOriginator` is attribution only, and its public-path validator ID is zero;
- not every owner status/configuration setter emits a dedicated event.

After a write, use the function-specific state named above rather than treating logs as the sole source of truth. A simulated Solidity return value describes the call result, but transaction receipts contain logs and status, not the function return value.
