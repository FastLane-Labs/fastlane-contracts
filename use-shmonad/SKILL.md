---
name: use-shmonad
description: Interact with the currently supported ShMonad (shMON) ERC-4626-like native-MON liquid-staking deployment through EVM JSON-RPC. Use for deposits, minting, atomic or traditional exits, ERC-20 and permit operations, policies and balance buckets, zero-yield balances, yield and validator rewards, cranking, administration, events, and revert diagnosis. Requires the network-specific proxy to point to the exact implementation documented by this skill. Includes a concrete ABI, public Monad RPC URLs, task-specific call semantics, and ShMonad safety rules.
---

# Use ShMonad

Use this skill for ShMonad contract selection, call semantics, state checks, simulations, events, and post-state. It is a rolling-current skill, not a historical compatibility layer. When a supported network upgrades, update this skill in place and remove the replaced implementation.

## Route The Task

Read only the references needed for the requested operation:

- [deployments-and-rpc.md](references/deployments-and-rpc.md): public RPC URLs, the exact compatibility sequence, JSON-RPC call shapes, and Monad execution or staking behavior that affects ShMonad. Read this before interacting with a live deployment.
- [holder-operations.md](references/holder-operations.md): deposits, minting, atomic exits, traditional unstaking, ERC-20, permit, conversions, fees, zero-yield balances, and yield boosts.
- [policies.md](references/policies.md): committed and uncommitting balances, policy creation, top-ups, uncommit flows, approvals, transient holds, and agent spending.
- [validators-and-admin.md](references/validators-and-admin.md): validator rewards, cranking, accounting views, pool configuration, status, validator lifecycle, Coinbase processing, and owner operations.
- [events-and-errors.md](references/events-and-errors.md): event units and exceptions, post-state requirements, custom-error diagnosis, and ABI/interface hazards.
- [shmonad-abi.json](references/shmonad-abi.json): canonical concrete ABI. Use it only after the deployment gate passes.

## Verify The Supported Deployment

| Network | Chain ID | ShMonad proxy | Required implementation |
| --- | ---: | --- | --- |
| Monad Mainnet | `143` (`0x8f`) | `0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c` | `0x856a4019228c265dee336df705277607c4a18e1b` |
| Monad Testnet | `10143` (`0x279f`) | `0x282BdDFF5e58793AcAb65438b257Dbd15A8745C9` | `0xbc123976c241873541eabff550724a9adfc4651d` |

Always call the proxy, never the implementation directly. Before using the bundled ABI:

1. Require the live chain ID to match the selected row.
2. Require nonempty code at the proxy.
3. Read EIP-1967 implementation slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` and take its rightmost 20 bytes.
4. Require that address to equal the row's required implementation and require nonempty code there.
5. Only after the address match, require `name() == "ShMonad"`, `symbol() == "shMON"`, and `decimals() == 18`.

Use [verify-deployment.mjs](scripts/verify-deployment.mjs) for the deterministic read-only version of this gate when Node is available. If the implementation differs, stop and report the network, proxy, expected implementation, and observed implementation. Initializer version, metadata, bytecode similarity, or shared selectors are not substitutes for the exact implementation-address match.

If incompatible implementations are live on different networks during an upgrade, support only the network/ABI pair explicitly represented by the skill. Never combine incompatible semantics or retain a replaced implementation for historical compatibility.

## Apply The ShMonad Model

ShMonad is an ERC-20 share token and an ERC-4626-like vault for native MON. Its standard-looking `deposit`, `mint`, `withdraw`, and `redeem` surface has native-value, liquidity, fee, and rounding behavior defined in the holder reference. ShMonad extends the base vault shape with detailed previews (`previewWithdrawDetailed`, `previewRedeemDetailed`) and bounded exits (`withdrawWithSlippageProtection`, `redeemWithSlippageProtection`). Prefer those extensions for atomic exits.

The vault is not a fully standard ERC-4626 token-asset vault: `asset()` is the native-MON sentinel `0xEeee...EEeE`, deposits carry native value, and a plain MON transfer to `receive()` is treated as a donation that mints no shares.

Keep MON and shMON distinct: MON is the native asset, while shMON is an 18-decimal vault share whose MON value is live and not fixed at 1:1.

An account can hold shares in three mutually exclusive buckets:

- **Uncommitted:** `balanceOf(account)`; transferable and usable for holder exits.
- **Committed:** `balanceOfCommitted(...)`; controlled through a policy and spendable by its agents.
- **Uncommitting:** `balanceOfUncommitting(policyID, account)`; in policy block escrow and excluded from `balanceOf`.

`totalSupply()` includes all three states; `committedTotalSupply()` excludes uncommitting shares. Do not reconstruct these buckets from ERC-20 `Transfer` logs.

## Apply Universal Call Discipline

For every state-changing ShMonad operation:

1. Identify the exact caller, owner/source, receiver, contract role, and allowance or policy authority required by that function.
2. Read the workflow-specific status, balance bucket, allowance, liquidity maximum, request, policy, validator, or configuration state at one explicit block context.
3. Obtain the workflow's live preview. Do not substitute `totalAssets / totalSupply` or a similarly named conversion when the reference says its accounting path differs.
4. Reject zero or unacceptable output before irreversibly consuming MON, shMON, a zero-yield liability, or an unstake request.
5. Require every intended asset/share recipient to be nonzero and able to receive native MON where applicable, including nonstandard functions that omit this check.
6. Prefer an explicit on-chain slippage bound. When none exists, surface that limitation and enforce every available precondition before simulating.
7. Simulate the exact proxy, function, arguments, caller, receiver, and native value, then keep those fields unchanged for execution.
8. After success, decode the expected events and re-read the authoritative balance, request, policy, validator, allowance, liquidity, or status state. Receipts do not contain Solidity return values.

## Report The Result

Report the network, proxy, verified implementation, function signature, caller/owner/receiver roles, MON assets, shMON shares, payable value, slippage bound or absence of one, and decision-state block. For writes, include decoded ShMonad events and the verified post-state named by the task reference.
