---
name: use-shmonad
description: Interact with only the currently supported ShMonad (shMON) liquid-staking deployment on Monad through an EVM JSON-RPC client. Use for ShMonad deposits and minting, atomic or traditional exits, ERC-20 and permit operations, committed and uncommitting balances, policies, zero-yield balances, yield donations, validator rewards, cranking, administration, events, and revert diagnosis. Requires the network-specific proxy to point to the exact implementation documented by this skill. Includes the complete concrete ABI, public Monad RPC URLs, contract-specific call recipes, and ShMonad accounting and safety rules.
---

# Use ShMonad

Use this skill for ShMonad contract selection, calldata semantics, state checks, simulations, expected events, and post-state.

This is a rolling-current skill, not a historical compatibility layer. It documents only the ShMonad implementations currently listed below. When a supported network upgrades, update this skill in place and remove the replaced implementation from that network.

## Load The Relevant Reference

- Read [contract-api.md](references/contract-api.md) to select functions, interpret returns, understand roles and accounting, or decode ShMonad events and errors.
- Read [rpc-interactions.md](references/rpc-interactions.md) for RPC call sequences for each ShMonad workflow.
- Read [rpc-and-monad.md](references/rpc-and-monad.md) for public RPC URLs and Monad behavior that materially affects ShMonad deposits, gas cost, staking timing, and settlement.
- Use [shmonad-abi.json](references/shmonad-abi.json) as the canonical concrete ABI only after passing the implementation compatibility gate. It contains all 141 functions, 79 events, 79 custom errors, the constructor, and `receive()`.

## Select And Verify The Deployment

| Network | Chain ID | ShMonad proxy | Required implementation | Primary public RPC |
| --- | ---: | --- | --- | --- |
| Monad Mainnet | `143` (`0x8f`) | `0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c` | `0x856a4019228c265dee336df705277607c4a18e1b` | `https://rpc.monad.xyz` |
| Monad Testnet | `10143` (`0x279f`) | `0x282BdDFF5e58793AcAb65438b257Dbd15A8745C9` | `0xbc123976c241873541eabff550724a9adfc4651d` | `https://testnet-rpc.monad.xyz` |

Always call the proxy, never the implementation directly. Before using the bundled ABI against a network:

1. Require `eth_chainId` to equal the table's chain ID.
2. Require nonempty `eth_getCode` at the table's proxy.
3. Read the proxy's EIP-1967 implementation slot with `eth_getStorageAt` and take the rightmost 20 bytes.
4. Require the observed implementation to equal the table's network-specific implementation.
5. Only after that match, require `name() == "ShMonad"`, `symbol() == "shMON"`, and `decimals() == 18`.

The implementation slot is `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`. If the implementation differs, stop and report the network, proxy, expected implementation, and observed implementation. Do not reuse this ABI or these semantics against the new implementation. Initializer version, token metadata, or shared selectors are not substitutes for the implementation-address match.

If incompatible versions are temporarily live on different networks during a rollout, mark unsupported networks explicitly or provide network-specific ABI and semantics. Do not pretend one ABI describes incompatible implementations, and do not retain a replaced implementation merely for historical compatibility.

## Apply ShMonad Call Discipline

- Distinguish MON assets from shMON shares. `1 MON = 10^18 wei`; `1 shMON = 10^18 share subunits`. They are not economically equal. Use live preview functions for conversion.
- Treat WAD (`1e18`), RAY (`1e27`), basis-point, epoch, block, validator-ID, and policy-ID parameters according to their documented units. They are not token amounts.
- For a state-changing call, read the ShMonad state named by its workflow, encode from the bundled ABI, and simulate the exact ShMonad function, arguments, sender, receiver, and native value before execution.
- Reject a zero or unacceptable simulated output for any operation that irreversibly consumes MON, shMON, a zero-yield balance, or an unstake request.
- Require every asset or share recipient to be the intended nonzero address, including nonstandard policy-agent and zero-yield functions that do not enforce this themselves.
- Prefer ShMonad functions with explicit slippage bounds. When a function has no bound, surface that fact before it is used.
- After a successful write, decode the expected ShMonad events and re-read the affected balance bucket, allowance, request, policy record, validator record, or status.

## Understand The Balance Buckets

ShMonad has three mutually exclusive shMON balance states:

- **Uncommitted:** `balanceOf(account)`. Transferable, approvable, redeemable, and usable in `requestUnstake`.
- **Committed:** `balanceOfCommitted(policyID, account)` and aggregate `balanceOfCommitted(account)`. Policy agents can spend it; the holder cannot transfer it directly.
- **Uncommitting:** `balanceOfUncommitting(policyID, account)`. Waiting through policy escrow and excluded from `balanceOf`.

`totalSupply()` includes shares across all three states. `committedTotalSupply()` includes committed shares but not uncommitting shares. Do not reconcile policy balances from ERC-20 `Transfer` events alone.

## Deposit MON For shMON

Use `deposit(assets, receiver)` when the input is an exact MON amount:

1. Require a nonzero receiver and read `getGlobalStatus(0)`; its return order is `(frozen, closed)`.
2. Call `previewDeposit(assets)` and require the quoted shares to be positive and acceptable.
3. Simulate `deposit(assets, receiver)` with `value = assets`; require its returned shares to be positive and acceptable.
4. Submit the same payable call, then verify `Deposit` and the receiver's free `balanceOf` increase.

Use `mint(shares, receiver)` only when exact shMON output matters. Require positive shares, call `previewMint(shares)`, and use that exact MON amount as `value`. Both deposit functions require exact native value. Neither has an on-chain minimum-shares argument, so a successful simulation does not create an execution-time slippage bound.

`depositAndCommit` routes through `deposit`; apply the same positive-output and native-value rules before considering the policy-specific risks below. `maxDeposit` and `maxMint` always return `uint128.max` and do not reflect closed status.

Never use a plain MON transfer as a deposit. `receive()` treats it as goodwill that mints no shares. `boostYield`, `sendValidatorRewards`, and `depositToZeroYieldTranche` also accept MON without performing a standard shMON deposit.

## Exit To MON

### Atomic Exit

- For exact net MON, read `maxWithdraw(owner)` and `previewWithdrawDetailed(assets)`, then use `withdrawWithSlippageProtection(assets, receiver, owner, maxBurntShares)`.
- For exact shMON burn, read `maxRedeem(owner)` and `previewRedeemDetailed(shares)`, require positive net MON and a positive `minAssetsOut`, then use `redeemWithSlippageProtection(shares, receiver, owner, minAssetsOut)`.
- Require a nonzero receiver that can accept native MON. If caller differs from owner, the owner must approve the shares that may be burned.
- Previews ignore current liquidity. Enforce the corresponding `maxWithdraw` or `maxRedeem` immediately before the call.
- The plain `withdraw` and `redeem` variants have no caller-supplied slippage bound.

### Traditional Exit

Use the traditional path for a fee-free, delayed exit:

1. Require positive shares within the caller's uncommitted `balanceOf`.
2. Call `previewUnstake(shares)` and require a positive, accepted MON amount. A zero result would burn shares into an unusable zero-amount request, or, when a request is already pending, add nothing while pushing its completion epoch later.
3. If the caller is a contract or smart account, establish before requesting that it can receive native MON when it later calls `completeUnstake()`.
4. Simulate and call `requestUnstake(shares)` from the share owner. Record `RequestUnstake` and confirm `getUnstakeRequest(account)`.
5. Poll `getInternalEpoch()`. At or after the stored completion epoch, simulate and call `completeUnstake()` from the same account.

Requests merge per account: MON amounts accumulate and the completion epoch becomes the later quote. There is no cancel, partial completion, receiver parameter, or third-party completion. Maturity can still encounter `InsufficientReservedLiquidity`; retry completion later rather than creating another request.

## Use ERC-20 And Permit

- `transfer` and `transferFrom` operate only on uncommitted shares.
- Standard allowance also authorizes delegated atomic exits and share-funded `boostYield`.
- EIP-2612 uses domain name `ShMonad`, version `3`, the live chain ID, and the proxy as verifying contract.
- For an EOA signature, `v` must be the `27` or `28` form accepted by the implementation.
- The permit entrypoint accepts only `(v,r,s)`. Its ERC-1271 fallback passes exactly the packed 65-byte `r || s || v` signature. Contract wallets requiring another signature length or format cannot use this permit path.

## Work With Policies

Commitment grants policy agents enforceable spending authority:

1. Read `getPolicy`, `getPolicyAgents`, and `isPolicyAgent` before committing. Treat escrow duration as an arbitrary `uint48` number of blocks.
2. Require a nonzero committed-share recipient. Use `commit` for existing free shares or payable `depositAndCommit` for a deposit plus commitment. With `sharesToCommit == uint256.max`, only the newly minted shares are committed; a finite amount can also consume pre-existing free shares.
3. Before recovering funds, inspect `getCommittedData`, `getUncommittingData`, and `getTopUpSettings`. `requestUncommit(..., newMinBalance)` changes only the minimum; it does not clear existing top-up limits.
4. To disable free-balance top-up while the policy is active, call `setMinCommittedBalance(policyID, 0, 0, 0)`. This does not stop an agent from pulling shares back out of the uncommitting bucket; that pull emits no event, so detect it by re-reading `getUncommittingData`.
5. Record the completion block returned by `requestUncommit`, verify a nonzero uncommitting balance, and wait for `block.number >= completionBlock` before completing.
6. Prefer `completeUncommit` followed by a slippage-protected atomic exit. `completeUncommitAndRedeem` has no minimum-MON argument; require a positive accepted `previewRedeem(shares)` before considering it.

`minCommitted` is a top-up target, not a guaranteed post-spend floor. Every later uncommit request resets the start block for the account's entire uncommitting balance in that policy, including `requestUncommit(policyID, 0, newMinBalance)`. Reject a zero-share request unless that reset is explicitly intended. Disabled policies reject new commits and agent spends but still allow request and completion of uncommit.

Uncommit completion approvals are stored as `uint96`. `setUncommitApproval` reverts above `uint96.max`. `requestUncommitWithApprovedCompletor` adds the requested shares to the existing approval and therefore reverts on overflow, including an attempt to add positive shares to an already infinite approval; replace the approval deliberately when needed.

`policyBalanceAvailable(policyID, account, false)` is the aggregate share capacity visible to an agent. With `true`, it applies `previewRedeem` and returns a fee-aware, liquidity-ignorant indicative net-MON quote. It is not a universal executable maximum for every agent operation, and agent spend calls still reject an `account` that is itself a policy agent.

For `agentTransferFromCommitted`, `agentTransferToUncommitted`, and `agentWithdrawFromCommitted`, require nonzero intended recipients. `inUnderlying=true` on transfer functions converts MON to shares without the atomic fee; quote the exact shares with the full-equity ceil formula documented in `rpc-interactions.md`, because the functions return nothing and public `convertToShares` is not exact (it deducts recent revenue and rounds down). Their events report the resulting share amount. Agent withdrawal uses the atomic pool and has no slippage parameter: underlying mode has no maximum-shares bound, while share mode has no minimum-MON bound, so require a positive accepted `previewRedeemDetailed(shares).netAssets` yourself before using it. `AgentWithdrawFromCommitted.amount` is net MON.

Holds use EIP-1153 transient storage and disappear at transaction end. A standalone `hold` call does not lock a later transaction.

For owner-managed policy agents, require `agent != address(0)` before `addPolicyAgent`; the contract does not enforce this. Never remove the remaining real agent while zero is the only other configured agent.

## Work With The Zero-Yield Tranche

`depositToZeroYieldTranche(assets, receiver)` creates a non-transferable, non-yield-bearing MON balance and mints no shMON. Require exact `value = assets` and a nonzero receiver; the contract does not reject `receiver == address(0)`.

To convert, simulate `convertZeroYieldTrancheToShares(assets, receiver)` from the balance owner and require a positive, accepted share result before consuming the zero-yield principal. The same zero-output guard applies to owner-only `claimOwnerCommissionAsShares`. There is no direct zero-yield-to-MON withdrawal; convert to shMON and then choose an exit path.

## Handle Yield And Validator Rewards

- Both `boostYield` variants take the live owner boost commission. `yieldOriginator` is event attribution only. `BoostYield.amount` is the gross pre-commission amount, `sharesBurned` identifies the share-funded path, and `validatorId` is always `0` in these public paths.
- Before share-funded `boostYield`, require positive shares and a positive accepted gross asset effect. Its exact full-equity conversion does not deduct recent revenue, so public `convertToAssets` is not the exact quote.
- Before `sendValidatorRewards(validatorId, feeRate)`, require `feeRate <= 1e18`, confirm the caller-selected rate is intended, and inspect `getValidatorData(validatorId)`; the contract does not read that rate from validator configuration.
- A validator receives a delayed payout only when it is not a placeholder, is active, and is in the current active set. Otherwise `validatorPayout` becomes zero and the value, net of owner commission accounting, is directed to shMON yield. The owner commission on either path is the boost commission applied only to the fee portion, so `feeRate = 0` yields no commission.
- For an eligible validator, `validatorPayout = value - floor(value * feeRate / 1e18)` and emitted `feeTaken` is that gross fee. For an ineligible validator, emitted `validatorPayout = 0` and `feeTaken = value`.

## Respect Status, Cranking, And Administration

- `closed` blocks deposits, minting, `depositAndCommit`, traditional request/completion, and zero-yield deposit/conversion. It does not block atomic exits in this implementation.
- `frozen` blocks `crank` and Coinbase processing but is not a universal ERC-20 pause.
- `crank()` is permissionless and may require repeated calls to process all validators.
- `setPoolTargetLiquidityPercentage` accepts WAD input up to `1e18`, but input `1` is the internal no-pending-update sentinel. Use `0` or multiples of `1e14` WAD (one basis point); finer precision is truncated when applied. Every call overwrites any pending update, and cranking can itself set a pending value to rebalance drift. Updates can apply gradually. When the current applied target is zero, `getPendingTargetLiquidity()` can return zero even while a positive percentage update is pending.
- `processCoinbaseByAuth(uint64)` requires the registered Coinbase to contain contract code. A validator registered with a plain EOA Coinbase cannot use that overload.
- The transparent proxy admin and ShMonad `owner()` are separate roles. `initialize` is upgrade machinery, not a holder interaction.

## Interpret Results

For every ShMonad operation, report the network, proxy, verified implementation, function signature, sender/owner/receiver roles, MON assets, shMON shares, payable value, slippage bound if any, and the state used for the decision. For writes, report decoded ShMonad events and verified post-state. Do not claim an output was received merely because a simulation returned it; transaction return values are not placed in receipts.
