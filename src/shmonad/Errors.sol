//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

abstract contract ShMonadErrors {
    // Holds
    error NotPolicyAgent(uint64 policyID, address caller);

    // Bonds
    error InsufficientUnbondedBalance(uint256 available, uint256 requested);
    error InsufficientUnheldBondedBalance(uint128 bonded, uint128 held, uint128 requested);
    error InsufficientFunds(uint128 bonded, uint128 unbonding, uint128 held, uint128 requested);
    error InsufficientUnbondingBalance(uint256 available, uint256 requested);
    error UnbondingPeriodIncomplete(uint256 unbondingCompleteBlock);
    error PolicyInactive(uint64 policyID);
    error PolicyAgentAlreadyExists(uint64 policyID, address agent);
    error PolicyAgentNotFound(uint64 policyID, address agent);
    error PolicyNeedsAtLeastOneAgent(uint64 policyID);
    error TopUpPeriodDurationTooShort(uint32 requestedPeriodDuration, uint32 minPeriodDuration);
    error AgentSelfUnbondingDisallowed(uint64 policyID, address agent);

    // ShMonad
    error MsgDotValueExceedsMsgValueArg(uint256 msgDotValue, uint256 msgValueArg);
    error MsgGasLimitTooLow(uint256 gasLeft, uint256 gasLimit);

    // ERC4626
    error InsufficientNativeTokenSent();

    // Setup
    error InvalidTaskManagerAddress();
    error InvalidSponsoredExecutorAddress();
}
