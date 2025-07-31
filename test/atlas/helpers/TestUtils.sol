// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library TestUtils {
    // String <> uint32 binary Converter Utility
    function uint32ToBinaryString(uint32 n) public pure returns (string memory) {
        uint256 newN = uint256(n);
        // revert on out of range input
        require(newN < 4_294_967_296, "n too large");

        bytes memory output = new bytes(32);

        for (uint256 i = 0; i < 32; i++) {
            if (newN == 0) {
                // Now that we've filled in the last 1, fill rest of 0s in
                for (; i < 32; i++) {
                    output[31 - i] = bytes1("0");
                }
                break;
            }
            output[31 - i] = (newN % 2 == 1) ? bytes1("1") : bytes1("0");
            newN /= 2;
        }
        return string(output);
    }

    // String <> uint256 binary Converter Utility
    function uint256ToBinaryString(uint256 n) public pure returns (string memory) {
        bytes memory output = new bytes(256);

        for (uint256 i = 0; i < 256; i++) {
            if (n == 0) {
                // Now that we've filled in the last 1, fill rest of 0s in
                for (; i < 256; i++) {
                    output[255 - i] = bytes1("0");
                }
                break;
            }
            output[255 - i] = (n % 2 == 1) ? bytes1("1") : bytes1("0");
            n /= 2;
        }
        return string(output);
    }
}
