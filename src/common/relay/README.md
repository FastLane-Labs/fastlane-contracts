# Gas Relay Module  

> **Seamless gas‑less UX for your dApp, powered by ShMonad & the Atlas Task Manager**  

---

## 📚 Overview
The **Gas Relay** module lets you delegate transaction fees to a *session key* that is automatically topped‑up with **MON** (the Monad native token) bonded inside **ShMonad**. End‑users sign with their regular wallet once, then interact through an expendable session key while your dApp silently handles gas.

* **No user gas pop‑ups** – reduce drop‑off and improve onboarding.
* **Policy‑driven security** – every relay is backed by a ShMonad commitment policy that you control.
* **Composable** – integrates with the **Atlas** MEV framework and any EVM‑compatible contract.
* **Battle‑tested** – used in the *Task Manager* contracts that secure Monad's LST liquidity and auctions.

---

## 🗺️ Architecture

```
User Wallet ─┐                 ┌─────────────────────────────────┐
             │   1. create     │  GasRelayBase (this module)      │
             └─▶ Session Key ─▶│   ‑ maintains key metadata       │
                               │   ‑ funds key from ShMonad       │
Session Key ─┐                 │   ‑ exposes GasAbstracted mod.   │
             │ 2. call dApp    └─────────────────────────────────┘
             ▼
        Your dApp               ┌─────────────────────────────────┐
              ▲ 3. execute      │ Atlas Task Manager              │
              └────────────────▶ │   ‑ bundles residual gas        │
                                 │   ‑ pays credits in shMON       │
                                 └─────────────────────────────────┘
```

---

## 🚀 Quick Start
### Prerequisites

* Solidity ^0.8.28
* Hardhat / Foundry for deployment & tests
* Access to a **ShMonad** instance (mainnet or testnet)

### Installation

#### Option 1: Forge (Recommended)
```bash
# Install Foundry if you haven't already
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Add as a dependency to your Forge project
forge install FastLane-Labs/fastlane-contracts

# Default installs from main branch
# For a specific version/branch:
# forge install monad-labs/task-manager-contracts@<branch-or-tag>

# To update dependencies later
forge update
```

## 🔌 Integration Guide

To implement gas-less transactions in your dApp:

### 1. Inherit from GasRelayBase

Your contract must inherit from `GasRelayBase` to access the gas abstraction functionality:

```solidity
contract MyDApp is GasRelayBase {
    constructor(
        address taskManager,
        address shMonad,
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier
    ) 
        GasRelayBase(taskManager, shMonad, maxExpectedGasUsagePerTx, escrowDuration, targetBalanceMultiplier) 
    {}
    
    // Your contract code...
}
```

### 2. Apply the GasAbstracted modifier

Wrap your public/external functions with the `GasAbstracted` modifier:

```solidity
// Users can call this function via their session key without paying gas
function performAction() external GasAbstracted {
    // Inside this function, msg.sender == session key address
    // But _abstractedMsgSender() == original owner address
    
    address realSender = _abstractedMsgSender();
    
    // Your business logic using the real sender...
}
```

### 3. Gas accounting flow

1. When a session key calls a `GasAbstracted` function, the modifier:
   - Identifies the original owner of the session key
   - Tracks gas consumption during execution
   - Routes surplus gas through the Atlas Task Manager
   - Deducts the gas cost from the owner's bonded shMONAD balance
   - Returns any rewards back to the owner

2. Session key balances are managed by:
   - Initial funding during key creation with `updateSessionKey()`
   - Automatic refilling from the owner's bonded shMONAD when needed
   - Manual top-ups with `replenishGasBalance()`

This approach allows EOAs to function as lightweight session keys while the gas costs are covered by the owner's shMONAD bonds, creating a seamless UX for your users.

---

## 🔑 Core Concepts

| Concept                      | Why it matters                                                                                   | Key functions                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| **Session Key**              | Expendable signer holding enough MON to pay gas. Expires automatically.                          | `updateSessionKey`, `deactivateSessionKey`, `_isSessionKey()` |
| **ShMONAD Policy**           | Bonds user MON into **shMON** shares that can be slashed / withdrawn to keep keys funded.        | `_creditToOwnerAndBond`, `_takeFromOwnerBondedShares`         |
| **Gas Abstraction Modifier** | Wrap any public function to make it gas‑less for users.                                          | `GasAbstracted`                                               |
| **Task Execution Credits**   | Surplus gas is routed through **Atlas Task Manager**; rewards are auto‑bonded back to the owner. | `executeTasks`, `_handleUnusedGas`                            |

---

## 🛠️ Contract Surface (public / external)

| Contract       | Signature                                                            | Purpose                                 |
| -------------- | -------------------------------------------------------------------- | --------------------------------------- |
| `GasRelayBase` | `updateSessionKey(address key, uint256 expiry)`                      | Create / modify session key             |
|                | `replenishGasBalance()`                                              | Top‑up key, bond surplus                |
|                | `deactivateSessionKey(address key)`                                  | Early key removal                       |
|                | `getCurrentSessionKeyData(address owner)`                            | View helper (balances, expiry, targets) |
|                | **Modifiers**: `GasAbstracted`, `CreateOrUpdateSessionKey`, `Locked` | Plug‑in to your functions               |


---

## 🔐 Security Notes

1. **Session Key Limits** – Keys can *only* spend gas; they cannot withdraw bonded funds.
2. **Reentrancy Guards** – `Locked` modifier hardens every external entry point.
3. **Expiration Enforcement** – All logic checks `block.number` < `expiration` before funding or abstraction.
4. **Fail‑Safe Refunds** – If MON transfer to the key fails, the tx reverts with `SessionKeyMonTransferFailed`.

---

## 🧪 Testing

* Foundry test‑suite: `forge test --match-contract GasRelay*`
* Scenario scripts under `test/fuzz` simulate hostile keys & extreme base‑fee spikes.


## 📝 License
BUSL‑1.1 © Fastlane Labs 2025 