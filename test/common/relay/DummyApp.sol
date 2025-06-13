// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { GasRelayWithScheduling } from "../../../src/common/relay/GasRelayWithScheduling.sol";

contract DummyApp is GasRelayWithScheduling {
    uint256 minTargetBlockDistance = 6;
    uint256 maxTargetBlockDistance = 24;

    event MethodCalled(address caller, string method, uint256 value);

    constructor() GasRelayWithScheduling(500_000, 16, 2, 100_000, 100_000) { }

    function begin(uint256 value, bool reschedule) public payable GasAbstracted {
        emit MethodCalled(_abstractedMsgSender(), "begin", value);
        _scheduleCallback(
            abi.encodeCall(DummyApp.followUp, (value, reschedule)),
            270_000,
            block.number + minTargetBlockDistance,
            block.number + maxTargetBlockDistance,
            true
        );
    }

    function followUp(uint256 value, bool reschedule) external GasAbstracted {
        // NOTE: Calldata must match perfectly during reschedule for _abstractedMsgSender() to work
        emit MethodCalled(_abstractedMsgSender(), "followUp", value);
        if (reschedule) {
            _scheduleCallback(
                abi.encodeCall(DummyApp.followUp, (value, reschedule)),
                270_000,
                block.number + minTargetBlockDistance,
                block.number + maxTargetBlockDistance,
                true
            );
        }
    }
}
