// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { GasAccLib, GasLedger, BorrowsLedger } from "../../../src/atlas/libraries/GasAccLib.sol";
import { IL2GasCalculator } from "../../../src/atlas/interfaces/IL2GasCalculator.sol";

// Very basic MockL2GasCalculator for testing, just returns 5x what the default (address(0)) gas calculator would.
contract MockL2GasCalculator is IL2GasCalculator {
    // Should return 5x the default calldata gas
    function getCalldataGas(uint256 calldataLength) external view returns (uint256 calldataGas) {
        return calldataLength * 8 * 5; // 8 is the gas per calldata byte
    }

    // Should return 5x the default initial gas used
    function initialGasUsed(uint256 calldataLength) external view returns (uint256 gasUsed) {
        return calldataLength * 8 * 5; // 8 is the gas per calldata byte
    }
}
