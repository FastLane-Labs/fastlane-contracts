// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { AtlasBaseTest } from "./base/AtlasBaseTest.t.sol";

import { Base } from "../../src/atlas/common/ExecutionBase.sol";
import { ExecutionPhase } from "../../src/atlas/types/LockTypes.sol";

import { SafetyBits } from "../../src/atlas/libraries/SafetyBits.sol";

import "../../src/atlas/libraries/SafetyBits.sol";

contract ExecutionBaseTest is AtlasBaseTest {
    using SafetyBits for Context;

    MockExecutionEnvironment public mockExecutionEnvironment;
    address dAppControl;
    uint32 callConfig;
    bytes randomData;

    function setUp() public override {
        super.setUp();

        mockExecutionEnvironment = new MockExecutionEnvironment(address(atlas));
        dAppControl = address(0x3333);
        callConfig = 888;
        randomData = "0x1234";
    }

    function test_forward() public {
        ExecutionPhase phase = ExecutionPhase.PreOps;
        (bytes memory firstSet, Context memory _ctx) = forwardGetFirstSet(phase);
        bytes memory secondSet = abi.encodePacked(user, dAppControl, callConfig);

        bytes memory expected = bytes.concat(randomData, firstSet, secondSet);

        bytes memory data = abi.encodeCall(MockExecutionEnvironment.forward, randomData);
        executeForwardCase(phase, "forward", data, _ctx, expected);
    }

    function executeForwardCase(
        ExecutionPhase phase,
        string memory testName,
        bytes memory data,
        Context memory ctx,
        bytes memory expected
    )
        internal
    {
        data = abi.encodePacked(data, ctx.setAndPack(phase));

        // Mimic the Mimic
        data = abi.encodePacked(data, user, dAppControl, callConfig);

        (, bytes memory result) = address(mockExecutionEnvironment).call(data);
        result = abi.decode(result, (bytes));

        assertEq(result, expected, testName);
    }

    function forwardGetFirstSet(ExecutionPhase _phase)
        public
        pure
        returns (bytes memory firstSet, Context memory _ctx)
    {
        _ctx = Context({
            executionEnvironment: address(123),
            userOpHash: bytes32(uint256(456)),
            bundler: address(789),
            solverSuccessful: false,
            solverIndex: 7,
            solverCount: 11,
            phase: uint8(_phase),
            solverOutcome: 2,
            bidFind: true,
            isSimulation: false,
            callDepth: 1,
            dappGasLeft: 0
        });

        firstSet = abi.encodePacked(
            _ctx.bundler,
            _ctx.solverSuccessful,
            _ctx.solverIndex,
            _ctx.solverCount,
            _ctx.phase,
            _ctx.solverOutcome,
            _ctx.bidFind,
            _ctx.isSimulation,
            _ctx.callDepth + 1
        );
    }
}

contract MockExecutionEnvironment is Base {
    constructor(address _atlas) Base(_atlas) { }

    function forward(bytes memory data) external pure returns (bytes memory) {
        return _forward(data);
    }
}