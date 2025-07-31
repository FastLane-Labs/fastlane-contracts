// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

library JsonHelper {
    using stdJson for string;

    /// @notice Return the block number of the last deployment or upgrade, read from `deployments.json`.
    /// @param vm        The Foundry cheatcode interface.
    /// @param isMainnet Pass `true` for mainnet, `false` for testnet.
    /// @return blockNumber The stored block height, used when forking the chain inside tests and scripts.
    function getLastDeployBlock(VmSafe vm, bool isMainnet) internal view returns (uint256) {
        // Get the path to deployments.json
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments.json");

        // Build the full key in the JSON file, based on isMainnet flag
        string memory fullKey = isMainnet ? ".MONAD_MAINNET" : ".MONAD_TESTNET";
        fullKey = string.concat(fullKey, ".LAST_DEPLOY_BLOCK"); // e.g. ".MONAD_TESTNET.LAST_DEPLOY_BLOCK"

        // Read the LAST_DEPLOY_BLOCK from deployments.json
        string memory json = vm.readFile(path);
        return json.readUint(fullKey);
    }

    /// @notice Update the recorded last deploy block if the supplied value is
    ///         newer (greater than or equal to the current value).
    /// @param vm          The Foundry cheatcode interface.
    /// @param isMainnet   Pass `true` for mainnet, `false` for testnet.
    /// @param blockNumber The candidate block height to store.
    function updateLastDeployBlock(VmSafe vm, bool isMainnet, uint256 blockNumber) internal {
        // Get the path to deployments.json
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments.json");

        // Build the full key in the JSON file, based on isMainnet flag
        string memory fullKey = isMainnet ? ".MONAD_MAINNET" : ".MONAD_TESTNET";
        fullKey = string.concat(fullKey, ".LAST_DEPLOY_BLOCK"); // e.g. ".MONAD_TESTNET.LAST_DEPLOY_BLOCK"

        // Read the most recent LAST_DEPLOY_BLOCK
        string memory json = vm.readFile(path);
        uint256 lastDeployBlock = json.readUint(fullKey);

        if (lastDeployBlock > blockNumber) {
            // If the existing block number is greater than the new candidate, do not update
            console.log("Higher LAST_DEPLOY_BLOCK found in deployments.json, no update required.");
            return;
        }

        // Write the block number to the deployments.json file
        vm.writeJson(vm.toString(blockNumber), path, fullKey);

        console.log("Updated LAST_DEPLOY_BLOCK in deployments.json to:", blockNumber);
    }
}
