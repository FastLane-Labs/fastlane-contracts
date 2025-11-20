//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { PolicyAccount, CommittedData } from "../Types.sol";
import { ZERO } from "../Constants.sol";

/// @title HoldsLib
/// @notice Library for shMONAD's Holds functionality implemented using transient storage
library HoldsLib {
    error InsufficientCommittedForHold(uint256 committed, uint256 holdRequested);

    function hold(PolicyAccount memory pAcc, CommittedData storage committedData, uint256 amount) internal {
        bytes32 slot = _holdKey(pAcc);
        amount += _getHoldAmount(slot);
        uint256 committed = committedData.committed;

        require(committed >= amount, InsufficientCommittedForHold(committed, amount));

        _setHoldAmount(slot, amount);
    }

    // Use amount = type(uint256).max to skip the slot read, and release hold entirely.
    function release(PolicyAccount memory pAcc, uint256 amount) internal {
        bytes32 slot = _holdKey(pAcc);

        if (amount == type(uint256).max) {
            // Set hold to 0
            _setHoldAmount(slot, ZERO);
        } else {
            // Decrease hold by amount (floor is 0)
            uint256 currentHold = _getHoldAmount(slot);
            currentHold = currentHold > amount ? currentHold - amount : ZERO;
            _setHoldAmount(slot, currentHold);
        }
    }

    function getHoldAmount(PolicyAccount memory pAcc) internal view returns (uint256 amount) {
        bytes32 slot = _holdKey(pAcc);
        return _getHoldAmount(slot);
    }

    function _holdKey(PolicyAccount memory pAcc) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(pAcc.account)) << 64) | uint256(pAcc.policyID));
    }

    function _getHoldAmount(bytes32 slot) internal view returns (uint256 amount) {
        assembly {
            amount := tload(slot)
        }
    }

    function _setHoldAmount(bytes32 slot, uint256 amount) internal {
        assembly {
            tstore(slot, amount)
        }
    }
}
