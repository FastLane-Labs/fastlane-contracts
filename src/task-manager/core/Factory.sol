// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { TaskExecutionEnvironment } from "../common/ExecutionEnvironment.sol";

/// @title TaskFactory
/// @notice Factory for creating task execution environments
/// @dev Uses optimized creation code pattern for gas efficiency
abstract contract TaskFactory {
    /// @notice The default implementation contract
    address public immutable EXECUTION_ENV_TEMPLATE;

    /// @notice Base salt for CREATE2 deployment
    bytes32 private immutable _FACTORY_BASE_SALT;

    /// @notice Emitted when a new environment is created
    /// @param owner The owner of the environment
    /// @param environment The environment address
    /// @param implementation The implementation being used
    /// @param taskNonce The task nonce used for this environment
    event ExecutionEnvironmentCreated(
        address indexed owner, address indexed environment, address implementation, uint256 taskNonce
    );

    constructor() {
        // Deploy default implementation and reference task manager
        EXECUTION_ENV_TEMPLATE = address(new TaskExecutionEnvironment(address(this)));

        // Generate base salt from chain ID and contract address
        _FACTORY_BASE_SALT = keccak256(abi.encodePacked(block.chainid, address(this)));
    }

    /// @notice Gets or creates an environment for a given owner and task nonce
    /// @param owner The owner of the environment
    /// @param taskNonce The task nonce for this environment
    /// @param implementation Optional custom implementation (use address(0) for default)
    /// @param taskData The task data to embed in code
    /// @return environment The environment address
    function _createEnvironment(
        address owner,
        uint256 taskNonce,
        address implementation,
        bytes memory taskData
    )
        internal
        returns (address environment)
    {
        require(owner != address(0), "Factory: zero owner");

        // Use default implementation if none specified
        address _implementation = implementation == address(0) ? EXECUTION_ENV_TEMPLATE : implementation;

        // Compute deterministic salt using only owner and taskNonce
        bytes32 salt = _computeSalt(owner, taskNonce, _implementation);

        // Get the creation code with taskData for address computation
        bytes memory creationCode = _getMimicCreationCode(_implementation, address(this), taskData);
        bytes32 initCodeHash = keccak256(creationCode);

        // Compute the environment address using the same init code hash
        environment =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));

        // Deploy if not already deployed
        if (environment.code.length == 0) {
            assembly {
                environment := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            }
            emit ExecutionEnvironmentCreated(owner, environment, _implementation, taskNonce);
        }
    }

    function _computeSalt(address owner, uint256 taskNonce, address implementation) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_FACTORY_BASE_SALT, owner, taskNonce, implementation));
    }

    /// @notice Generates creation code with injected parameters
    /// @dev Uses hardcoded offsets for maximum efficiency
    function _getMimicCreationCode(
        address implementation,
        address taskManager,
        bytes memory data
    )
        internal
        pure
        returns (bytes memory code)
    {
        assembly {
            // Assign a slot for the returned byte array
            code := mload(0x40)

            // ASSIGN POINTER
            //
            // + 32 length of code bytearray
            //
            // + 18 Init portion will be 18 bytes but we fill that in last
            //
            // + 32 beginning of runtime code:
            //
            // Runtime code starts off with:
            //          0x361561xxxx5773cccccccccccccccccccccccccccccccccccccccc330361yyyy
            //                 x = runtimeLength - 0xf
            //                                      c = task manager
            //                                                           y = runtimeLength - 0x1f
            //
            // But we need to know the runtime length to do that, so we'll come back to it later...
            //
            // for now, let's start with the second runtime word, which begins with 0x577f

            mstore(add(code, 82), 0x577f000000000000000000000000000000000000000000000000000000000000)

            // Set pointer
            let ptr := add(code, 84)

            // Add in the args
            // Handle the args length
            let srcPtr := add(data, 32)
            let srcLength := mload(data)
            let buffer := 0x6110000000000000000000000000000000000000000000000000000000000000

            for { let srcOffset := 0 } lt(srcOffset, srcLength) { } {
                // Get the next 32 byte word
                let nextWord := mload(add(srcPtr, srcOffset))

                // Increment offset
                srcOffset := add(srcOffset, 32)

                // new offset >= length
                if iszero(lt(srcOffset, srcLength)) {
                    // Clean the word if there's a surplus
                    if gt(srcOffset, srcLength) {
                        let dif := sub(srcOffset, srcLength)
                        nextWord := shr(mul(dif, 8), nextWord)
                        nextWord := shl(mul(dif, 8), nextWord)
                    }

                    // Store the word
                    mstore(ptr, nextWord)

                    // handle the exit buffer
                    //                     buffer = 0x6110000000000000000000000000000000000000000000000000000000000000
                    mstore(add(ptr, 32), or(buffer, 0x000000525f807f00000000000000000000000000000000000000000000000000))
                    ptr := add(ptr, 39)

                    // make like a tree
                    break
                }

                // Store the word
                mstore(ptr, nextWord)

                // Store the buffer
                mstore(add(ptr, 32), or(buffer, 0x000000527f000000000000000000000000000000000000000000000000000000))
                buffer := add(buffer, 0x0000200000000000000000000000000000000000000000000000000000000000)

                // Increment pointer
                ptr := add(ptr, 37)
            }

            // store the calldata's length
            // replacing 0x1111111111111111111111111111111111111111111111111111111111111111
            mstore(ptr, srcLength)
            ptr := add(ptr, 32) // keep at 32 so that offsets dont change

            // store implementation
            mstore(
                ptr,
                or(
                    shl(64, implementation),
                    //  0x61100073aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa5af4005b63027307
                    0x6110007300000000000000000000000000000000000000005af4005b63027307
                )
            )
            ptr := add(ptr, 32)

            // Final piece of runtime code
            mstore(ptr, 0xc3612000526004612000fd5b00fea164736f6c634300081c000a000000000000)
            ptr := add(ptr, 26)

            // Now we know the runtime length so we can fill in the beginning of the runtime:
            // NOTE: We don't change pointer anymore because we need it to keep track of final memory allocations
            // runtimeLength = total array length - 32 (stored length) - 18 (init length)
            let runtimeLength := sub(sub(ptr, code), 50)

            // NOTE: We assume that runtimeLength < type(uint16).max or it messes up the bit shifting
            if gt(runtimeLength, 0xffff) {
                mstore(ptr, runtimeLength)
                mstore(0x40, add(ptr, 0x40))
                revert(ptr, 0x20)
            }

            // We can finally return to the first word in the runtime:
            //
            //                 x = runtimeLength - 0xf
            //                                      c = task manager
            //                                                           y = runtimeLength - 0x1f
            //                    0x361561xxxx5773cccccccccccccccccccccccccccccccccccccccc330361yyyy
            mstore(
                add(code, 50),
                or(
                    or(0x3615610000577300000000000000000000000000000000000000003303610000, sub(runtimeLength, 0x1f)),
                    or(shl(40, taskManager), shl(216, sub(runtimeLength, 0xf)))
                )
            )

            // Now handle initcode - be careful not to overwrite existing memory
            // (note that there's a slightly more efficient way to do this part
            // by combining it with the last one - if you have free time and nothing
            // else that's important to work on, please feel free to submit a PR )
            //
            //
            // 0x60808060405261xxxx90816100128239f3fe0000000000000000000000000000
            //          x = runtimeLength            | // 0's get or'd with runtime code
            //                          <- init code | runtime code ->
            //
            let codeStart := add(code, 32)
            // Need a mask bc we are playing a bit loose with the memory
            mstore(
                codeStart,
                or( //                                             <- init code | runtime code ->
                    and(mload(codeStart), 0x000000000000000000000000000000000000ffffffffffffffffffffffffffff),
                    or(0x60808060405261000090816100128239f3fe0000000000000000000000000000, shl(184, runtimeLength))
                )
            )

            // WRAPPING UP
            // Store the length of the actual bytes array
            mstore(code, sub(ptr, add(code, 0x20)))

            // Gotta do free mem pointer since internal func
            mstore(0x40, add(ptr, 0x40))
        }
        return code;
    }

    /// @notice Returns the environment address for the given owner, nonce, implementation, and task data.
    ///         Does not attempt to create the environment – if it isn't deployed, returns address(0).
    /// @param owner The owner of the environment.
    /// @param taskNonce The task nonce for this environment.
    /// @param implementation Optional custom implementation (use address(0) for default).
    /// @param taskData The task data embedded in code.
    /// @return environment The deployed environment address or address(0) if not deployed.
    function _getEnvironment(
        address owner,
        uint256 taskNonce,
        address implementation,
        bytes memory taskData
    )
        internal
        view
        returns (address environment)
    {
        // Use default implementation if none specified.
        address _implementation = implementation == address(0) ? EXECUTION_ENV_TEMPLATE : implementation;

        // Compute deterministic salt using only owner and taskNonce.
        bytes32 salt = _computeSalt(owner, taskNonce, _implementation);

        // Get the creation code with taskData for address computation.
        bytes memory creationCode = _getMimicCreationCode(_implementation, address(this), taskData);
        bytes32 initCodeHash = keccak256(creationCode);

        // Compute the environment address as it would be deployed via CREATE2.
        environment =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
