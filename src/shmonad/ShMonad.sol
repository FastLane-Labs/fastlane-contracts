//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math as OZMath } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";

// OVERRIDE STUFF
import { Policies } from "./Policies.sol";
import { CommittedData, Delivery, UserUnstakeRequest, AdminValues } from "./Types.sol";
import { EIP1967_ADMIN_SLOT, OWNER_COMMISSION_ACCOUNT } from "./Constants.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";
import { AccountingLib } from "./libraries/AccountingLib.sol";

/**
 * @title ShMonad - Liquid Staking Token on Monad
 * @notice ShMonad is an LST integrated with the FastLane ecosystem
 * @dev Extends Policies which provides ERC4626 functionality plus policy-based commitment mechanisms
 * @author FastLane Labs
 */
contract ShMonad is Policies {
    using SafeTransferLib for address;
    using SafeCast for uint256;
    using Math for uint256;

    constructor() {
        // Disable initializers on implementation
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with ownership set to the deployer
     * @dev This is part of the OpenZeppelin Upgradeable pattern
     * @dev Protected against front-running: constructor disables initializers on implementation
     * @dev For proxy upgrades, this must be called via ProxyAdmin.upgradeAndCall()
     * @param deployer The address that will own the contract
     */
    function initialize(address deployer) public reinitializer(10) {
        // Prevent unauthorized initialization during upgrades
        // Only allow if called by current owner (for upgrades)
        address _proxyAdmin = _getProxyAdmin();
        require(msg.sender == _proxyAdmin, UnauthorizedInitializer());

        __EIP712_init("ShMonad", "3");
        __Ownable_init(deployer);
        __AtomicUnstakePool_init();
        __ReentrancyGuardTransient_init();
        __StakeTracker_init();
    }

    /// @dev Returns the proxy admin when running behind a TransparentUpgradeableProxy.
    function _getProxyAdmin() private view returns (address _proxyAdmin) {
        // Assembly required to sload the admin slot defined by the proxy standard.
        // Pseudocode: proxyAdmin = StorageSlot(EIP1967_ADMIN_SLOT).read();
        assembly ("memory-safe") {
            _proxyAdmin := sload(EIP1967_ADMIN_SLOT)
        }
    }

    // --------------------------------------------- //
    //                 Agent Functions               //
    // --------------------------------------------- //

    /**
     * @notice Transfers committed shares from one account to another within the same policy.
     * @dev Implementation details:
     *      1. Releases any holds on the source account if requested.
     *      2. If `inUnderlying` is true, interprets `amount` as MON (post-fee, ignoring liquidity limits) and converts
     *         to shares via `_convertToShares(amount)` semantics.
     *      3. Updates the source account's committed balance in memory then persists to storage.
     *      4. Updates the destination account's committed balance directly in storage.
     *      5. Does not decrease committedTotalSupply as the value remains committed.
     * @param policyID The ID of the policy powering the transfer.
     * @param from The address providing the committed shares.
     * @param to The address receiving the committed shares.
     * @param amount The amount to transfer (shares or assets depending on `inUnderlying`).
     * @param fromReleaseAmount Shares to release from holds before transferring.
     * @param inUnderlying Whether `amount` is specified in MON (`true`) or shMON (`false`).
     */
    function agentTransferFromCommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        nonReentrant
        onlyPolicyAgentAndActive(policyID)
    {
        // Agents cannot transfer their own committed funds, otherwise they could circumvent the rule that disallows
        // them from instantly uncommitting their own funds by first transferring them to a non-agent account.
        require(!_isPolicyAgent(policyID, from), AgentInstantUncommittingDisallowed(policyID, from));

        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);
        // Interpret `amount` in underlying units using the vault exchange rate (no fee path)
        if (inUnderlying) amount = _convertToShares(amount, OZMath.Rounding.Ceil, false, false);

        uint128 sharesToDeduct = amount.toUint128();

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease committed balance (respecting any holds if not released above)
        // - do not decrease committedTotalSupply (value stays in committed form)
        CommittedData memory fromCommittedData = s_committedData[policyID][from];
        _spendFromCommitted(fromCommittedData, policyID, from, sharesToDeduct, Delivery.Committed);
        s_committedData[policyID][from] = fromCommittedData;

        // Changes to the `to` account - done directly in storage:
        // - increase committed balance (holds not applicable if increasing)
        s_committedData[policyID][to].committed += sharesToDeduct;
        s_balances[to].committed += sharesToDeduct;

        emit AgentTransferFromCommitted(policyID, from, to, amount);
    }

    /**
     * @notice Transfers committed shares from an account into another account's uncommitted balance.
     * @dev Implementation details:
     *      1. Prevents agents from uncommitting their own balance.
     *      2. Releases any holds on the source account if requested.
     *      3. If `inUnderlying` is true, interprets `amount` as MON and converts to shares via `_convertToShares`.
     *      4. Updates the source account's committed balance in memory then persists to storage.
     *      5. Increases the destination account's uncommitted balance.
     *      6. Decreases committedTotalSupply because value leaves the committed form.
     * @param policyID The ID of the policy powering the transfer.
     * @param from The address providing the committed shares.
     * @param to The address receiving the uncommitted shares.
     * @param amount The amount to transfer (shares or assets depending on `inUnderlying`).
     * @param fromReleaseAmount Shares to release from holds before transferring.
     * @param inUnderlying Whether `amount` is specified in MON (`true`) or shMON (`false`).
     */
    function agentTransferToUncommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        onlyPolicyAgentAndActive(policyID)
    {
        // Agents cannot instantly uncommit their own or other agents' balances
        require(!_isPolicyAgent(policyID, from), AgentInstantUncommittingDisallowed(policyID, from));

        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);
        // Interpret `amount` in underlying units using the vault exchange rate (no fee path)
        if (inUnderlying) amount = _convertToShares(amount, OZMath.Rounding.Ceil, false, false);

        uint128 sharesToDeduct = amount.toUint128();

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease committed balance (respecting any holds if not released above)
        // - decreases committedTotalSupply (value converts to uncommitted form)
        CommittedData memory fromCommittedData = s_committedData[policyID][from];
        _spendFromCommitted(fromCommittedData, policyID, from, sharesToDeduct, Delivery.Uncommitted);
        s_committedData[policyID][from] = fromCommittedData;

        // Increase uncommitted balance
        s_balances[to].uncommitted += sharesToDeduct;

        emit AgentTransferToUncommitted(policyID, from, to, amount);
    }

    /**
     * @notice Withdraws MON from an account's committed balance to a recipient.
     * @dev Implementation details:
     *      1. Prevents agents from withdrawing their own balance.
     *      2. Releases any holds on the source account if requested.
     *      3. Handles conversion between shares and assets based on the `amountSpecifiedInUnderlying` flag.
     *      4. Updates the source account's committed balance in memory then persists to storage.
     *      5. Temporarily increases the destination's uncommitted balance.
     *      6. Burns the shares from the destination account.
     *      7. Transfers the underlying assets (MON) to the destination.
     *      NOTE: Conversions go through the AtomicUnstakePool. Fees and liquidity limits apply; agents should consult
     *      `previewWithdraw()`/`previewRedeem()` before calling.
     * @param policyID The ID of the policy powering the withdrawal.
     * @param from The address providing the committed shares.
     * @param to The address receiving the withdrawn MON.
     * @param amount The amount to withdraw (shares or assets depending on `amountSpecifiedInUnderlying`).
     * @param fromReleaseAmount Shares to release from holds before withdrawing.
     * @param amountSpecifiedInUnderlying Whether `amount` is specified in MON (`true`) or shMON (`false`).
     */
    function agentWithdrawFromCommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool amountSpecifiedInUnderlying
    )
        external
        nonReentrant
        onlyPolicyAgentAndActive(policyID)
    {
        // Agents cannot instantly uncommit their own or other agents' balances
        require(!_isPolicyAgent(policyID, from), AgentInstantUncommittingDisallowed(policyID, from));

        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);

        uint128 _sharesToDeduct;
        uint256 _assetsToReceive;
        uint256 _feeTaken;

        if (amountSpecifiedInUnderlying) {
            // CASE: amount is a net assets (MON) figure.
            _assetsToReceive = amount;
            uint256 _grossAssets;
            (_grossAssets, _feeTaken) = _getGrossAndFeeFromNetAssets(_assetsToReceive);
            // Burn shares equivalent to the required before-fee gross (ceil rounding).
            _sharesToDeduct = _convertToShares(_grossAssets, OZMath.Rounding.Ceil, true, false).toUint128();
        } else {
            // CASE: amount is a gross shares (shMON) figure.
            uint256 _grossAssetsWanted = _convertToAssets(amount, OZMath.Rounding.Floor, true, false);
            uint256 _grossAssetsCapped;
            (_grossAssetsCapped, _feeTaken) = _getGrossCappedAndFeeFromGrossAssets(_grossAssetsWanted);
            _assetsToReceive = _grossAssetsCapped - _feeTaken;
            _sharesToDeduct = amount.toUint128();
        }

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease committed balance (respecting any holds if not released above)
        // - decrease committedTotalSupply (value leaving committed form)
        CommittedData memory fromCommittedData = s_committedData[policyID][from];
        _spendFromCommitted(fromCommittedData, policyID, from, _sharesToDeduct, Delivery.Underlying);
        s_committedData[policyID][from] = fromCommittedData;

        // Call StakeTracker hook to account for assets leaving via instant unstake
        _accountForWithdraw(_assetsToReceive.toUint128(), _feeTaken.toUint128());

        // Send net assets to the `to` address
        to.safeTransferETH(_assetsToReceive);

        emit AgentWithdrawFromCommitted(policyID, from, to, _assetsToReceive);
    }

    // --------------------------------------------- //
    //            Unstake Functions                  //
    // --------------------------------------------- //

    function requestUnstake(uint256 shares) external notWhenClosed returns (uint64 completionEpoch) {
        completionEpoch = _requestUnstake(shares);
    }

    function _requestUnstake(uint256 shares) internal returns (uint64 completionEpoch) {
        require(shares != 0, CannotUnstakeZeroShares());
        require(shares <= balanceOf(msg.sender), InsufficientBalanceForUnstake());

        uint256 amount = previewUnstake(shares);

        // burn shMON → record request into global trackers
        _burn(msg.sender, shares);
        _afterRequestUnstake(amount);

        // Calculate the internal epoch when the unstake request can be completed
        completionEpoch = _calcUnstakeRequestCompletionEpoch(amount);

        // Load the user's previous completion epoch to ensure we do not move it backwards
        uint64 _prevCompletionEpoch = s_unstakeRequests[msg.sender].completionEpoch;

        // We take the furthest completion epoch between the new request and the previous one
        completionEpoch = uint64(Math.max(completionEpoch, _prevCompletionEpoch));

        // Store the user's cumulative unstaking amount, and the furthest completion epoch
        s_unstakeRequests[msg.sender].amountMon += amount.toUint128();
        s_unstakeRequests[msg.sender].completionEpoch = completionEpoch;

        emit RequestUnstake(msg.sender, shares, amount, completionEpoch);
    }

    function completeUnstake() external virtual notWhenClosed {
        _completeUnstake(msg.sender);
    }

    function _completeUnstake(address account) internal {
        // pull request
        uint64 _currentInternalEpoch = s_admin.internalEpoch;
        UserUnstakeRequest memory _unstakeRequest = s_unstakeRequests[account];
        require(_unstakeRequest.amountMon != 0, NoUnstakeRequestFound());
        require(
            _currentInternalEpoch >= _unstakeRequest.completionEpoch,
            CompletionEpochNotReached(_currentInternalEpoch, _unstakeRequest.completionEpoch)
        );

        uint128 _amount = _unstakeRequest.amountMon;
        delete s_unstakeRequests[account];

        _beforeCompleteUnstake(_amount);

        account.safeTransferETH(_amount);

        emit CompleteUnstake(account, _amount);
    }

    function _calcUnstakeRequestCompletionEpoch(uint256 amount) internal view returns (uint64 completionEpoch) {
        uint64 _currentInternalEpoch = s_admin.internalEpoch;
        // Worst case: users can `completeUnstake()` [k + 4] internal (ShMonad) epochs after calling `requestUnstake()`
        // where k is the native withdrawal delay (currently 1 Monad epoch)
        completionEpoch = _currentInternalEpoch + STAKING_WITHDRAWAL_DELAY + 4;
        // TIMING - Assumption of Worst Case
        //  Epoch N+0 Request Unstake
        //  Epoch N+1 (boundary) Last validator cranked
        //  Epoch N+2 (effective epoch of crank due to boundary)
        //  Epoch N+3 EPOCH_DELAY_PERIOD
        //  Epoch N+4 collect unstaked amount from validators
        //  Epoch N+5 user can withdraw safely
        uint256 _maxGlobalRedemptionAllowed = AccountingLib.maximumNewGlobalRedemptionAmount(
            s_globalCapital, s_globalLiabilities, s_admin, s_globalPending, address(this).balance
        );

        // If the requested amount exceeds the maximum global redemption allowed, the completion epoch is extended by 2
        // additional epochs to account for the activation of pending stake.
        if (amount > _maxGlobalRedemptionAllowed) {
            // TIMING - Assumption of Worst Case
            // NOTE: We must wait for deposit to finish before we can start unstaking it
            //  Epoch N+0 Deposit requested in boundary block
            //  Epoch N+1 effective deposit block
            //  Epoch N+2 verify deposit complete +  Request Unstake
            //  Epoch N+3 (boundary) Last validator cranked
            //  Epoch N+4 (effective epoch of crank due to boundary)
            //  Epoch N+5 EPOCH_DELAY_PERIOD
            //  Epoch N+6 collect unstaked amount from validators <- Net New Delay
            //  Epoch N+7 user can withdraw safely <- Net New Delay
            completionEpoch += 2;
        }
    }

    // --------------------------------------------- //
    //        Zero Yield Tranche Functions           //
    // --------------------------------------------- //

    /// @notice Deposits assets into the zero-yield tranche, crediting the balance to the receiver
    /// @dev The zero-yield tranche does not earn any yield. Yield earned on the deposited assets go towards boosting
    /// shMON yield. Accounts with zero-yield tranche balances can convert their balances into yield-bearing shMON at
    /// any time, via `convertZeroYieldTrancheToShMON()`.
    /// @param assets The amount of underlying assets (MON) to deposit
    /// @param receiver The address receiving the zero-yield tranche shares
    function depositToZeroYieldTranche(uint256 assets, address receiver) external payable notWhenClosed nonReentrant {
        _depositToZeroYieldTranche(assets, msg.sender, receiver);
    }

    function _depositToZeroYieldTranche(uint256 assets, address from, address to) internal {
        AdminValues memory _admin = s_admin;

        require(msg.value == assets, IncorrectNativeTokenAmountSent());

        // Increase zero-yield tranche balance
        s_zeroYieldBalances[to] += assets;

        // Increase total liabilities to reflect the new assets held in the zero-yield tranche
        _admin.totalZeroYieldPayable += uint128(assets);

        // Queue up the new funds to be staked
        _accountForDeposit(assets.toUint128());

        // Persist AdminValues changes to storage
        s_admin = _admin;

        emit DepositToZeroYieldTranche(from, to, assets);
    }

    /// @notice Converts zero-yield tranche balances into yield-bearing shMON shares.
    /// @param assets The amount of underlying assets (MON) to convert
    /// @param receiver The address receiving the yield-bearing shMON shares
    /// @return shares The amount of yield-bearing shMON shares minted to the receiver
    function convertZeroYieldTrancheToShares(
        uint256 assets,
        address receiver
    )
        external
        notWhenClosed
        nonReentrant
        returns (uint256 shares)
    {
        shares = _convertZeroYieldBalanceToShares(assets, msg.sender, receiver);
    }

    /// @notice Allows the contract owner to claim their accumulated commission as yield-bearing shMON shares.
    /// @param assets The amount of underlying assets (MON) to convert
    /// @param receiver The address receiving the yield-bearing shMON shares
    /// @return shares The amount of yield-bearing shMON shares minted to the receiver
    function claimOwnerCommissionAsShares(
        uint256 assets,
        address receiver
    )
        external
        onlyOwner
        nonReentrant
        returns (uint256 shares)
    {
        shares = _convertZeroYieldBalanceToShares(assets, OWNER_COMMISSION_ACCOUNT, receiver);
        emit AdminCommissionClaimedAsShares(receiver, assets, shares);
    }

    function _convertZeroYieldBalanceToShares(
        uint256 assets,
        address from,
        address to
    )
        internal
        returns (uint256 shares)
    {
        AdminValues memory _admin = s_admin;

        require(s_zeroYieldBalances[from] >= assets, InsufficientZeroYieldBalance(s_zeroYieldBalances[from], assets));

        // Instead of depositing new assets, we decrease totalZeroYieldPayable, which decreases total liabilities. Thus
        // there is still an increase in totalEquity that is commensurate with the increase in totalSupply caused by new
        // shares minted below.
        _admin.totalZeroYieldPayable -= uint128(assets);

        // Decrease the `from` account's zero-yield balance
        s_zeroYieldBalances[from] -= assets;

        // Logic below is similar to standard `deposit()` logic, but bypasseses maxDeposit and msg.value checks.
        // `false` indicates that msg.value should not be deducted from total assets before calculating shares. Recent
        // revenue will also not be deducted from total assets.
        shares = _previewDeposit(assets, false);
        _mint(to, shares);

        // NOTE: `_accountForDeposit()` not called, as no new assets are being deposited

        // Persist AdminValues changes to storage
        s_admin = _admin;

        // Transfer event emitted by _mint(). Additional Deposit event emitted here.
        emit ZeroYieldBalanceConvertedToShares(from, to, assets, shares);
        emit Deposit(from, to, assets, shares);
    }

    /// @notice Returns the zero-yield tranche balance of an account
    /// @param account The account to query
    /// @return The zero-yield tranche balance of the account, in MON
    function balanceOfZeroYieldTranche(address account) external view returns (uint256) {
        return s_zeroYieldBalances[account];
    }

    /// @notice Returns the unclaimed owner commission balance
    /// @return The unclaimed owner commission balance, in MON
    function unclaimedOwnerCommission() external view returns (uint256) {
        return s_zeroYieldBalances[OWNER_COMMISSION_ACCOUNT];
    }
}
