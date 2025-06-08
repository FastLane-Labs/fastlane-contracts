//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

contract TaskErrors {
    // Core task management errors
    error TaskNotFound(bytes32 taskId);
    error Unauthorized(address caller, address owner);
    error TaskAlreadyRescheduled(bytes32 taskId);
    error TaskAlreadyCancelled(bytes32 taskId);
    error TaskAlreadyExecuted(bytes32 taskId);
    error TaskCostAboveMax(uint256 cost, uint256 maxPayment);
    error TaskMustRescheduleSelf();
    error TaskGasTooLarge(uint256 gasLimit);
    error TaskManagerLocked();

    // Bond errors
    error InvalidPayoutAddress(address payoutAddress);
    error BoostYieldFailed(address from, uint256 amount);
    error ValidatorReimbursementFailed(address from, uint256 amount);
    error ExecutorReimbursementFailed(address from, uint256 amount);
    error InvalidPaymentAmount(uint256 expected, uint256 provided);

    // Task validation errors
    error TaskValidation_InvalidTargetAddress();
    error TaskValidation_TargetBlockInPast(uint64 targetBlock, uint256 currentBlock);
    error TaskValidation_TargetBlockTooFar(uint64 targetBlock, uint256 currentBlock);
    error InvalidCancellerAddress();

    // Execution errors
    error NoActiveTask();
    error LookaheadExceedsMaxScheduleDistance(uint64 lookahead);
    error NextExecutionBlock(uint64 blockNumber);

    // TaskManagerEntrypoint errors
    error InvalidPolicyId();
    error InvalidShMonadAddress();
}
