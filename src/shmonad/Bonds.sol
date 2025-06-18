//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { FastLaneERC4626 } from "./FLERC4626.sol";
import { PolicyERC20Wrapper } from "./PolicyERC20Wrapper.sol";
import {
    Balance,
    Policy,
    PolicyAccount,
    BondedData,
    UnbondingData,
    TopUpData,
    TopUpSettings,
    Delivery,
    Supply
} from "./Types.sol";

import { ShMonadStorage } from "./Storage.sol";

import { ITaskManager } from "../task-manager/interfaces/ITaskManager.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";

/**
 * @title Bonds - Core bonding, unbonding, and claiming functionality for ShMonad
 * @author FastLane Labs
 * @dev Implements bonding mechanism for shMON shares to policies with agent-controlled operations
 *      and secure unbonding with escrow periods. Integrates with TaskManager for scheduled claims.
 */
abstract contract Bonds is FastLaneERC4626 {
    using SafeTransferLib for address;
    using SafeCast for uint256;

    // The address of the UnbondingTask implementation
    address private immutable _UNBONDING_TASK;
    // The address of the Task Manager
    address internal immutable _TASK_MANAGER;
    address internal immutable _SPONSORED_EXECUTOR;

    /**
     * @dev Storage architecture:
     * - User balances: bonded and unbonded balances per user
     * - Policy data: tracking bonded, unbonding, holds per-policy-per-user
     * - Top-up mechanism: maintains minimum bonded balances
     * - Policy settings: escrow duration and active status
     * - Agent permissions: authorized policy operators
     */

    /**
     * @notice Initializes the Bonds contract
     * @param sponsoredExecutor The address of the SponsoredExecutor contract
     * @param taskManager The address of the TaskManager contract
     * @param unbondingTask The address of the UnbondingTask implementation
     * @dev Validates that critical addresses are not zero
     */
    constructor(address sponsoredExecutor, address taskManager, address unbondingTask) {
        if (taskManager == address(0)) revert InvalidTaskManagerAddress();
        if (sponsoredExecutor == address(0)) revert InvalidSponsoredExecutorAddress();
        _TASK_MANAGER = taskManager;
        _SPONSORED_EXECUTOR = sponsoredExecutor;
        _UNBONDING_TASK = unbondingTask;
    }

    // --------------------------------------------- //
    //               Bond, Unbond, Claim             //
    // --------------------------------------------- //

    /**
     * @dev Bonding lifecycle:
     * - Bond: Moves shares from unbonded to bonded under policy control
     * - Unbond: Starts escrow period defined by policy's escrowDuration
     * - Claim: After escrow, moves shares from unbonding to unbonded state
     *
     * Security: Uses holds to prevent malicious unbonding, escrow period for fraud detection
     */

    /**
     * @inheritdoc IShMonad
     * @dev Directly calls _bondToPolicy with the msg.sender as the source of shares
     */
    function bond(uint64 policyID, address bondRecipient, uint256 shares) external onlyActivePolicy(policyID) {
        _bondToPolicy(policyID, msg.sender, bondRecipient, shares, true);
    }

    /**
     * @inheritdoc IShMonad
     */
    function depositAndBond(
        uint64 policyID,
        address bondRecipient,
        uint256 shMonToBond
    )
        external
        payable
        onlyActivePolicy(policyID)
    {
        // Mint shMON for msg.sender using the normal `deposit()` function.
        // Includes a Transfer event for the minted shMON.
        uint256 sharesMinted = deposit(msg.value, msg.sender);

        if (shMonToBond == type(uint256).max) shMonToBond = sharesMinted;

        // Then, bond the `shMonToBond` in `bondRecipient`'s policy bonded balance.
        // This will also decrease the msg.sender's unbonded balance.
        _bondToPolicy(policyID, msg.sender, bondRecipient, shMonToBond, true);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Uses _unbondFromPolicy to handle the actual unbonding logic
     */
    function unbond(uint64 policyID, uint256 shares, uint256 newMinBalance) external returns (uint256 unbondBlock) {
        unbondBlock = _unbondFromPolicy(policyID, msg.sender, shares, newMinBalance);
    }

    /**
     * @inheritdoc IShMonad
     * @dev After unbonding, schedules a task to automatically claim the shares after the escrow period.
     * Refunds any overpaid ETH and uses any remaining gas to execute other pending tasks.
     */
    function unbondWithTask(
        uint64 policyID,
        uint256 shares,
        uint256 newMinBalance
    )
        external
        payable
        returns (uint256 unbondBlock)
    {
        unbondBlock = _unbondFromPolicy(policyID, msg.sender, shares, newMinBalance);

        (bool success, bytes memory returndata) = _TASK_MANAGER.call{ gas: gasleft() }(
            abi.encodeCall(
                ITaskManager.scheduleTask,
                (
                    _UNBONDING_TASK,
                    99_000,
                    uint64(unbondBlock + 1),
                    msg.value,
                    abi.encodeCall(this.claimAsTask, (policyID, shares, msg.sender))
                )
            )
        );

        require(success, "ERR-TaskNotScheduled");

        (bool _scheduled, uint256 _executionCost, bytes32 _taskId) = abi.decode(returndata, (bool, uint256, bytes32));

        address _task = address(uint160(uint256(_taskId)));

        // Store the task address so that it can finish the claim later
        s_userTaskClaims[_task] = keccak256(abi.encode(msg.sender, policyID));

        // Refund the user any unused msg.value
        uint256 _overpaidAmount = msg.value - _executionCost;
        if (_overpaidAmount > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, _overpaidAmount);
        }

        // Use any extra gas to execute other tasks
        (success,) = _TASK_MANAGER.call{ gas: gasleft() }(abi.encodeCall(ITaskManager.executeTasks, (msg.sender, 0)));
    }

    /**
     * @inheritdoc IShMonad
     * @dev Uses a mapping of task address to user+policy hash to verify that the caller is authorized
     */
    function claimAsTask(uint64 policyID, uint256 shares, address account) external {
        require(s_userTaskClaims[msg.sender] == keccak256(abi.encode(account, policyID)), "ERR-TaskNotUsers");
        _claimFromPolicy(policyID, account, shares);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Direct wrapper around _claimFromPolicy with the caller as the beneficiary
     */
    function claim(uint64 policyID, uint256 shares) external {
        _claimFromPolicy(policyID, msg.sender, shares);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Claims the shares then immediately redeems them for the underlying asset (MON)
     */
    function claimAndRedeem(uint64 policyID, uint256 shares) external returns (uint256 assets) {
        _claimFromPolicy(policyID, msg.sender, shares);
        assets = redeem(shares, msg.sender, msg.sender);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Claims from one policy and immediately bonds to another, maintaining total bonded supply
     */
    function claimAndRebond(
        uint64 fromPolicyID,
        uint64 toPolicyID,
        address bondRecipient,
        uint256 shares
    )
        external
        onlyActivePolicy(toPolicyID)
    {
        // changeBondedTotalSupply = true in _bondToPolicy() below, as it would have decreased in the unbond() step
        // before the claim() step here
        _claimFromPolicy(fromPolicyID, msg.sender, shares);
        _bondToPolicy(toPolicyID, msg.sender, bondRecipient, shares, true);
    }

    // --------------------------------------------- //
    //           Top-Up Management Functions         //
    // --------------------------------------------- //

    /**
     * @dev Top-Up Mechanism Design:
     *
     * The top-up system automatically maintains a minimum bonded balance, ensuring users
     * always have sufficient bonded shares available for policy operations:
     *
     * 1. Purpose:
     *    - Ensures users can always cover operational costs via their bonded balance
     *    - Prevents accounts from becoming inoperable due to insufficient bonded shares
     *    - Allows users to set predictable limits on automatic rebonding
     *
     * 2. Parameters:
     *    - minBonded: The minimum balance to maintain in the bonded state
     *    - maxTopUpPerPeriod: Limit on how much can be automatically bonded in a period
     *    - topUpPeriodDuration: Time window controlling top-up frequency (in blocks)
     *
     * 3. Mechanism:
     *    - When a user's bonded balance falls below minBonded, the system attempts to bond
     *      more shares from their unbonded balance
     *    - Top-ups are capped by maxTopUpPerPeriod to prevent unexpected large transfers
     *    - Each period resets the top-up counter, managing frequency of automatic bonding
     *
     * 4. Integration:
     *    - Top-up occurs automatically during _spendFromBonded operations when needed
     *    - Users can disable top-up by setting parameters to zero
     */

    /**
     * @inheritdoc IShMonad
     * @dev Updates top-up settings in memory then persists to storage. Validates minimum period duration.
     */
    function setMinBondedBalance(
        uint64 policyID,
        uint128 minBonded,
        uint128 maxTopUpPerPeriod,
        uint32 topUpPeriodDuration
    )
        external
        onlyActivePolicy(policyID)
    {
        TopUpSettings memory topUpSettings = s_topUpSettings[policyID][msg.sender];

        require(
            topUpPeriodDuration >= MIN_TOP_UP_PERIOD_DURATION,
            TopUpPeriodDurationTooShort(topUpPeriodDuration, MIN_TOP_UP_PERIOD_DURATION)
        );

        topUpSettings.maxTopUpPerPeriod = maxTopUpPerPeriod;
        topUpSettings.topUpPeriodDuration = topUpPeriodDuration;

        s_bondedData[policyID][msg.sender].minBonded = minBonded;

        // Persist topUpSettings to storage
        s_topUpSettings[policyID][msg.sender] = topUpSettings;

        emit SetTopUp(policyID, msg.sender, minBonded, maxTopUpPerPeriod, topUpPeriodDuration);
    }

    // --------------------------------------------- //
    //           Policy Management Functions         //
    // --------------------------------------------- //

    /**
     * @dev Policies organize bonded shares:
     * - Each has unique ID, configuration, and authorized agents
     * - Balances tracked per-user per-policy
     * - Agents perform operations on bonded shares
     * - Policies can be disabled to prevent new bonds
     */

    /**
     * @inheritdoc IShMonad
     * @dev Creates a new policy, adds the caller as the first agent, and deploys a new ERC20 wrapper for the policy
     */
    function createPolicy(uint48 escrowDuration) external returns (uint64 policyID, address policyERC20Wrapper) {
        policyID = ++s_policyCount; // First policyID is 1
        s_policies[policyID] = Policy(escrowDuration, true, msg.sender);
        _addPolicyAgent(policyID, msg.sender); // Add caller as first agent of the policy

        // TODO refactor this to minimal proxy with PolicyERC20WrapperLib for gas efficiency
        policyERC20Wrapper = address(new PolicyERC20Wrapper(address(this), policyID));

        emit CreatePolicy(policyID, msg.sender, escrowDuration);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Only callable by owner. Delegates to internal _addPolicyAgent function.
     */
    function addPolicyAgent(uint64 policyID, address agent) external onlyOwner {
        _addPolicyAgent(policyID, agent);

        emit AddPolicyAgent(policyID, agent);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Only callable by owner. Delegates to internal _removePolicyAgent function.
     */
    function removePolicyAgent(uint64 policyID, address agent) external onlyOwner {
        _removePolicyAgent(policyID, agent);

        emit RemovePolicyAgent(policyID, agent);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Only callable by a policy agent. This action is irreversible.
     */
    function disablePolicy(uint64 policyID) external onlyPolicyAgentAndActive(policyID) {
        s_policies[policyID].active = false;

        emit DisablePolicy(policyID);
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    /**
     * @inheritdoc IShMonad
     */
    function unbondingCompleteBlock(uint64 policyID, address account) external view returns (uint256) {
        return s_unbondingData[policyID][account].unbondStartBlock + s_policies[policyID].escrowDuration;
    }

    // Returns the max available amount that a policy agent could take from an account.
    // Calculated as: bonded - held + unbonding + remaining top-up allowance
    function policyBalanceAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        external
        view
        returns (uint256 balanceAvailable)
    {
        // Add account's bonded balance
        balanceAvailable = s_bondedData[policyID][account].bonded;
        // Add account's unbonding balance
        balanceAvailable += s_unbondingData[policyID][account].unbonding;
        // Add account's max top-up amount available
        balanceAvailable += topUpAvailable(policyID, account, false);
        // Subtract any holds on the account's bonded balance
        balanceAvailable -= _getHoldAmount(policyID, account);

        // Convert from shMON to MON if required
        if (inUnderlying) balanceAvailable = previewRedeem(balanceAvailable);
    }

    // Returns the amount currently available via top-up, for a specific account and policy.
    function topUpAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        public
        view
        returns (uint256 amountAvailable)
    {
        TopUpData memory topUpData = s_topUpData[policyID][account];
        TopUpSettings memory topUpSettings = s_topUpSettings[policyID][account];
        uint256 unbondedBalance = s_balances[account].unbonded;
        uint256 topUpLeftInPeriod;

        if (block.number > topUpData.topUpPeriodStartBlock + topUpSettings.topUpPeriodDuration) {
            // If in new top-up period, max top-up is available
            topUpLeftInPeriod = topUpSettings.maxTopUpPerPeriod;
        } else {
            // If in same top-up period, calc remaining top-up allowance
            topUpLeftInPeriod = topUpSettings.maxTopUpPerPeriod - topUpData.totalPeriodTopUps;
        }

        // Top-up amount available is capped by the account's unbonded balance
        amountAvailable = unbondedBalance < topUpLeftInPeriod ? unbondedBalance : topUpLeftInPeriod;

        // Convert from shMON to MON if required
        if (inUnderlying) amountAvailable = previewRedeem(amountAvailable);
    }

    // --------------------------------------------- //
    //                Internal Functions             //
    // --------------------------------------------- //

    /**
     * @dev Internal architecture:
     * - Public functions delegate to internal functions with core logic
     * - Uses memory-first approach for gas efficiency
     * - Validates state before modifications
     * - Emits events for all state changes
     */

    /**
     * @dev Bonds shares to a policy from one account to a recipient
     * @param policyID The ID of the policy
     * @param accountFrom The address providing the shares
     * @param bondRecipient The address receiving the bonded shares
     * @param shares The amount of shMON shares to bond
     * @param changeBondedTotalSupply Whether to increase the bondedTotalSupply
     * @dev Implementation details:
     * 1. Checks if accountFrom has sufficient unbonded balance
     * 2. If accountFrom != bondRecipient, handles as a transfer + bond
     * 3. If accountFrom == bondRecipient, handles as a simple bond
     * 4. Updates bonded balance in the policy and total bonded supply if requested
     * 5. Emits Transfer event for cross-account transfers and Bond event in all cases
     */
    function _bondToPolicy(
        uint64 policyID,
        address accountFrom,
        address bondRecipient,
        uint256 shares,
        bool changeBondedTotalSupply
    )
        internal
    {
        Balance memory fromBalance = s_balances[accountFrom];
        uint128 shares128 = shares.toUint128();

        require(fromBalance.unbonded >= shares128, InsufficientUnbondedBalance(fromBalance.unbonded, shares));

        if (bondRecipient != accountFrom) {
            // from and recipient are different --> effectively a transfer(), then a bond()

            // Increase recipient's bonded balance, then persist to storage
            Balance memory recipientBalance = s_balances[bondRecipient];
            recipientBalance.bonded += shares128;
            s_balances[bondRecipient] = recipientBalance;

            // Same event as if transfer() was called
            emit Transfer(accountFrom, bondRecipient, shares);
        } else {
            // from and recipient are the same --> effectively just a bond() action
            fromBalance.bonded += shares128;
            // No transfer event required
        }

        // Safe unchecked arithmetic due to [unbonded >= amount] check above
        unchecked {
            // In both cases above, from's unbonded balance decreases. Underflow check at start of func.
            fromBalance.unbonded -= shares128;

            // Increase bondRecipient's bonded balance in the policy
            s_bondedData[policyID][bondRecipient].bonded += shares128;

            // Increase bondedTotalSupply if requested
            if (changeBondedTotalSupply) {
                s_supply.bondedTotal += shares128;
            }
        }

        // Persist changes in from's balance to storage
        s_balances[accountFrom] = fromBalance;

        emit Bond(policyID, bondRecipient, shares);
    }

    /**
     * @dev Unbonds shares from a policy, starting the escrow period
     * @param policyID The ID of the policy
     * @param account The address unbonding shares
     * @param shares The amount of shMON shares to unbond
     * @param newMinBalance The new minimum balance for top-up settings
     * @return unbondBlock The block number when the unbonding period will be complete
     * @dev Implementation details:
     * 1. Checks if account has sufficient unheld bonded balance
     * 2. Decreases account's bonded balance and the total bonded supply
     * 3. Increases account's unbonding balance and sets the unbond start block
     * 4. Updates top-up settings to use the new minimum balance
     * 5. Calculates and returns the block when unbonding will be complete
     */
    function _unbondFromPolicy(
        uint64 policyID,
        address account,
        uint256 shares,
        uint256 newMinBalance
    )
        internal
        returns (uint256 unbondBlock)
    {
        BondedData memory bondedData = s_bondedData[policyID][account];
        UnbondingData memory unbondingData = s_unbondingData[policyID][account];

        uint128 shares128 = shares.toUint128();
        uint128 held128 = _getHoldAmount(policyID, account).toUint128();

        require(
            bondedData.bonded - held128 >= shares128,
            InsufficientUnheldBondedBalance(bondedData.bonded, held128, shares128)
        );

        // Should not be able to underflow due to check above
        unchecked {
            // Decrease account's total bonded and policy bonded balances
            bondedData.bonded -= shares128;
            s_balances[account].bonded -= shares128;

            // Also decrease totalBondedSupply due to decrease in bonded balance
            s_supply.bondedTotal -= shares128;

            // Increase account's unbonding balance and update unbondStartBlock
            unbondingData.unbonding += shares128;
            unbondingData.unbondStartBlock = uint48(block.number);
        }

        // To disable top-up, set maxTopUpPerPeriod to newMinBalance
        s_topUpSettings[policyID][account].maxTopUpPerPeriod = newMinBalance.toUint128();

        // Persist changes in memory struct to storage
        s_bondedData[policyID][account] = bondedData;
        s_unbondingData[policyID][account] = unbondingData;

        // Calculate the block at which the unbonding will be complete, for event and return value
        unbondBlock = block.number + s_policies[policyID].escrowDuration;

        emit Unbond(policyID, account, shares, unbondBlock);
    }

    /**
     * @dev Claims unbonded shares after escrow period completion
     * @param policyID The ID of the policy
     * @param account The address claiming shares
     * @param shares The amount of shMON shares to claim
     * @dev Implementation details:
     * 1. Checks if the unbonding period is complete by comparing current block to unbondStartBlock + escrowDuration
     * 2. Verifies account has sufficient unbonding balance
     * 3. Decreases account's unbonding balance and increases their unbonded balance
     */
    function _claimFromPolicy(uint64 policyID, address account, uint256 shares) internal {
        UnbondingData memory unbondingData = s_unbondingData[policyID][account];
        uint256 policyEscrowDuration = s_policies[policyID].escrowDuration;
        uint128 shares128 = shares.toUint128();

        require(
            block.number > unbondingData.unbondStartBlock + policyEscrowDuration,
            UnbondingPeriodIncomplete(unbondingData.unbondStartBlock + policyEscrowDuration)
        );

        // This check ensures no overflows or underflows below
        require(unbondingData.unbonding >= shares128, InsufficientUnbondingBalance(unbondingData.unbonding, shares));

        unchecked {
            // Decrease account's unbonding balance
            unbondingData.unbonding -= shares128;

            // Increase account's unbonded balance
            s_balances[account].unbonded += shares128;
        }

        // Persist changes in memory struct to storage
        s_unbondingData[policyID][account] = unbondingData;

        emit Claim(policyID, account, shares);
    }

    /**
     * @dev Respects any holds on the account's bonded balance and decreases it if sufficient after deducting holds.
     * May attempt top-up if needed, then draws from unbonding if necessary.
     * @param bondedData Memory struct containing the account's bonded data
     * @param policyID The ID of the policy
     * @param account The address whose bonded balance is being decreased
     * @param shares The amount of shMON shares to spend
     * @param out Whether to decrease the bondedTotalSupply
     * @dev Implementation details:
     * 1. Calculates available funds after deducting holds
     * 2. If insufficient funds, first try take from account's unbonding balance
     * 3. If still insufficient funds, attempt top-up from account's unbonded balance
     * 4. If still insufficient after trying unbonding and top-up sources, reverts with InsufficientFunds error
     * 5. Updates balances in memory structures (must be persisted to storage separately)
     * 6. Decreases both bondedTotalSupply and totalSupply, depending on the `out` parameter
     */
    function _spendFromBonded(
        BondedData memory bondedData,
        uint64 policyID,
        address account,
        uint128 shares,
        Delivery out
    )
        internal
    {
        Balance memory balance = s_balances[account];
        TopUpData memory topUpData = s_topUpData[policyID][account];
        uint128 held128 = _getHoldAmount(policyID, account).toUint128();
        uint128 fundsAvailable = bondedData.bonded - held128; // Initially just unheld bonded balance
        uint128 bondedSupplyIncrease; // remains 0 unless required below

        // If account's bonded balance is insufficient, try make up the shortfall from other sources in this order:
        // 1) Unbonding balance
        // 2) Unbonded balance, if top-up is enabled

        // First, try take from unbonding balance
        if (fundsAvailable < shares) {
            // Load account's unbonding data
            UnbondingData memory _unbondingData = s_unbondingData[policyID][account];
            uint128 takenFromUnbonding;

            if (fundsAvailable + _unbondingData.unbonding >= shares) {
                // we can take the shortfall from account's unbonding balance
                unchecked {
                    takenFromUnbonding = shares - fundsAvailable;
                    _unbondingData.unbonding -= takenFromUnbonding;
                }
            } else {
                takenFromUnbonding = _unbondingData.unbonding;
                _unbondingData.unbonding = 0;
            }

            // If spending from account's unbonding funds, must to reverse the changes made to any balances or totals
            // made in `_unbondFromPolicy()` when account starting the unbonding action:

            // Increase account's policy-specific bonded balance
            bondedData.bonded += takenFromUnbonding;
            // Increase account's total bonded balance
            balance.bonded += takenFromUnbonding;
            // Track increase in global supply.bondedTotal, applied at end of this function
            bondedSupplyIncrease += takenFromUnbonding;

            // Persist unbonding data to storage
            s_unbondingData[policyID][account] = _unbondingData;

            // Update fundsAvailable after moving funds from unbonding to bonded above
            fundsAvailable = bondedData.bonded - held128;
        }

        // Second, if fundsAvailable is still insufficient, try top-up from unbonded balance
        if (fundsAvailable < shares) {
            // CASE: deduct amount exceeds account's unheld bonded balance
            // --> attempt top-up
            uint128 bondedShortfall = shares - fundsAvailable;

            uint128 topUpAmount;
            (topUpData, topUpAmount) = _tryTopUp(topUpData, balance, bondedData, policyID, account, bondedShortfall);

            // supply.bondedTotal will be increased by any top-up amount, at the end of this function
            bondedSupplyIncrease += topUpAmount;

            // Update fundsAvailable again after top-up
            fundsAvailable = bondedData.bonded - held128;
        }

        // If fundsAvailable is still insufficient after attempting to draw from unbonding and unbonded via top-up,
        // revert with InsufficientFunds error
        if (fundsAvailable < shares) {
            revert InsufficientFunds(bondedData.bonded, s_unbondingData[policyID][account].unbonding, held128, shares);
        }

        // Attempt to keep account's bonded balance topped up to their minBonded level
        if (fundsAvailable - shares < bondedData.minBonded) {
            uint128 topUpAmount;

            (topUpData, topUpAmount) = _tryTopUp(
                topUpData, balance, bondedData, policyID, account, bondedData.minBonded - (fundsAvailable - shares)
            );

            // supply.bondedTotal will be increased by any top-up amount, at the end of this function
            bondedSupplyIncrease += topUpAmount;
        }

        // Safe to do unchecked subtractions due to early revert above if underflow would occur
        unchecked {
            // Decrease account's bonded balance (in the policy and total balances)
            bondedData.bonded -= shares;
            balance.bonded -= shares;
        }

        if (out == Delivery.Bonded) {
            // CASE: Bonded ShMON -> Bonded ShMON
            // --> Do nothing to total supply
        } else if (out == Delivery.Unbonded) {
            // CASE: Bonded ShMON -> Unbonded ShMON
            // --> Decrease bondedTotalSupply but not totalSupply (no shMON burnt)
            Supply memory _supply = s_supply;

            // NOTE: Cannot assume shares > bondedSupplyIncrease, due to potential top-up to minBonded level
            // First increase supply.bondedTotal by any newly-bonded shares
            _supply.bondedTotal += bondedSupplyIncrease;
            // Then decrease supply.bondedTotal by the shares being spent
            _supply.bondedTotal -= shares;

            // Persist supply changes to storage
            s_supply = _supply;
        } else {
            // CASE: Bonded ShMON -> Underlying MON
            // (i.e. if out == Delivery.Underlying)
            // --> Decrease both bondedTotalSupply and totalSupply (shMON burnt)
            Supply memory _supply = s_supply;

            // NOTE: Cannot assume shares > bondedSupplyIncrease, due to potential top-up to minBonded level
            // First increase supply.bondedTotal by any newly-bonded shares
            _supply.bondedTotal += bondedSupplyIncrease;
            // Then decrease supply.bondedTotal by the shares being spent
            _supply.bondedTotal -= shares;
            // Finally, decrease supply.total (unbonded) by shares which will be burnt for underlying
            _supply.total -= shares;

            // Persist supply changes to storage
            s_supply = _supply;
        }

        // Persist Balance changes in memory struct to storage
        s_balances[account] = balance;

        // Persist TopUpData changes in memory struct to storage
        s_topUpData[policyID][account] = topUpData;

        // NOTE: BondedData changes must be persisted to storage separately.
    }

    /**
     * @dev Tops up an account's bonded balance from their unbonded balance if possible
     * @param balance Memory struct containing account's balance
     * @param bondedData Memory struct containing the account's bonded data
     * @param policyID The ID of the policy
     * @param account The address whose bonded balance is being topped up
     * @param sharesToBond The amount of shMON shares to bond from unbonded balance
     * @return Whether the top-up was successful
     * @dev Implementation details:
     * 1. Checks if a new top-up period has started and resets period variables if so
     * 2. If in existing period, checks if top-up would exceed the maximum allowed
     * 3. Verifies account has sufficient unbonded balance for the top-up
     * 4. Updates balances and top-up tracking in memory (TopUpData persisted to storage in this function)
     * 5. Emits Bond event for the top-up transaction
     */
    function _tryTopUp(
        TopUpData memory topUpData,
        Balance memory balance,
        BondedData memory bondedData,
        uint64 policyID,
        address account,
        uint128 sharesToBond
    )
        internal
        returns (TopUpData memory, uint128 bondedSupplyIncrease)
    {
        TopUpSettings memory topUpSettings = s_topUpSettings[policyID][account];

        if (block.number > topUpData.topUpPeriodStartBlock + topUpSettings.topUpPeriodDuration) {
            // If in new top-up period, reset period vars
            topUpData.totalPeriodTopUps = 0;
            topUpData.topUpPeriodStartBlock = uint48(block.number);
        } else {
            // If in same top-up period, check if top-up amount is exceeded
            if (topUpData.totalPeriodTopUps + sharesToBond > topUpSettings.maxTopUpPerPeriod) return (topUpData, 0);
        }

        if (balance.unbonded < sharesToBond) return (topUpData, 0);

        unchecked {
            // Changes to account's memory structs.
            bondedData.bonded += sharesToBond;
            topUpData.totalPeriodTopUps += sharesToBond;

            // Decrease account's unbonded balance
            balance.unbonded -= sharesToBond;

            // Increase account's total bonded balance
            balance.bonded += sharesToBond;

            // Increase bondedTotalSupply
            // s_supply.bondedTotal += sharesToBond;
            bondedSupplyIncrease = sharesToBond;
        }

        // Same event as if bond() was called by the account
        emit Bond(policyID, msg.sender, sharesToBond);

        return (topUpData, bondedSupplyIncrease);
    }

    /**
     * @dev Adds a policy agent to the specified policy
     * @param policyID The ID of the policy
     * @param agent The address of the agent to add
     * @dev Implementation details:
     * 1. Checks that the address is not already an agent for the policy
     * 2. Sets the mapping flag and adds to the agents array
     */
    function _addPolicyAgent(uint64 policyID, address agent) internal {
        require(!_isPolicyAgent(policyID, agent), PolicyAgentAlreadyExists(policyID, agent));
        s_isPolicyAgent[policyID][agent] = true; // Set agent to true in isPolicyAgent mapping
        s_policyAgents[policyID].push(agent); // Add agent to policyAgents array
    }

    /**
     * @dev Removes a policy agent from the specified policy
     * @param policyID The ID of the policy
     * @param agent The address of the agent to remove
     * @dev Implementation details:
     * 1. Ensures the policy still has at least one agent after removal
     * 2. Verifies the address is currently an agent
     * 3. Sets the mapping flag to false and removes from the agents array
     * 4. Replaces the removed agent with the last agent in the array and pops the array
     */
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

    /**
     * @dev Reverts if policy is not active
     * @param policyID The ID of the policy to check
     */
    function _onlyActivePolicy(uint64 policyID) internal view {
        require(s_policies[policyID].active, PolicyInactive(policyID));
    }

    // --------------------------------------------- //
    //                     Modifiers                 //
    // --------------------------------------------- //

    /**
     * @dev Modifier that reverts if the policy is not active
     * @param policyID The ID of the policy to check
     */
    modifier onlyActivePolicy(uint64 policyID) {
        _onlyActivePolicy(policyID);
        _;
    }
}
