# ShMonad Holder Operations

Use this reference after the deployment compatibility gate in `SKILL.md` has passed. It covers holder-facing ShMonad behavior: receiving and moving shMON, depositing native MON, choosing an exit, using the zero-yield tranche, and donating yield.

## Contents

- [Understand the vault](#understand-the-vault)
- [Read holder state](#read-holder-state)
- [Deposit an exact MON amount](#deposit-an-exact-mon-amount)
- [Mint an exact shMON amount](#mint-an-exact-shmon-amount)
- [Choose an exit path](#choose-an-exit-path)
- [Withdraw an exact MON amount atomically](#withdraw-an-exact-mon-amount-atomically)
- [Redeem an exact shMON amount atomically](#redeem-an-exact-shmon-amount-atomically)
- [Request and complete a traditional unstake](#request-and-complete-a-traditional-unstake)
- [Transfer and approve free shares](#transfer-and-approve-free-shares)
- [Use permit](#use-permit)
- [Use the zero-yield tranche](#use-the-zero-yield-tranche)
- [Donate yield](#donate-yield)

## Understand The Vault

ShMonad is an almost-standard, ERC-4626-like vault for native MON. Its shares are the non-rebasing ERC-20 token shMON. Yield changes the MON value of each share; it does not increase a holder's share count.

The ERC-4626 shape is useful, but an integration must account for these ShMonad differences:

- `asset()` returns the native-token sentinel `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`, not an ERC-20 token address.
- `deposit` and `mint` are payable and require native MON. There is no asset-token approval and no WMON step.
- Atomic `withdraw` and `redeem` use ShMonad's liquidity pool and charge a utilization-dependent fee.
- Traditional unstaking is a separate fee-free, delayed path.
- ShMonad extends the familiar previews with `previewWithdrawDetailed` and `previewRedeemDetailed`, which expose gross assets, fees, and net assets.
- ShMonad extends the familiar exit functions with `withdrawWithSlippageProtection` and `redeemWithSlippageProtection`, which enforce holder-supplied bounds.
- Standard `previewWithdraw` and `previewRedeem` intentionally ignore the current atomic-pool liquidity limit. The corresponding `maxWithdraw` and `maxRedeem` reads are liquidity-aware.
- `maxDeposit` and `maxMint` always return `uint128.max`; they do not report whether deposits are currently closed.

MON assets and shMON shares both use 18 decimal places, but they are different units and are not economically 1:1. Use the live preview for the selected operation.

The public conversion functions have path-specific accounting:

- `previewDeposit` rounds shares down; a positive dust deposit can quote zero shares.
- `previewMint` rounds required MON up.
- `previewWithdraw` rounds required shares up and includes the atomic fee.
- `previewRedeem` rounds MON down and includes the atomic fee.
- `previewUnstake` rounds MON down but applies no atomic fee.
- Deposits and mints price against full equity. Public conversions and exit previews (`convertToShares`, `convertToAssets`, `previewWithdraw`, `previewRedeem`, and `previewUnstake`) deduct smoothed recent revenue. A same-epoch deposit followed by an exit can therefore return less than the deposit even before an atomic fee. These public conversions are not exact quotes for ShMonad-specific paths that deliberately use full equity.

`totalAssets()` reports full equity attributable to issued shMON. Do not derive an operation's exchange rate from `totalAssets() / totalSupply()` when a matching preview exists.

## Read Holder State

Use these reads to distinguish the holder's assets and the contract's current status:

```text
balanceOf(account)                       -> free, transferable shMON shares
balanceOfCommitted(account)              -> aggregate committed shMON shares
balanceOfCommitted(policyID, account)    -> shares committed to one policy
balanceOfUncommitting(policyID, account) -> shares waiting in one policy escrow
balanceOfZeroYieldTranche(account)       -> zero-yield MON principal
allowance(owner, spender)                -> free-share allowance
getGlobalStatus(0)                       -> (frozen, closed)
getCurrentLiquidity()                    -> atomic-pool MON liquidity
getInternalEpoch()                       -> current ShMonad epoch
```

The share buckets are mutually exclusive:

- Free shares appear in `balanceOf` and can be transferred, approved, atomically exited, or traditionally unstaked.
- Committed shares are controlled through a policy and cannot be transferred directly by the holder.
- Uncommitting shares are in a policy's block-based recovery escrow and do not appear in `balanceOf`.

`totalSupply()` includes all three share states. `committedTotalSupply()` includes committed shares but excludes uncommitting shares. See `policies.md` before acting on committed or uncommitting balances.

`getGlobalStatus(0)` returns `(frozen, closed)` in that order. `closed` blocks deposits and traditional unstake requests and completions, but does not block atomic holder exits in this implementation. `frozen` is not a general transfer pause; it can delay cranking and therefore delay epoch-dependent settlement.

## Deposit An Exact MON Amount

Use `deposit(assets, receiver)` when the input amount of MON is fixed.

Before the call:

1. Require `assets > 0` and `receiver != address(0)`.
2. Require `getGlobalStatus(0).closed == false`.
3. Read `previewDeposit(assets)` and require the result to be positive and acceptable.
4. Simulate the exact call with native value equal to `assets` and require the returned share amount to remain positive and acceptable.

Call shape:

```text
deposit(assets, receiver) -> shares
native value              = assets
```

ShMonad requires native value to equal `assets` exactly. The function has no `minShares` argument. A successful simulation is a quote at the simulated state, not an execution-time minimum, so surface that missing on-chain bound.

After success, verify:

```text
Deposit(sender, receiver, assets, shares)
Transfer(address(0), receiver, shares)
balanceOf(receiver) increased by shares
```

Do not send MON to the proxy without calldata as a substitute for `deposit`. The payable `receive()` path treats a plain transfer as goodwill and mints no shares.

## Mint An Exact shMON Amount

Use `mint(shares, receiver)` when the output amount of shMON is fixed.

Before the call:

1. Require `shares > 0` and `receiver != address(0)`.
2. Require `getGlobalStatus(0).closed == false`.
3. Read `assets = previewMint(shares)` at the state intended for execution.
4. Simulate `mint(shares, receiver)` with native value exactly equal to `assets`.

Call shape:

```text
mint(shares, receiver) -> assetsPaid
native value           = previewMint(shares)
```

The contract recalculates the required assets and reverts if native value differs. Verify the `Deposit` and mint `Transfer` events and the receiver's free balance.

## Choose An Exit Path

ShMonad offers two economically different exits:

| Path | Result | Fee | Timing | Principal risk control |
| --- | --- | --- | --- | --- |
| Atomic pool | MON is delivered in the same call | Utilization-dependent atomic fee | Immediate when liquidity is sufficient | Use liquidity-aware maximums and slippage wrappers |
| Traditional unstake | MON amount is fixed when shares burn | No atomic fee | Normally ShMonad epoch `N+5`, or `N+7` when additional capital activation is needed | Require a positive preview, then wait for the recorded live epoch gate |

Atomic liquidity and fees can change between a read and execution. Traditional unstaking is irreversible once requested and exposes the holder to a delay rather than atomic-pool pricing.

Every MON receiver must be nonzero and able to accept native MON. When a caller exits on behalf of another owner, the owner must have approved enough free shares for the actual burn.

## Withdraw An Exact MON Amount Atomically

Use the slippage-protected withdraw wrapper when the desired output is an exact net MON amount.

Read:

```text
maxWithdraw(owner)
previewWithdrawDetailed(netAssets)
  -> (shares, grossAssets, feeAssets)
allowance(owner, caller) when caller != owner
```

Require `netAssets <= maxWithdraw(owner)`. Choose an accepted `maxBurntShares` no smaller than the current detailed quote, then simulate:

```text
withdrawWithSlippageProtection(
  netAssets,
  receiver,
  owner,
  maxBurntShares
) -> sharesBurned
```

The wrapper reverts if the actual burn exceeds `maxBurntShares`. The plain `withdraw(netAssets, receiver, owner)` has no caller-supplied maximum-share bound.

## Redeem An Exact shMON Amount Atomically

Use the slippage-protected redeem wrapper when the amount of shMON to burn is fixed.

Read:

```text
maxRedeem(owner)
previewRedeemDetailed(shares)
  -> (grossAssets, feeAssets, netAssets)
allowance(owner, caller) when caller != owner
```

Require all of the following:

- `shares > 0` and `shares <= maxRedeem(owner)`.
- `receiver != address(0)` and the receiver can accept native MON.
- The detailed preview's `netAssets > 0` and that output is acceptable.
- The selected `minAssetsOut > 0`.

Then simulate:

```text
redeemWithSlippageProtection(
  shares,
  receiver,
  owner,
  minAssetsOut
) -> assetsReceived
```

The wrapper reverts if actual net MON is below `minAssetsOut`. The plain `redeem(shares, receiver, owner)` has no caller-supplied minimum-MON bound. Without a positive-output check, an extreme rounding or fee case can burn positive shares for zero MON.

Both atomic exit forms emit:

```text
Withdraw(caller, receiver, owner, netAssetsDelivered, sharesBurned)
Transfer(owner, address(0), sharesBurned)
```

`Withdraw.assets` is net MON delivered, not gross MON before the fee.

## Request And Complete A Traditional Unstake

Traditional unstaking burns free shMON immediately and records a fee-free MON amount for later completion.

Before requesting:

1. Require `shares > 0` and `shares <= balanceOf(caller)`.
2. Require `getGlobalStatus(0).closed == false`.
3. Read `amountMon = previewUnstake(shares)` and require `amountMon > 0` and acceptable.
4. If the caller is a contract or smart account, establish that it can later receive native MON from its own `completeUnstake()` call.

Call:

```text
requestUnstake(shares) -> completionEpoch
```

The request fixes `amountMon` when the shares burn. A zero-output request can burn shares into an unusable zero-amount record. If the account already has a valid request, another request merges the MON amount and takes the later completion epoch; even a newly quoted zero amount can extend that existing request without adding MON.

Record `RequestUnstake(owner, shares, amountMon, completionEpoch)` and confirm:

```text
getUnstakeRequest(owner) -> (storedAmountMon, storedCompletionEpoch)
```

The normal wait is from ShMonad epoch `N` to `N+5`. If pending stake must first activate, it is `N+7`. At approximately 50,000 blocks per Monad staking epoch and roughly 400 ms per block, these are about 28 hours and 39 hours respectively. Those durations are estimates only: ShMonad's internal epoch advances at most once per Monad staking epoch and depends on cranking, so it can take longer.

The actual completion gate is always:

```text
getInternalEpoch() >= getUnstakeRequest(owner).completionEpoch
```

At that gate, simulate and call `completeUnstake()` from the same account. It pays the entire stored request to that caller and clears the record.

There is no cancellation, partial completion, receiver parameter, delegated approval, or third-party completion. If a mature completion reverts with `InsufficientReservedLiquidity`, preserve the request and retry after reserves and cranking advance. Do not create a second request as a retry.

## Transfer And Approve Free Shares

`transfer` and `transferFrom` operate only on free `balanceOf` shares. They cannot spend committed or uncommitting shares.

`approve(spender, shares)` also authorizes these ShMonad actions when the caller differs from the share owner:

- `withdraw` and `withdrawWithSlippageProtection`;
- `redeem` and `redeemWithSlippageProtection`;
- share-funded `boostYield`.

A maximum `uint256` allowance is treated as infinite and is not decremented. Finite spending decrements allowance, but ShMonad does not emit a new `Approval` event for that decrement. Re-read `allowance` when its current value matters.

## Use Permit

ShMonad supports the fixed `(v,r,s)` EIP-2612 entrypoint:

```text
permit(owner, spender, value, deadline, v, r, s)
```

The ShMonad-specific domain is:

```text
name              = "ShMonad"
version           = "3"
chainId           = the selected live network
verifyingContract = the verified ShMonad proxy
```

Read `nonces(owner)`, `eip712Domain()`, and `DOMAIN_SEPARATOR()` from the proxy before constructing the authorization. For an EOA owner, the implementation accepts `v` only as `27` or `28`; it does not normalize `0` or `1`.

For a contract owner, the ERC-1271 fallback validates exactly the packed 65-byte `r || s || v` representation. A contract wallet that requires an arbitrary-length or differently encoded signature cannot use this permit path. A deadline equal to the current block timestamp is valid; a past deadline is not.

## Use The Zero-Yield Tranche

The zero-yield tranche records non-transferable MON principal. It mints no shMON and earns no yield for its owner; yield generated by those assets benefits shMON.

To deposit:

```text
depositToZeroYieldTranche(assets, receiver)
native value = assets
```

Require `assets > 0`, exact native value, `closed == false`, and `receiver != address(0)`. Unlike standard deposit, this function does not enforce a nonzero receiver and can create an unusable balance for the zero address. Verify `DepositToZeroYieldTranche(sender, receiver, assets)` and the receiver's `balanceOfZeroYieldTranche` increase.

Only the balance owner can convert its principal:

```text
convertZeroYieldTrancheToShares(assets, receiver) -> shares
```

Require sufficient caller principal, `closed == false`, a nonzero receiver, and a positive acceptable simulated share result before conversion. Floor rounding can consume positive principal while minting zero shares. A successful conversion emits `ZeroYieldBalanceConvertedToShares`, `Deposit`, and the share-mint `Transfer` event.

There is no direct zero-yield-to-MON withdrawal and no transfer function for zero-yield balances. Convert to shMON first, then choose an atomic or traditional exit.

## Donate Yield

ShMonad has two explicit public yield-boost paths:

```text
boostYield(yieldOriginator)                         // donate native MON
boostYield(shares, from, yieldOriginator)           // burn free shMON
```

Both paths take the current owner boost commission, whose live rate is reported in basis points by `getAdminValues`; only the remainder becomes holder yield. `yieldOriginator` is event attribution and does not receive shares or MON.

For a share-funded boost, require positive shares, sufficient free balance or allowance, and a positive acceptable gross asset effect before burning. This path uses the full-equity floor conversion without the recent-revenue deduction:

```text
grossMON = floor(
  shares * (totalAssets() + 1) /
  (realTotalSupply() + 1)
)
```

Public `convertToAssets(shares)` is not the exact quote for this path. If the exact conversion rounds to zero, the function can still burn the shares.

`BoostYield.amount` is the gross amount before owner commission. `sharesBurned` identifies the share-funded path, `yieldOriginator` remains attribution only, and these public paths emit validator ID `0`.

For exact event units, emission exceptions, required post-state, or revert diagnosis, read [events-and-errors.md](events-and-errors.md).
