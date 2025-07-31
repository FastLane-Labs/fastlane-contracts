// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// For any shared test constants (not specific to a protocol's setup)
contract TestConstants {
    // Monad Testnet Constants
    uint256 internal constant BLOCKS_PER_DAY = 172_800; // 0.5s per block = 172_800 blocks per day

    // AddressHub
    address internal constant TESTNET_ADDRESS_HUB = 0xC9f0cDE8316AbC5Efc8C3f5A6b571e815C021B51;

    // SHMONAD
    address internal constant TESTNET_SHMONAD_PROXY_ADMIN = 0x0f8361B0C2F9C23e6e9BBA54FF01084596b38AcA;
    address internal constant TESTNET_FASTLANE_DEPLOYER = 0x78C5d8DF575098a97A3bD1f8DCCEb22D71F3a474; // fastlane
        // deployer EOA

    address internal constant TESTNET_TASK_MANAGER_PROXY_ADMIN = 0x86780dA77e5c58f5DD3e16f58281052860f9136b;
    address internal constant TESTNET_PAYMASTER_PROXY_ADMIN = 0xc8b98327453dF25003829f220261086F39eB8899;
    address internal constant TESTNET_RPC_POLICY_PROXY_ADMIN = 0x74B1EEf0BaFA7589a1FEF3ff59996667CFCFb511;

    // Paymaster Constants
    address internal constant MONAD_TESTNET_ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant MONAD_TESTNET_ENTRY_POINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    // networks
}
