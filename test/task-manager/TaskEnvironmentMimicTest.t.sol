// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TaskEnvironmentMimic } from "../../src/task-manager/common/EnvironmentMimic.sol";
import { TaskFactory } from "../../src/task-manager/core/Factory.sol";

bytes32 constant ARG_CHECK_A = keccak256("moose stuff A");
bytes32 constant ARG_CHECK_B = keccak256("moose stuff B");
bytes4 constant ARG_CHECK_C = bytes4(0x33333333);
uint128 constant ARG_CHECK_D = uint128(type(uint128).max/2);


contract LightTaskManager is TaskFactory, Test {
    address public taskLock;
    uint256 public taskIndex;
    address[] public tasksToCall;
    uint256 private nonce;

    function createTask(address implementation, bytes calldata taskData) public {
        if (taskLock != address(0)) {
            console.log("ERR - LOCKED1");
            return;
        }
        // Use internal function directly since we are the task manager
        bytes32 salt = _computeSalt(msg.sender, ++nonce, implementation);
        bytes memory creationCode = _getMimicCreationCode(implementation, address(this), taskData);
        
        address environment;
        assembly {
            environment := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(environment != address(0), "Factory: deployment failed");
        
        emit ExecutionEnvironmentCreated(msg.sender, environment, implementation, nonce);
        tasksToCall.push(environment);
    }

    function executeTask() public {
        uint256 _i = taskIndex;
        if (_i >= tasksToCall.length) {
            console.log("ERR - NO TASK0");
            return;
        }
        address _task = tasksToCall[_i];
        if (_task == address(0)) {
            console.log("ERR - NO TASK1");
            return;
        }
        if (taskLock != address(0)) {
            console.log("ERR - LOCKED1");
            return;
        }
        unchecked { ++taskIndex; }

        taskLock = _task;
        (bool success, ) = _task.call("a");
        assert(success);
        taskLock = address(0);
    }

    function rescheduleTask() public {
        if (taskLock != msg.sender) {
            console.log("ERR - TASK_MUST_RESCHEDULE");
            return;
        }
        tasksToCall.push(address(msg.sender));
    }

}

interface ILightTaskManager {
    function rescheduleTask() external; 
}

contract Moose is Test {
    uint256 public nonce;

    modifier repeatedTask(uint256 iterations) {
        _;
        if (++nonce < iterations) {
            ILightTaskManager(msg.sender).rescheduleTask();
        }
    }

    function repeatMooseStuff(bytes32[] calldata stuffs) repeatedTask(stuffs.length) external {
        console.log("received:");
        console.logBytes32(stuffs[nonce]);
    }

    function doMooseStuff(bytes32 someStuff, bytes32 otherStuff, bytes4 aThirdThing) external {
        if (someStuff == ARG_CHECK_A && otherStuff == ARG_CHECK_B && aThirdThing == ARG_CHECK_C) {
            nonce++;
            console.log("*Success* WITH long Mooses!");
            // console.log("-");
            // console.logBytes(msg.data);
        } else {
            console.log("_Failure_ WITH long Mooses");
            console.log("-");
            console.logBytes(msg.data);
            console.log("-");
        }
    }

    function doMooseStuffMedium(bytes32 someStuff, bytes4 aThirdThing) external {
        if (someStuff == ARG_CHECK_A && aThirdThing == ARG_CHECK_C) {
            nonce++;
            console.log("*Success* WITH medium Mooses!");
            // console.log("-");
            // console.logBytes(msg.data);
        } else {
            console.log("_Failure_ WITH medium Mooses");
            console.log("-");
            console.logBytes(msg.data);
            console.log("-");
        }
    }

    function doShortMooseStuff(uint128 aMooseNumber) external {
        if (aMooseNumber == ARG_CHECK_D) {
            nonce++;
            console.log("*Success* WITH short Mooses!");
            // console.logBytes(msg.data);
            // console.log("-");
        } else {
            console.log("_Failure_ WITH short Mooses");
            console.logBytes(msg.data);
            console.log("-");
        }
    }

    fallback() external payable {
        console.log("_Failure_ with=OUT= Mooses - fallback");
        console.log("-");
        console.logBytes(msg.data);
        console.log("-");
        for (uint256 i; i < msg.data.length; i += 32) {
            bytes32 word = bytes32(msg.data[i:i+32]);
            console.logBytes32(word);
        }
    }
    receive() external payable { 
        console.log("_Failure_ with=OUT= Mooses - receive");
        console.log("-");
        console.log("no msg data received");
    }
}

contract TaskEnvironmentMimicTest is Test {
    bytes internal creationCode;
    // Address placeholders without PUSH20 opcode
    bytes internal constant IMPLEMENTATION_PLACEHOLDER = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    bytes internal constant TASK_MANAGER_PLACEHOLDER = hex"cccccccccccccccccccccccccccccccccccccccc";
    bytes internal constant TASK_DATA_PLACEHOLDER = hex"2222222222222222222222222222222222222222222222222222222222222222";
    bytes1 internal constant PUSH20 = 0x73;
    bytes1 internal constant PUSH32 = 0x7f;  // PUSH32 opcode
    bytes2 internal constant PUSH1_32 = hex"6020";  // PUSH1 0x20

    struct Offsets {
        uint256 implementation;
        uint256 taskManager;
        uint256 taskData;
        uint256 taskDataLength;
        uint256 calldataLength;
    }

    function setUp() public {
        creationCode = type(TaskEnvironmentMimic).creationCode;
    }

    function testRepeatMooses() public {
        Moose moose = new Moose();
        LightTaskManager taskManager = new LightTaskManager();

        bytes32[] memory stuffs = new bytes32[](5);
        stuffs[0] = bytes32("first stuffs");
        stuffs[1] = bytes32("second stuffs");
        stuffs[2] = bytes32("third stuffs");
        stuffs[3] = bytes32("fourth stuffs");
        stuffs[4] = bytes32("last one");

        bytes memory _args = abi.encodeCall(Moose.repeatMooseStuff, (stuffs));

        taskManager.createTask(address(moose), _args);

        // Five things
        console.log("expect:");
        console.logBytes32(stuffs[0]);
        taskManager.executeTask();
        console.log("-");
        console.log("expect:");
        console.logBytes32(stuffs[1]);
        taskManager.executeTask();
        console.log("-");console.log("expect:");
        console.logBytes32(stuffs[2]);
        taskManager.executeTask();
        console.log("-");console.log("expect:");
        console.logBytes32(stuffs[3]);
        taskManager.executeTask();
        console.log("-");console.log("expect:");
        console.logBytes32(stuffs[4]);
        taskManager.executeTask();
        console.log("-");
        console.log("next one should should give ERR - NO TASK0");
        taskManager.executeTask();
    }

    function testMooses() public {
        Moose moose = new Moose();
        bool success;
        bytes32 _salt = keccak256(abi.encodePacked("Moose Test"));

        bytes memory _args1 = abi.encodeCall(Moose.doMooseStuff, (ARG_CHECK_A, ARG_CHECK_B, ARG_CHECK_C));
        bytes memory _creationCode1 = _getMimicCreationCode(address(moose), address(this), _args1);

        address _mooseMimic1;
        assembly {
            _mooseMimic1 := create2(0, add(_creationCode1, 32), mload(_creationCode1), _salt)
        }

        (success, ) = _mooseMimic1.call("a");
        assert(success);

        bytes memory _args2 = abi.encodeCall(Moose.doMooseStuffMedium, (ARG_CHECK_A, ARG_CHECK_C));
        
        bytes memory _creationCode2 = _getMimicCreationCode(address(moose), address(this), _args2);

        address _mooseMimic2;
        assembly {
            _mooseMimic2 := create2(0, add(_creationCode2, 32), mload(_creationCode2), _salt)
        }

        (success, ) = _mooseMimic2.call("a");
        assert(success);

        bytes memory _args3 = abi.encodeCall(Moose.doShortMooseStuff, (ARG_CHECK_D));
        
        bytes memory _creationCode3 = _getMimicCreationCode(address(moose), address(this), _args3);

        address _mooseMimic3;
        assembly {
            _mooseMimic3 := create2(0, add(_creationCode3, 32), mload(_creationCode3), _salt)
        }

        (success, ) = _mooseMimic3.call("a");
        assert(success);
    }

    function testLongMooses() public {
        Moose moose = new Moose();
        bytes32 _salt = keccak256(abi.encodePacked("Moose Test"));

        console.log("cccccccccccccccccccccccccccccccccccccccc =", address(this));
        console.log("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa =", address(moose));
        console.log("---");

        bytes memory _args = abi.encodeCall(Moose.doMooseStuff, (ARG_CHECK_A, ARG_CHECK_B, ARG_CHECK_C));
        bytes memory _creationCode = _getMimicCreationCode(address(moose), address(this), _args);

        
        //console.logBytes(_args);
        //console.log("-");
        console.logBytes(type(TaskEnvironmentMimic).creationCode);
        console.log("---");
        console.logBytes(_creationCode);
        console.log("-");
        console.logBytes(_args);
        console.log("-");
        //console.logBytes32(_printByte);
        //console.log("-");
        //console.logUint(uint256(_printByte));
        //console.logBytes(_args);
        
        address _mooseMimic;
        assembly {
            _mooseMimic := create2(0, add(_creationCode, 32), mload(_creationCode), _salt)
        }

        console.log("-");
        console.logAddress(_mooseMimic);

        (bool success, ) = _mooseMimic.call("a");
        assert(success);
    }

    function testMediumMooses() public {
        Moose moose = new Moose();
        bytes32 _salt = keccak256(abi.encodePacked("Moose Test"));

        console.log("cccccccccccccccccccccccccccccccccccccccc =", address(this));
        console.log("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa =", address(moose));
        console.log("---");

        //console.logBytes(type(TaskEnvironmentMimic).creationCode);
        //console.log("---");
        bytes memory _args = abi.encodeCall(Moose.doMooseStuffMedium, (ARG_CHECK_A, ARG_CHECK_C));
        
        bytes memory _creationCode = _getMimicCreationCode(address(moose), address(this), _args);

        //console.logBytes(_args);
        //console.log("-");
        console.log("template:");
        console.logBytes(type(TaskEnvironmentMimic).creationCode);
        console.log("---");
        console.log("creationCode:");
        console.logBytes(_creationCode);
        console.log("-");
        console.log("args:");
        console.logBytes(_args);
        console.log("-");
        //console.logBytes(_args);

        
        address _mooseMimic;
        assembly {
            _mooseMimic := create2(0, add(_creationCode, 32), mload(_creationCode), _salt)
        }

        //console.log("-");
        //console.logAddress(_mooseMimic);

        (bool success, ) = _mooseMimic.call("a");
        assert(success);
    }

    function testShortMooses() public {
        Moose moose = new Moose();
        bytes32 _salt = keccak256(abi.encodePacked("Moose Test"));

        console.log("cccccccccccccccccccccccccccccccccccccccc =", address(this));
        console.log("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa =", address(moose));
        console.log("---");
        
        bytes memory _args2 = abi.encodeCall(Moose.doShortMooseStuff, (ARG_CHECK_D));
        
        bytes memory _creationCode2 = _getMimicCreationCode(address(moose), address(this), _args2);

        console.logBytes(type(TaskEnvironmentMimic).creationCode);
        console.log("---");
        console.logBytes(_creationCode2);
        console.log("-");
        console.logBytes(_args2);
        console.log("-");

        address _mooseMimic2;
        assembly {
            _mooseMimic2 := create2(0, add(_creationCode2, 32), mload(_creationCode2), _salt)
        }
        (bool success, ) = _mooseMimic2.call("a");
        assert(success);
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

            for { let srcOffset := 0} lt(srcOffset, srcLength) { } {
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
            mstore(ptr, 
                or(shl(64, implementation), 
            //  0x61100073aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa5af4005b63027307
                0x6110007300000000000000000000000000000000000000005af4005b63027307))
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

            //                 x = runtimeLength - 0xf  
            //                                      c = task manager        
            //                                                           y = runtimeLength - 0x1f
            //                    0x361561xxxx5773cccccccccccccccccccccccccccccccccccccccc330361yyyy
            mstore(add(code, 50), or(
                or(
                    0x3615610000577300000000000000000000000000000000000000003303610000,
                    sub(runtimeLength, 0x1f)),
                or(
                    shl(40, taskManager),
                    shl(216, sub(runtimeLength, 0xf))
                )
            ))

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
            let codeStart := add(code, 32)   // Need a mask bc we are playing a bit loose with the memory                       
            mstore(codeStart, or(           //                 <- init code | runtime code ->
                and(mload(codeStart), 0x000000000000000000000000000000000000ffffffffffffffffffffffffffff), 
                or(
                0x60808060405261000090816100128239f3fe0000000000000000000000000000,
                shl(184, runtimeLength)
            )))

            // WRAPPING UP
            // Store the length of the actual bytes array
            mstore(code, sub(ptr, add(code, 0x20)))

            // Gotta do free mem pointer since internal func
            mstore(0x40, add(ptr, 0x40))
        }

        return code;
    }
} 