//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { FastLaneERC20 } from "./FLERC20.sol";
import { IERC4626Custom } from "./interfaces/IERC4626Custom.sol";

/// @author FastLane Labs
/// @dev Based on OpenZeppelin's ERC4626 implementation, with modifications to support shMonad's storage structure.
abstract contract FastLaneERC4626 is FastLaneERC20 {
    using Math for uint256;
    using SafeTransferLib for address;

    // --------------------------------------------- //
    //            ERC4626 Custom Functions           //
    // --------------------------------------------- //

    // NOTE: Placeholder for now. Accepts MON which increases yield for shMON holders.
    /// @inheritdoc IERC4626Custom
    /// @dev Accepts native MON tokens via msg.value which increases yield for all shMON holders
    /// @dev The provided native tokens are not distributed but remain in the contract as yield
    function boostYield() external payable {
        emit BoostYield(_msgSender(), msg.value, false);
    }

    // Burns shMON shares and converts the underlying assets into yield for all other shMON holders
    /// @inheritdoc IERC4626Custom
    /// @dev Burns shMON shares from the specified address, effectively donating their value to other holders
    /// @dev If the sender is not the 'from' address, allowance is consumed
    /// @dev The underlying assets are not withdrawn but remain in the contract as yield for other shMON holders
    function boostYield(uint256 shares, address from) external {
        uint256 _assets = _convertToAssets(shares, Math.Rounding.Floor, false);
        if (from != _msgSender()) {
            _spendAllowance(from, _msgSender(), shares);
        }
        _burn(from, shares);
        emit BoostYield(from, _assets, true);
        // Native tokens intentionally not sent - remains in ShMonad as yield
    }

    // --------------------------------------------- //
    //           ERC4626 Standard Functions          //
    // --------------------------------------------- //

    /**
     * @dev See {IERC4626-deposit}.
     */
    function deposit(uint256 assets, address receiver) public payable virtual returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = _previewDeposit(assets, true);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /**
     * @dev See {IERC4626-mint}.
     */
    function mint(uint256 shares, address receiver) public payable virtual returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets = _previewMint(shares, true);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /**
     * @dev See {IERC4626-withdraw}.
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        // TODO: Integrate FastLane ClearingHouse for atomic ShMON -> MON conversions without
        // withdrawal queue. Relative to the current version, builders preparing for the prod
        // version of ShMonad should expect a moderate gas cost increase (~30-40k)and a dynamic,
        // utilization-based fee on all atomic ShMON -> MON conversions.
        //
        // You can read more about the ClearingHouse here:
        //      https://www.fastlane.xyz/ClearingHouse_Whitepaper.pdf
        //
        // NOTE: ClearingHouse integration is blocked by the unavailability of the Monad Staking
        // contracts.
        receiver.safeTransferETH(assets);
        // NOTE: Builders working with the ShMonad contracts can expect this function to maintain
        // its ability to withdraw MON atomically. A separate, asynchronous withdrawal function
        // will be added for depositors wishing to withdraw via queue rather than ClearingHouse

        return shares;
    }

    /**
     * @dev See {IERC4626-redeem}.
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        // TODO: Integrate FastLane ClearingHouse for atomic ShMON -> MON conversions without
        // withdrawal queue. Relative to the current version, builders preparing for the prod
        // version of ShMonad should expect a moderate gas cost increase (~30-40k)and a dynamic,
        // utilization-based fee on all atomic ShMON -> MON conversions.
        //
        // You can read more about the ClearingHouse here:
        //      https://www.fastlane.xyz/ClearingHouse_Whitepaper.pdf
        //
        // NOTE: ClearingHouse integration is blocked by the unavailability of the Monad Staking
        // contracts.
        receiver.safeTransferETH(assets);
        // NOTE: Builders working with the ShMonad contracts can expect this function to maintain
        // its ability to withdraw MON atomically. A separate, asynchronous withdrawal function
        // will be added for depositors wishing to withdraw via queue rather than ClearingHouse

        return assets;
    }

    // --------------------------------------------- //
    //               Internal Functions              //
    // --------------------------------------------- //

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding,
        bool deductMsgValue
    )
        internal
        view
        virtual
        returns (uint256)
    {
        uint256 _totalAssets = deductMsgValue ? totalAssets() - msg.value : totalAssets();
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), _totalAssets + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding,
        bool deductMsgValue
    )
        internal
        view
        virtual
        returns (uint256)
    {
        uint256 _totalAssets = deductMsgValue ? totalAssets() - msg.value : totalAssets();
        return shares.mulDiv(_totalAssets + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        require(assets == msg.value, InsufficientNativeTokenSent());

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        internal
        virtual
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _previewDeposit(uint256 assets, bool deductMsgValue) internal view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor, deductMsgValue);
    }

    function _previewMint(uint256 shares, bool deductMsgValue) internal view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil, deductMsgValue);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    // --------------------------------------------- //
    //                 View Functions                //
    // --------------------------------------------- //

    /**
     * @dev See {IERC4626-asset}.
     */
    function asset() public view virtual returns (address) {
        return NATIVE_TOKEN;
    }

    /**
     * @dev See {IERC4626-totalAssets}.
     */
    function totalAssets() public view virtual returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev See {IERC4626-convertToShares}.
     */
    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor, false);
    }

    /**
     * @dev See {IERC4626-convertToAssets}.
     */
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor, false);
    }

    /**
     * @dev See {IERC4626-maxDeposit}.
     */
    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint128).max;
    }

    /**
     * @dev See {IERC4626-maxMint}.
     */
    function maxMint(address) public view virtual returns (uint256) {
        // Limited to
        return type(uint128).max;
    }

    /**
     * @dev See {IERC4626-maxWithdraw}.
     */
    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor, false);
    }

    /**
     * @dev See {IERC4626-maxRedeem}.
     */
    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf(owner);
    }

    /**
     * @dev See {IERC4626-previewDeposit}.
     */
    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor, false);
    }

    /**
     * @dev See {IERC4626-previewMint}.
     */
    function previewMint(uint256 shares) public view virtual returns (uint256) {
        return _previewMint(shares, false);
    }

    /**
     * @dev See {IERC4626-previewWithdraw}.
     */
    function previewWithdraw(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil, false);
    }

    /**
     * @dev See {IERC4626-previewRedeem}.
     */
    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor, false);
    }
}
