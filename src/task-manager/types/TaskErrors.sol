//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

contract TaskErrors {
    // Core task management errors
    error TaskNotFound(bytes32 taskId);
    error Unauthorized(address caller, address owner);
    error TaskAlreadyScheduled(bytes32 taskHash);
    error TaskAlreadyRescheduled(bytes32 taskId);
    error TaskAlreadyCancelled(bytes32 taskId);
    error TaskAlreadyExecuted(bytes32 taskId);
    error TaskExecutionFailed(bytes32 taskHash, bytes returnData);
    error TaskCostAboveMax(uint256 cost, uint256 maxPayment);
    error TaskMustRescheduleSelf();
    error TaskExpired();
    error TaskGasTooLarge(uint256 gasLimit);
    error TaskManagerLocked();

    // Bond errors
    error InsufficientBond(uint256 required, uint256 actual);
    error TaskSchedulePaymentFailed(address from, uint256 amount);
    error InvalidGasReserve(uint256 provided, uint256 minimum);
    error InvalidPayoutAddress(address payoutAddress);
    error BoostYieldFailed(address from, uint256 amount);
    error ValidatorReimbursementFailed(address from, uint256 amount);
    error ExecutorReimbursementFailed(address from, uint256 amount);
    error InvalidPaymentAmount(uint256 expected, uint256 provided);

    // Task validation errors
    error TaskValidation_InvalidTargetAddress();
    error CallerNotOwnerOrTaskManager();
    error TaskValidation_TargetBlockInPast(uint64 targetBlock, uint256 currentBlock);
    error TaskValidation_TargetBlockTooFar(uint64 targetBlock, uint256 currentBlock);
    error InvalidAgentAddress();
    error InvalidCancellerAddress();

    // Execution errors
    error TooManyTasksScheduled();
    error NoRecursiveExecution();
    error NoActiveTask();
    error RescheduleTooSoon();
    error LookaheadExceedsMaxScheduleDistance(uint64 lookahead);
    error NextExecutionBlock(uint64 blockNumber);

    // TaskManagerEntrypoint errors
    error InvalidPolicyId();
    error InvalidShMonadAddress();
}
