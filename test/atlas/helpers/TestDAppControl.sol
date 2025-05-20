// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";

import { DAppControl } from "../../../src/atlas/dapp/DAppControl.sol";
import { CallConfig } from "../../../src/atlas/types/ConfigTypes.sol";
import { UserOperation } from "../../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../../src/atlas/types/SolverOperation.sol";

import "forge-std/Test.sol";

contract TestDAppControl is DAppControl {
    using SafeTransferLib for address;

    TestDAppControl public immutable SELF;
    address public immutable BID_RECIPIENT;

    error TestDAppControl_PreOpsRevertRequested();
    error TestDAppControl_UserOpRevertRequested();
    error TestDAppControl_PreSolverRevertRequested();
    error TestDAppControl_PostSolverRevertRequested();
    error TestDAppControl_AllocateValueRevertRequested();
    error TestDAppControl_PostOpsRevertRequested();

    bool public preOpsShouldRevert;
    bool public userOpShouldRevert;
    bool public preSolverShouldRevert;
    bool public postSolverShouldRevert;
    bool public allocateValueShouldRevert;
    bool public postOpsShouldRevert;

    bytes public preOpsInputData;
    bytes public userOpInputData;
    bytes public preSolverInputData;
    bytes public postSolverInputData;
    bytes public allocateValueInputData;
    bytes public postOpsInputData;

    constructor(
        address atlas,
        address gov,
        address bidRecipient,
        CallConfig memory callConfig
    )
        DAppControl(atlas, gov, callConfig)
    {
        SELF = TestDAppControl(address(this));
        BID_RECIPIENT = bidRecipient;
    }

    // --------------------------------------------- //
    //                 Hook Overrides                //
    // --------------------------------------------- //

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        require(!SELF.preOpsShouldRevert(), TestDAppControl_PreOpsRevertRequested());
        SELF.setInputData(abi.encode(userOp), 0); // 0 = preOps
    }

    // NOTE: UserOperation happens here: Atlas --(delegatecall)--> EE --(call)--> `userOperationCall()`
    function userOperationCall(uint256 userOpInputNum) public returns (uint256) {
        require(!SELF.userOpShouldRevert(), TestDAppControl_UserOpRevertRequested());
        SELF.setInputData(abi.encode(userOpInputNum), 1); // 1 = userOp

        return userOpInputNum;
    }

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal virtual override {
        require(!SELF.preSolverShouldRevert(), TestDAppControl_PreSolverRevertRequested());
        SELF.setInputData(abi.encode(solverOp, returnData), 2); // 2 = preSolver
    }

    function _postSolverCall(SolverOperation calldata solverOp, bytes calldata returnData) internal virtual override {
        require(!SELF.postSolverShouldRevert(), TestDAppControl_PostSolverRevertRequested());
        SELF.setInputData(abi.encode(solverOp, returnData), 3); // 3 = postSolver
    }

    function _allocateValueCall(
        bool solved,
        address bidToken,
        uint256 winningBid,
        bytes calldata data
    )
        internal
        virtual
        override
    {
        require(!SELF.allocateValueShouldRevert(), TestDAppControl_AllocateValueRevertRequested());
        SELF.setInputData(abi.encode(solved, bidToken, winningBid, data), 4); // 4 = allocateValue

        _sendBidToBidRecipient(bidToken, winningBid);
    }

    // --------------------------------------------- //
    //               Non-Hook Overrides              //
    // --------------------------------------------- //

    function getBidValue(SolverOperation calldata solverOp) public view virtual override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getBidFormat(UserOperation calldata) public view virtual override returns (address) {
        return address(0); // bid is in MON
    }

    function _checkUserOperation(UserOperation memory) internal pure virtual override { }

    // --------------------------------------------- //
    //                 Custom Functions              //
    // --------------------------------------------- //

    // Used to use all gas available during a call to get OOG error.
    function burnEntireGasLimit() public {
        uint256 _uselessSum;
        while (true) {
            _uselessSum += uint256(keccak256(abi.encodePacked(_uselessSum, gasleft()))) / 1e18;
        }
    }

    // Revert settings

    function setPreOpsShouldRevert(bool _preOpsShouldRevert) public {
        preOpsShouldRevert = _preOpsShouldRevert;
    }

    function setUserOpShouldRevert(bool _userOpShouldRevert) public {
        userOpShouldRevert = _userOpShouldRevert;
    }

    function setPreSolverShouldRevert(bool _preSolverShouldRevert) public {
        preSolverShouldRevert = _preSolverShouldRevert;
    }

    function setPostSolverShouldRevert(bool _postSolverShouldRevert) public {
        postSolverShouldRevert = _postSolverShouldRevert;
    }

    function setAllocateValueShouldRevert(bool _allocateValueShouldRevert) public {
        allocateValueShouldRevert = _allocateValueShouldRevert;
    }

    function setPostOpsShouldRevert(bool _postOpsShouldRevert) public {
        postOpsShouldRevert = _postOpsShouldRevert;
    }

    // Called by the EE to save input data for testing after the metacall ends
    function setInputData(
        bytes memory inputData,
        uint256 hook // 0: preOps, 1: userOp, 2: preSolver, 3: postSolver, 4: allocateValue, 5: postOps
    )
        public
    {
        if (hook == 0) preOpsInputData = inputData;
        if (hook == 1) userOpInputData = inputData;
        if (hook == 2) preSolverInputData = inputData;
        if (hook == 3) postSolverInputData = inputData;
        if (hook == 4) allocateValueInputData = inputData;
        if (hook == 5) postOpsInputData = inputData;
    }

    // --------------------------------------------- //
    //                 Internal Helpers              //
    // --------------------------------------------- //

    function _sendBidToBidRecipient(address bidToken, uint256 winningBid) internal {
        if (bidToken == address(0)) {
            BID_RECIPIENT.safeTransferETH(winningBid);
        } else {
            bidToken.safeTransfer(BID_RECIPIENT, winningBid);
        }
    }
}
