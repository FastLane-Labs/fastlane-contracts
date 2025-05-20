// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Size } from "../types/TaskTypes.sol";

/// @title TaskBits
/// @notice Library for packing task information into a single bytes32
/// @dev Layout: [environment (20 bytes)][initBlock (8 bytes)][initIndex (2 bytes)][size (1 byte)][cancelled (1 byte)]
library TaskBits {
    /// @notice Pack task information into bytes32
    /// @param environment The address of the execution environment
    /// @param initBlock The initial block number
    /// @param initIndex The index in the block
    /// @param size The task size category
    /// @param cancelled Whether the task is cancelled
    /// @return packedTask The packed task information
    function pack(
        address environment,
        uint64 initBlock,
        uint16 initIndex,
        Size size,
        bool cancelled
    )
        internal
        pure
        returns (bytes32 packedTask)
    {
        packedTask = bytes32(
            uint256(uint160(environment)) | (uint256(initBlock) << 160) | (uint256(initIndex) << 224)
                | (uint256(size) << 240) | (uint256(cancelled ? 1 : 0) << 248)
        );
    }

    /// @notice Unpack task information from bytes32
    /// @param packedTask The packed task information
    /// @return environment The execution environment address
    /// @return initBlock The initial block number
    /// @return initIndex The index in the block
    /// @return size The task size category
    /// @return cancelled Whether the task is cancelled
    function unpack(bytes32 packedTask)
        internal
        pure
        returns (address environment, uint64 initBlock, uint16 initIndex, Size size, bool cancelled)
    {
        environment = address(uint160(uint256(packedTask)));
        initBlock = uint64(uint256(packedTask) >> 160);
        initIndex = uint16(uint256(packedTask) >> 224);
        size = Size(uint8(uint256(packedTask) >> 240));
        cancelled = uint8(uint256(packedTask) >> 248) == 1;
    }

    /// @notice Get the environment address from packed task info
    /// @param packedTask The packed task information
    /// @return environment The execution environment address
    function getMimicAddress(bytes32 packedTask) internal pure returns (address environment) {
        environment = address(uint160(uint256(packedTask)));
    }

    /// @notice Get the task size from packed task info
    /// @param packedTask The packed task information
    /// @return size The task size category
    function getSize(bytes32 packedTask) internal pure returns (Size size) {
        size = Size(uint8(uint256(packedTask) >> 240));
    }
}
