# Monad Contracts

FastLane smart contracts on Monad.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Make

### Available Commands

```shell
# Clean, install dependencies, build and test
$ make all

# Build the project (with IR-based codegen)
$ make build

# Run tests with detailed output
$ make test

# Run tests with gas reporting
$ make test-gas

# Format code
$ make format

# Generate gas snapshots
$ make snapshot

# Start local node
$ make anvil

# Check contract sizes
$ make size

# Update dependencies
$ make update
```

### Deployment

To deploy contracts:

1. Set environment variables:
```shell
NETWORK=<your_rpc_url>
PRIVATE_KEY=<your_private_key>
```

2. Run:
```shell
$ make deploy
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
