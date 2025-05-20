// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

contract MockProxyImplementation is OwnableUpgradeable {
    function initialize(address deployer) public {
        // Empty implementation
    }
}
