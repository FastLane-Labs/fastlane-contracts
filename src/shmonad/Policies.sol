//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { AtomicUnstakePool } from "./AtomicUnstakePool.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";
import {
    Balance,
    Policy,
    PolicyAccount,
    CommittedData,
    UncommittingData,
    TopUpData,
    TopUpSettings,
    Delivery,
    Supply,
    UncommitApproval
} from "./Types.sol";
import { MIN_TOP_UP_PERIOD_BLOCKS } from "./Constants.sol";

/// @title Policies - Core commit and uncommit actions relating to ShMonad policies
/// @author FastLane Labs
/// @dev Implements commitment mechanism for shMON shares to policies with agent-controlled operations
/// and secure uncommitting with escrow periods. Uses an approval-based mechanism for uncommit completion.
abstract contract Policies is AtomicUnstakePool {
    using SafeTransferLib for address;
    using SafeCast for uint256;

    /// @notice Initializes the Policies contract
    constructor() { }

    // --------------------------------------------- //
    //   Commit, RequestUncommit, CompleteUncommit   //
    // --------------------------------------------- //

    /// @dev Commitment lifecycle:
    /// - Commit: Moves shares from uncommitted to committed under policy control
    /// - RequestUncommit: Starts escrow period defined by policy's escrowDuration
    /// - CompleteUncommit: After escrow, moves shares from uncommitting to uncommitted state

    /// @notice Commits shMON shares to a specific policy.
    /// @dev Directly calls _commitToPolicy with msg.sender as the source. Always review the policy's escrow duration,
    /// as extremely long escrows can make uncommitting effectively impossible.
    /// @param policyID The ID of the policy to commit into.
    /// @param commitRecipient The address that will own the committed shares.
    /// @param shares The amount of shMON shares to commit.
    /// @custom:selector 0xf0881442
    function commit(uint64 policyID, address commitRecipient, uint256 shares) external onlyActivePolicy(policyID) {
        _commitToPolicy(policyID, msg.sender, commitRecipient, shares);
    }

    /// @notice Deposits MON and commits the resulting shMON shares to a specific policy.
    /// @dev Combines deposit and commit for gas efficiency. Always review the policy's escrow duration before
    /// committing, as extremely long escrows can make uncommitting effectively impossible.
    /// @param policyID The ID of the policy to commit shares to.
    /// @param sharesRecipient The address that will own the committed shares.
    /// @param sharesToCommit The number of shMON shares to commit (use type(uint256).max to commit all newly minted
    /// shares).
    /// @return sharesMinted The amount of shMON shares minted (before any optional partial commit occurs).
    /// @custom:selector 0x9e1844c6
    function depositAndCommit(
        uint64 policyID,
        address sharesRecipient,
        uint256 sharesToCommit
    )
        external
        payable
        onlyActivePolicy(policyID)
        returns (uint256 sharesMinted)
    {
        // Mint shMON for msg.sender using the normal `deposit()` function.
        // Includes a Transfer event for the minted shMON.
        sharesMinted = deposit(msg.value, msg.sender);

        if (sharesToCommit == type(uint256).max) sharesToCommit = sharesMinted;

        // Then, commit the `sharesToCommit` in `sharesRecipient`'s policy committed balance.
        // This will also decrease the msg.sender's uncommitted balance.
        _commitToPolicy(policyID, msg.sender, sharesRecipient, sharesToCommit);
    }

    /// @notice Requests uncommitment of shares from a policy, starting the escrow countdown before completion.
    /// @dev Delegates to _requestUncommitFromPolicy for the core accounting and event emission.
    /// @param policyID The ID of the policy to request uncommitment from.
    /// @param shares The amount of shMON shares to request uncommitment for.
    /// @param newMinBalance The new minimum committed balance to maintain for automatic top-ups.
    /// @return uncommitCompleteBlock The block number when the uncommitting period will be complete.
    /// @custom:selector 0x417b7e51
    function requestUncommit(
        uint64 policyID,
        uint256 shares,
        uint256 newMinBalance
    )
        external
        returns (uint256 uncommitCompleteBlock)
    {
        uncommitCompleteBlock = _requestUncommitFromPolicy(policyID, msg.sender, shares, newMinBalance);
    }

    /// @notice Requests uncommitment and sets or updates an approval for a future completor.
    /// @dev Approval behavior accumulates share allowance and overwrites the completor address:
    /// - Shares: adds the requested `shares` to the existing approval allowance for future completions.
    /// - Completor: replaces the approved completor (use address(0) for an open approval).
    /// - Infinite approval: `type(uint96).max` represents an unlimited share allowance.
    /// @param policyID The ID of the policy to request uncommitment from.
    /// @param shares The amount of shMON shares to uncommit (and add to the approval allowance).
    /// @param newMinBalance The new minimum committed balance to maintain.
    /// @param completor The address authorized to complete the uncommit (zero address allows anyone).
    /// @return uncommitCompleteBlock The block number when the uncommitting period will be complete.
    /// @custom:selector 0x67070c95
    function requestUncommitWithApprovedCompletor(
        uint64 policyID,
        uint256 shares,
        uint256 newMinBalance,
        address completor
    )
        external
        returns (uint256 uncommitCompleteBlock)
    {
        uncommitCompleteBlock = _requestUncommitFromPolicy(policyID, msg.sender, shares, newMinBalance);

        UncommitApproval memory _uncommitApproval = s_uncommitApprovals[policyID][msg.sender];
        // Approval semantics: accumulates share allowance, overrides completor address.
        // - Passing address(0) makes approval open (anyone can complete).
        // - Use type(uint96).max via setUncommitApproval for infinite allowance.
        _uncommitApproval.completor = completor; // override completor for subsequent completions
        _uncommitApproval.shares += shares.toUint96(); // accumulate allowance by requested shares

        // Persist UncommitApproval changes to storage
        s_uncommitApprovals[policyID][msg.sender] = _uncommitApproval;

        emit UncommitApprovalUpdated(policyID, msg.sender, _uncommitApproval.completor, _uncommitApproval.shares);
    }

    /// @notice Completes uncommitment of shares after escrow, honoring any outstanding approval.
    /// @dev Operates on the passed `account`'s balances (not the caller's) and enforces approval semantics:
    /// - Completor: requires `msg.sender` to match the approved completor unless approval uses `address(0)`.
    /// - Allowance: decreases the approved shares unless it is `type(uint96).max` (infinite).
    /// @param policyID The ID of the policy to complete uncommitment from.
    /// @param shares The amount of shMON shares to complete uncommitment for.
    /// @param account The address whose uncommitting will be completed and who receives the shares.
    /// @custom:selector 0x4e4ed7fc
    function completeUncommitWithApproval(uint64 policyID, uint256 shares, address account) external {
        UncommitApproval memory _uncommitApproval = s_uncommitApprovals[policyID][account];
        // Operates on `account` balances, not caller's.
        // If completor == address(0) the approval is open and anyone may call.
        if (_uncommitApproval.completor != address(0)) {
            require(_uncommitApproval.completor == msg.sender, InvalidUncommitCompletor());
        }

        // If shares approval is not infinite (type(uint96).max), ensure sufficient allowance and reduce it
        if (_uncommitApproval.shares != type(uint96).max) {
            uint96 _shares96 = shares.toUint96();
            require(
                _uncommitApproval.shares >= _shares96, InsufficientUncommitApproval(_uncommitApproval.shares, shares)
            );
            _uncommitApproval.shares -= _shares96;

            // Only persist UncommitApproval changes to storage and emit event if shares were actually reduced
            s_uncommitApprovals[policyID][account] = _uncommitApproval;
            emit UncommitApprovalUpdated(policyID, account, _uncommitApproval.completor, _uncommitApproval.shares);
        }

        _completeUncommitFromPolicy(policyID, account, shares);
    }

    /// @notice Completes uncommitment of shares after the escrow period finishes.
    /// @dev Thin wrapper around _completeUncommitFromPolicy with msg.sender as the beneficiary.
    /// @param policyID The ID of the policy to complete uncommitment from.
    /// @param shares The amount of shMON shares to complete uncommitment for.
    /// @custom:selector 0x6a610788
    function completeUncommit(uint64 policyID, uint256 shares) external {
        _completeUncommitFromPolicy(policyID, msg.sender, shares);
    }

    /// @notice Completes uncommitment of shMON and immediately redeems the resulting shares for MON.
    /// @param policyID The ID of the policy from which to complete uncommitment of shMON.
    /// @param shares The amount of shMON to complete uncommitment for and then redeem for MON.
    /// @return assets The amount of MON redeemed for the given shMON shares.
    /// @custom:selector 0x3664f7af
    function completeUncommitAndRedeem(uint64 policyID, uint256 shares) external returns (uint256 assets) {
        _completeUncommitFromPolicy(policyID, msg.sender, shares);
        assets = redeem(shares, msg.sender, msg.sender);
    }

    /// @notice Completes uncommitment of shMON from one policy and commits it into another policy in a single call.
    /// @dev Maintains total committed supply by recommitting immediately after completing the uncommitment.
    /// @param fromPolicyID The policy to complete uncommitment from.
    /// @param toPolicyID The policy to commit shares to.
    /// @param sharesRecipient The address that will own the recommitted shares.
    /// @param shares The amount of shMON shares to move between policies.
    /// @custom:selector 0x9eaeb31a
    function completeUncommitAndRecommit(
        uint64 fromPolicyID,
        uint64 toPolicyID,
        address sharesRecipient,
        uint256 shares
    )
        external
        onlyActivePolicy(toPolicyID)
    {
        // changeCommittedTotalSupply = true in _commitToPolicy() below, as it would have decreased in the
        // requestUncommit() step
        // before the completeUncommit() step here
        _completeUncommitFromPolicy(fromPolicyID, msg.sender, shares);
        _commitToPolicy(toPolicyID, msg.sender, sharesRecipient, shares);
    }

    /// @notice Sets or overwrites the caller's uncommit approval for a policy.
    /// @dev Overrides any existing approval. Use `type(uint96).max` for infinite allowance and `address(0)` for an open
    /// approval that allows anyone to complete the uncommitment.
    /// @param policyID The ID of the policy for which to configure approval.
    /// @param completor The address authorized to complete uncommitment (zero address allows anyone).
    /// @param shares The maximum shares that can be completed using this approval.
    /// @custom:selector 0x55e69124
    function setUncommitApproval(uint64 policyID, address completor, uint256 shares) external {
        // Overrides any existing approval. For open approval set completor = address(0).
        // Use type(uint96).max to grant infinite allowance.
        s_uncommitApprovals[policyID][msg.sender] =
            UncommitApproval({ completor: completor, shares: shares.toUint96() });

        emit UncommitApprovalUpdated(policyID, msg.sender, completor, shares.toUint96());
    }

    // --------------------------------------------- //
    //           Top-Up Management Functions         //
    // --------------------------------------------- //

    /// @dev Top-Up Mechanism Design:
    ///
    /// The top-up system automatically maintains a minimum committed balance, ensuring users
    /// always have sufficient committed shares available for policy operations:
    ///
    /// 1. Purpose:
    /// - Ensures users can always cover operational costs via their committed balance
    /// - Prevents accounts from becoming inoperable due to insufficient committed shares
    /// - Allows users to set predictable limits on automatic recommitting
    ///
    /// 2. Parameters:
    /// - minCommitted: The minimum balance to maintain in the committed state
    /// - maxTopUpPerPeriod: Limit on how much can be automatically committed in a period
    /// - topUpPeriodDuration: Time window controlling top-up frequency (in blocks)
    ///
    /// 3. Mechanism:
    /// - When a user's committed balance falls below minCommitted, the system attempts to commit
    /// more shares from their uncommitted balance
    /// - Top-ups are capped by maxTopUpPerPeriod to prevent unexpected large transfers
    /// - Each period resets the top-up counter, managing frequency of automatic committing
    ///
    /// 4. Integration:
    /// - Top-up occurs automatically during _spendFromCommitted operations when needed
    /// - Users can disable top-up by setting parameters to zero

    /// @notice Sets the caller's minimum committed balance and automatic top-up settings for a policy.
    /// @dev Updates top-up settings in memory then persists to storage. Validates minimum period duration.
    /// @param policyID The ID of the policy whose thresholds are being updated.
    /// @param minCommitted The minimum committed balance to maintain.
    /// @param maxTopUpPerPeriod The maximum amount automatically recommitted per period.
    /// @param topUpPeriodDuration The duration of each top-up period in blocks.
    /// @custom:selector 0x9b5e7cf2
    function setMinCommittedBalance(
        uint64 policyID,
        uint128 minCommitted,
        uint128 maxTopUpPerPeriod,
        uint32 topUpPeriodDuration
    )
        external
        onlyActivePolicy(policyID)
    {
        TopUpSettings memory topUpSettings = s_topUpSettings[policyID][msg.sender];

        // Only enforce minimum duration if top-up is being enabled (non-zero values)
        // Users can disable top-up by setting all parameters to zero
        if (topUpPeriodDuration > 0) {
            require(
                topUpPeriodDuration >= MIN_TOP_UP_PERIOD_BLOCKS,
                TopUpPeriodDurationTooShort(topUpPeriodDuration, MIN_TOP_UP_PERIOD_BLOCKS)
            );
        }

        topUpSettings.maxTopUpPerPeriod = maxTopUpPerPeriod;
        topUpSettings.topUpPeriodDuration = topUpPeriodDuration;

        s_committedData[policyID][msg.sender].minCommitted = minCommitted;

        // Persist topUpSettings to storage
        s_topUpSettings[policyID][msg.sender] = topUpSettings;

        emit SetTopUp(policyID, msg.sender, minCommitted, maxTopUpPerPeriod, topUpPeriodDuration);
    }

    // --------------------------------------------- //
    //           Policy Management Functions         //
    // --------------------------------------------- //

    /// @dev Policies organize committed shares:
    /// - Each has unique ID, configuration, and authorized agents
    /// - Balances tracked per-user per-policy
    /// - Agents perform operations on committed shares
    /// - Policies can be disabled to prevent new commitments

    /// @notice Creates a new policy with the specified escrow duration.
    /// @dev Adds the caller as the first policy agent.
    /// @param escrowDuration The duration in blocks that uncommitting must wait before completion (<=
    /// type(uint48).max).
    /// @return policyID The ID of the newly created policy.
    /// @custom:selector 0x321677f2
    function createPolicy(uint48 escrowDuration) external returns (uint64 policyID) {
        policyID = ++s_policyCount; // First policyID is 1
        s_policies[policyID] = Policy(escrowDuration, true, msg.sender);
        _addPolicyAgent(policyID, msg.sender); // Add caller as first agent of the policy

        emit CreatePolicy(policyID, msg.sender, escrowDuration);
    }

    /// @notice Adds a policy agent to the specified policy.
    /// @dev Only callable by the contract owner; delegates to the internal _addPolicyAgent helper.
    /// @param policyID The ID of the policy.
    /// @param agent The address of the agent to add.
    /// @custom:selector 0x462fff96
    function addPolicyAgent(uint64 policyID, address agent) external onlyOwner {
        _addPolicyAgent(policyID, agent);

        emit AddPolicyAgent(policyID, agent);
    }

    /// @notice Removes a policy agent from the specified policy.
    /// @dev Only callable by the contract owner; delegates to the internal _removePolicyAgent helper.
    /// @param policyID The ID of the policy.
    /// @param agent The address of the agent to remove.
    /// @custom:selector 0x13788fe5
    function removePolicyAgent(uint64 policyID, address agent) external onlyOwner {
        _removePolicyAgent(policyID, agent);

        emit RemovePolicyAgent(policyID, agent);
    }

    /// @notice Disables a policy, blocking new commitments but still allowing uncommitting.
    /// @dev Only callable by a policy agent. This action is irreversible and policies cannot be re-enabled.
    /// @param policyID The ID of the policy to disable.
    /// @custom:selector 0x4d28a646
    function disablePolicy(uint64 policyID) external onlyPolicyAgentAndActive(policyID) {
        s_policies[policyID].active = false;

        emit DisablePolicy(policyID);
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    /// @notice Gets the block number when uncommitting will be complete for an account in a policy.
    /// @param policyID The ID of the policy to inspect.
    /// @param account The address whose uncommitting schedule is being queried.
    /// @return The block number when uncommitting will be complete.
    /// @custom:selector 0x822c6d6d
    function uncommittingCompleteBlock(uint64 policyID, address account) external view returns (uint256) {
        return s_uncommittingData[policyID][account].uncommitStartBlock + s_policies[policyID].escrowDuration;
    }

    /// @notice Returns the maximum amount a policy agent could take from an account.
    /// @dev Calculated as committed - held + uncommitting + remaining top-up allowance.
    /// @param policyID The ID of the policy being queried.
    /// @param account The account whose balances are evaluated.
    /// @param inUnderlying Whether to express the result in MON (true) or shMON (false).
    /// @return balanceAvailable The amount available for agent operations.
    /// @custom:selector 0x7d05b18e
    function policyBalanceAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        external
        view
        returns (uint256 balanceAvailable)
    {
        // Add account's committed balance
        balanceAvailable = s_committedData[policyID][account].committed;
        // Add account's uncommitting balance
        balanceAvailable += s_uncommittingData[policyID][account].uncommitting;
        // Add account's max top-up amount available
        balanceAvailable += topUpAvailable(policyID, account, false);
        // Subtract any holds on the account's committed balance
        balanceAvailable -= _getHoldAmount(policyID, account);

        // Convert from shMON to MON if required
        if (inUnderlying) balanceAvailable = previewRedeem(balanceAvailable);
    }

    /// @notice Returns the amount currently available via automatic top-up for an account in a policy.
    /// @param policyID The ID of the policy being queried.
    /// @param account The account whose top-up allowance is evaluated.
    /// @param inUnderlying Whether to express the result in MON (true) or shMON (false).
    /// @return amountAvailable The amount that can still be auto-committed this period.
    /// @custom:selector 0x97c76115
    function topUpAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        public
        view
        returns (uint256 amountAvailable)
    {
        TopUpSettings memory topUpSettings = s_topUpSettings[policyID][account];

        // Early returns for zero balances
        if (topUpSettings.maxTopUpPerPeriod == 0) return 0;

        uint256 uncommittedBalance = s_balances[account].uncommitted;
        if (uncommittedBalance == 0) return 0;

        TopUpData memory topUpData = s_topUpData[policyID][account];
        uint256 topUpLeftInPeriod;

        if (block.number > topUpData.topUpPeriodStartBlock + topUpSettings.topUpPeriodDuration) {
            // If in new top-up period, max top-up is available
            topUpLeftInPeriod = topUpSettings.maxTopUpPerPeriod;
        } else {
            // If in same top-up period, calc remaining top-up allowance
            if (topUpSettings.maxTopUpPerPeriod > topUpData.totalPeriodTopUps) {
                topUpLeftInPeriod = topUpSettings.maxTopUpPerPeriod - topUpData.totalPeriodTopUps;
            } else {
                return 0;
            }
        }

        // Top-up amount available is capped by the account's uncommitted balance
        amountAvailable = uncommittedBalance < topUpLeftInPeriod ? uncommittedBalance : topUpLeftInPeriod;

        // Convert from shMON to MON if required
        if (inUnderlying) amountAvailable = previewRedeem(amountAvailable);
        return amountAvailable;
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    /// @notice Returns top-up settings for an account (no structs).
    /// @return maxTopUpPerPeriod Maximum top-up per period
    /// @return topUpPeriodDuration Duration of top-up period in blocks
    /// @custom:selector 0x7bca5126
    function getTopUpSettings(
        uint64 policyID,
        address account
    )
        external
        view
        returns (uint128 maxTopUpPerPeriod, uint32 topUpPeriodDuration)
    {
        TopUpSettings memory _topUpSettings = s_topUpSettings[policyID][account];
        return (_topUpSettings.maxTopUpPerPeriod, _topUpSettings.topUpPeriodDuration);
    }

    /// @notice Returns committed data (committed amount and minCommitted threshold).
    /// @custom:selector 0x584e3785
    function getCommittedData(
        uint64 policyID,
        address account
    )
        external
        view
        returns (uint128 committed, uint128 minCommitted)
    {
        CommittedData memory _committedData = s_committedData[policyID][account];
        return (_committedData.committed, _committedData.minCommitted);
    }

    /// @notice Returns uncommitting data (uncommitting amount and start block).
    /// @custom:selector 0x67f6007c
    function getUncommittingData(
        uint64 policyID,
        address account
    )
        external
        view
        returns (uint128 uncommitting, uint48 uncommitStartBlock)
    {
        UncommittingData memory _uncommittingData = s_uncommittingData[policyID][account];
        return (_uncommittingData.uncommitting, _uncommittingData.uncommitStartBlock);
    }

    /// @notice Gets the uncommit approval settings for an account in a policy
    /// @param policyID The ID of the policy
    /// @param account The address to check
    /// @return approval The uncommit approval (completor and approved shares)
    /// @custom:selector 0x4cac8783
    function getUncommitApproval(
        uint64 policyID,
        address account
    )
        external
        view
        returns (UncommitApproval memory approval)
    {
        approval = s_uncommitApprovals[policyID][account];
    }

    // --------------------------------------------- //
    //                Internal Functions             //
    // --------------------------------------------- //

    /// @dev Commits shares to a policy from one account to a recipient
    /// @param policyID The ID of the policy
    /// @param accountFrom The address providing the shares
    /// @param sharesRecipient The address receiving the committed shares
    /// @param shares The amount of shMON shares to commit
    /// @dev Implementation details:
    /// 1. Checks if accountFrom has sufficient uncommitted balance
    /// 2. If accountFrom != sharesRecipient, handles as a transfer + commit
    /// 3. If accountFrom == sharesRecipient, handles as a simple commit
    /// 4. Updates committed balance in the policy and total committed supply if requested
    /// 5. Emits Transfer event for cross-account transfers and Commit event in all cases
    function _commitToPolicy(uint64 policyID, address accountFrom, address sharesRecipient, uint256 shares) internal {
        Balance memory fromBalance = s_balances[accountFrom];
        uint128 shares128 = shares.toUint128();

        require(sharesRecipient != address(0), CommitRecipientCannotBeZeroAddress());
        require(fromBalance.uncommitted >= shares128, InsufficientUncommittedBalance(fromBalance.uncommitted, shares));

        if (sharesRecipient != accountFrom) {
            // from and recipient are different --> effectively a transfer(), then a commit()

            // Increase recipient's committed balance, then persist to storage
            Balance memory recipientBalance = s_balances[sharesRecipient];
            recipientBalance.committed += shares128;
            s_balances[sharesRecipient] = recipientBalance;

            // No Transfer(from, recipient) event. Instead the Transfer pattern is:
            // - commit = Transfer(from, ShMonad)
            // - completeUncommit = Transfer(ShMonad, recipient)
        } else {
            // from and recipient are the same --> effectively just a commit() action
            fromBalance.committed += shares128;
            // No transfer event required
        }

        // Safe unchecked arithmetic due to [uncommitted >= amount] check above
        unchecked {
            // In both cases above, from's uncommitted balance decreases. Underflow check at start of func.
            fromBalance.uncommitted -= shares128;

            // Increase sharesRecipient's committed balance in the policy
            s_committedData[policyID][sharesRecipient].committed += shares128;

            // Increase committedTotalSupply
            s_supply.committedTotal += shares128;
        }

        // Persist changes in from's balance to storage
        s_balances[accountFrom] = fromBalance;

        emit Commit(policyID, sharesRecipient, shares);

        // For frontends: we track commits/uncommits as transfers to/from this ShMonad contract
        emit Transfer(accountFrom, address(this), shares);
    }

    /// @dev Requests uncommitment of shares from a policy, starting the escrow period
    /// @param policyID The ID of the policy
    /// @param account The address uncommitting shares
    /// @param shares The amount of shMON shares to uncommit
    /// @param newMinBalance The new minimum balance for top-up settings
    /// @return uncommitCompleteBlock The block number when the uncommitting period will be complete
    /// @dev Implementation details:
    /// 1. Checks if account has sufficient unheld committed balance
    /// 2. Decreases account's committed balance and the total committed supply
    /// 3. Increases account's uncommitting balance and sets the uncommit start block
    /// 4. Updates the caller's minCommitted threshold to the new minimum balance
    /// 5. Calculates and returns the block when uncommitting will be complete
    function _requestUncommitFromPolicy(
        uint64 policyID,
        address account,
        uint256 shares,
        uint256 newMinBalance
    )
        internal
        returns (uint256 uncommitCompleteBlock)
    {
        CommittedData memory committedData = s_committedData[policyID][account];
        UncommittingData memory uncommittingData = s_uncommittingData[policyID][account];

        uint128 shares128 = shares.toUint128();
        uint128 held128 = _getHoldAmount(policyID, account).toUint128();

        require(
            committedData.committed - held128 >= shares128,
            InsufficientUnheldCommittedBalance(committedData.committed, held128, shares128)
        );

        // Should not be able to underflow due to check above
        unchecked {
            // Decrease account's total committed and policy committed balances
            committedData.committed -= shares128;
            s_balances[account].committed -= shares128;

            // Also decrease totalCommittedSupply due to decrease in committed balance
            s_supply.committedTotal -= shares128;

            // Increase account's uncommitting balance and update uncommitStartBlock
            uncommittingData.uncommitting += shares128;
            uncommittingData.uncommitStartBlock = uint48(block.number);
        }

        // Persist the caller's new minimum committed balance threshold
        committedData.minCommitted = newMinBalance.toUint128();

        // Persist changes in memory struct to storage
        s_committedData[policyID][account] = committedData;
        s_uncommittingData[policyID][account] = uncommittingData;

        // Calculate the block at which the uncommitting will be complete, for event and return value
        uncommitCompleteBlock = block.number + s_policies[policyID].escrowDuration;

        emit RequestUncommit(policyID, account, shares, uncommitCompleteBlock);
    }

    /// @dev Completes uncommitment after escrow period completion
    /// @param policyID The ID of the policy
    /// @param account The address completing uncommitment
    /// @param shares The amount of shMON shares to complete uncommitment for
    /// @dev Implementation details:
    /// 1. Checks if the uncommitting period is complete
    /// 2. Verifies account has sufficient uncommitting balance
    /// 3. Decreases account's uncommitting balance and increases their uncommitted balance
    function _completeUncommitFromPolicy(uint64 policyID, address account, uint256 shares) internal {
        UncommittingData memory uncommittingData = s_uncommittingData[policyID][account];
        uint256 policyEscrowDuration = s_policies[policyID].escrowDuration;
        uint128 shares128 = shares.toUint128();

        require(
            block.number >= uncommittingData.uncommitStartBlock + policyEscrowDuration,
            UncommittingPeriodIncomplete(uncommittingData.uncommitStartBlock + policyEscrowDuration)
        );

        // This check ensures no overflows or underflows below
        require(
            uncommittingData.uncommitting >= shares128,
            InsufficientUncommittingBalance(uncommittingData.uncommitting, shares)
        );

        unchecked {
            // Decrease account's uncommitting balance
            uncommittingData.uncommitting -= shares128;

            // Increase account's uncommitted balance
            s_balances[account].uncommitted += shares128;
        }

        // Persist changes in memory struct to storage
        s_uncommittingData[policyID][account] = uncommittingData;

        emit CompleteUncommit(policyID, account, shares);

        // For frontends: we track commits/uncommits as transfers to/from this ShMonad contract
        emit Transfer(address(this), account, shares);
    }

    /// @dev Respects any holds on the account's committed balance and decreases it if sufficient after deducting holds.
    /// May attempt top-up if needed, then draws from uncommitting if necessary.
    /// @param committedData Memory struct containing the account's committed data
    /// @param policyID The ID of the policy
    /// @param account The address whose committed balance is being decreased
    /// @param shares The amount of shMON shares to spend
    /// @param out Whether to decrease the committedTotalSupply
    /// @dev Implementation details:
    /// 1. Calculates available funds after deducting holds
    /// 2. If insufficient funds, first try take from account's uncommitting balance
    /// 3. If still insufficient funds, attempt top-up from account's uncommitted balance
    /// 4. If still insufficient after trying uncommitting and top-up sources, reverts with InsufficientFunds error
    /// 5. Updates balances in memory structures (must be persisted to storage separately)
    /// 6. Decreases both committedTotalSupply and totalSupply, depending on the `out` parameter
    function _spendFromCommitted(
        CommittedData memory committedData,
        uint64 policyID,
        address account,
        uint128 shares,
        Delivery out
    )
        internal
    {
        Balance memory balance = s_balances[account];
        uint128 held128 = _getHoldAmount(policyID, account).toUint128();
        uint128 fundsAvailable = committedData.committed - held128; // Initially just unheld committed balance
        uint128 newSharesCommitted; // Cumulative shares committed through the `_increaseTopUpSpend()` calls
        uint256 minCommittedRequired = uint256(shares) + uint256(committedData.minCommitted);

        // If account's committed balance is insufficient, try make up the shortfall from other sources in this order:
        // 1) Uncommitting balance
        // 2) Uncommitted balance, if top-up is enabled

        // First, try take from uncommitting balance
        if (uint256(fundsAvailable) < minCommittedRequired) {
            // Load account's uncommitting data
            UncommittingData memory uncommittingData = s_uncommittingData[policyID][account];

            // Take the shortfall from uncommitting, up to a max of the account's total uncommitting balance
            uint128 takenFromUncommitting = Math.min(
                minCommittedRequired - uint256(fundsAvailable), uint256(uncommittingData.uncommitting)
            ).toUint128();

            // Decrease account's uncommitting balance
            uncommittingData.uncommitting -= takenFromUncommitting;
            // Increase account's policy-specific committed balance
            committedData.committed += takenFromUncommitting;
            // Increase account's total committed balance
            balance.committed += takenFromUncommitting;

            // Increase the total committed supply by the amount taken from uncommitting
            newSharesCommitted = takenFromUncommitting;

            // Persist uncommitting data to storage
            s_uncommittingData[policyID][account] = uncommittingData;

            // Update fundsAvailable after moving funds from uncommitting to committed above
            fundsAvailable = committedData.committed - held128;

            // TODO add new event here to indicate flow of funds from uncommitting back to committed
        }

        // Second, if fundsAvailable is still insufficient, try top-up from uncommitted balance
        if (uint256(fundsAvailable) < minCommittedRequired) {
            uint128 committedShortfall =
                Math.min(minCommittedRequired - uint256(fundsAvailable), uint256(type(uint128).max)).toUint128();

            // NOTE: will attempt to top up to user's minCommitted level in addition to any shortfall top-up
            newSharesCommitted += _tryTopUp(balance, committedData, policyID, account, committedShortfall);

            // Update fundsAvailable again after top-up
            fundsAvailable = committedData.committed - held128;

            // NOTE: No additional Commit/Transfer events needed here as the `_tryTopUp()` call above emits them.
        }

        // If fundsAvailable is still insufficient after attempting to draw from uncommitting and uncommitted via
        // top-up, revert with InsufficientFunds error
        require(
            fundsAvailable >= shares,
            InsufficientFunds(
                committedData.committed, s_uncommittingData[policyID][account].uncommitting, held128, shares
            )
        );

        // Safe to do unchecked subtractions due to early revert above if underflow would occur
        unchecked {
            // Decrease account's committed balance (in the policy and total balances)
            committedData.committed -= shares;
            balance.committed -= shares;
        }

        // Persist Balance changes to storage before early return - not modified again in this function.
        s_balances[account] = balance;

        // No new shares committed from uncommitting or top-up, and no change to committedTotalSupply --> return early
        if (newSharesCommitted == 0 && out == Delivery.Committed) return;

        // Finally, make the net changes to totalSupply and committedTotalSupply
        Supply memory supply = s_supply;

        if (out == Delivery.Committed) {
            // CASE: Committed shMON -> Committed shMON
            // --> No change to totalSupply (as no shMON burnt).
            // --> No decrease to committedTotalSupply (as it stays in committed form), but there is an increase due to
            // either
            // taken from uncommitting or uncommitted via top-up.
            supply.committedTotal += newSharesCommitted;
        } else if (out == Delivery.Uncommitted) {
            // CASE: Committed shMON -> Uncommitted shMON
            // --> No change to totalSupply (as no shMON burnt).
            // --> Decrease committedTotalSupply by `shares` being spent.
            // --> Potentially increase committedTotalSupply either taken from uncommitting or uncommitted via top-up.

            // NOTE: Cannot assume shares > committedSupplyIncrease, due to potential top-up to minCommitted level

            // First increase supply.committedTotal by any newly-committed shares
            supply.committedTotal += newSharesCommitted;
            // Then decrease supply.committedTotal by the shares being spent
            supply.committedTotal -= shares;
        } else {
            // CASE: Committed shMON -> Underlying MON
            // (i.e. if out == Delivery.Underlying)
            // --> Decrease totalSupply by `shares` being spent (shMON burnt).
            // --> Decrease committedTotalSupply by `shares` being spent.
            // --> Potentially increase committedTotalSupply either taken from uncommitting or uncommitted via top-up.

            // NOTE: Cannot assume shares > committedSupplyIncrease, due to potential top-up to minCommitted level

            // First increase supply.committedTotal by any newly-committed shares
            supply.committedTotal += newSharesCommitted;
            // Then decrease supply.committedTotal by the shares being spent
            supply.committedTotal -= shares;
            // Finally, decrease supply.total (uncommitted) by shares which will be burnt for underlying
            supply.total -= shares;

            // TODO add event to indicate that committed shMON was instantly uncommitted + completed + withdrawn
        }

        // Persist supply changes to storage
        s_supply = supply;

        // NOTE: CommittedData changes must be persisted to storage separately.
    }

    // Returns the amount of new shares committed via top-up. Possible values are between 0 and the requested shortfall,
    // clamped by both the account's remaining top-up allowance and uncommitted balance.
    function _tryTopUp(
        Balance memory balance,
        CommittedData memory committedData,
        uint64 policyID,
        address account,
        uint128 sharesRequested
    )
        internal
        returns (uint128)
    {
        TopUpData memory topUpData = s_topUpData[policyID][account];
        TopUpSettings memory topUpSettings = s_topUpSettings[policyID][account];
        uint128 sharesCommitted; // Will be set to the shMON amount taken from uncommitted balance and committed here

        // If in new top-up period, reset period vars
        if (block.number > topUpData.topUpPeriodStartBlock + topUpSettings.topUpPeriodDuration) {
            topUpData.totalPeriodTopUps = 0;
            topUpData.topUpPeriodStartBlock = uint48(block.number);
        }

        // Determine how much headroom remains in the current top-up period
        uint128 remainingTopUpAllowance;
        if (topUpSettings.maxTopUpPerPeriod > topUpData.totalPeriodTopUps) {
            remainingTopUpAllowance = topUpSettings.maxTopUpPerPeriod - topUpData.totalPeriodTopUps;
        } else {
            return 0;
        }

        // Clamp the next top-up by both remaining allowance and the user's uncommitted balance
        uint128 capacity = Math.min(balance.uncommitted, remainingTopUpAllowance).toUint128();
        if (capacity == 0) return 0;

        // Never commit more than the shortfall requested by the caller
        sharesCommitted = Math.min(sharesRequested, capacity).toUint128();

        unchecked {
            // Changes to account's memory structs.
            committedData.committed += sharesCommitted;
            topUpData.totalPeriodTopUps += sharesCommitted;

            // Decrease account's uncommitted balance
            balance.uncommitted -= sharesCommitted;

            // Increase account's total committed balance
            balance.committed += sharesCommitted;
        }

        // Persist topUpData changes to storage
        s_topUpData[policyID][account] = topUpData;

        // Commit event indicates the total flow of funds from uncommitted --> committed here
        emit Commit(policyID, account, sharesCommitted);

        // For frontends: we track commits/uncommits as transfers to/from this ShMonad contract
        emit Transfer(account, address(this), sharesCommitted);

        // committedTotalSupply has increased by `sharesCommitted`. This change to the storage value must be made
        // separately
        // to minimize gas useage.
        return sharesCommitted;
    }

    /// @dev Adds a policy agent to the specified policy
    /// @param policyID The ID of the policy
    /// @param agent The address of the agent to add
    /// @dev Implementation details:
    /// 1. Checks that the address is not already an agent for the policy
    /// 2. Sets the mapping flag and adds to the agents array
    function _addPolicyAgent(uint64 policyID, address agent) internal {
        require(!_isPolicyAgent(policyID, agent), PolicyAgentAlreadyExists(policyID, agent));
        s_isPolicyAgent[policyID][agent] = true; // Set agent to true in isPolicyAgent mapping
        s_policyAgents[policyID].push(agent); // Add agent to policyAgents array
    }

    /// @dev Removes a policy agent from the specified policy
    /// @param policyID The ID of the policy
    /// @param agent The address of the agent to remove
    /// @dev Implementation details:
    /// 1. Ensures the policy still has at least one agent after removal
    /// 2. Verifies the address is currently an agent
    /// 3. Sets the mapping flag to false and removes from the agents array
    /// 4. Replaces the removed agent with the last agent in the array and pops the array
    function _removePolicyAgent(uint64 policyID, address agent) internal {
        uint256 agentCount = s_policyAgents[policyID].length;

        require(agentCount > 1, PolicyNeedsAtLeastOneAgent(policyID));
        require(_isPolicyAgent(policyID, agent), PolicyAgentNotFound(policyID, agent));

        // Set agent to false in isPolicyAgent mapping
        s_isPolicyAgent[policyID][agent] = false;

        // Remove agent from policyAgents array
        for (uint256 i = 0; i < agentCount; ++i) {
            if (s_policyAgents[policyID][i] == agent) {
                s_policyAgents[policyID][i] = s_policyAgents[policyID][agentCount - 1];
                s_policyAgents[policyID].pop();
                break;
            }
        }

        // Remove as primary, if applicable
        if (agent == s_policies[policyID].primaryAgent && s_policyAgents[policyID].length != 0) {
            s_policies[policyID].primaryAgent = s_policyAgents[policyID][0];
        }
    }

    /// @dev Reverts if policy is not active
    /// @param policyID The ID of the policy to check
    function _onlyActivePolicy(uint64 policyID) internal view {
        require(s_policies[policyID].active, PolicyInactive(policyID));
    }

    // --------------------------------------------- //
    //                     Modifiers                 //
    // --------------------------------------------- //

    /// @dev Modifier that reverts if the policy is not active
    /// @param policyID The ID of the policy to check
    modifier onlyActivePolicy(uint64 policyID) {
        _onlyActivePolicy(policyID);
        _;
    }
}
