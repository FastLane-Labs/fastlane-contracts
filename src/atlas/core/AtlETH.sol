//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Permit69 } from "./Permit69.sol";
import "../types/EscrowTypes.sol";

// NOTE Atlas only uses the surchargeRecipient to set the Atlas surcharge rate. Any Atlas surcharge is sent to ShMonad
// as yield on Monad Testnet. The other functions around surcharge and surchargeRecipient are left in place to maintain
// compatibility with the vanilla version of Atlas.

/// @author FastLane Labs
abstract contract AtlETH is Permit69 {
    constructor(
        uint256 atlasSurchargeRate,
        address verification,
        address simulator,
        address initialSurchargeRecipient,
        address l2GasCalculator,
        address shMonad,
        uint64 shMonadPolicyID
    )
        Permit69(
            atlasSurchargeRate,
            verification,
            simulator,
            initialSurchargeRecipient,
            l2GasCalculator,
            shMonad,
            shMonadPolicyID
        )
    { }

    function accountLastActiveBlock(address account) external view returns (uint256) {
        return S_accessData[account].lastAccessedBlock;
    }

    /// @notice Allows the current surcharge recipient to withdraw the accumulated surcharge. NOTE: If the only MON in
    /// Atlas is the surcharge, be mindful that withdrawing this MON may limit solvers' liquidity to flashloan MON from
    /// Atlas in their solverOps.
    /// @dev This function can only be called by the current surcharge recipient.
    /// It transfers the accumulated surcharge amount to the surcharge recipient's address.
    function withdrawSurcharge() external {
        _onlySurchargeRecipient();

        uint256 _paymentAmount = S_cumulativeSurcharge;
        S_cumulativeSurcharge = 0; // Clear before transfer to prevent reentrancy
        SafeTransferLib.safeTransferETH(msg.sender, _paymentAmount);
        emit SurchargeWithdrawn(msg.sender, _paymentAmount);
    }

    /// @notice Starts the transfer of the surcharge recipient designation to a new address.
    /// @dev This function can only be called by the current surcharge recipient.
    /// It sets the `pendingSurchargeRecipient` to the specified `newRecipient` address,
    /// allowing the new recipient to claim the surcharge recipient designation by calling `becomeSurchargeRecipient`.
    /// If the caller is not the current surcharge recipient, it reverts with an `InvalidAccess` error.
    /// @param newRecipient The address of the new surcharge recipient.
    function transferSurchargeRecipient(address newRecipient) external {
        _onlySurchargeRecipient();

        address _surchargeRecipient = S_surchargeRecipient;

        S_pendingSurchargeRecipient = newRecipient;
        emit SurchargeRecipientTransferStarted(_surchargeRecipient, newRecipient);
    }

    /// @notice Finalizes the transfer of the surcharge recipient designation to a new address.
    /// @dev This function can only be called by the pending surcharge recipient,
    /// and it completes the transfer of the surcharge recipient designation to the address
    /// stored in `pendingSurchargeRecipient`.
    /// If the caller is not the pending surcharge recipient, it reverts with an `InvalidAccess` error.
    function becomeSurchargeRecipient() external {
        if (msg.sender != S_pendingSurchargeRecipient) {
            revert InvalidAccess();
        }

        S_surchargeRecipient = msg.sender;
        S_pendingSurchargeRecipient = address(0);
        emit SurchargeRecipientTransferred(msg.sender);
    }
}
