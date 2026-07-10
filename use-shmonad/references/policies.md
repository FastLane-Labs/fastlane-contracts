# ShMonad Policies

Use this reference after the deployment compatibility gate in `SKILL.md` has passed. A ShMonad policy gives its agents enforceable authority over shares that users commit to that policy. This is not a passive label or allowance: agents can transfer committed value, return it to a free balance, or withdraw it as MON.

## Contents

- [Understand policy balances and authority](#understand-policy-balances-and-authority)
- [Inspect a policy before commitment](#inspect-a-policy-before-commitment)
- [Create and manage a policy](#create-and-manage-a-policy)
- [Commit shares](#commit-shares)
- [Configure automatic top-up](#configure-automatic-top-up)
- [Request uncommitment](#request-uncommitment)
- [Delegate uncommit completion](#delegate-uncommit-completion)
- [Complete, recommit, or redeem](#complete-recommit-or-redeem)
- [Measure agent capacity](#measure-agent-capacity)
- [Use transaction-scoped holds](#use-transaction-scoped-holds)
- [Execute agent transfers](#execute-agent-transfers)
- [Execute an agent withdrawal](#execute-an-agent-withdrawal)
- [Handle disabled policies](#handle-disabled-policies)

## Understand Policy Balances And Authority

An account's shMON can occupy three mutually exclusive states:

- **Free or uncommitted:** `balanceOf(account)`. The holder can transfer, approve, exit, or commit these shares.
- **Committed:** `balanceOfCommitted(policyID, account)`. Active policy agents can spend these shares; the holder cannot transfer them directly.
- **Uncommitting:** `balanceOfUncommitting(policyID, account)`. These shares are waiting through policy escrow, but an active policy agent can pull them back into committed state while spending.

`balanceOfCommitted(account)` is the aggregate committed balance. `totalSupply()` includes all three states. `committedTotalSupply()` includes committed shares but excludes uncommitting shares.

Policy escrow restricts the holder's recovery path; it does not restrict an active agent's spend authority. Treat commitment as granting the configured agents control over that value for at least the policy's escrow duration.

## Inspect A Policy Before Commitment

Read:

```text
getPolicy(policyID)
  -> (escrowDuration, active, primaryAgent)
getPolicyAgents(policyID)
isPolicyAgent(policyID, eachExpectedAgent)
```

Require the policy to be active and independently recognize every intended agent. `escrowDuration` is an immutable `uint48` number of blocks chosen by the creator. It is not a ShMonad epoch count and can be extremely long.

For an account with existing policy activity, also read:

```text
getCommittedData(policyID, account)
  -> (committed, minCommitted)
getUncommittingData(policyID, account)
  -> (uncommitting, uncommitStartBlock)
getTopUpSettings(policyID, account)
  -> (maxTopUpPerPeriod, topUpPeriodDuration)
getUncommitApproval(policyID, account)
  -> (completor, shares)
```

These values determine what agents can reach, whether free shares may be recommitted automatically, and when pending recovery can complete.

## Create And Manage A Policy

`createPolicy(escrowDuration)` is permissionless. IDs begin at `1`. The call makes its caller the primary and first agent and fixes the block-based escrow duration permanently.

`policyCount()` returns the last allocated policy ID/count. Use it to bound enumeration before reading individual policies.

Policy-agent management uses:

```text
addPolicyAgent(policyID, agent)       // ShMonad owner only
removePolicyAgent(policyID, agent)    // ShMonad owner only
disablePolicy(policyID)               // any active agent
```

`addPolicyAgent` does not reject `address(0)`. Require a nonzero agent before calling it. Never remove the remaining real agent while zero is the only other configured agent; the contract's list-length check can otherwise leave an active policy with no usable agent.

Removing an agent requires the policy to retain at least one configured agent. Disabling is irreversible. Verify management changes through `getPolicy`, `getPolicyAgents`, and `isPolicyAgent`, not events alone.

## Commit Shares

For existing free shares, use:

```text
commit(policyID, commitRecipient, shares)
```

The caller supplies free shares and `commitRecipient` owns the resulting policy balance. Require an active policy, nonzero recipient, sufficient `balanceOf(caller)`, accepted agents, and an accepted escrow duration.

To deposit native MON and commit in one call, use:

```text
depositAndCommit(policyID, sharesRecipient, sharesToCommit)
  -> sharesMinted
native value = MON assets deposited
```

Apply the standard ShMonad deposit guards: require positive MON, a nonzero recipient, `getGlobalStatus(0).closed == false`, `previewDeposit(nativeValue) > 0`, and a positive acceptable simulated `sharesMinted`. There is no minimum-shares argument.

When `sharesToCommit == uint256.max`, the call commits all shares newly minted by that call. A finite amount can consume both newly minted and pre-existing free shares; do not assume it is capped by `sharesMinted`.

A commit for another recipient does not emit a normal transfer from source to recipient. Verify `Commit`, the synthetic transfer described below, and both free and policy-specific balances.

## Configure Automatic Top-Up

An account configures its own top-up with:

```text
setMinCommittedBalance(
  policyID,
  minCommitted,
  maxTopUpPerPeriod,
  topUpPeriodDuration
)
```

The policy must be active. Amounts are shMON shares. `minCommitted` and `maxTopUpPerPeriod` are `uint128`; the duration is a `uint32` number of blocks.

The settings do not reserve free shares. During agent spending, ShMonad tries to cover the spend and leave `minCommitted` by sourcing shares in this order:

1. Unheld committed shares.
2. Shares in the policy's uncommitting bucket.
3. Free shares, subject to the top-up allowance.

`minCommitted` is a best-effort target, not a guaranteed post-spend floor. If the target cannot be met but the spend itself can be covered, the spend can proceed and leave less than `minCommitted`.

A nonzero period must be at least `216,000` blocks. The period check applies even when `maxTopUpPerPeriod == 0`. Disable free-balance top-up by setting all three fields to zero:

```text
setMinCommittedBalance(policyID, 0, 0, 0)
```

Setting `newMinBalance` to zero during an uncommit does not clear the two top-up settings. A zero period with a nonzero maximum passes validation and can reset its period on each later block, leaving top-up enabled.

`topUpAvailable(policyID, account, false)` returns the lesser of free shares and remaining per-period capacity. With `true`, it passes the share amount through `previewRedeem`; that result is an indicative net-MON quote, not a guaranteed executable output.

Automatic free-balance top-up emits `Commit` and a synthetic `Transfer`. Pulling shares from the uncommitting bucket emits no event and cannot be disabled by zeroing top-up settings.

## Request Uncommitment

Before recovery, read committed, uncommitting, hold, and top-up state. Then use:

```text
requestUncommit(policyID, shares, newMinBalance)
  -> uncommitCompleteBlock
```

The caller can move only its unheld committed shares. The call:

- moves `shares` from committed to the account's single uncommitting bucket;
- sets `minCommitted` to `newMinBalance` without changing top-up limits;
- sets the current block as the start for the entire uncommitting bucket;
- returns and emits the completion block.

Every request restarts escrow for all existing uncommitting shares, not only the new amount. This also happens when `shares == 0`. Reject a zero-share request unless changing `newMinBalance` and deliberately resetting the entire escrow are both intended.

`uncommittingCompleteBlock(policyID, account)` computes start plus policy duration, but it does not prove that a request or positive balance exists. Confirm a positive `getUncommittingData(...).uncommitting` or `balanceOfUncommitting(...)`.

Requesting remains available after policy disable. A hold can block a request only within the same transaction context as that hold.

## Delegate Uncommit Completion

Authorization can be configured separately or combined with a request:

```text
setUncommitApproval(policyID, completor, shares)

requestUncommitWithApprovedCompletor(
  policyID,
  shares,
  newMinBalance,
  completor
) -> uncommitCompleteBlock
```

Approval shares are stored as `uint96`:

- `setUncommitApproval` replaces both fields and reverts above `uint96.max`.
- `completor == address(0)` means anyone may complete; it does not disable completion.
- `shares == uint96.max` is infinite and is not decremented.
- A finite allowance decreases by shares completed.
- The combined request adds requested shares to the old allowance but replaces the completor.
- That addition reverts on overflow, including any positive addition to an existing infinite approval. Use the setter when replacement is intended.

Completion approval never transfers ownership to the completor. Completed free shares are credited to the account whose uncommitting bucket is used.

## Complete, Recommit, Or Redeem

Completion is allowed at equality:

```text
block.number >= uncommitStartBlock + escrowDuration
```

The holder uses `completeUncommit(policyID, shares)`. An authorized or open completor uses `completeUncommitWithApproval(policyID, shares, account)`.

Policy completion can be partial. Completed shares become free `balanceOf(account)` shares. Any remainder keeps its original start block and is already mature after the same gate. Completion remains available after policy disable.

To move matured shares directly into another policy:

```text
completeUncommitAndRecommit(
  fromPolicyID,
  toPolicyID,
  sharesRecipient,
  shares
)
```

The source escrow must be mature, the destination policy active, and the recipient nonzero. Inspect the destination agents and escrow before moving value.

To redeem matured shares immediately:

```text
completeUncommitAndRedeem(policyID, shares) -> assets
```

This completes to the caller and immediately uses the atomic pool. It has no receiver parameter and no minimum-MON bound. Require positive accepted `previewRedeem(shares)`, sufficient atomic liquidity, and a caller able to receive native MON. `completeUncommit` followed by `redeemWithSlippageProtection` provides an explicit output floor when atomic composition is unnecessary.

## Measure Agent Capacity

`policyBalanceAvailable(policyID, account, false)` returns aggregate share capacity:

```text
committed - current-transaction holds
+ uncommitting
+ available free-balance top-up
```

With `true`, this aggregate is passed through `previewRedeem`. The result is fee-aware but liquidity-ignorant and is not a universal executable maximum for all agent operations.

The view also omits the agent-source eligibility rule: every agent spend rejects `from` when that account is itself a policy agent, even if another agent calls. Read the individual buckets whenever it matters whether a spend will cancel pending recovery or pull free shares through top-up.

## Use Transaction-Scoped Holds

Active agents can use:

```text
hold(policyID, account, shares)
release(policyID, account, shares)
batchHold(policyID, accounts, amounts)
batchRelease(policyID, accounts, amounts)
getHoldAmount(policyID, account)
```

Holds use EIP-1153 transient storage and disappear at transaction end. A standalone `hold` call does not lock a later transaction. The hold and protected action must share one transaction context.

- Holds accumulate and cannot exceed currently committed shares.
- Held shares are unavailable to uncommit requests and agent spending.
- Release is saturating; an amount at least equal to the hold clears it.
- `release(..., uint256.max)` clears the hold directly.
- Batch arrays must have equal lengths, and any failing entry reverts the batch.
- Hold and release emit no dedicated event. `getHoldAmount` is meaningful only in the same transaction context.

Each agent-spend call accepts `fromReleaseAmount`, which releases that amount from the source's same-transaction hold before calculating spendable shares.

## Execute Agent Transfers

Active agents can use:

```text
agentTransferFromCommitted(
  policyID, from, to, amount, fromReleaseAmount, inUnderlying
)

agentTransferToUncommitted(
  policyID, from, to, amount, fromReleaseAmount, inUnderlying
)
```

The first credits `to` with committed shares in the same policy. Despite its historical name, the second credits `to` with free shares.

Require an active policy, an authorized caller, a `from` account that is not a policy agent, an intended nonzero `to`, sufficient capacity, and a same-transaction hold when release is requested.

When `inUnderlying == false`, `amount` is shMON shares. When true, it is MON converted without an atomic fee using:

```text
shares = ceil(
  amountMON * (realTotalSupply() + 1) /
  (totalAssets() + 1)
)
```

`convertToShares` is not exact for this path because it deducts recent revenue and rounds down. The calls return no value, so calculate and simulate the exact share effect.

Both agent transfer events report the resulting shMON shares even when input was in MON. The movement itself emits no standard ERC-20 `Transfer`.

## Execute An Agent Withdrawal

Use:

```text
agentWithdrawFromCommitted(
  policyID,
  from,
  to,
  amount,
  fromReleaseAmount,
  amountSpecifiedInUnderlying
)
```

Require an active policy, authorized caller, non-agent source, intended nonzero receiver able to accept native MON, sufficient policy capacity, and sufficient atomic liquidity.

The call has no slippage parameter:

- With `amountSpecifiedInUnderlying == true`, `amount` is exact net MON. ShMonad computes fee-inclusive shares, but there is no maximum-share bound.
- With it false, `amount` is exact shMON shares. Require positive accepted `previewRedeemDetailed(amount).netAssets`, but there is no minimum-MON bound.

Insufficient pool liquidity reverts rather than reducing the withdrawal. The function returns no value. `AgentWithdrawFromCommitted.amount` is net MON delivered, and the withdrawal emits no standard burn `Transfer` or ERC-4626 `Withdraw`. An automatic top-up inside the same spend can still emit `Commit` and a synthetic `Transfer`.

## Handle Disabled Policies

Disabling blocks new commitments, top-up configuration, holds, releases, and all agent spends. It does not block holder recovery: requests, completion from the disabled source policy, and existing completion approvals continue to work. Recommit still requires an active destination policy. Re-read `getPolicy(policyID).active` before any action that requires an active policy.

For exact policy event units, synthetic or missing emissions, required post-state, or revert diagnosis, read [events-and-errors.md](events-and-errors.md).
