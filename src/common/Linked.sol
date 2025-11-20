//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

// This lets us deploy upgrades to specific contracts without disrupting composability for cross-contract tests

import { Directory } from "./Directory.sol";
import { IAddressHub } from "./IAddressHub.sol";

// Having an address helper at the bottom of the inheritance graph lets us
// use these functions without having to pass the AddressHubAddress through all
// the constructors, which we'll presumably be changing a lot during testing / deployment.
contract Linked {
    error ForwardingError(bytes4 nestedError);

    address public immutable ADDRESS_HUB;

    // masks 16 bytes - leaves 4 bytes uncovered for the pointer. Pointer max is 1024a, so we're fine
    bytes20 private constant _POINTER_MASK = bytes20(0xfFFFFfffFFFfFfFFffFFFfFfffFFfFfF00000000);

    constructor(address addressHub) {
        ADDRESS_HUB = addressHub;
    }

    // Returns whether target is a contract in the FastLane network
    function _isFastLane(address target) internal view virtual returns (bool) {
        return bytes20(target) > _POINTER_MASK || IAddressHub(ADDRESS_HUB).isFastLane(target);
    }

    function _fastLaneAddress(uint256 pointer) internal view virtual returns (address) {
        return IAddressHub(ADDRESS_HUB).getAddressFromPointer(pointer);
    }

    function _fastLanePointer(address target) internal view virtual returns (uint256) {
        return bytes20(target) > _POINTER_MASK
            ? uint256(bytes32(bytes20(target) ^ _POINTER_MASK))
            : IAddressHub(ADDRESS_HUB).getPointerFromAddress(target);
    }

    // For address tracking internal to a specific contract (IE a balance in this contract's storage)
    // This lets us put the pointer in as an address (E.G. the key in a map for addresses)
    // NOTE: Only works in conjuction with the _currentAddress() function below!
    function _placeholder(uint256 pointer) internal pure returns (address) {
        return address(bytes20(bytes32(pointer)) ^ _POINTER_MASK);
    }

    // Detects a placeholder address and then returns its current value
    function _currentAddress(address target) internal view returns (address) {
        if (bytes20(target) > _POINTER_MASK) {
            // This also filters out the zero address
            uint256 _pointer = uint256(bytes32(bytes20(target) ^ _POINTER_MASK));
            return IAddressHub(ADDRESS_HUB).getAddressFromPointer(_pointer);
        }
        return target;
    }

    // Calls another FastLane contract using its pointer. The AddressHub will attach the caller as the _msgSender per
    // ERC-2771.
    function _fastLaneCall(
        uint256 pointer,
        uint256 value,
        uint256 gas,
        bytes memory data
    )
        internal
        returns (bool success, bytes memory returnData)
    {
        (success, returnData) = ADDRESS_HUB.call{ gas: gas * 63 / 64, value: value }(
            abi.encodeCall(IAddressHub.intraFastLaneCall, (pointer, data))
        );
        // Handle outer call to forwarder
        if (!success) {
            revert ForwardingError(bytes4(returnData));
        }
        // Get inner call's results
        (success, returnData) = abi.decode(returnData, (bool, bytes));
    }

    // Staticcalls another FastLane contract using its pointer. The AddressHub will attach the caller as the _msgSender
    // per
    // ERC-2771.
    function _fastLaneStaticCall(
        uint256 pointer,
        uint256 gas,
        bytes memory data
    )
        internal
        view
        returns (bool success, bytes memory returnData)
    {
        uint256 _gasLimit = gas < gasleft() - 1000 ? gas : gasleft() - 1000;

        (success, returnData) =
            ADDRESS_HUB.staticcall{ gas: _gasLimit }(abi.encodeCall(IAddressHub.intraFastLaneCall, (pointer, data)));
        // Handle outer call to forwarder
        if (!success) {
            revert ForwardingError(bytes4(returnData));
        }
        // Get inner call's results
        (success, returnData) = abi.decode(returnData, (bool, bytes));
    }

    // NOTE: For FastLaneBatchCall and FastLaneBatchStaticCall, we expect each contract using those functions to
    // manually input the caller, as creating a generalized one would not significantly reduce the code complexity.

    modifier onlyOwner() virtual {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        require(IAddressHub(ADDRESS_HUB).isOwner(msg.sender), "ERR - NOT OWNER");
    }

    // Forked from OpenZeppelin's ERC-2771: // TODO: properly attribute it
    /**
     * @dev Override for `msg.sender`. Defaults to the original `msg.sender` whenever
     * a call is not performed by the trusted forwarder or the calldata length is less than
     * 20 bytes (an address length).
     */
    function _msgSender() internal view virtual returns (address) {
        uint256 calldataLength = msg.data.length;
        if (msg.sender == ADDRESS_HUB && calldataLength >= 52) {
            return address(bytes20(msg.data[calldataLength - 20:]));
        } else {
            return msg.sender;
        }
    }

    // Returns the pointer of the calling address if it's a FastLane contract
    function _msgSenderPointer() internal view returns (uint256) {
        uint256 calldataLength = msg.data.length;
        if (msg.sender == ADDRESS_HUB && calldataLength >= 52) {
            return uint256(bytes32(msg.data[calldataLength - 52:]));
        } else {
            return 0;
        }
    }

    // Returns the address of the caller in most cases, but returns a placeholder address if the caller is the
    // AddressHub
    function _msgSenderPlaceholder() internal view returns (address) {
        uint256 calldataLength = msg.data.length;
        if (msg.sender == ADDRESS_HUB && calldataLength >= 52) {
            return _placeholder(uint256(bytes32(msg.data[calldataLength - 52:])));
        } else {
            return msg.sender;
        }
    }

    // This view function lets a FastLane contract check if the caller is another
    // FastLane contract. For example, for a function that is only meant to be called
    // by the shMONAD contract, you could write:
    //      require(_msgSenderMatch(_SHMONAD), "ERR - CallerNotShMonad");
    function _msgSenderMatch(uint256 pointer) internal view returns (bool) {
        if (pointer == 0) return false;
        return _msgSenderPointer() == pointer;
    }

    /**
     * @dev Override for `msg.data`. Defaults to the original `msg.data` whenever
     * a call is not performed by the trusted forwarder or the calldata length is less than
     * 20 bytes (an address length).
     */
    function _msgData() internal view virtual returns (bytes calldata) {
        uint256 calldataLength = msg.data.length;
        if (msg.sender == ADDRESS_HUB && calldataLength >= 52) {
            return msg.data[:calldataLength - 52];
        } else {
            return msg.data;
        }
    }
}
