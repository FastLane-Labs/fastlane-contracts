# ShMonad Deployments And RPC

Use this reference to select a supported ShMonad deployment, prove that its proxy still points to the implementation documented by this skill, and account for Monad behavior that changes ShMonad execution or settlement.

## Contents

- [Supported deployments](#supported-deployments)
- [Public RPC endpoints](#public-rpc-endpoints)
- [Fail-closed compatibility gate](#fail-closed-compatibility-gate)
- [Compact JSON-RPC shapes](#compact-json-rpc-shapes)
- [ShMonad units and native MON](#shmonad-units-and-native-mon)
- [Declared gas-limit charging](#declared-gas-limit-charging)
- [Reserve balance and payable calls](#reserve-balance-and-payable-calls)
- [Block state and settlement](#block-state-and-settlement)
- [Staking epochs and ShMonad timing](#staking-epochs-and-shmonad-timing)
- [Staking precompile behavior](#staking-precompile-behavior)

## Supported Deployments

The network-to-proxy-to-implementation table in `SKILL.md` is authoritative. Call its proxy, never its implementation. The implementation address is an identity check for the semantics and ABI bundled with this skill; it is not the transaction target. The package validator requires the table to match the deterministic deployment verifier.

## Public RPC Endpoints

Public endpoints are shared and may be rate-limited.

| Network | HTTP | WebSocket |
| --- | --- | --- |
| Mainnet | `https://rpc.monad.xyz` | `wss://rpc.monad.xyz` |
| Mainnet | `https://rpc1.monad.xyz` | `wss://rpc1.monad.xyz` |
| Mainnet | `https://rpc2.monad.xyz` | `wss://rpc2.monad.xyz` |
| Mainnet | `https://rpc3.monad.xyz` | `wss://rpc3.monad.xyz` |
| Mainnet | `https://rpc-mainnet.monadinfra.com` | `wss://rpc-mainnet.monadinfra.com` |
| Testnet | `https://testnet-rpc.monad.xyz` | `wss://testnet-rpc.monad.xyz` |
| Testnet | `https://rpc.ankr.com/monad_testnet` | not published |
| Testnet | `https://rpc-testnet.monadinfra.com` | `wss://rpc-testnet.monadinfra.com` |

Do not treat successful connectivity as proof that an endpoint is on the intended chain. Run the compatibility gate against the endpoint being used.

## Fail-Closed Compatibility Gate

The EIP-1967 implementation slot is:

```text
0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
```

Before using `shmonad-abi.json` or any behavior described by this skill:

1. Call `eth_chainId` and require the exact chain ID in the deployment table.
2. Select only that row's proxy and required implementation.
3. Call `eth_getCode` for the proxy and require a nonempty result.
4. Call `eth_getStorageAt` for the proxy and EIP-1967 slot at the same block context.
5. Require a full 32-byte storage word, take its rightmost 20 bytes, normalize it as an address, and require exact equality with the selected row's implementation.
6. Call `eth_getCode` for the observed implementation and require a nonempty result.
7. Only after the address match, call the proxy and require `name() == "ShMonad"`, `symbol() == "shMON"`, and `decimals() == 18`.

Fail closed on any missing, malformed, or mismatched response. Report the chain ID, proxy, expected implementation, observed implementation, endpoint, and block context. Do not probe an unknown implementation with the bundled ABI to infer compatibility. Matching metadata, initializer state, bytecode fragments, or individual selectors cannot replace the implementation-address match.

If one network upgrades before another, support only the rows that still match. Update this rolling-current skill when the new deployment is deliberately adopted; do not keep a replaced implementation as historical fallback.

The transparent proxy administrator and ShMonad `owner()` are separate roles. A transparent proxy administrator cannot fall through the proxy to invoke ordinary ShMonad functions.

## Compact JSON-RPC Shapes

The requests below show the required RPC fields. `BLOCK_CONTEXT` should be a deliberate block tag or quantity, and `ABI_ENCODE(...)` means calldata encoded from the bundled concrete ABI after the gate succeeds.

```text
chain:
  {"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}

code:
  {"jsonrpc":"2.0","id":1,"method":"eth_getCode",
   "params":[SHMONAD_PROXY,BLOCK_CONTEXT]}

implementation:
  {"jsonrpc":"2.0","id":1,"method":"eth_getStorageAt",
   "params":[SHMONAD_PROXY,EIP1967_IMPLEMENTATION_SLOT,BLOCK_CONTEXT]}

read:
  {"jsonrpc":"2.0","id":1,"method":"eth_call",
   "params":[{"to":SHMONAD_PROXY,"data":ABI_ENCODE(signature,args)},BLOCK_CONTEXT]}

state-changing simulation:
  {"jsonrpc":"2.0","id":1,"method":"eth_call",
   "params":[{"from":SENDER,"to":SHMONAD_PROXY,
              "data":ABI_ENCODE(signature,args),"value":HEX_MON_WEI},BLOCK_CONTEXT]}

estimate selected call:
  {"jsonrpc":"2.0","id":1,"method":"eth_estimateGas",
   "params":[{"from":SENDER,"to":SHMONAD_PROXY,
              "data":ABI_ENCODE(signature,args),"value":HEX_MON_WEI}]}

receipt:
  {"jsonrpc":"2.0","id":1,"method":"eth_getTransactionReceipt",
   "params":[TRANSACTION_HASH]}

proxy logs:
  {"jsonrpc":"2.0","id":1,"method":"eth_getLogs",
   "params":[{"address":SHMONAD_PROXY,"topics":[TOPIC0],
              "fromBlock":FROM_BLOCK,"toBlock":TO_BLOCK}]}
```

For a nonpayable simulation, omit `value`; for a payable ShMonad call, use the exact required MON wei. Keep the ShMonad function, arguments, sender, receiver, value, and relevant state context consistent between simulation and execution. A successful transaction receipt contains status and logs, not the Solidity return value produced during simulation.

## ShMonad Units And Native MON

- `1 MON = 10^18` wei.
- `1 shMON = 10^18` share subunits.
- MON assets and shMON shares are not economically 1:1. Use the live ShMonad preview appropriate to the selected operation.
- WAD is `1e18`, RAY is `1e27`, and basis points use `10_000 = 100%`. Do not interchange these parameter units.
- ShMonad represents native MON with `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`. Deposits and exits do not use WMON.
- A plain MON transfer to ShMonad invokes `receive()` as goodwill and mints no shMON.

## Declared Gas-Limit Charging

Monad charges for the transaction's declared gas limit, not only the gas actually used:

```text
fee paid = declared gas limit * effective gas price
```

Unused gas-limit headroom has no economic refund. This affects every ShMonad write and is especially material for `crank()`, whose work depends on validator state. Estimate the exact selected call without adding arbitrary headroom. Monad's protocol maximum per transaction is 30,000,000 gas.

## Reserve Balance And Payable Calls

Monad's asynchronous execution model applies a 10 MON reserve-balance mechanism to EOAs. This can make a nearly full-balance ShMonad payment revert even when the displayed balance appears to cover the call value and transaction cost.

- An undelegated EOA may qualify for the limited emptying-transaction exception after the required quiet period.
- An EIP-7702-delegated EOA cannot use that exception when its balance is decremented.

Account for this rule before a large payable `deposit`, `mint`, `depositAndCommit`, `depositToZeroYieldTranche`, `boostYield`, or `sendValidatorRewards` call. Eligibility depends on the sender's delegation and recent transaction history.

## Block State And Settlement

Monad separates consensus ordering from execution. Select the block context according to the ShMonad decision:

| Block tag | ShMonad use |
| --- | --- |
| `latest` | Fresh, speculative previews and exact-call simulation |
| `safe` | State backed by a supermajority vote |
| `finalized` | Settled receipt and post-state verification |

Blocks are produced at roughly 400 ms and normally finalize in roughly 800 ms, but use block tags instead of fixed delays. A `latest` quote is current but speculative; a `finalized` quote may be too old for pricing a new state-changing call.

## Staking Epochs And ShMonad Timing

Monad staking has a 50,000-block boundary, about 5.5 hours at 400 ms blocks, followed by a 5,000-round activation delay. Rounds are not blocks.

ShMonad advances its own `getInternalEpoch()` through cranking around Monad staking epochs. For the implementation-specific traditional-unstake delay and completion gate, read [holder-operations.md](holder-operations.md#request-and-complete-a-traditional-unstake).

## Staking Precompile Behavior

Monad's staking precompile is `0x0000000000000000000000000000000000001000`. It accepts normal `CALL` but rejects `STATICCALL`, `DELEGATECALL`, and `CALLCODE`.

`STAKING_PRECOMPILE()` returns that address from ShMonad.

Consequently, ShMonad exposes `isGlobalCrankAvailable()` and `getEpochInfo()` as ABI `nonpayable` rather than `view`. A top-level JSON-RPC `eth_call` can evaluate them without committing state; a Solidity integration must not try to reach these paths through `STATICCALL`.
