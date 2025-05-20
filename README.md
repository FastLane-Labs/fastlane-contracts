# FastLane Contracts

Smart contracts powering FastLane Labs' staking and infrastructure on the Monad blockchain.
**NOTE: Many of these smart contracts have been specifically calibrated to handle Monad's unique asynchronous execution and transaction fee mechanism. These contracts should not be deployed on other blockchains or L2s without significant modifications.**

## About FastLane Labs

FastLane Labs is building critical staking, automation, and MEV infrastructure for the Monad ecosystem, focusing on improving the developer and user experience through optimized smart contracts and latency-minimized services.

## Projects

### Atlas

Atlas is FastLane's application-specific sequencing layer, letting each dApp set its own rules for transaction ordering and MEV handling. It captures the surrounding MEV and leaves distribution up to the application—whether that means rebating users, rewarding LPs, or powering protocol revenue.

[Source Code](./src/atlas) | [Documentation](https://docs.shmonad.xyz/products/monad-atlas/overview/)

### ShMonad

Stake MON, get shMON—the liquid staking token that keeps earning + MEV rewards while you commit it to programmable policies. One token secures the network and backs your favourite dApps, all without sacrificing liquidity.

[Source Code](./src/shmonad) | [Documentation](https://docs.shmonad.xyz/products/shmonad/overview/)

### Task Manager

An on-chain "cron" that lets anyone schedule execution for a future block and guarantees it executes, paid for with committed shMON or MON. No off-chain bots, no forgotten claims—just a single call to set it and forget it.

[Source Code](./src/task-manager) | [Documentation](https://docs.shmonad.xyz/products/task-manager/overview/)

### Paymaster

A ready-made ERC-4337 bundler that batches UserOps and fronts gas via a shMON-funded Paymaster. The bundler handles Monad's async quirks and gets your transactions on-chain.

[Source Code](./src/paymaster) | [Documentation](https://docs.shmonad.xyz/products/shbundler-4337/paymaster/)

### Gas Relay

A module that enables seamless, gas-less UX for dApps, powered by ShMonad. Users sign with their regular wallet to "log in" to the dApp and then interact through an expendable session key while the dApp silently handles gas payments. Helper functions for the Task Manager have also been included.

Key features:
- No user gas pop-ups - improves onboarding and reduces drop-off
- Policy-driven security via ShMonad commitments
- dApps can receive MON from Users, convert it into shMON, commit the shMON to themselves, and then give the committed shMON back to the User - all without requiring an extra transaction
- dApps can reference the `_abstractedMsgSender()` to get the session key's underlying owner - Users no longer need to transfer their inventory to a dApp-specific embedded wallet 
- Composable with Atlas MEV framework and EVM-compatible contracts

[Source Code](./src/common/relay) | [Module Documentation](./src/common/relay/README.md)

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Make

### Quick Start

```shell
# Install dependencies
$ make install

# Build the project
$ make build

# Run tests
$ make test
```

### Available Commands

```shell
# Clean, install dependencies, build and test
$ make all

# Run tests with gas reporting
$ make test-gas

# Format code
$ make format

# Generate gas snapshots
$ make snapshot

# Start local node
$ make anvil

# Fork a specific network for testing
$ make fork-anvil NETWORK=monad-testnet

# Check contract sizes
$ make size
```

### Deployment

To deploy contracts:

1. Set environment variables:
```shell
MONAD_TESTNET_RPC_URL=<your_rpc_url>
```

## Documentation

For full documentation, visit [docs.shmonad.xyz](https://docs.shmonad.xyz/).
