//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// OVERRIDE STUFF
import { ShMonadStorage } from "./Storage.sol";
import { Directory } from "../common/Directory.sol";
import { ISponsoredExecutor } from "../common/ISponsoredExecutor.sol";
import { IAddressHub } from "../common/IAddressHub.sol";
import { Bonds } from "./Bonds.sol";
import { BondedData } from "./Types.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";

/**
 * @title ShMonad - Liquid Staking Token on Monad
 * @notice ShMonad is an LST integrated with the FastLane ecosystem
 * @dev Extends Bonds which provides ERC4626 functionality plus policy-based bonding mechanisms
 * @author FastLane Labs
 */
contract ShMonad is Bonds {
    using SafeTransferLib for address;
    using SafeCast for uint256;

    /**
     * @notice Initializes the ShMonad contract
     * @param sponsoredExecutor The address of the SponsoredExecutor contract
     * @param taskManager The address of the TaskManager contract
     * @param unbondingTask The address of the UnbondingTask implementation
     */
    constructor(
        address sponsoredExecutor,
        address taskManager,
        address unbondingTask
    )
        Bonds(sponsoredExecutor, taskManager, unbondingTask)
    { }

    /**
     * @notice Initializes the contract with ownership set to the deployer
     * @dev This is part of the OpenZeppelin Upgradeable pattern
     * @param deployer The address that will own the contract
     */
    function initialize(address deployer) public reinitializer(6) {
        __EIP712_init("ShMonad", "2");
        __Ownable_init(deployer);
    }

    // --------------------------------------------- //
    //                 Agent Functions               //
    // --------------------------------------------- //

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Releases any holds on the source account if requested
     * 2. Converts to shares if amount is specified in underlying assets
     * 3. Updates the source account's bonded balance in memory then persists to storage
     * 4. Updates the destination account's bonded balance directly in storage
     * 5. Does not decrease bondedTotalSupply as the value remains in bonded form
     */
    function agentTransferFromBonded(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        onlyActivePolicy(policyID)
        onlyPolicyAgent(policyID)
    {
        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);
        if (inUnderlying) amount = previewWithdraw(amount);

        uint128 sharesToDeduct = amount.toUint128();

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease bonded balance (respecting any holds if not released above)
        // - do not decrease bondedTotalSupply (value stays in bonded form)
        BondedData memory fromBondedData = s_bondedData[policyID][from];
        _spendFromBonded(fromBondedData, policyID, from, sharesToDeduct, false);
        s_bondedData[policyID][from] = fromBondedData;

        // Changes to the `to` account - done directly in storage:
        // - increase bonded balance (holds not applicable if increasing)
        s_bondedData[policyID][to].bonded += sharesToDeduct;
        s_balances[to].bonded += sharesToDeduct;

        emit AgentTransferFromBonded(policyID, from, to, amount);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Prevents agents from unbonding their own balance
     * 2. Releases any holds on the source account if requested
     * 3. Converts to shares if amount is specified in underlying assets
     * 4. Updates the source account's bonded balance in memory then persists to storage
     * 5. Increases the destination account's unbonded balance
     * 6. Decreases bondedTotalSupply since value is leaving the bonded form
     */
    function agentTransferToUnbonded(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        onlyActivePolicy(policyID)
        onlyPolicyAgent(policyID)
    {
        // Make sure agent isn't unbonding their own balance
        if (from == msg.sender && _isPolicyAgent(policyID, msg.sender)) {
            revert AgentSelfUnbondingDisallowed(policyID, msg.sender);
        }

        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);
        if (inUnderlying) amount = previewWithdraw(amount);

        uint128 sharesToDeduct = amount.toUint128();

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease bonded balance (respecting any holds if not released above)
        // - do not decrease bondedTotalSupply (value stays in bonded form)
        BondedData memory fromBondedData = s_bondedData[policyID][from];
        _spendFromBonded(fromBondedData, policyID, from, sharesToDeduct, true);
        s_bondedData[policyID][from] = fromBondedData;

        // Increase unbonded balance
        s_balances[to].unbonded += sharesToDeduct;

        emit AgentTransferToUnbonded(policyID, from, to, amount);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Prevents agents from withdrawing their own balance
     * 2. Releases any holds on the source account if requested
     * 3. Handles conversion between shares and assets based on inUnderlying flag
     * 4. Updates the source account's bonded balance in memory then persists to storage
     * 5. Temporarily increases the destination's unbonded balance
     * 6. Burns the shares from the destination account
     * 7. Transfers the underlying assets (MON) to the destination
     */
    function agentWithdrawFromBonded(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        onlyPolicyAgent(policyID)
        onlyActivePolicy(policyID)
    {
        // Make sure agent isn't unbonding their own balance
        if (from == msg.sender && _isPolicyAgent(policyID, msg.sender)) {
            revert AgentSelfUnbondingDisallowed(policyID, msg.sender);
        }

        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);

        uint128 sharesToDeduct;
        uint256 assetsToReceive;

        if (inUnderlying) {
            // amount = MON
            assetsToReceive = amount;
            sharesToDeduct = previewWithdraw(amount).toUint128();
        } else {
            // amount = shMON
            assetsToReceive = previewRedeem(amount);
            sharesToDeduct = amount.toUint128();
        }

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease bonded balance (respecting any holds if not released above)
        // - decrease bondedTotalSupply (value leaving bonded form)
        BondedData memory fromBondedData = s_bondedData[policyID][from];
        _spendFromBonded(fromBondedData, policyID, from, sharesToDeduct, true);
        s_bondedData[policyID][from] = fromBondedData;

        // Increase to's unbonded shMON balance in prep for withdrawal below
        s_balances[to].unbonded += sharesToDeduct;

        // Skips approval checks in ERC4626 redeem func, burns deducted shares, transfers assets to `to`
        _burn(to, sharesToDeduct);
        to.safeTransferETH(assetsToReceive);

        emit AgentWithdrawFromBonded(policyID, from, to, assetsToReceive);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Releases any holds on the source account if requested
     * 2. Handles conversion between shares and assets based on inUnderlying flag
     * 3. Updates the source account's bonded balance in memory then persists to storage
     * 4. Temporarily increases the source's unbonded balance
     * 5. Burns the shares from the source account
     * 6. The burning of shares effectively boosts yield for all remaining shareholders
     * 7. Unlike agentWithdrawFromBonded, no assets are transferred out, improving the shares:assets ratio
     */
    function agentBoostYieldFromBonded(
        uint64 policyID,
        address from,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        onlyPolicyAgent(policyID)
        onlyActivePolicy(policyID)
    {
        // TODO: Consider adding this check
        /*
        if (from == msg.sender && _isPolicyAgent(policyID, msg.sender)) {
            revert AgentSelfUnbondingDisallowed(policyID, msg.sender);
        }
        */

        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);

        uint128 sharesToDeduct;
        uint256 assetsToReceive;

        if (inUnderlying) {
            // amount = MON
            assetsToReceive = amount;
            sharesToDeduct = previewWithdraw(amount).toUint128();
        } else {
            // amount = shMON
            assetsToReceive = previewRedeem(amount);
            sharesToDeduct = amount.toUint128();
        }

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease bonded balance (respecting any holds if not released above)
        // - decrease bondedTotalSupply (value leaving bonded form)
        BondedData memory fromBondedData = s_bondedData[policyID][from];
        _spendFromBonded(fromBondedData, policyID, from, sharesToDeduct, true);
        s_bondedData[policyID][from] = fromBondedData;

        // Increase to's unbonded shMON balance in prep for withdrawal below
        s_balances[from].unbonded += sharesToDeduct;

        // Skips approval checks in ERC4626 redeem func, burns deducted shares, transfers assets to `to`
        _burn(from, sharesToDeduct);

        emit AgentBoostYieldFromBonded(policyID, from, assetsToReceive);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Calculates maximum payor cost based on gas limit and tx.gasprice
     * 2. Verifies msg.value doesn't exceed msgValue parameter
     * 3. Charges payor's bonded balance for gas cost and any msgValue not covered by agent
     * 4. Increases recipient's bonded balance by the amount charged to payor
     * 5. Performs the inner call through the SponsoredExecutor
     * 6. Uses a gas reserve to ensure there's enough gas to complete the function after the inner call
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
        onlyPolicyAgent(policyID)
        onlyActivePolicy(policyID)
        returns (uint128 actualPayorCost, bool success, bytes memory returnData)
    {
        // Offset added to account for gas cost incurred after actualGasCost calculation at end
        uint256 maxPayorCost = (gasLimit + EXECUTE_END_GAS_OFFSET) * tx.gasprice;

        require(gasleft() > gasLimit + EXECUTE_END_GAS_OFFSET, MsgGasLimitTooLow(gasleft(), gasLimit));

        // Caller should not send more than `msgValue`.
        require(msg.value <= msgValue, MsgDotValueExceedsMsgValueArg(msg.value, msgValue));

        // Payor will be charged for any `msgValue` that `msg.value` does not cover
        maxPayorCost += msgValue - msg.value;

        // Do payor's BondedData SLOAD here before final gas cost calculation
        BondedData memory payorBondedData = s_bondedData[policyID][payor];

        // Calculate correct shares to deduct from payor's bonded balance
        uint256 sharesDeducted = previewWithdraw(maxPayorCost);
        uint128 sharesDeducted128 = sharesDeducted.toUint128();

        // Charge payor's bonded balance for actual gas cost + any msgValue not covered by agent
        _spendFromBonded(payorBondedData, policyID, payor, sharesDeducted128, true);

        // Persist payor's BondedData changes to storage
        s_bondedData[policyID][payor] = payorBondedData;

        // Increase recipient's bonded balance by amount charged to payor
        s_bondedData[policyID][recipient].bonded += sharesDeducted128;
        s_balances[recipient].bonded += sharesDeducted128;

        // Do the inner call
        (success, returnData) = _SPONSORED_EXECUTOR.call{ value: msgValue, gas: gasleft() - EXECUTE_CALL_GAS_RESERVE }(
            abi.encodeCall(
                ISponsoredExecutor.agentExecuteWithSponsor,
                (policyID, payor, recipient, msgValue, gasLimit, callTarget, callData)
            )
        );

        emit AgentExecuteWithSponsor(policyID, payor, msg.sender, recipient, msgValue, gasLimit, sharesDeducted128);
    }
}
