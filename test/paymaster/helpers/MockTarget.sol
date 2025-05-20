// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract MockTarget {
    uint256 public value;
    uint256 public gasUsed;

    function setValue(uint256 newValue) external returns (uint256) {
        value = newValue;
        gasUsed = gasleft();
        return newValue;
    }

    function revertWithMessage() external pure {
        revert("MockTarget: expected revert");
    }

    function useGas(uint256 iterations) external {
        uint256 initialGas = gasleft();
        uint256 sum;
        for (uint256 i; i < iterations; i++) {
            sum += i;
        }
        gasUsed = initialGas - gasleft();
        value = sum;
    }
}
