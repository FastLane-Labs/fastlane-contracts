//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { ShMonadStorage } from "./Storage.sol";
import { HoldsLib } from "./libraries/HoldsLib.sol";
import { PolicyAccount, CommittedData, Policy } from "./Types.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";

/**
 * @title ShMonadHolds
 * @author FastLane Labs
 * @notice Transient storage-based Holds mechanism to prevent malicious uncommitting during a transaction.
 * @dev Key security features:
 *   - Policy agents can temporarily lock user's committed shares
 *   - Held shares cannot be uncommitted, preventing front-running attacks
 *   - Implemented using transient storage for transaction-duration holds
 *   - Only authorized agents can create/release holds
 *   - Policies contract respects holds during uncommit operations
 */
abstract contract ShMonadHolds is ShMonadStorage {
    using HoldsLib for PolicyAccount;

    // --------------------------------------------- //
    //           onlyPolicyAgent Functions           //
    // --------------------------------------------- //

    /**
     * @notice Places a hold on a specific amount of an account's committed shares in a policy.
     * @dev If a hold is already active for an account, the new amount is added to the existing hold. Held shares cannot
     *      be uncommitted until released and the call reverts if the account lacks sufficient committed value.
     * @param policyID The ID of the policy.
     * @param account The address whose shares will be held.
     * @param amount The amount of shares to hold.
     */
    function hold(uint64 policyID, address account, uint256 amount) external onlyPolicyAgentAndActive(policyID) {
        _hold(policyID, account, amount);
    }

    /**
     * @notice Releases previously held shares for an account in a policy.
     * @dev Deducts `amount` from the existing hold; if the release exceeds the hold, it is set to zero.
     * @param policyID The ID of the policy.
     * @param account The address whose shares will be released.
     * @param amount The amount of shares to release.
     */
    function release(uint64 policyID, address account, uint256 amount) external onlyPolicyAgentAndActive(policyID) {
        _release(policyID, account, amount);
    }

    /**
     * @notice Places holds on multiple accounts' committed shares in a policy.
     * @dev Batch version of hold() for gas efficiency; reverts if any account lacks sufficient committed value.
     * @param policyID The ID of the policy.
     * @param accounts Array of addresses whose shares will be held.
     * @param amounts Array of hold amounts for each account.
     */
    function batchHold(
        uint64 policyID,
        address[] calldata accounts,
        uint256[] memory amounts
    )
        external
        onlyPolicyAgentAndActive(policyID)
    {
        require(
            accounts.length == amounts.length, BatchHoldAccountAmountLengthMismatch(accounts.length, amounts.length)
        );
        for (uint256 i = 0; i < accounts.length; ++i) {
            _hold(policyID, accounts[i], amounts[i]);
        }
    }

    /**
     * @notice Releases previously held shares for multiple accounts in a policy.
     * @dev Batch version of release() for gas efficiency when processing multiple accounts.
     * @param policyID The ID of the policy.
     * @param accounts Array of addresses whose shares will be released.
     * @param amounts Array of release amounts for each account.
     */
    function batchRelease(
        uint64 policyID,
        address[] calldata accounts,
        uint256[] calldata amounts
    )
        external
        onlyPolicyAgentAndActive(policyID)
    {
        require(
            accounts.length == amounts.length, BatchReleaseAccountAmountLengthMismatch(accounts.length, amounts.length)
        );
        for (uint256 i = 0; i < accounts.length; ++i) {
            _release(policyID, accounts[i], amounts[i]);
        }
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    /**
     * @notice Gets the amount of shares that are held for an account in a policy.
     * @dev Uses transient storage through the HoldsLib library to retrieve the current hold amount.
     * @param policyID The ID of the policy.
     * @param account The address to check.
     * @return The amount of shares held.
     */
    function getHoldAmount(uint64 policyID, address account) external view returns (uint256) {
        return _getHoldAmount(policyID, account);
    }

    // --------------------------------------------- //
    //                Internal Functions             //
    // --------------------------------------------- //

    /**
     * @notice Internal implementation of the hold functionality
     * @dev Uses the HoldsLib to place a hold on the account's shares
     * @dev Accesses the policy's committed data from storage before placing the hold
     * @param policyID The ID of the policy
     * @param account The address whose shares will be held
     * @param amount The amount of shares to place on hold
     */
    function _hold(uint64 policyID, address account, uint256 amount) internal {
        CommittedData storage committedData = s_committedData[policyID][account];
        PolicyAccount(policyID, account).hold(committedData, amount);
    }

    /**
     * @notice Internal implementation of the release functionality
     * @dev Uses the HoldsLib to release a hold on the account's shares
     * @param policyID The ID of the policy
     * @param account The address whose shares will be released
     * @param amount The amount of shares to release from hold
     */
    function _release(uint64 policyID, address account, uint256 amount) internal {
        PolicyAccount(policyID, account).release(amount);
    }

    /**
     * @notice Internal implementation to get the amount of shares on hold
     * @dev Uses the HoldsLib to access the transient storage value of hold amount
     * @param policyID The ID of the policy
     * @param account The address to check the hold amount for
     * @return The amount of shares currently on hold
     */
    function _getHoldAmount(uint64 policyID, address account) internal view returns (uint256) {
        return PolicyAccount(policyID, account).getHoldAmount();
    }

    // --------------------------------------------- //
    //                     Modifiers                 //
    // --------------------------------------------- //

    /**
     * @notice Restricts function access to policy agents only
     * @dev Checks if the msg.sender is an agent for the specified policy
     * @param policyID The ID of the policy to check agent status for
     */
    modifier onlyPolicyAgentAndActive(uint64 policyID) {
        Policy memory _policy = s_policies[policyID];
        require(_policy.active, PolicyInactive(policyID));
        if (msg.sender != _policy.primaryAgent) {
            require(_isPolicyAgent(policyID, msg.sender), NotPolicyAgent(policyID, msg.sender));
        }
        _;
    }
}
