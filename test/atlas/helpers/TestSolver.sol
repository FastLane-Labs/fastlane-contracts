//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";

import { IAtlas } from "../../../src/atlas/interfaces/IAtlas.sol";

contract TestSolver {
    using SafeTransferLib for address;

    error TestSolver_WrongSolverFrom();
    error TestSolver_IntentionalRevert();

    IAtlas public immutable ATLAS;
    address public immutable OWNER;

    bool public shouldRevert;

    constructor(address atlas) {
        ATLAS = IAtlas(atlas);
        OWNER = msg.sender;
    }

    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address bidToken,
        uint256 bidAmount,
        bytes calldata solverOpData,
        bytes calldata forwardedData
    )
        external
        payable
    {
        require(solverOpFrom == OWNER, TestSolver_WrongSolverFrom());

        // Allows us to test solver fault failure easily
        if (shouldRevert) revert TestSolver_IntentionalRevert();

        // Pay bid to Execution Environment
        if (bidToken == address(0)) {
            // Pay bid in MON
            executionEnvironment.safeTransferETH(bidAmount);
        } else {
            // Pay bid in ERC20 (bidToken)
            bidToken.safeTransfer(executionEnvironment, bidAmount);
        }

        // Settle up Atlas liabilities:
        // - borrowed funds that need to be repaid in native token
        // - gas liabilities that can be repaid in native token, or an approval to take from bonded shMON
        (uint256 gasLiability, uint256 borrowLiability) = ATLAS.shortfall();
        uint256 nativeRepayment = borrowLiability < msg.value ? borrowLiability : msg.value;
        ATLAS.reconcile{ value: nativeRepayment }(gasLiability);
    }

    function setShouldRevert(bool solverShouldRevert) external {
        shouldRevert = solverShouldRevert;
    }
}
