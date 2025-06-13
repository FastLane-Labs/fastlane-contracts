//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IShMonad } from "../../../shmonad/interfaces/IShMonad.sol";
import { GasRelayConstants } from "./GasRelayConstants.sol";

import { IAddressHub } from "../../IAddressHub.sol";

/// @title RelayNonUpgradeable
/// @notice Helper functions for session key and ShMONAD interactions
/// @dev Contains utility functions for the gas relay system
contract RelayNonUpgradeable is GasRelayConstants {
    /// @notice Policy ID for this contract
    uint64 private immutable _policy_id;

    /// @notice Policy wrapper ERC20 token address
    address private immutable _policy_wrapper;

    /// @notice Maximum expected gas usage per transaction
    uint256 private immutable _max_expected_gas_usage_per_tx;

    /// @notice Multiplier for target balance (1=1x, 2=2x, 4=4x)
    uint256 private immutable _target_balance_multiplier;

    /// @notice Namespace for session key storage
    bytes32 private immutable _session_key_namespace;

    /// @notice Namespace for key owner storage
    bytes32 internal immutable _key_owner_namespace;

    /// @notice Namespace for underlying caller transient storage
    bytes32 internal immutable _underlying_caller_namespace;

    /// @notice Constructor for GasRelayHelper
    /// @param maxExpectedGasUsagePerTx Maximum expected gas per transaction
    /// @param escrowDuration Duration of escrow in blocks
    /// @param targetBalanceMultiplier Multiplier for target balance calculation (1=1x, 2=2x, etc.)
    constructor(uint256 maxExpectedGasUsagePerTx, uint48 escrowDuration, uint256 targetBalanceMultiplier) {
        address _shMonad = IAddressHub(ADDRESS_HUB).shMonad();

        // Create ShMONAD commitment policy for this app
        (uint64 _policyIDLocal, address _policyERC20WrapperLocal) = IShMonad(_shMonad).createPolicy(escrowDuration);
        _policy_id = _policyIDLocal;
        _policy_wrapper = _policyERC20WrapperLocal;

        _max_expected_gas_usage_per_tx = maxExpectedGasUsagePerTx;
        _target_balance_multiplier = targetBalanceMultiplier;

        bool _upgradeable = false;

        // Create storage namespaces
        _session_key_namespace = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encodePacked(
                        "ShMonad GasRelayHelper 1.0",
                        "Session Key Namespace",
                        _upgradeable,
                        address(this),
                        _shMonad,
                        block.chainid
                    )
                ),
                address(this),
                _policyIDLocal
            )
        );
        _key_owner_namespace = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encodePacked(
                        "ShMonad GasRelayHelper 1.0",
                        "Key Owner Namespace",
                        _upgradeable,
                        address(this),
                        _shMonad,
                        block.chainid
                    )
                ),
                address(this),
                _policyIDLocal
            )
        );
        _underlying_caller_namespace = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encodePacked(
                        "ShMonad GasRelayHelper 1.0",
                        "Underlying Caller Transient Namespace",
                        _upgradeable,
                        address(this),
                        _shMonad,
                        block.chainid
                    )
                ),
                address(this),
                _policyIDLocal
            )
        );
    }

    function POLICY_ID() public view override returns (uint64) {
        return _policy_id;
    }

    function POLICY_WRAPPER() public view override returns (address) {
        return _policy_wrapper;
    }

    function _MAX_EXPECTED_GAS_USAGE_PER_TX() internal view override returns (uint256) {
        return _max_expected_gas_usage_per_tx;
    }

    function _TARGET_BALANCE_MULTIPLIER() internal view override returns (uint256) {
        return _target_balance_multiplier;
    }

    function _GAS_USAGE_AND_MULTIPLIER() internal view override returns (uint256, uint256) {
        return (_max_expected_gas_usage_per_tx, _target_balance_multiplier);
    }

    function _SESSION_KEY_NAMESPACE() internal view override returns (bytes32) {
        return _session_key_namespace;
    }

    function _KEY_OWNER_NAMESPACE() internal view override returns (bytes32) {
        return _key_owner_namespace;
    }

    function _UNDERLYING_CALLER_NAMESPACE() internal view override returns (bytes32) {
        return _underlying_caller_namespace;
    }
}
