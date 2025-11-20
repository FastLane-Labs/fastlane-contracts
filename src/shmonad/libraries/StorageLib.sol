//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { CashFlows, StakingEscrow, PendingBoost, Revenue } from "../Types.sol";

/// @title StorageLib
/// @notice Library to ensure we never unnecessarily store zero values in storage, as it then costs 125 000 gas on zero
/// to non-zero writes.
library StorageLib {
    function clear(CashFlows storage ptr) internal {
        ptr.queueForUnstake = 0;
        ptr.queueToStake = 0;
        ptr.alwaysTrue = true; // Avoids storing a zero slot to save gas on future writes
    }

    function clear(StakingEscrow storage ptr) internal {
        ptr.pendingStaking = 0;
        ptr.pendingUnstaking = 0;
        ptr.alwaysTrue = true; // Avoids storing a zero slot to save gas on future writes
    }

    function clear(PendingBoost storage ptr) internal {
        ptr.rewardsPayable = 0;
        ptr.earnedRevenue = 0;
        ptr.alwaysTrue = true; // Avoids storing a zero slot to save gas on future writes
    }

    function clear(Revenue storage ptr) internal {
        ptr.allocatedRevenue = 0;
        ptr.earnedRevenue = 0;
        ptr.alwaysTrue = true; // Avoids storing a zero slot to save gas on future writes
    }
}
