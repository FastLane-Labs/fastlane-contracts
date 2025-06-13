//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IShMonad } from "../../../shmonad/interfaces/IShMonad.sol";
import { IAddressHub } from "../../IAddressHub.sol";

import { GasRelayConstants } from "./GasRelayConstants.sol";

/// @title RelayUpgradeable
/// @notice Helper functions for session key and ShMONAD interactions
/// @dev Contains utility functions for the gas relay system
contract RelayUpgradeable is GasRelayConstants {
    struct PolicyStorage {
        address policyWrapper;
        uint64 policyID;
        uint24 maxExpectedGasUsage; // max = 16,777,216
        uint8 targetBalanceMultiplier; // max = 256
    }

    /// @notice Namespace for session key storage
    bytes32 private immutable _session_key_seed;

    /// @notice Namespace for key owner storage
    bytes32 private immutable _key_owner_seed;

    /// @notice Namespace for underlying caller transient storage
    bytes32 private immutable _underlying_caller_seed;

    /// @notice Namespace for initializable storage seed
    bytes32 private immutable _init_storage_slot;

    /// @notice Implementation address
    address private immutable _implementation;

    error BalanceMultiplierTooHigh();
    error MaxGasTooHigh();
    error ShMonadAddressWrong();

    /// @notice Constructor for RelayUpgradeable
    constructor() {
        _implementation = address(this);

        address _shMonad = IAddressHub(ADDRESS_HUB).shMonad();
        // Create storage namespace seeds - this saves gas in the hot path
        _init_storage_slot = keccak256(
            abi.encodePacked(
                "ShMonad GasRelayHelper 1.0", "Initializable Storage", true, address(this), _shMonad, block.chainid
            )
        );
        _session_key_seed = keccak256(
            abi.encodePacked(
                "ShMonad GasRelayHelper 1.0", "Session Key Namespace", true, address(this), _shMonad, block.chainid
            )
        );
        _key_owner_seed = keccak256(
            abi.encodePacked(
                "ShMonad GasRelayHelper 1.0", "Key Owner Namespace", true, address(this), _shMonad, block.chainid
            )
        );
        _underlying_caller_seed = keccak256(
            abi.encodePacked(
                "ShMonad GasRelayHelper 1.0",
                "Underlying Caller Transient Namespace",
                true,
                address(this),
                _shMonad,
                block.chainid
            )
        );
    }

    function __gasRelayInitialize(
        uint256 maxExpectedGasUsagePerTx,
        uint48 escrowDuration,
        uint256 targetBalanceMultiplier
    )
        internal
    {
        if (targetBalanceMultiplier > type(uint8).max) revert BalanceMultiplierTooHigh();
        if (maxExpectedGasUsagePerTx > type(uint24).max) revert MaxGasTooHigh();

        // If ShMonad address has been updated, the implementation will need to be updated prior to upgrade
        address _shMonad = IAddressHub(ADDRESS_HUB).shMonad();
        if (_shMonad != GasRelayConstants(_implementation).SHMONAD()) revert ShMonadAddressWrong();

        // NOTE: The policyID value acts as a gas efficient stand-in for versioning
        (uint64 _policyIDLocal, address _policyERC20WrapperLocal) = IShMonad(_shMonad).createPolicy(escrowDuration);

        __store(
            PolicyStorage({
                policyWrapper: _policyERC20WrapperLocal,
                policyID: _policyIDLocal,
                maxExpectedGasUsage: uint24(maxExpectedGasUsagePerTx),
                targetBalanceMultiplier: uint8(targetBalanceMultiplier)
            })
        );
    }

    function _load() private view returns (PolicyStorage memory) {
        bytes32 _slot = _init_storage_slot;
        uint256 _packed;
        assembly {
            _packed := sload(_slot)
        }
        return _unpack(_packed);
    }

    function __store(PolicyStorage memory unpacked) private {
        bytes32 _slot = _init_storage_slot;
        uint256 _packed = _pack(unpacked);
        assembly {
            sstore(_slot, _packed)
        }
    }

    function _pack(PolicyStorage memory unpacked) private pure returns (uint256 packed) {
        uint256 policyWrapper = uint256(uint160(unpacked.policyWrapper));
        uint256 policyID = uint256(unpacked.policyID);
        uint256 maxExpectedGasUsage = uint256(unpacked.maxExpectedGasUsage);
        uint256 targetBalanceMultiplier = uint256(unpacked.targetBalanceMultiplier);

        packed = policyWrapper | (policyID << 160) | (maxExpectedGasUsage << 224) | (targetBalanceMultiplier << 248);
    }

    function _unpack(uint256 packed) private pure returns (PolicyStorage memory unpacked) {
        unpacked.policyWrapper =
            address(uint160(packed & 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff));
        unpacked.policyID = uint64((packed >> 160) & 0x000000000000000000000000000000000000000000000000ffffffffffffffff);
        unpacked.maxExpectedGasUsage =
            uint24((packed >> 224) & 0x0000000000000000000000000000000000000000000000000000000000ffffff);
        unpacked.targetBalanceMultiplier =
            uint8((packed >> 248) & 0x00000000000000000000000000000000000000000000000000000000000000ff);
    }

    function POLICY_ID() public view override returns (uint64) {
        return _load().policyID;
    }

    function POLICY_WRAPPER() public view override returns (address) {
        return _load().policyWrapper;
    }

    function _MAX_EXPECTED_GAS_USAGE_PER_TX() internal view override returns (uint256) {
        return uint256(_load().maxExpectedGasUsage);
    }

    function _TARGET_BALANCE_MULTIPLIER() internal view override returns (uint256) {
        return uint256(_load().targetBalanceMultiplier);
    }

    function _GAS_USAGE_AND_MULTIPLIER() internal view override returns (uint256, uint256) {
        PolicyStorage memory _policyStorage = _load();
        return (_policyStorage.maxExpectedGasUsage, _policyStorage.targetBalanceMultiplier);
    }

    function _SESSION_KEY_NAMESPACE() internal view override returns (bytes32) {
        return keccak256(abi.encodePacked(_session_key_seed, address(this), POLICY_ID()));
    }

    function _KEY_OWNER_NAMESPACE() internal view override returns (bytes32) {
        return keccak256(abi.encodePacked(_key_owner_seed, address(this), POLICY_ID()));
    }

    function _UNDERLYING_CALLER_NAMESPACE() internal view override returns (bytes32) {
        return keccak256(abi.encodePacked(_underlying_caller_seed, address(this), POLICY_ID()));
    }
}
