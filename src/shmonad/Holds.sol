//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ShMonadStorage } from "./Storage.sol";
import { HoldsLib } from "./libraries/HoldsLib.sol";
import { PolicyAccount, BondedData } from "./Types.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";

/**
 * @title ShMonadHolds
 * @author FastLane Labs
 * @notice Transient storage-based Holds mechanism to prevent malicious unbonding during a transaction.
 * @dev Key security features:
 *   - Policy agents can temporarily lock user's bonded shares
 *   - Held shares cannot be unbonded, preventing front-running attacks
 *   - Implemented using transient storage for transaction-duration holds
 *   - Only authorized agents can create/release holds
 *   - Bonds contract respects holds during unbond operations
 */
abstract contract ShMonadHolds is ShMonadStorage {
    using HoldsLib for PolicyAccount;

    // --------------------------------------------- //
    //           onlyPolicyAgent Functions           //
    // --------------------------------------------- //

    /**
     * @inheritdoc IShMonad
     * @dev If a hold is already active for an account, the new amount will be added to the existing hold
     * @dev Will revert if the account's bonded value is insufficient to cover the hold
     */
    function hold(uint64 policyID, address account, uint256 amount) external onlyPolicyAgent(policyID) {
        _hold(policyID, account, amount);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Deducts amount from any existing hold on the account
     * @dev If release amount exceeds the held amount, the hold will be set to 0
     */
    function release(uint64 policyID, address account, uint256 amount) external onlyPolicyAgent(policyID) {
        _release(policyID, account, amount);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Batch version of hold() for gas efficiency when processing multiple accounts
     * @dev Will revert if any account's bonded value is insufficient to cover its hold
     */
    function batchHold(
        uint64 policyID,
        address[] calldata accounts,
        uint256[] memory amounts
    )
        external
        onlyPolicyAgent(policyID)
    {
        for (uint256 i = 0; i < accounts.length; ++i) {
            _hold(policyID, accounts[i], amounts[i]);
        }
    }

    /**
     * @inheritdoc IShMonad
     * @dev Batch version of release() for gas efficiency when processing multiple accounts
     */
    function batchRelease(
        uint64 policyID,
        address[] calldata accounts,
        uint256[] calldata amounts
    )
        external
        onlyPolicyAgent(policyID)
    {
        for (uint256 i = 0; i < accounts.length; ++i) {
            _release(policyID, accounts[i], amounts[i]);
        }
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    /**
     * @inheritdoc IShMonad
     * @dev Uses transient storage through the HoldsLib library to retrieve the current hold amount
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
     * @dev Accesses the policy's bonded data from storage before placing the hold
     * @param policyID The ID of the policy
     * @param account The address whose shares will be held
     * @param amount The amount of shares to place on hold
     */
    function _hold(uint64 policyID, address account, uint256 amount) internal {
        BondedData storage bondedData = s_bondedData[policyID][account];
        PolicyAccount(policyID, account).hold(bondedData, amount);
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
    modifier onlyPolicyAgent(uint64 policyID) {
        require(_isPolicyAgent(policyID, msg.sender), NotPolicyAgent(policyID, msg.sender));
        _;
    }
}
