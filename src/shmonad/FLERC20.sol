//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol";
import { NoncesUpgradeable } from "@openzeppelin-upgradeable/contracts/utils/NoncesUpgradeable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IERC20Permit } from "./interfaces/IERC20Full.sol";
import { ShMonadHolds } from "./Holds.sol";
import { Balance, Supply } from "./Types.sol";
import { PERMIT_TYPEHASH } from "./Constants.sol";

/// @author FastLane Labs
/// @dev Based on OpenZeppelin's ERC20 implementation, with modifications to support shMonad's storage structure.
/// Supports EIP-2612 Permit.
abstract contract FastLaneERC20 is ShMonadHolds, EIP712Upgradeable, NoncesUpgradeable, OwnableUpgradeable {
    using SafeCast for uint256;

    // NOTE: `initialize()` for EIP712 setup defined in ShMonad.sol

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return "ShMonad";
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return "shMON";
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev Returns the real total supply of minted shMON.
     */
    function totalSupply() public view returns (uint256) {
        return _realTotalSupply();
    }

    /**
     * @dev Returns the real total supply of minted shMON.
     */
    function realTotalSupply() external view returns (uint256) {
        return _realTotalSupply();
    }

    function committedTotalSupply() external view returns (uint256) {
        return uint256(s_supply.committedTotal);
    }

    /**
     * @dev Returns the real total supply of minted shMON.
     */
    function _realTotalSupply() internal view returns (uint256) {
        return uint256(s_supply.total);
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return s_balances[account].uncommitted;
    }

    /**
     * @notice Gets the total committed balance of an account across all policies.
     * @param account The address to check.
     * @return The committed balance in shares.
     */
    function balanceOfCommitted(address account) external view returns (uint256) {
        return s_balances[account].committed;
    }

    /**
     * @notice Gets the committed balance of an account within a specific policy.
     * @param policyID The ID of the policy.
     * @param account The address to check.
     * @return The committed balance in shares.
     */
    function balanceOfCommitted(uint64 policyID, address account) external view returns (uint256) {
        return s_committedData[policyID][account].committed;
    }

    /**
     * @notice Gets the uncommitting balance of an account within a specific policy.
     * @param policyID The ID of the policy.
     * @param account The address to check.
     * @return The uncommitting balance in shares.
     */
    function balanceOfUncommitting(uint64 policyID, address account) external view returns (uint256) {
        return s_uncommittingData[policyID][account].uncommitting;
    }

    /**
     * @inheritdoc IERC20Permit
     */
    function nonces(address owner) public view virtual override(IERC20Permit, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    /**
     * @inheritdoc IERC20Permit
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view virtual returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return s_allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /**
     * @inheritdoc IERC20Permit
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        public
        virtual
    {
        require(block.timestamp <= deadline, ERC2612ExpiredSignature(deadline));

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline));
        bytes32 hash = _hashTypedDataV4(structHash);

        // 1) Try ECDSA first (works for EOAs, including 7702 EOAs with transient code)
        address recovered = ECDSA.recover(hash, v, r, s);
        if (recovered != owner) {
            // 2) If not an ECDSA signer, try ERC-1271 for contract accounts
            if (owner.code.length == 0) revert ERC2612InvalidSigner(recovered, owner);
            bytes memory sig = abi.encodePacked(r, s, v);
            bool ok = SignatureChecker.isValidSignatureNow(owner, hash, sig);
            require(ok, ERC2612InvalidSigner(address(0), owner));
        }

        _approve(owner, spender, value);
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Skips emitting an {Approval} event indicating an allowance update. This is not
     * required by the ERC. See {xref-ERC20-_approve-address-address-uint256-bool-}[_approve].
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        require(from != address(0), ERC20InvalidSender(address(0)));
        require(to != address(0), ERC20InvalidReceiver(address(0)));
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * @dev Modifies the `uncommitted` value of an account's balance, in the s_balances mapping.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        uint128 value128 = value.toUint128();
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            s_supply.total += value128;
        } else {
            Balance memory fromBalance = s_balances[from];
            uint256 fromUncommitted = fromBalance.uncommitted;
            require(fromUncommitted >= value, ERC20InsufficientBalance(from, fromUncommitted, value));
            unchecked {
                // Underflow not possible: value <= fromBalance <= totalSupply.
                fromBalance.uncommitted -= value128;
                s_balances[from] = fromBalance;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Underflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                s_supply.total -= value128;
            }
        } else {
            // Overflow IS possible as s_supply.total is not a uint128, but Balance.uncommitted is.
            s_balances[to].uncommitted += value128;
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        require(account != address(0), ERC20InvalidReceiver(address(0)));
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        require(account != address(0), ERC20InvalidSender(address(0)));
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     *
     * ```solidity
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        require(owner != address(0), ERC20InvalidApprover(address(0)));
        require(spender != address(0), ERC20InvalidSpender(address(0)));
        s_allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            require(currentAllowance >= value, ERC20InsufficientAllowance(spender, currentAllowance, value));
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }

    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding,
        bool excludeRecentRevenue,
        bool deductMsgValue
    )
        internal
        view
        virtual
        returns (uint256);
}
