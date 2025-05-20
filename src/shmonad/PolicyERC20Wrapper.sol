//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Import the interface or contract that includes balanceOfBonded
import { IShMonad } from "../shmonad/interfaces/IShMonad.sol";

// TODO implement other ERC20 functions but they should revert when called
interface IERC20 {
    /// @notice Returns the bonded balance of tokens from a shmonad policy
    function balanceOf(address account) external view returns (uint256);
}

// TODO refactor this to minimal proxy with PolicyERC20WrapperLib for gas efficiency

/// @title PolicyERC20Wrapper
/// @notice These wrappers are primarily for wallet UX, to show the distribution of an account's assets between unbonded
/// shMON and any policies in which they might have bonded/unbonding shMON.
/// @author FastLane Labs
contract PolicyERC20Wrapper is IERC20 {
    IShMonad public immutable SHMONAD;
    uint64 public immutable POLICY_ID;

    constructor(address shmonad, uint64 policyID) {
        SHMONAD = IShMonad(shmonad);
        POLICY_ID = policyID;
    }

    /// @return the total (bonded and unbonding) shMON that an account owns within the wrapper's policy
    function balanceOf(address account) public view returns (uint256) {
        return SHMONAD.balanceOfBonded(POLICY_ID, account) + SHMONAD.balanceOfUnbonding(POLICY_ID, account);
    }
}
