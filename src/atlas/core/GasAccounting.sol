//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solady/utils/FixedPointMathLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SafetyLocks } from "./SafetyLocks.sol";
import { EscrowBits } from "../libraries/EscrowBits.sol";
import { CallBits } from "../libraries/CallBits.sol";
import { AccountingMath } from "../libraries/AccountingMath.sol";
import { GasAccLib, GasLedger, BorrowsLedger } from "../libraries/GasAccLib.sol";
import { SolverOperation } from "../types/SolverOperation.sol";
import "../types/EscrowTypes.sol";
import "../types/LockTypes.sol";

/// @title GasAccounting
/// @author FastLane Labs
/// @notice GasAccounting manages the accounting of gas surcharges and escrow balances for the Atlas protocol.
abstract contract GasAccounting is SafetyLocks {
    using EscrowBits for uint256;
    using CallBits for uint32;
    using AccountingMath for uint256;
    using SafeCast for uint256;
    using GasAccLib for uint256;
    using GasAccLib for GasLedger;
    using GasAccLib for BorrowsLedger;
    using FixedPointMathLib for uint256;

    constructor(
        uint256 atlasSurchargeRate,
        address verification,
        address simulator,
        address initialSurchargeRecipient,
        address l2GasCalculator,
        address taskManager,
        address shMonad,
        uint64 shMonadPolicyID
    )
        SafetyLocks(
            atlasSurchargeRate,
            verification,
            simulator,
            initialSurchargeRecipient,
            l2GasCalculator,
            taskManager,
            shMonad,
            shMonadPolicyID
        )
    { }

    /// @notice Sets the initial gas accounting values for the metacall transaction in transient storage.
    /// @dev Resets `t_gasLedger`, `t_borrowsLedger`, `t_solverLock`, and `t_solverTo` at the start of each metacall.
    ///     Initializes `remainingMaxGas` with the overall gas estimate and `unreachedSolverGas` with the precalculated
    ///     gas for all potential solver operations. Sets initial `repays` based on `msg.value`.
    /// @param initialRemainingMaxGas The gas measurement at the start of the metacall, which generally includes
    ///     Execution gas limits, Calldata gas costs, and an additional buffer for safety. NOTE: If in exPostBids mode,
    ///     this param does not include calldata gas as solvers are not liable for calldata gas costs. And in
    ///     multipleSuccessfulSolvers mode, this param is the same value as `allSolverOpsGas`, because solvers are only
    ///     liable for their own solverOp gas, even if they execute successfully.
    /// @param allSolverOpsGas The sum of (C + E) gas limits for all solverOps in the metacall.
    function _initializeAccountingValues(
        uint256 initialRemainingMaxGas,
        uint256 allSolverOpsGas,
        uint24 bundlerSurchargeRate
    )
        internal
    {
        t_gasLedger = GasLedger({
            remainingMaxGas: initialRemainingMaxGas.toUint40(),
            writeoffsGas: 0,
            solverFaultFailureGas: 0,
            unreachedSolverGas: allSolverOpsGas.toUint40(),
            maxApprovedGasSpend: 0,
            atlasSurchargeRate: _atlasSurchargeRate(),
            bundlerSurchargeRate: bundlerSurchargeRate
        }).pack();

        // If any native token sent in the metacall, add to the repays account
        t_borrowsLedger = BorrowsLedger({ borrows: 0, repays: uint128(msg.value) }).pack();

        t_solverLock = 0;
        t_solverTo = address(0);

        // The Lock slot is cleared at the end of the metacall, so no need to zero again here.
    }

    /// @notice Contributes MON to the contract, increasing the deposits if a non-zero value is sent.
    function contribute() external payable {
        address _activeEnv = _activeEnvironment();
        if (_activeEnv != msg.sender) revert InvalidExecutionEnvironment(_activeEnv);
        _contribute();
    }

    /// @notice Borrows MON from the contract, transferring the specified amount to the caller if available.
    /// @dev Borrowing is only available until the end of the SolverOperation phase, for solver protection.
    /// @param amount The amount of MON to borrow.
    function borrow(uint256 amount) external {
        // TODO this will break until Flash Loans on ShMonad are enabled and integrated here

        if (amount == 0) return;

        // borrow() can only be called by the Execution Environment (by delegatecalling a DAppControl hook), and only
        // during or before the SolverOperation phase.
        (address _activeEnv,, uint8 _currentPhase) = _lock();
        if (_activeEnv != msg.sender) revert InvalidExecutionEnvironment(_activeEnv);
        if (_currentPhase > uint8(ExecutionPhase.SolverOperation)) revert WrongPhase();

        // borrow() will revert if called after solver calls reconcile()
        (, bool _calledBack,) = _solverLockData();
        if (_calledBack) revert WrongPhase();

        if (_borrow(amount)) {
            SafeTransferLib.safeTransferETH(msg.sender, amount);
        } else {
            // TODO refactor errors to say ShMon instead of AtlETH
            revert InsufficientAtlETHBalance(address(this).balance, amount);
        }
    }

    /// @notice Calculates the current shortfall currently owed by the winning solver.
    /// @dev The shortfall is calculated `(claims + withdrawals + fees - writeoffs) - deposits`. If this value is less
    /// than zero, shortfall returns 0 as there is no shortfall because the solver is in surplus.
    /// @return gasLiability The total gas charge (base + surcharges) owed by the solver. Can be repaid using bonded
    /// balance or native token.
    /// @return borrowLiability The total value of MON borrowed but not yet repaid, only repayable using native token.
    function shortfall() external view returns (uint256 gasLiability, uint256 borrowLiability) {
        gasLiability = t_gasLedger.toGasLedger().solverGasLiability();

        BorrowsLedger memory _bL = t_borrowsLedger.toBorrowsLedger();
        borrowLiability = (_bL.borrows < _bL.repays) ? 0 : _bL.borrows - _bL.repays;
    }

    /// @notice Allows a solver to settle any outstanding MON owed, either to repay gas used by their solverOp or to
    /// repay any MON borrowed from Atlas. This debt can be paid either by sending MON when calling this function
    /// (msg.value) or by approving Atlas to use a certain amount of the solver's bonded shMON.
    /// @param maxApprovedGasSpend The maximum amount of MON from the solver's bonded shMON that Atlas can deduct to
    /// cover the solver's debt.
    /// @return owed The amount owed, if any, by the solver after reconciliation.
    /// @dev The solver can call this function multiple times until the owed amount is zero.
    /// @dev Note: `reconcile()` must be called by the solver to avoid a `CallbackNotCalled` error in `solverCall()`.
    function reconcile(uint256 maxApprovedGasSpend) external payable returns (uint256 owed) {
        // NOTE: maxApprovedGasSpend is the amount of the solver's MON that the solver is allowing
        // to be used to cover what they owe. Assuming they're successful, a value up to this amount
        // will be subtracted from the solver's bonded shMON during _settle().

        // NOTE: After reconcile is called for the first time by the solver, neither the claims nor the borrows values
        // can be increased.

        (, uint32 _callConfig, uint8 _currentPhase) = _lock();

        // NOTE: While anyone can call this function, it can only be called in the SolverOperation phase. Because Atlas
        // calls directly to the solver contract in this phase, the solver should be careful to not call malicious
        // contracts which may call reconcile() on their behalf, with an excessive maxApprovedGasSpend.
        if (_currentPhase != uint8(ExecutionPhase.SolverOperation)) revert WrongPhase();
        if (msg.sender != t_solverTo) revert InvalidAccess();

        (address _currentSolver, bool _calledBack,) = _solverLockData();
        uint256 _bondedBalance = SHMONAD.convertToAssets(SHMONAD.balanceOfBonded(POLICY_ID, _currentSolver));

        // Solver can only approve up to their bonded balance, not more
        if (maxApprovedGasSpend > _bondedBalance) maxApprovedGasSpend = _bondedBalance;

        GasLedger memory _gL = t_gasLedger.toGasLedger();
        BorrowsLedger memory _bL = t_borrowsLedger.toBorrowsLedger();

        uint256 _borrows = _bL.borrows; // total native borrows
        uint256 _repays = _bL.repays; // total native repayments of borrows
        uint256 _maxGasLiability = _gL.solverGasLiability(); // max gas liability of winning solver

        // Store update to repays in t_borrowLedger, if any msg.value sent
        if (msg.value > 0) {
            _repays += msg.value;
            _bL.repays = _repays.toUint128();
            t_borrowsLedger = _bL.pack();
        }

        // Store solver's maxApprovedGasSpend for use in the _isBalanceReconciled() check
        if (maxApprovedGasSpend > 0) {
            // Convert maxApprovedGasSpend from wei (native token) units to gas units
            _gL.maxApprovedGasSpend = (maxApprovedGasSpend / tx.gasprice).toUint40();
            t_gasLedger = _gL.pack();
        }

        // Check if fullfilled:
        // - native borrows must be repaid (using only native token)
        // - gas liabilities must be repaid (using bonded shMON or native token)

        if (_borrows > _repays) {
            if (!_calledBack) t_solverLock = (uint256(uint160(_currentSolver)) | _SOLVER_CALLED_BACK_MASK);
            return _maxGasLiability + (_borrows - _repays);
        } else {
            // If multipleSuccessfulSolvers = true, the solver's gas liability cannot be paid in ETH - must be fully
            // paid by the solver's bonded AtlETH balance.
            uint256 _excess;
            if (!_callConfig.multipleSuccessfulSolvers()) _excess = _repays - _borrows;

            if (maxApprovedGasSpend + _excess < _maxGasLiability) {
                if (!_calledBack) t_solverLock = (uint256(uint160(_currentSolver)) | _SOLVER_CALLED_BACK_MASK);
                return _maxGasLiability - _excess;
            }
        }

        // If we get here, native borrows have been repaid, and enough approved to cover gas liabilities
        t_solverLock = (uint256(uint160(_currentSolver)) | _SOLVER_CALLED_BACK_MASK | _SOLVER_FULFILLED_MASK);
        return 0;
    }

    /// @notice Internal function to handle MON contribution, increasing deposits if a non-zero value is sent.
    function _contribute() internal {
        if (msg.value == 0) return;

        BorrowsLedger memory _bL = t_borrowsLedger.toBorrowsLedger();
        _bL.repays += msg.value.toUint128();
        t_borrowsLedger = _bL.pack();
    }

    /// @notice Borrows MON from the contract, transferring the specified amount to the caller if available.
    /// @dev Borrowing should never be allowed after the SolverOperation phase, for solver safety. This is enforced in
    /// the external `borrow` function, and the only other time this internal `_borrow` function is called is in
    /// `_solverOpInner` which happens at the beginning of the SolverOperation phase.
    /// @param amount The amount of MON to borrow.
    /// @return valid A boolean indicating whether the borrowing operation was successful.
    function _borrow(uint256 amount) internal returns (bool valid) {
        if (amount == 0) return true;
        if (address(this).balance < amount) return false;

        BorrowsLedger memory _bL = t_borrowsLedger.toBorrowsLedger();
        _bL.borrows += amount.toUint128();
        t_borrowsLedger = _bL.pack();

        return true;
    }

    /// @notice Takes a specified amount of MON from a specified account, from the Atlas policy in ShMonad. The account
    /// pays from their bonded shMON (shares), and Atlas recieves the specified amount of MON (native token).
    /// @dev No GasLedger accounting changes are made in this function - should be done separately. NOTE: On Monad,
    /// assign does not take an accountData memory param, as charging accounts is done via shMonad.
    /// @param account The address of the bonded shMON account from which MON is taken.
    /// @param amount The amount of MON to be taken.
    /// @return deficit The amount of MON that was not repaid, if any.
    function _assign(address account, uint256 amount) internal returns (uint256 deficit) {
        // Get the max amount of MON we can take from the account in ShMonad
        uint256 balanceAvailable = SHMONAD.policyBalanceAvailable(POLICY_ID, account, true);

        // If any shortfall, account for it in deficit, and adjust amount to take down to avoid revert
        if (amount > balanceAvailable) {
            deficit = amount - balanceAvailable;
            amount = balanceAvailable;
        }

        // Take the final amount (in MON) from the account in ShMonad
        SHMONAD.agentWithdrawFromBonded(POLICY_ID, account, address(this), amount, 0, true);
    }

    /// @notice Deposits MON, and bonds resulting shMON on behalf of an account, in ShMonad.
    /// @param account The address of the recipient of the bonded shMON.
    /// @param amount The amount of MON by which to increase the account's bonded balance (will be converted to shMON).
    function _credit(address account, uint256 amount) internal {
        // NOTE: amount is measured in MON units, which will all be converted to shMON at the current exchange rate.
        SHMONAD.depositAndBond{ value: amount }(POLICY_ID, account, type(uint256).max);
    }

    /// @notice Accounts for the gas cost of a failed SolverOperation, either by increasing writeoffs (if the bundler is
    /// blamed for the failure) or by assigning the gas cost to the solver's bonded shMON balance (if the solver is
    /// blamed for the failure).
    /// @dev On Monad, we use solverOp.gas instead of dConfig.solverGasLimit, so no dConfigSolverGasLimit param is
    /// needed.
    /// @param solverOp The current SolverOperation for which to account.
    /// @param dConfigSolverGasLimit The gas limit for the solver operation, as specified in the DAppConfig.
    /// @param result The result bitmap of the SolverOperation execution.
    /// @param exPostBids A boolean indicating whether exPostBids is set to true in the current metacall.
    function _handleSolverFailAccounting(
        SolverOperation calldata solverOp,
        uint256 dConfigSolverGasLimit,
        uint256 result,
        bool exPostBids
    )
        internal
    {
        GasLedger memory _gL = t_gasLedger.toGasLedger();
        uint256 _solverGasLimit = solverOp.gas;
        // NOTE: On Monad, we charge solverOps for full gas limit in all cases, not just gas used.

        // Solvers do not pay for calldata gas in exPostBids mode.
        uint256 _calldataGas;
        if (!exPostBids) {
            _calldataGas = GasAccLib.solverOpCalldataGas(solverOp.data.length, L2_GAS_CALCULATOR);
        }

        // Solver execution max gas is calculated as solverOp.gas, with a ceiling of dConfig.solverGasLimit
        uint256 _executionMaxGas = Math.min(solverOp.gas, dConfigSolverGasLimit);

        // Deduct solver's max (C + E) gas from remainingMaxGas, for future solver gas liability calculations.
        // NOTE: On Monad, remainingMaxGas iincludes the sum of solverOp.gas, not dConfig.solverGasLimit * len
        _gL.remainingMaxGas -= (_executionMaxGas + _calldataGas).toUint40();

        uint256 _gasUsed = _calldataGas + _solverGasLimit;

        // Calculate what the solver owes
        // NOTE: This will cause an error if you are simulating with a gasPrice of 0
        if (result.bundlersFault()) {
            // CASE: Solver is not responsible for the failure of their operation, so we blame the bundler
            // and reduce the total amount refunded to the bundler
            _gasUsed += _BUNDLER_FAULT_OFFSET;
            _gL.writeoffsGas += _gasUsed.toUint40();
        } else {
            // CASE: Solver failed, so we calculate what they owe.
            _gasUsed += _SOLVER_FAULT_OFFSET;
            uint256 _gasValueWithSurcharges = _gasUsed.withSurcharge(_gL.totalSurchargeRate()) * tx.gasprice;

            AccountAnalytics memory _solverAccountData = S_accessData[solverOp.from];

            // In `_assign()`, the solver's bonded shMON balance is reduced by `_gasValueWithSurcharges`. Any deficit
            // from that operation is returned as `_assignDeficit` below.
            uint256 _assignDeficit = _assign(solverOp.from, _gasValueWithSurcharges);

            // Solver's analytics updated:
            // - increment auctionFails
            // - increase totalGasValueUsed by gas cost + surcharges paid by solver, less any deficit
            _updateAnalytics(_solverAccountData, false, _gasValueWithSurcharges - _assignDeficit);

            // Update solver's lastAccessedBlock to current block
            _solverAccountData.lastAccessedBlock = uint32(block.number);

            // Persist the updated solver account data to storage
            S_accessData[solverOp.from] = _solverAccountData;

            if (_assignDeficit > 0) {
                // If any deficit, calculate the gas units unpaid for due to assign deficit.
                // Gas units written off = gas used * (deficit / gas value with surcharges) ratio.
                // `mulDivUp()` rounds in favor of writeoffs, so we don't overestimate gas that was actually paid for
                // and end up reimbursing the bundler for more than was actually taken from the solvers.
                uint256 _gasWrittenOff = _gasUsed.mulDivUp(_assignDeficit, _gasValueWithSurcharges);

                // No risk of underflow in subtraction below, because:
                // _assignDeficit is <= _gasValueWithSurcharges, so _gasWrittenOff is <= _solverGasLimit.

                // Deduct gas written off from gas tracked as "paid for" by failed solver
                _solverGasLimit -= _gasWrittenOff;
                _gL.writeoffsGas += _gasWrittenOff.toUint40(); // add to writeoffs in gasLedger
            }

            // The gas paid for here by failed solver, and gas written off due to shortfall in `_assign()`, will offset
            // what the winning solver owes in `_settle()`.
            _gL.solverFaultFailureGas += _solverGasLimit.toUint40();
        }

        // Persist the updated gas ledger to transient storage
        t_gasLedger = _gL.pack();
    }

    function _writeOffBidFindGas(uint256 gasUsed) internal {
        GasLedger memory _gL = t_gasLedger.toGasLedger();
        _gL.writeoffsGas += gasUsed.toUint40();
        t_gasLedger = _gL.pack();
    }

    /// @notice Charges solvers that were not reached during the metacall for the total gas cost of their solverOps. On
    /// Monad, unreached solvers are charged for their calldata and execution (solverOp.gas) gas costs.
    /// @dev Iterates through `solverOps` starting from the index *after* `winningSolverIdx`. For each unreached
    /// operation, `VERIFICATION.verifySolverOp` is called to determine fault.
    ///      - If bundler fault: The gas is added to `gL.writeoffsGas` (reducing bundler's refund).
    ///      - If solver fault: Attempts to charge the solver's bonded shMON using `_assign` for the gas cost (no
    ///        surcharges added). Any deficit is added to `gL.writeoffsGas`.
    ///      The gas cost of executing this loop is also added to `gL.writeoffsGas` to ensure the bundler pays for it.
    /// @param solverOps The SolverOperation array containing the solvers' transaction data.
    /// @param gL The GasLedger struct (memory); `gL.writeoffsGas` is updated within this function.
    /// @param winningSolverIdx Index of the winning/last attempted solver; the loop starts after this index.
    /// @param userOpHash Hash of the UserOperation, used for verification.
    /// @param maxFeePerGas userOp.maxFeePerGas, used for verification.
    /// @param bundler The metacall caller (msg.sender), used for verification.
    /// @param allowsTrustedOpHash Flag indicating with trustedOpHash is enabled in the metacall.
    /// @return unreachedSolverGasValuePaid Total value successfully charged to unreached solvers (cost - deficits).
    function _chargeUnreachedSolvers(
        SolverOperation[] calldata solverOps,
        GasLedger memory gL,
        uint256 winningSolverIdx,
        bytes32 userOpHash,
        uint256 maxFeePerGas,
        address bundler,
        bool allowsTrustedOpHash
    )
        internal
        returns (uint256 unreachedSolverGasValuePaid)
    {
        uint256 _writeoffGasMarker = gasleft();
        uint256 _solverGasCost;
        uint256 _deficit;

        // Start at the solver after the current solverIdx, because current solverIdx is the winner
        for (uint256 i = winningSolverIdx + 1; i < solverOps.length; ++i) {
            _solverGasCost = (
                solverOps[i].gas + GasAccLib.solverOpCalldataGas(solverOps[i].data.length, L2_GAS_CALCULATOR)
            ) * tx.gasprice;

            // Verify the solverOp, and write off solver's gas if included due to bundler fault
            uint256 _result =
                VERIFICATION.verifySolverOp(solverOps[i], userOpHash, maxFeePerGas, bundler, allowsTrustedOpHash);

            if (_result.bundlersFault()) {
                gL.writeoffsGas += _solverGasCost.divUp(tx.gasprice).toUint40();
                continue;
            }

            // No surcharges added to calldata cost for unreached solvers
            _deficit = _assign(solverOps[i].from, _solverGasCost);

            unreachedSolverGasValuePaid += _solverGasCost - _deficit;

            // Any deficits from the `_assign()` operations are converted to gas units and written off so as not to
            // charge the winning solver for calldata that is not their responsibility, in `_settle()`.
            if (_deficit > 0) gL.writeoffsGas += _deficit.divUp(tx.gasprice).toUint40();
        }

        // The gas cost of this loop is always paid by the bundler so as not to charge the winning solver for an
        // excessive number of loops and SSTOREs via _assign(). This gas is therefore added to writeoffs.
        gL.writeoffsGas += (_writeoffGasMarker - gasleft()).toUint40();
    }

    /// @notice Finalizes gas accounting at the end of the metacall, settles balances, and pays refunds/surcharges.
    /// @param ctx The context struct (memory), used for ctx.bundler and ctx.solverSuccessful.
    /// @param gL The final state of the GasLedger struct (memory), used for gas calculations.
    /// @param gasMarker The initial gas measurement taken at the start of the metacall.
    /// @param gasRefundBeneficiary The address designated to receive the bundler's gas refund. Defaults to
    /// `ctx.bundler`.
    /// @param unreachedSolverGasValuePaid The total value successfully collected from unreached solvers for their
    /// @param multipleSuccessfulSolvers A boolean indicating whether the multipleSuccessfulSolvers mode is enabled.
    /// total solverOp gas costs (C + E) (from `_chargeUnreachedSolvers`).
    /// @return claimsPaidToBundler The net amount of ETH transferred to the `gasRefundBeneficiary`.
    /// @return netAtlasGasSurcharge The net amount of ETH taken as Atlas surcharge during the metacall.
    function _settle(
        Context memory ctx,
        GasLedger memory gL,
        uint256 gasMarker,
        address gasRefundBeneficiary,
        uint256 unreachedSolverGasValuePaid,
        bool multipleSuccessfulSolvers
    )
        internal
        returns (uint256 claimsPaidToBundler, uint256 netAtlasGasSurcharge)
    {
        AccountAnalytics memory _winningSolverData;
        BorrowsLedger memory _bL = t_borrowsLedger.toBorrowsLedger();
        (address _winningSolver,,) = _solverLockData();

        // No need to SLOAD analytics struct etc. if no winning solver
        if (ctx.solverSuccessful) _winningSolverData = S_accessData[_winningSolver];

        // Send gas refunds to bundler if no gas refund beneficiary specified
        if (gasRefundBeneficiary == address(0)) gasRefundBeneficiary = ctx.bundler;

        // First check if all borrows have been repaid.
        // Borrows can only be repaid in native token, not from bonded balances.
        // This is also done at end of solverCall(), so check here only needed for zero solvers case.
        int256 _netRepayments = _bL.netRepayments();
        if (_netRepayments < 0) revert BorrowsNotRepaid(_bL.borrows, _bL.repays);

        uint256 _winnerGasCharge;
        // NOTE: On Monad, we do not deduct gasleft() here, because the bundler will not be reimbursed for that unusesd
        // gas due to Monad's gas usage model. Instead, the winning solver is charged more to reimburse the bundler.

        // NOTE: Trivial for bundler to run a different EOA for solver so no bundler == solver carveout.
        if (ctx.solverSuccessful) {
            // CASE: Winning solver.

            // Winning solver should pay for:
            // - Gas (C + E) limit of their solverOp
            // - Gas (C + E) limits of userOp, dapp hooks, and other metacall overhead
            // - Any (E) gasleft() gas that was not used in the metacall tx.
            // Winning solver should not pay for:
            // - Gas (C + E) used by other reached solvers (bundler or solver fault failures)
            // - Gas (C + E) used by unreached solvers
            // - Gas (E only) used during the bid-finding loops
            _winnerGasCharge =
                gasMarker - gL.writeoffsGas - gL.solverFaultFailureGas - (unreachedSolverGasValuePaid / tx.gasprice);
            // NOTE: On Monad, we do not deduct gasleft here, as bundler will be charged for full gas limit.

            uint256 _surchargedGasPaidBySolvers = gL.solverFaultFailureGas + _winnerGasCharge;

            // Bundler gets base gas cost + bundler surcharge of (solver fault fails + winning solver charge)
            // Bundler also gets reimbursed for the calldata of unreached solvers (only base, no surcharge)
            claimsPaidToBundler = (_surchargedGasPaidBySolvers.withSurcharge(gL.bundlerSurchargeRate) * tx.gasprice)
                + unreachedSolverGasValuePaid;

            // Atlas gets only the Atlas surcharge of (solver fault fails + winning solver charge)
            netAtlasGasSurcharge = _surchargedGasPaidBySolvers.getSurcharge(gL.atlasSurchargeRate) * tx.gasprice;

            // Calculate what winning solver pays: add surcharges and multiply by gas price
            _winnerGasCharge = _winnerGasCharge.withSurcharge(gL.totalSurchargeRate()) * tx.gasprice;

            uint256 _deficit; // Any shortfall that the winning solver is not able to repay from bonded balance
            if (_winnerGasCharge < uint256(_netRepayments)) {
                // CASE: solver recieves more than they pay --> net credit to account
                _credit(_winningSolver, uint256(_netRepayments) - _winnerGasCharge);
            } else {
                // CASE: solver pays more than they recieve --> net assign to account
                _deficit = _assign(_winningSolver, _winnerGasCharge - uint256(_netRepayments));
            }

            if (_deficit > claimsPaidToBundler) revert AssignDeficitTooLarge(_deficit, claimsPaidToBundler);
            claimsPaidToBundler -= _deficit;

            _updateAnalytics(_winningSolverData, true, _winnerGasCharge);

            // Update winning solver's lastAccessedBlock to current block
            _winningSolverData.lastAccessedBlock = uint32(block.number);

            // Persist winning solver's analytics data to storage
            S_accessData[_winningSolver] = _winningSolverData;
        } else {
            // CASE: No winning solver.

            // Bundler may still recover a partial refund (from solver fault failure charges) up to 80% of the gas cost
            // of the metacall. The remaining 20% could be recovered through storage refunds, and it is important that
            // metacalls with no winning solver are not profitable for the bundler.
            // The exception to this rule is when multipleSuccessfulSolvers is set to true. In this case, all solvers
            // should be able to execute and pay for their own gas + surcharges, but the bundler refund should not be
            // capped.

            uint256 _maxRefund;
            if (multipleSuccessfulSolvers) {
                _maxRefund = type(uint256).max;
            } else {
                _maxRefund = (gasMarker - gL.writeoffsGas).maxBundlerRefund() * tx.gasprice;
            }

            // Bundler gets (base gas cost + bundler surcharge) of solver fault failures, plus base gas cost of
            // unreached solverOps (C + E). This is compared to _maxRefund below. Net repayments is added after the 80%
            // cap has been applied to the gas refund components.
            // `unreachedSolverGasValuePaid` is not added here as it should always be 0 when solverSuccessful = false,
            // because there should then be no unreached solvers.
            uint256 _bundlerCutBeforeLimit =
                uint256(gL.solverFaultFailureGas).withSurcharge(gL.bundlerSurchargeRate) * tx.gasprice;

            // Atlas only keeps the Atlas surcharge of solver fault failures, and any gas due to bundler that exceeds
            // the 80% limit.
            netAtlasGasSurcharge = uint256(gL.solverFaultFailureGas).getSurcharge(gL.atlasSurchargeRate) * tx.gasprice;

            if (_bundlerCutBeforeLimit > _maxRefund) {
                // More than max gas refund was taken by failed/unreached solvers, excess goes to Atlas
                claimsPaidToBundler = _maxRefund;
                netAtlasGasSurcharge += _bundlerCutBeforeLimit - _maxRefund;
            } else {
                // Otherwise, the bundler can receive the full solver fault failure gas
                claimsPaidToBundler = _bundlerCutBeforeLimit;
            }

            // Finally, add any net repayments, which should not be subject to the 80% cap, to the bundler's claims
            claimsPaidToBundler += uint256(_netRepayments);
        }

        // Set lock to FullyLocked to prevent any reentrancy possibility in refund transfer below
        _setLockPhase(uint8(ExecutionPhase.FullyLocked));

        // Atlas gas surcharge is sent to ShMonad as yield for all shMON holders
        if (netAtlasGasSurcharge != 0) SHMONAD.boostYield{ value: netAtlasGasSurcharge }();

        // The bundler's gas refund beneficiary receives the gas refund in MON
        if (claimsPaidToBundler != 0) SafeTransferLib.safeTransferETH(gasRefundBeneficiary, claimsPaidToBundler);
    }

    /// @notice Updates auctionWins, auctionFails, and totalGasUsed values of a solver's AccountAnalytics.
    /// @dev This function is only ever called in the context of bidFind = false so no risk of doublecounting changes.
    /// @param aData The Solver's AccountAnalytics struct to update.
    /// @param auctionWon A boolean indicating whether the solver's solverOp won the auction.
    /// @param gasValueUsed The MON value of gas used by the solverOp. Should be calculated as gasUsed * tx.gasprice.
    function _updateAnalytics(AccountAnalytics memory aData, bool auctionWon, uint256 gasValueUsed) internal pure {
        if (auctionWon) {
            unchecked {
                ++aData.auctionWins;
            }
        } else {
            unchecked {
                ++aData.auctionFails;
            }
        }

        // Track total MON value of gas spent by solver in metacalls. Measured in gwei (1e9 digits truncated).
        aData.totalGasValueUsed += SafeCast.toUint64(gasValueUsed / _GAS_VALUE_DECIMALS_TO_DROP);
    }

    /// @notice Checks all obligations have been reconciled: native borrows AND gas liabilities.
    /// @return True if both dimensions are reconciled, false otherwise.
    function _isBalanceReconciled(bool multipleSuccessfulSolvers) internal view returns (bool) {
        GasLedger memory gL = t_gasLedger.toGasLedger();
        BorrowsLedger memory bL = t_borrowsLedger.toBorrowsLedger();

        // DApp's excess repayments via `contribute()` can offset solverGasLiability.
        // NOTE: This solver gas subsidy feature is disabled in multipleSuccessfulSolvers mode.
        uint256 _netRepayments;
        if (!multipleSuccessfulSolvers && bL.repays > bL.borrows) _netRepayments = bL.repays - bL.borrows;

        // gL.maxApprovedGasSpend only stores the gas units, must be scaled by tx.gasprice
        uint256 _maxApprovedGasValue = gL.maxApprovedGasSpend * tx.gasprice;

        return (bL.repays >= bL.borrows) && (_maxApprovedGasValue + _netRepayments >= gL.solverGasLiability());
    }
}
