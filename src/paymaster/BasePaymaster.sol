// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/* solhint-disable reason-string */

import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { IEntryPoint as IEntryPointV7 } from "account-abstraction-v7/contracts/interfaces/IEntryPoint.sol";
import { IEntryPoint as IEntryPointV8 } from "account-abstraction-v8/contracts/interfaces/IEntryPoint.sol";

import "account-abstraction-v7/contracts/interfaces/IPaymaster.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * Helper class for creating a paymaster.
 * provides helper methods for staking.
 * Validates that the postOp is called only by the entryPoint.
 */
abstract contract BasePaymaster is IPaymaster, OwnableUpgradeable {
    IEntryPointV7 public immutable entryPointV7;
    IEntryPointV8 public immutable entryPointV8;

    /// @notice Constructor that sets the entry point addresses
    /// @param _entryPointV7 The entry point address for v7
    /// @param _entryPointV8 The entry point address for v8
    constructor(address _entryPointV7, address _entryPointV8) {
        _validateEntryPointInterface(_entryPointV7, true);
        _validateEntryPointInterface(_entryPointV8, false);

        entryPointV7 = IEntryPointV7(_entryPointV7);
        entryPointV8 = IEntryPointV8(_entryPointV8);
    }

    /// @notice Initialize the paymaster
    /// @param _owner The owner of the paymaster
    function _initialize(address _owner) internal {
        __Ownable_init(_owner);
    }

    // sanity check: make sure this EntryPoint was compiled against the same
    // IEntryPoint of this paymaster
    function _validateEntryPointInterface(address entryPoint, bool isV7) internal virtual {
        if (isV7) {
            require(
                IERC165(entryPoint).supportsInterface(type(IEntryPointV7).interfaceId),
                "IEntryPointV7 interface mismatch"
            );
        } else {
            require(
                IERC165(entryPoint).supportsInterface(type(IEntryPointV8).interfaceId),
                "IEntryPointV8 interface mismatch"
            );
        }
    }

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    )
        external
        override
        returns (bytes memory context, uint256 validationData)
    {
        _requireFromEntryPoint();
        return _validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    /**
     * Validate a user operation.
     * @param userOp     - The user operation.
     * @param userOpHash - The hash of the user operation.
     * @param maxCost    - The maximum cost of the user operation.
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    )
        internal
        virtual
        returns (bytes memory context, uint256 validationData);

    /// @inheritdoc IPaymaster
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    )
        external
        override
    {
        bool isV7 = _requireFromEntryPoint();
        _postOp(
            isV7 ? address(entryPointV7) : address(entryPointV8), mode, context, actualGasCost, actualUserOpFeePerGas
        );
    }

    /**
     * Post-operation handler.
     * (verified to be called only through the entryPoint)
     * @dev If subclass returns a non-empty context from validatePaymasterUserOp,
     *      it must also implement this method.
     * @param entryPoint          - The entry point address.
     * @param mode          - Enum with the following options:
     *                        opSucceeded - User operation succeeded.
     *                        opReverted  - User op reverted. The paymaster still has to pay for gas.
     *                        postOpReverted - never passed in a call to postOp().
     * @param context       - The context value returned by validatePaymasterUserOp
     * @param actualGasCost - Actual gas used so far (without this postOp call).
     * @param actualUserOpFeePerGas - the gas price this UserOp pays. This value is based on the UserOp's maxFeePerGas
     *                        and maxPriorityFee (and basefee)
     *                        It is not the same as tx.gasprice, which is what the bundler pays.
     */
    function _postOp(
        address entryPoint,
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    )
        internal
        virtual
    {
        (entryPoint, mode, context, actualGasCost, actualUserOpFeePerGas); // unused params
        // subclass must override this method if validatePaymasterUserOp returns a context
        revert("must override");
    }

    /**
     * Add a deposit for this paymaster, used for paying for transaction fees.
     * @param entryPoint - The entry point address.
     */
    function deposit(address entryPoint) public payable {
        if (_isV7(entryPoint)) {
            entryPointV7.depositTo{ value: msg.value }(address(this));
        } else {
            entryPointV8.depositTo{ value: msg.value }(address(this));
        }
    }

    /**
     * Withdraw value from the deposit.
     * @param entryPoint - The entry point address.
     * @param withdrawAddress - Target to send to.
     * @param amount          - Amount to withdraw.
     */
    function withdrawTo(address entryPoint, address payable withdrawAddress, uint256 amount) public onlyOwner {
        if (_isV7(entryPoint)) {
            entryPointV7.withdrawTo(withdrawAddress, amount);
        } else {
            entryPointV8.withdrawTo(withdrawAddress, amount);
        }
    }

    /**
     * Add stake for this paymaster.
     * This method can also carry eth value to add to the current stake.
     * @param entryPoint - The entry point address.
     * @param unstakeDelaySec - The unstake delay for this paymaster. Can only be increased.
     */
    function addStake(address entryPoint, uint32 unstakeDelaySec) external payable onlyOwner {
        if (_isV7(entryPoint)) {
            entryPointV7.addStake{ value: msg.value }(unstakeDelaySec);
        } else {
            entryPointV8.addStake{ value: msg.value }(unstakeDelaySec);
        }
    }

    /**
     * Return current paymaster's deposit on the entryPoint.
     * @param entryPoint - The entry point address.
     */
    function getDeposit(address entryPoint) public view returns (uint256) {
        if (_isV7(entryPoint)) {
            return entryPointV7.balanceOf(address(this));
        } else {
            return entryPointV8.balanceOf(address(this));
        }
    }

    /**
     * Unlock the stake, in order to withdraw it.
     * The paymaster can't serve requests once unlocked, until it calls addStake again
     * @param entryPoint - The entry point address.
     */
    function unlockStake(address entryPoint) external onlyOwner {
        if (_isV7(entryPoint)) {
            entryPointV7.unlockStake();
        } else {
            entryPointV8.unlockStake();
        }
    }

    /**
     * Withdraw the entire paymaster's stake.
     * stake must be unlocked first (and then wait for the unstakeDelay to be over)
     * @param entryPoint - The entry point address.
     * @param withdrawAddress - The address to send withdrawn value.
     */
    function withdrawStake(address entryPoint, address payable withdrawAddress) external onlyOwner {
        if (_isV7(entryPoint)) {
            entryPointV7.withdrawStake(withdrawAddress);
        } else {
            entryPointV8.withdrawStake(withdrawAddress);
        }
    }

    /**
     * Validate the call is made from a valid entrypoint
     */
    function _requireFromEntryPoint() internal virtual returns (bool isV7) {
        isV7 = _isV7(msg.sender);
        require(isV7 || msg.sender == address(entryPointV8), "Sender not EntryPoint");
    }

    function _isV7(address entryPoint) internal view returns (bool) {
        return entryPoint == address(entryPointV7);
    }
}
