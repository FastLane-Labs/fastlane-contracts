//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { AddressHub } from "../../../src/common/AddressHub.sol";

contract MockUpgradedAddressHub is AddressHub {
    // Only initializeable if this is at max the 2nd upgrade
    function initialize2() public reinitializer(2) {
        // Upgrade should keep existing address pointers and add this new one
        S_labels[69] = "newSpecialAddress";
        S_pointers[69] = address(0x12345);
    }

    function newSpecialAddress() external view returns (address) {
        return S_pointers[69];
    }
}
