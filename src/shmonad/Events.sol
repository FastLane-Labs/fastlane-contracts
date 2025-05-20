//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

abstract contract ShMonadEvents {
    event Bond(uint64 indexed policyID, address indexed account, uint256 amount);
    event Unbond(uint64 indexed policyID, address indexed account, uint256 amount, uint256 expectedUnbondBlock);
    event Claim(uint64 indexed policyID, address indexed account, uint256 amount);
    event AgentTransferFromBonded(uint64 indexed policyID, address indexed from, address indexed to, uint256 amount);
    event AgentTransferToUnbonded(uint64 indexed policyID, address indexed from, address indexed to, uint256 amount);
    event AgentWithdrawFromBonded(uint64 indexed policyID, address indexed from, address indexed to, uint256 amount);
    event AgentBoostYieldFromBonded(uint64 indexed policyID, address indexed from, uint256 amount);
    event AgentExecuteWithSponsor(
        uint64 indexed policyID,
        address indexed payor,
        address indexed agent,
        address recipient,
        uint256 msgValue,
        uint256 gasLimit,
        uint256 actualPayorCost
    );
    event SetTopUp(
        uint64 indexed policyID,
        address indexed account,
        uint128 minBonded,
        uint128 maxTopUpPerPeriod,
        uint32 topUpPeriodDuration
    );
    event CreatePolicy(uint64 indexed policyID, address indexed creator, uint48 escrowDuration);
    event AddPolicyAgent(uint64 indexed policyID, address indexed agent);
    event RemovePolicyAgent(uint64 indexed policyID, address indexed agent);
    event DisablePolicy(uint64 indexed policyID);
    event BoostYield(address indexed sender, uint256 amount, bool sharesBurned);
}
