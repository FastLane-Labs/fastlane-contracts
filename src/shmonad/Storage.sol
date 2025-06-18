//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ShMonadErrors } from "./Errors.sol";
import { ShMonadEvents } from "./Events.sol";
import { Balance, Policy, BondedData, UnbondingData, TopUpData, TopUpSettings, Supply } from "./Types.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";

abstract contract ShMonadStorage is ShMonadErrors, ShMonadEvents, IShMonad {
    address internal constant NATIVE_TOKEN = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    uint256 internal constant EXECUTE_CALL_GAS_RESERVE = 28_000; // TODO calculate this properly
    uint256 internal constant EXECUTE_END_GAS_OFFSET = 25_000;
    uint32 internal constant MIN_TOP_UP_PERIOD_DURATION = 1 days;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint64 internal s_policyCount = 0; // Incremented to create ID for each new policy.

    // ERC20 data
    uint256 internal s_totalSupply; // Total supply of all shMonad (unbonded, bonded, unbonding)
    uint256 internal s_bondedTotalSupply; // Total supply of just bonded shMonad
    mapping(address account => Balance balance) internal s_balances; // Tracks all types and just bonded balances
    mapping(address account => mapping(address spender => uint256)) internal s_allowances;

    // Policy-Account Bonded, Unbonding, and Top-Up data
    mapping(uint64 policyID => mapping(address account => BondedData bondedData)) internal s_bondedData;
    mapping(uint64 policyID => mapping(address account => UnbondingData unbondingData)) internal s_unbondingData;
    mapping(uint64 policyID => mapping(address account => TopUpData topUpData)) internal s_topUpData;
    mapping(uint64 policyID => mapping(address account => TopUpSettings topUpSettings)) internal s_topUpSettings;

    // Policy data
    mapping(uint64 policyID => Policy policy) internal s_policies;
    mapping(uint64 policyID => mapping(address agent => bool)) internal s_isPolicyAgent;
    mapping(uint64 policyID => address[] policyAgents) internal s_policyAgents;

    // NOTE: `initialize()` for Ownable setup defined in ShMonad.sol

    // Added in 1.2
    mapping(address task => bytes32 policyIdUserHash) internal s_userTaskClaims;

    // Added in 1.3
    // NOTE: Move this to replace s_totalSupply / bonded in prod, but keep as separate storage
    // on testnet to prevent disrupting balances.
    Supply internal s_supply;

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    function policyCount() external view returns (uint64) {
        return s_policyCount;
    }

    function getPolicy(uint64 policyID) external view returns (Policy memory) {
        return s_policies[policyID];
    }

    function isPolicyAgent(uint64 policyID, address agent) external view returns (bool) {
        return _isPolicyAgent(policyID, agent);
    }

    function getPolicyAgents(uint64 policyID) external view returns (address[] memory) {
        return s_policyAgents[policyID];
    }

    // --------------------------------------------- //
    //                Internal Functions             //
    // --------------------------------------------- //

    function _isPolicyAgent(uint64 policyID, address agent) internal view returns (bool) {
        return s_isPolicyAgent[policyID][agent];
    }
}
