//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IERC4626Custom } from "./IERC4626Custom.sol";
import { IERC20Full } from "./IERC20Full.sol";

import { Policy } from "../Types.sol";
import { IERC4626Custom } from "./IERC4626Custom.sol";
import { IERC20Full } from "./IERC20Full.sol";

/**
 * @title IShMonad - Interface for the ShMonad Liquid Staking Token contract
 * @notice Interface for the ShMonad contract which provides ERC4626 functionality plus policy-based bonding mechanisms
 * @dev Extends ERC4626Custom and full ERC20 functionality
 */
interface IShMonad is IERC4626Custom, IERC20Full {
    // --------------------------------------------- //
    //             Extra ERC4626 Functions           //
    // --------------------------------------------- //

    /**
     * @notice Boosts yield by sending MON directly to the contract
     * @dev Uses msg.value for the yield boost
     */
    function boostYield() external payable;

    /**
     * @notice Boosts yield by using a specific address's shares
     * @param shares The amount of shMON shares to use for boosting yield
     * @param from The address providing the shares
     */
    function boostYield(uint256 shares, address from) external;

    // --------------------------------------------- //
    //                Account Functions              //
    // --------------------------------------------- //

    /**
     * @notice Bonds shMON shares to a specific policy
     * @param policyID The ID of the policy to bond shares to
     * @param bondRecipient The address that will own the bonded shares
     * @param shares The amount of shMON shares to bond
     */
    function bond(uint64 policyID, address bondRecipient, uint256 shares) external;

    /**
     * @notice Deposits MON and bonds the resulting shMON shares to a specific policy
     * @param policyID The ID of the policy to bond shares to
     * @param bondRecipient The address that will own the bonded shares
     * @param shMonToBond The amount of shMON shares to bond (or type(uint256).max to bond all newly minted shares)
     */
    function depositAndBond(uint64 policyID, address bondRecipient, uint256 shMonToBond) external payable;

    /**
     * @notice Unbonds shares from a policy, starting the escrow period before claiming
     * @param policyID The ID of the policy to unbond shares from
     * @param shares The amount of shMON shares to unbond
     * @param newMinBalance The new minimum balance to maintain (affects top-up settings)
     * @return unbondBlock The block number when the unbonding period will be complete
     */
    function unbond(uint64 policyID, uint256 shares, uint256 newMinBalance) external returns (uint256 unbondBlock);

    /**
     * @notice Unbonds shares and schedules a task to automatically claim them after the escrow period
     * @param policyID The ID of the policy to unbond shares from
     * @param shares The amount of shMON shares to unbond
     * @param newMinBalance The new minimum balance to maintain (affects top-up settings)
     * @return unbondBlock The block number when the unbonding period will be complete
     */
    function unbondWithTask(
        uint64 policyID,
        uint256 shares,
        uint256 newMinBalance
    )
        external
        payable
        returns (uint256 unbondBlock);

    /**
     * @notice Claims unbonded shares after escrow period completion
     * @param policyID The ID of the policy to claim shares from
     * @param shares The amount of shMON shares to claim
     */
    function claim(uint64 policyID, uint256 shares) external;

    /**
     * @notice Claims unbonded shMON, and immediately redeems for MON
     * @param policyID The ID of the policy from which to claim unbonded shMON
     * @param shares The amount of shMON to claim and then redeem for MON at the current exchange rate
     * @return assets The amount of MON that was redeemed for the given shMON shares
     */
    function claimAndRedeem(uint64 policyID, uint256 shares) external returns (uint256 assets);

    /**
     * @notice Claims unbonded shMON from one policy and bonds it to another policy
     * @param fromPolicyID The ID of the policy to claim shares from
     * @param toPolicyID The ID of the policy to bond shares to
     * @param bondRecipient The address that will own the bonded shares
     * @param shares The amount of shMON shares to claim and rebond
     */
    function claimAndRebond(uint64 fromPolicyID, uint64 toPolicyID, address bondRecipient, uint256 shares) external;

    /**
     * @notice Claims unbonded shares as a scheduled task after escrow period completion
     * @dev Only callable by the task that was scheduled during unbondWithTask
     * @param policyID The ID of the policy to claim shares from
     * @param shares The amount of shMON shares to claim
     * @param account The address that will receive the claimed shares
     */
    function claimAsTask(uint64 policyID, uint256 shares, address account) external;

    // --------------------------------------------- //
    //                 Agent Functions               //
    // --------------------------------------------- //

    /**
     * @notice Places a hold on a specific amount of an account's bonded shares in a policy
     * @dev Held shares cannot be unbonded until released
     * @param policyID The ID of the policy
     * @param account The address whose shares will be held
     * @param shares The amount of shares to hold
     */
    function hold(uint64 policyID, address account, uint256 shares) external;

    /**
     * @notice Releases previously held shares for an account in a policy
     * @param policyID The ID of the policy
     * @param account The address whose shares will be released
     * @param shares The amount of shares to release
     */
    function release(uint64 policyID, address account, uint256 shares) external;

    /**
     * @notice Places holds on multiple accounts' bonded shares in a policy
     * @param policyID The ID of the policy
     * @param accounts Array of addresses whose shares will be held
     * @param amounts Array of amounts to hold for each account
     */
    function batchHold(uint64 policyID, address[] calldata accounts, uint256[] memory amounts) external;

    /**
     * @notice Releases previously held shares for multiple accounts in a policy
     * @param policyID The ID of the policy
     * @param accounts Array of addresses whose shares will be released
     * @param amounts Array of amounts to release for each account
     */
    function batchRelease(uint64 policyID, address[] calldata accounts, uint256[] calldata amounts) external;

    /**
     * @notice Transfers bonded shares from one account to another within the same policy
     * @dev Can handle either shares (shMON) or assets (MON) based on inUnderlying flag
     * @param policyID The ID of the policy
     * @param from The address providing the bonded shares
     * @param to The address receiving the bonded shares
     * @param amount The amount to transfer (in shares or assets depending on inUnderlying)
     * @param fromReleaseAmount The amount of shares to release from any holds before transferring
     * @param inUnderlying Whether amount is specified in the underlying asset (MON) rather than shares (shMON)
     */
    function agentTransferFromBonded(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    /**
     * @notice Transfers bonded shares to an account's unbonded balance
     * @dev Can handle either shares (shMON) or assets (MON) based on inUnderlying flag
     * @param policyID The ID of the policy
     * @param from The address providing the bonded shares
     * @param to The address receiving the unbonded shares
     * @param amount The amount to transfer (in shares or assets depending on inUnderlying)
     * @param fromReleaseAmount The amount of shares to release from any holds before transferring
     * @param inUnderlying Whether amount is specified in the underlying asset (MON) rather than shares (shMON)
     */
    function agentTransferToUnbonded(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    /**
     * @notice Withdraws MON from an account's bonded balance to an address
     * @dev Can handle either shares (shMON) or assets (MON) based on inUnderlying flag
     * @param policyID The ID of the policy
     * @param from The address providing the bonded shares
     * @param to The address receiving the withdrawn MON
     * @param amount The amount to withdraw (in shares or assets depending on inUnderlying)
     * @param fromReleaseAmount The amount of shares to release from any holds before withdrawing
     * @param inUnderlying Whether amount is specified in the underlying asset (MON) rather than shares (shMON)
     */
    function agentWithdrawFromBonded(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    /**
     * @notice Uses an account's bonded shares to boost yield
     * @dev Can handle either shares (shMON) or assets (MON) based on inUnderlying flag
     * @param policyID The ID of the policy
     * @param from The address providing the bonded shares
     * @param amount The amount to use for yield boosting (in shares or assets depending on inUnderlying)
     * @param fromReleaseAmount The amount of shares to release from any holds before boosting
     * @param inUnderlying Whether amount is specified in the underlying asset (MON) rather than shares (shMON)
     */
    function agentBoostYieldFromBonded(
        uint64 policyID,
        address from,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    /**
     * @notice Executes a function call with funds from an account's bonded balance
     * @param policyID The ID of the policy
     * @param payor The address providing the bonded shares for gas costs
     * @param recipient The address that will receive any MON from the payor's bonded balance
     * @param msgValue The amount of MON to send with the call
     * @param gasLimit The gas limit for the inner call
     * @param callTarget The address to call
     * @param callData The calldata to send with the call
     * @return actualPayorCost The actual cost charged to the payor in shares
     * @return success Whether the call succeeded
     * @return returnData The data returned from the call
     */
    function agentExecuteWithSponsor(
        uint64 policyID,
        address payor,
        address recipient,
        uint256 msgValue,
        uint256 gasLimit,
        address callTarget,
        bytes calldata callData
    )
        external
        payable
        returns (uint128 actualPayorCost, bool success, bytes memory returnData);

    // --------------------------------------------- //
    //           Top-Up Management Functions         //
    // --------------------------------------------- //

    /**
     * @notice Sets minimum bonded balance and top-up settings for an account in a policy
     * @param policyID The ID of the policy
     * @param minBonded The minimum bonded balance to maintain
     * @param maxTopUpPerPeriod The maximum amount to top up per period
     * @param topUpPeriodDuration The duration of the top-up period in blocks
     */
    function setMinBondedBalance(
        uint64 policyID,
        uint128 minBonded,
        uint128 maxTopUpPerPeriod,
        uint32 topUpPeriodDuration
    )
        external;

    // --------------------------------------------- //
    //           Policy Management Functions         //
    // --------------------------------------------- //

    /**
     * @notice Creates a new policy with the specified escrow duration
     * @param escrowDuration The duration in blocks for which unbonded shares must wait before claiming
     * @return policyID The ID of the newly created policy
     * @return policyERC20Wrapper The address of the ERC20 wrapper for this policy
     */
    function createPolicy(uint48 escrowDuration) external returns (uint64 policyID, address policyERC20Wrapper);

    /**
     * @notice Adds a policy agent to the specified policy
     * @param policyID The ID of the policy
     * @param agent The address of the agent to add
     */
    function addPolicyAgent(uint64 policyID, address agent) external;

    /**
     * @notice Removes a policy agent from the specified policy
     * @param policyID The ID of the policy
     * @param agent The address of the agent to remove
     */
    function removePolicyAgent(uint64 policyID, address agent) external;

    /**
     * @notice Disables a policy, preventing new bonds but allowing unbonding and claiming
     * @dev This action is irreversible. Disabled policies cannot be re-enabled.
     * @param policyID The ID of the policy to disable
     */
    function disablePolicy(uint64 policyID) external;

    // --------------------------------------------- //
    //                 View Functions                //
    // --------------------------------------------- //

    /**
     * @notice Gets the total number of policies created
     * @return The current policy count
     */
    function policyCount() external view returns (uint64);

    /**
     * @notice Gets information about a specific policy
     * @param policyID The ID of the policy to query
     * @return The policy information (escrow duration and active status)
     */
    function getPolicy(uint64 policyID) external view returns (Policy memory);

    /**
     * @notice Checks if an address is an agent for a specific policy
     * @param policyID The ID of the policy
     * @param agent The address to check
     * @return Whether the address is a policy agent
     */
    function isPolicyAgent(uint64 policyID, address agent) external view returns (bool);

    /**
     * @notice Gets all agents for a specific policy
     * @param policyID The ID of the policy
     * @return Array of agent addresses
     */
    function getPolicyAgents(uint64 policyID) external view returns (address[] memory);

    /**
     * @notice Gets the amount of shares that are held for an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return The amount of shares held
     */
    function getHoldAmount(uint64 policyID, address account) external view returns (uint256);

    /**
     * @notice Gets the block number when unbonding will be complete for an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return The block number when unbonding will be complete
     */
    function unbondingCompleteBlock(uint64 policyID, address account) external view returns (uint256);

    /**
     * @notice Gets the bonded balance of an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return The bonded balance in shares
     */
    function balanceOfBonded(uint64 policyID, address account) external view returns (uint256);

    /**
     * @notice Gets the unbonding balance of an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return The unbonding balance in shares
     */
    function balanceOfUnbonding(uint64 policyID, address account) external view returns (uint256);

    function policyBalanceAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        external
        view
        returns (uint256 balanceAvailable);

    function topUpAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        external
        view
        returns (uint256 amountAvailable);
}
