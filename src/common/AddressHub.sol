//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { SponsoredExecutor } from "./SponsoredExecutor.sol";
import { Directory } from "./Directory.sol";

// This lets us deploy upgrades to specific contracts without disrupting composability for cross-contract tests
// Under no circumstance should this still look the same in a non-testnet environment.
contract AddressHub is Initializable {
    mapping(address => bool) public S_owners;
    mapping(uint256 => string) public S_labels;
    mapping(address => uint256) public S_addresses;

    address[1024] public S_pointers;

    uint256[50] private __gap; // For future storage expansion

    error BatchArrayLengthInvalid();
    error BatchValueArrayInvalid();

    function initialize(address deployer) public initializer {
        // NOTE: At AddressHub deployment, all member addresses are address(0)

        // Deploy executor
        SponsoredExecutor _sponsoredExecutor = new SponsoredExecutor();
        S_pointers[Directory._SPONSORED_EXECUTOR] = address(_sponsoredExecutor);
        S_addresses[address(_sponsoredExecutor)] = Directory._SPONSORED_EXECUTOR;

        // 0 index is null
        S_labels[Directory._SHMONAD] = "shMonad";
        S_labels[Directory._VALIDATOR_AUCTION] = "validatorAuction";
        S_labels[Directory._ATLAS] = "atlas";
        S_labels[Directory._CLEARING_HOUSE] = "clearingHouse";
        S_labels[Directory._TASK_MANAGER] = "taskManager";
        S_labels[Directory._CAPITAL_ALLOCATOR] = "capitalAllocator";
        S_labels[Directory._STAKING_HUB] = "stakingHub";
        S_labels[Directory._PAYMASTER_4337] = "paymaster4337";
        S_labels[Directory._SPONSORED_EXECUTOR] = "sponsoredExecutor";
        S_labels[Directory._RPC_POLICY] = "rpcPolicy";
        S_owners[deployer] = true;
    }

    // Call Forwarder (recipients have a modified ERC-2771 enabled)
    // NOTE: Keep this as the only call that isn't view / staticall
    function intraFastLaneCall(uint256 pointer, bytes calldata data) external payable returns (bool, bytes memory) {
        // Verify that the caller is a FastLane contract
        uint256 _callerPointer = S_addresses[msg.sender];
        require(_callerPointer != 0, "ERR - InvalidCaller");

        address _target = S_pointers[pointer];
        require(_target != address(0), "ERR - NullPointer");

        // Append the caller's pointer and address for the callee to verify
        return _target.call{ value: msg.value }(abi.encodePacked(data, _callerPointer, msg.sender));
    }

    // Call Forwarder for static calls (recipients have a modified ERC-2771 enabled)
    function intraFastLaneStaticCall(uint256 pointer, bytes calldata data) external view returns (bool, bytes memory) {
        // Verify that the caller is a FastLane contract
        uint256 _callerPointer = S_addresses[msg.sender];
        require(_callerPointer != 0, "ERR - InvalidCaller");

        address _target = S_pointers[pointer];
        require(_target != address(0), "ERR - NullPointer");

        // Append the caller's pointer and address for the callee to verify
        return _target.staticcall(abi.encodePacked(data, _callerPointer, msg.sender));
    }

    // Call Forwarder (recipients have a modified ERC-2771 enabled)
    // Note that the word "data" is already plural - the singular form is "datum," so we improvise.
    function intraFastLaneBatchCall(
        uint256[] calldata pointers,
        uint256[] calldata values,
        uint256[] calldata gasses,
        bytes[] calldata datumses
    )
        external
        payable
        returns (bool[] memory successes, bytes[] memory returnDatumses)
    {
        // Verify that the caller is a FastLane contract
        uint256 _callerPointer = S_addresses[msg.sender];
        require(_callerPointer != 0, "ERR - InvalidCaller");

        uint256 _len = pointers.length;

        if (values.length != _len || gasses.length != _len || datumses.length != _len) {
            revert BatchArrayLengthInvalid();
        }

        successes = new bool[](_len);
        returnDatumses = new bytes[](_len);

        // Declare variables
        address _target;
        uint256 _valueSum; // Track the values for each call in the batch

        for (uint256 i; i < _len; i++) {
            _target = S_pointers[pointers[i]];
            require(_target != address(0), "ERR - NullPointer");

            // Append the caller's pointer and address for the callee to verify
            (successes[i], returnDatumses[i]) = _target.call{ value: values[i], gas: gasses[i] }(
                abi.encodePacked(datumses[i], _callerPointer, msg.sender)
            );

            _valueSum += values[i];
        }

        if (_valueSum != msg.value) {
            revert BatchValueArrayInvalid();
        }

        return (successes, returnDatumses);
    }

    // Call Forwarder (recipients have a modified ERC-2771 enabled)
    // Note that the word "data" is already plural - the singular form is "datum," so we improvise.
    function intraFastLaneBatchStaticCall(
        uint256[] calldata pointers,
        uint256[] calldata gasses,
        bytes[] calldata datumses
    )
        external
        view
        returns (bool[] memory successes, bytes[] memory returnDatumses)
    {
        // Verify that the caller is a FastLane contract
        uint256 _callerPointer = S_addresses[msg.sender];
        require(_callerPointer != 0, "ERR - InvalidCaller");

        uint256 _len = pointers.length;

        if (gasses.length != _len || datumses.length != _len) {
            revert BatchArrayLengthInvalid();
        }

        successes = new bool[](_len);
        returnDatumses = new bytes[](_len);
        address _target;

        for (uint256 i; i < _len; i++) {
            _target = S_pointers[pointers[i]];
            require(_target != address(0), "ERR - NullPointer");

            // Append the caller's pointer and address for the callee to verify
            (successes[i], returnDatumses[i]) =
                _target.staticcall{ gas: gasses[i] }(abi.encodePacked(datumses[i], _callerPointer, msg.sender));
        }

        return (successes, returnDatumses);
    }

    // Getters
    function getAddressFromPointer(uint256 pointer) external view returns (address) {
        return S_pointers[pointer];
    }

    function getAddressesFromPointers(uint256[] calldata pointersArray)
        external
        view
        returns (address[] memory addressesArray)
    {
        addressesArray = new address[](pointersArray.length);
        for (uint256 i = 0; i < pointersArray.length; ++i) {
            addressesArray[i] = S_pointers[pointersArray[i]];
        }
        return addressesArray;
    }

    function getPointerFromAddress(address target) external view returns (uint256) {
        return S_addresses[target];
    }

    function getLabelFromPointer(uint256 pointer) external view returns (string memory) {
        return S_labels[pointer];
    }

    function isFastLane(address target) external view returns (bool) {
        return S_addresses[target] != 0 && target != address(this);
    }

    // Specific getters for contracts we know we'll use frequently
    function shMonad() external view returns (address) {
        return S_pointers[Directory._SHMONAD];
    }

    function validatorAuction() external view returns (address) {
        return S_pointers[Directory._VALIDATOR_AUCTION];
    }

    function atlas() external view returns (address) {
        return S_pointers[Directory._ATLAS];
    }

    function clearingHouse() external view returns (address) {
        return S_pointers[Directory._CLEARING_HOUSE];
    }

    function taskManager() external view returns (address) {
        return S_pointers[Directory._TASK_MANAGER];
    }

    function capitalAllocator() external view returns (address) {
        return S_pointers[Directory._CAPITAL_ALLOCATOR];
    }

    function stakingHub() external view returns (address) {
        return S_pointers[Directory._STAKING_HUB];
    }

    function paymaster4337() external view returns (address) {
        return S_pointers[Directory._PAYMASTER_4337];
    }

    function rpcPolicy() external view returns (address) {
        return S_pointers[Directory._RPC_POLICY];
    }

    // Maintenance Functions
    function addPointerAddress(uint256 newPointer, address newAddress, string calldata newLabel) external onlyOwner {
        // Map 1:1 pointer - address
        require(S_addresses[newAddress] == 0, "ERR - ExistingAddress");
        require(S_pointers[newPointer] == address(0), "ERR - ExistingPointer");

        S_pointers[newPointer] = newAddress;
        S_labels[newPointer] = newLabel;
        S_addresses[newAddress] = newPointer;
    }

    function updatePointerAddress(uint256 pointer, address newAddress) external onlyOwner {
        // We do not update the label / string when updating the pointer - we just update the address.

        // Only one pointer per address
        require(S_addresses[newAddress] == 0, "ERR - ExistingAddress");
        require(S_pointers[pointer] != address(0), "ERR - NullPointer");

        // Delete old address from the directory
        address _oldAddress = S_pointers[pointer];
        delete S_addresses[_oldAddress];

        S_pointers[pointer] = newAddress;
        S_addresses[newAddress] = pointer;
    }

    // Owner tracking
    function isOwner(address caller) external view returns (bool) {
        return S_owners[caller];
    }

    modifier onlyOwner() {
        require(S_owners[msg.sender], "ERR - NOT OWNER");
        _;
    }

    // Redo this with something secure
    function addOwner(address newOwner) external onlyOwner {
        S_owners[newOwner] = true;
    }

    // Redo this with something secure
    function removeOwner(address oldOwner) external onlyOwner {
        S_owners[oldOwner] = false;
    }
}
