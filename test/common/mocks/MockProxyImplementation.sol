// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

/**
 * @title MockProxyImplementation
 * @notice Generic mock implementation for proxy deployment
 * @dev This contract serves as a temporary implementation for proxies that will be immediately upgraded.
 *      Since it's replaced right away, we don't need specific initialize functions.
 */
contract MockProxyImplementation is OwnableUpgradeable {
    // Generic fallback to handle any initialize call
    // The proxy will be upgraded to the real implementation immediately after deployment
    fallback() external payable { }
    receive() external payable { }
}
