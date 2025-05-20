// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { DummyGasRelay } from "./DummyGasRelay.sol";

// A contract that cannot receive ETH for testing the H-1 fix
contract NonPayableContract {
// This contract has no fallback or receive function, making it unable to accept ETH
}

// A simple contract that attempts to exploit reentrancy
contract SimpleReentrancyAttack {
    function callSender(bytes calldata data) public {
        (bool success,) = msg.sender.call(data);
        require(success, "ReentrancyAttack: failed call");
    }
}

// A custom attack contract to test reentrancy for our specific use case
contract GasRelayAttack is SimpleReentrancyAttack {
    DummyGasRelay public target;
    bool public attemptedReentrancy;

    // Track which function was called and in what order
    uint256 public callCount;
    string[] public callHistory;

    constructor(address _target) {
        target = DummyGasRelay(_target);
    }

    // Function to reset state for a new test
    function reset() external {
        attemptedReentrancy = false;
        callCount = 0;
        delete callHistory;
    }

    // Function to trigger reentrancy attempt by calling updateSessionKey with itself as the session key
    function triggerReentrancy() external {
        callCount = 0;
        delete callHistory;
        // Call updateSessionKey with this contract as the session key
        // This will cause ETH to be sent to this contract, triggering the receive function
        target.updateSessionKey{ value: 0.5 ether }(address(this), block.number + 1000);
    }

    // Try reentrancy through replenishGasBalance
    function triggerReentrancyViaReplenish() external {
        callCount = 0;
        delete callHistory;
        // First register this contract as a session key
        target.updateSessionKey{ value: 0.1 ether }(address(this), block.number + 1000);
        // Then call replenishGasBalance to trigger potential reentrancy
        target.replenishGasBalance{ value: 0.5 ether }();
    }

    // Will be called when receiving ETH, which triggers a reentrancy attempt
    receive() external payable {
        callHistory.push(string(abi.encodePacked("receive_", callCount)));
        callCount++;

        if (!attemptedReentrancy) {
            attemptedReentrancy = true;

            // Try multiple reentrant attack vectors
            try target.replenishGasBalance{ value: 0.1 ether }() {
                callHistory.push("replenishGasBalance_succeeded");
            } catch {
                callHistory.push("replenishGasBalance_failed");
            }

            try target.updateSessionKey{ value: 0.1 ether }(address(this), block.number + 2000) {
                callHistory.push("updateSessionKey_succeeded");
            } catch {
                callHistory.push("updateSessionKey_failed");
            }
        }
    }

    // Helper to get the call history
    function getCallHistory() external view returns (string[] memory) {
        return callHistory;
    }
}
