//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { ShMonad } from "../../../src/shmonad/ShMonad.sol";

/**
 * @title ShMonadV2
 * @notice Modified ShMonad implementation for testing upgrades without reinitializer changes
 * @dev Demonstrates upgrading without bumping the reinitializer version
 */
contract ShMonadV2 is ShMonad {
    uint256 public newFeature;

    constructor() { }

    // We can add new functions without changing the reinitializer
    function setNewFeature(uint256 _value) external onlyOwner {
        newFeature = _value;
    }

    function getNewFeature() external view returns (uint256) {
        return newFeature;
    }

    function crankValidators() public returns (bool) {
        return _crankValidators();
    }
}
