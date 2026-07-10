# Monad Context For ShMonad

This reference contains only Monad network facts that materially affect ShMonad selection, deposits, call simulation, cranking, unstake timing, or settlement.

Network facts and endpoints were checked against official Monad documentation and live RPCs on 2026-07-10.

## Contents

- [Networks](#networks)
- [Public RPC endpoints](#public-rpc-endpoints)
- [Units and EVM compatibility](#units-and-evm-compatibility)
- [Declared gas-limit charging](#declared-gas-limit-charging)
- [Reserve balance and large deposits](#reserve-balance-and-large-deposits)
- [Asynchronous execution and finality](#asynchronous-execution-and-finality)
- [Staking epochs and ShMonad timing](#staking-epochs-and-shmonad-timing)
- [Staking precompile calls](#staking-precompile-calls)
- [Deployment compatibility](#deployment-compatibility)
- [Primary sources](#primary-sources)

## Networks

| Field | Mainnet | Testnet |
| --- | --- | --- |
| Network | Monad Mainnet | Monad Testnet |
| Chain ID | `143` / `0x8f` | `10143` / `0x279f` |
| Native currency | MON, 18 decimals | MON, 18 decimals |
| ShMonad proxy | `0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c` | `0x282BdDFF5e58793AcAb65438b257Dbd15A8745C9` |
| Required implementation | `0x856a4019228c265dee336df705277607c4a18e1b` | `0xbc123976c241873541eabff550724a9adfc4651d` |
| Explorer | `https://monadscan.com` | `https://testnet.monadscan.com` |
| Alternate explorer | `https://monadvision.com` | `https://testnet.monadvision.com` |
| Faucet | n/a | `https://faucet.monad.xyz` |

Official ShMonad documentation lists both proxy addresses. Monad Testnet was reset from genesis on 2025-12-16 and remains a resettable environment, so do not assume old testnet blocks or deployments still exist.

## Public RPC Endpoints

Public endpoints are shared and rate-limited.

### Mainnet

| HTTP | WebSocket | Provider |
| --- | --- | --- |
| `https://rpc.monad.xyz` | `wss://rpc.monad.xyz` | QuickNode |
| `https://rpc1.monad.xyz` | `wss://rpc1.monad.xyz` | Alchemy |
| `https://rpc2.monad.xyz` | `wss://rpc2.monad.xyz` | Goldsky Edge |
| `https://rpc3.monad.xyz` | `wss://rpc3.monad.xyz` | Ankr |
| `https://rpc-mainnet.monadinfra.com` | `wss://rpc-mainnet.monadinfra.com` | Monad Foundation |

### Testnet

| HTTP | WebSocket | Provider |
| --- | --- | --- |
| `https://testnet-rpc.monad.xyz` | `wss://testnet-rpc.monad.xyz` | QuickNode |
| `https://rpc.ankr.com/monad_testnet` | not listed | Ankr |
| `https://rpc-testnet.monadinfra.com` | `wss://rpc-testnet.monadinfra.com` | Monad Foundation |

## Units And EVM Compatibility

- `1 MON = 10^18 wei`.
- `1 shMON = 10^18 share subunits`.
- MON assets and shMON shares are not economically 1:1. Query ShMonad preview functions for the live conversion.
- Monad preserves EVM bytecode, ABI encoding, 20-byte addresses, Ethereum signatures, and standard Ethereum-style JSON-RPC methods used by this skill.
- ShMonad represents native MON with sentinel address `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`; it does not use WMON for deposits or exits.

## Declared Gas-Limit Charging

Monad charges for the transaction's declared gas limit rather than only execution `gasUsed`:

```text
fee paid = declared gas limit * effective gas price
```

Unused gas-limit headroom has no economic refund. This is relevant to every ShMonad write and especially `crank()`, whose work varies with validator state. Estimate the selected ShMonad call and avoid an unnecessarily large declared limit. Monad's protocol per-transaction limit is 30,000,000 gas.

## Reserve Balance And Large Deposits

Monad has a 10 MON reserve-balance mechanism for EOAs under asynchronous execution. It matters when a user attempts to deposit nearly the wallet's entire MON balance into ShMonad.

- An undelegated EOA may qualify for Monad's limited emptying-transaction exception after the required quiet period.
- An EIP-7702-delegated EOA cannot use that emptying exception when its balance is decremented.
- A near-full-balance ShMonad deposit can therefore revert even when the wallet appears to cover `assets` and transaction fees.

Before a large payable `deposit`, `mint`, `depositAndCommit`, `depositToZeroYieldTranche`, `boostYield`, or `sendValidatorRewards` call, account for the reserve rules applicable to the sender. Eligibility for the emptying exception depends on the sender's delegation and recent transaction history.

## Asynchronous Execution And Finality

Monad separates consensus ordering from execution. The useful RPC block states are:

| Block tag | Meaning for ShMonad |
| --- | --- |
| `latest` | Proposed/speculative executed state; useful for fresh previews and simulation |
| `safe` | Supermajority-voted state |
| `finalized` | Irreversible absent a hard fork; use for settled ShMonad post-state |

Blocks are produced at roughly 400 ms and normally finalize in roughly 800 ms, but clients should use the block tags rather than fixed sleeps. A ShMonad preview from `latest` is current but speculative; a finalized balance is settled but can be too old for pricing a new write.

## Staking Epochs And ShMonad Timing

Monad staking uses a 50,000-block boundary, approximately 5.5 hours at 400 ms blocks, followed by a 5,000-round delay before the next staking epoch activates. Rounds are not the same as blocks.

ShMonad maintains its own `getInternalEpoch()` and advances it through cranking around Monad staking epochs. Traditional unstake normally quotes current ShMonad epoch plus 5 and may quote plus 7 when additional capital activation is needed. Treat the resulting wall-clock duration as approximate and use the stored completion epoch plus live `getInternalEpoch()` as the actual gate.

## Staking Precompile Calls

Monad's staking precompile is `0x0000000000000000000000000000000000001000`. It supports normal `CALL` but rejects `STATICCALL`, `DELEGATECALL`, and `CALLCODE`.

This is why ShMonad exposes `isGlobalCrankAvailable()` and `getEpochInfo()` as ABI `nonpayable` rather than `view`. A top-level JSON-RPC `eth_call` can still simulate either function without committing state.

## Deployment Compatibility

Both ShMonad addresses are EIP-1967 transparent proxies. The implementation slot is:

```text
0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
```

Always call the proxy, but require the slot's rightmost 20 bytes to equal the network-specific implementation in the network table before using the bundled ABI or semantics. If it differs, the skill is stale for that network.

The proxy admin and ShMonad `owner()` are different roles. Transparent proxy administrators cannot fall through the proxy as ordinary ShMonad callers.

## Primary Sources

- ShMonad addresses: `https://docs.shmonad.xyz/addresses/`
- ShMonad liquid staking: `https://docs.shmonad.xyz/liquid-staking/`
- ShMonad traditional unstaking: `https://docs.shmonad.xyz/unstaking/traditional`
- ShMonad policies: `https://docs.shmonad.xyz/policies`
- Monad mainnet information: `https://docs.monad.xyz/developer-essentials/network-information`
- Monad testnet information: `https://docs.monad.xyz/developer-essentials/testnets`
- Monad gas pricing: `https://docs.monad.xyz/developer-essentials/gas-pricing`
- Monad reserve balance: `https://docs.monad.xyz/developer-essentials/reserve-balance`
- Monad block states: `https://docs.monad.xyz/monad-arch/consensus/block-states`
- Monad JSON-RPC: `https://docs.monad.xyz/reference/json-rpc/overview`
- Monad staking: `https://docs.monad.xyz/reference/staking/overview`
