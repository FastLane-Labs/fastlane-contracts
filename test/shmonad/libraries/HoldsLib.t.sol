// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { HoldsLib } from "../../../src/shmonad/libraries/HoldsLib.sol";
import { CommittedData, PolicyAccount } from "../../../src/shmonad/Types.sol";

contract HoldsLibTest is Test {
    using HoldsLib for PolicyAccount;

    uint64 internal constant POLICY_ID = 7;
    address internal constant ACCOUNT = address(0xBEEF);

    mapping(uint64 policyID => mapping(address account => CommittedData)) internal committedData;

    function test_holdAccumulatesExistingHold() public {
        _setCommitted(POLICY_ID, ACCOUNT, 5 ether);

        PolicyAccount memory pAcc = _policyAccount(POLICY_ID, ACCOUNT);
        pAcc.hold(committedData[POLICY_ID][ACCOUNT], 2 ether);
        assertEq(pAcc.getHoldAmount(), 2 ether, "initial hold");

        pAcc.hold(committedData[POLICY_ID][ACCOUNT], 1 ether);
        assertEq(pAcc.getHoldAmount(), 3 ether, "hold should accumulate");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_holdRevertsWhenExistingPlusNewExceedsCommitted() public {
        _setCommitted(POLICY_ID, ACCOUNT, 3 ether);

        PolicyAccount memory pAcc = _policyAccount(POLICY_ID, ACCOUNT);
        pAcc.hold(committedData[POLICY_ID][ACCOUNT], 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                HoldsLib.InsufficientCommittedForHold.selector,
                uint256(3 ether),
                uint256(4 ether)
            )
        );
        pAcc.hold(committedData[POLICY_ID][ACCOUNT], 2 ether);
    }

    function test_releaseWithoutExistingHoldNoop() public {
        _setCommitted(POLICY_ID, ACCOUNT, 1 ether);

        PolicyAccount memory pAcc = _policyAccount(POLICY_ID, ACCOUNT);
        pAcc.release(0.5 ether);
        assertEq(pAcc.getHoldAmount(), 0, "release without hold keeps zero");
    }

    function test_releaseMaxClearsAccumulatedHold() public {
        _setCommitted(POLICY_ID, ACCOUNT, 4 ether);

        PolicyAccount memory pAcc = _policyAccount(POLICY_ID, ACCOUNT);
        pAcc.hold(committedData[POLICY_ID][ACCOUNT], 3 ether);

        pAcc.release(type(uint256).max);
        assertEq(pAcc.getHoldAmount(), 0, "max release clears hold");
    }

    function test_releasePartialReducesHold() public {
        _setCommitted(POLICY_ID, ACCOUNT, 5 ether);

        PolicyAccount memory pAcc = _policyAccount(POLICY_ID, ACCOUNT);
        pAcc.hold(committedData[POLICY_ID][ACCOUNT], 4 ether);

        pAcc.release(1 ether);
        assertEq(pAcc.getHoldAmount(), 3 ether, "partial release keeps remaining hold");
    }

    function _setCommitted(uint64 policyID, address account, uint128 amount) internal {
        committedData[policyID][account].committed = amount;
    }

    function _policyAccount(uint64 policyID, address account) internal pure returns (PolicyAccount memory) {
        return PolicyAccount({ policyID: policyID, account: account });
    }
}
