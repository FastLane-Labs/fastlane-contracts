// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { BaseTest } from "../base/BaseTest.t.sol";
import { ShMonadErrors } from "../../src/shmonad/Errors.sol";
import { ShMonadEvents } from "../../src/shmonad/Events.sol";
import { Coinbase } from "../../src/shmonad/Coinbase.sol";
import { ValidatorStats, Epoch } from "../../src/shmonad/Types.sol";
import { TestShMonad } from "../base/helpers/TestShMonad.sol";
import { SCALE, BPS_SCALE, UNKNOWN_VAL_ID, UNKNOWN_VAL_ADDRESS, FIRST_VAL_ID, LAST_VAL_ID } from "../../src/shmonad/Constants.sol";

contract FakeCoinbaseInvalidValId {
    function VAL_ID() external pure returns (uint64) {
        return 0;
    }
}

contract ValidatorRegistryTest is BaseTest {
    TestShMonad internal testShMonad;

    function setUp() public override {
        super.setUp();
        testShMonad = TestShMonad(payable(address(shMonad)));
    }

    function _crankEpoch() internal {
        staking.harnessSyscallOnEpochChange(false);
        if (!useLocalMode) {
            uint64 internalEpochBefore = shMonad.getInternalEpoch();
            for (uint256 i = 0; i < 4; i++) {
                testShMonad.harnessCrankGlobalOnly();
                if (shMonad.getInternalEpoch() > internalEpochBefore) {
                    return;
                }
            }
            revert("fork: crank did not advance internal epoch");
        }
        while (!shMonad.crank()) {}
    }

    function _crankEpochForValidator(uint64 valId) internal {
        _crankEpoch();
        if (!useLocalMode) {
            testShMonad.harnessCrankValidator(valId);
        }
    }

    // -------------------------------------------------- //
    //                 Coinbase Contract                  
    // -------------------------------------------------- //

    function test_ValidatorRegistry_previewCoinbaseAddress_revertsForInvalidIds() public {
        // Goal: previewCoinbaseAddress should guard against invalid validator IDs (0 and UNKNOWN placeholder)
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, uint256(0)));
        shMonad.previewCoinbaseAddress(0);

        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, uint256(UNKNOWN_VAL_ID)));
        shMonad.previewCoinbaseAddress(uint64(UNKNOWN_VAL_ID));
    }

    function test_ValidatorRegistry_previewCoinbaseAddress_matchesAddValidatorDeployment() public {
        // Goal: Deterministic deployment via CREATE2 – addValidator(valId) returns the previewed address
        address validator = makeAddr("coinbasePredictor");
        uint64 valId = staking.registerValidator(validator);

        address predicted = shMonad.previewCoinbaseAddress(valId);

        vm.startPrank(deployer);
        address deployed = shMonad.addValidator(valId);
        vm.stopPrank();

        assertEq(deployed, predicted, "CREATE2 predicted address should match deployed");
        assertGt(deployed.code.length, 0, "coinbase should be a deployed contract");
    }

    function test_ValidatorRegistry_addValidator_linksMappingBothWays() public {
        // Goal: After addValidator(valId), both mappings are established:
        // - getValidatorCoinbase(valId) -> coinbase
        // - getValidatorIdForCoinbase(coinbase) -> valId
        address validator = makeAddr("coinbaseMapping");
        uint64 valId = staking.registerValidator(validator);

        vm.startPrank(deployer);
        address coinbase = shMonad.addValidator(valId);
        vm.stopPrank();

        assertEq(shMonad.getValidatorCoinbase(valId), coinbase, "valId -> coinbase mapping should be set");
        assertEq(shMonad.getValidatorIdForCoinbase(coinbase), valId, "coinbase -> valId mapping should be set");
    }

    function test_ValidatorRegistry_addValidator_explicitZeroAddressReverts() public {
        // Goal: addValidator(valId, coinbase) rejects zero address via ZeroAddress()
        address validator = makeAddr("coinbaseZero");
        uint64 valId = staking.registerValidator(validator);

        vm.startPrank(deployer);
        vm.expectRevert(ShMonadErrors.ZeroAddress.selector);
        shMonad.addValidator(valId, address(0));
        vm.stopPrank();
    }

    function test_ValidatorRegistry_deactivateValidator_fullyRemovesMappingAfterDelay() public {
        // Goal: After deactivation and required epochs, mapping is unlinked (valId->0 and coinbase->0)
        address validator = makeAddr("coinbaseDeactivate");
        uint64 valId = staking.registerValidator(validator);

        vm.startPrank(deployer);
        address coinbase = shMonad.addValidator(valId);
        shMonad.deactivateValidator(valId);
        vm.stopPrank();

        // See SHMONAD_VALIDATOR_DEACTIVATION_PERIOD in Constants.sol, currently set to 7

        // Advance 1 less than enough epochs and fully crank to trigger _completeDeactivatingValidator
        for (uint256 i = 0; i < 6; ++i) {
            _crankEpochForValidator(valId);
        }

        assertEq(shMonad.getValidatorCoinbase(valId), coinbase, "valId -> coinbase should still be set");
        assertEq(shMonad.getValidatorIdForCoinbase(coinbase), valId, "coinbase -> valId should still be set");

        // Crank 1 more time to complete deactivation
        _crankEpochForValidator(valId);

        // Mapping should be cleared in both directions
        assertEq(shMonad.getValidatorCoinbase(valId), address(0), "valId -> coinbase should be cleared");
        assertEq(shMonad.getValidatorIdForCoinbase(coinbase), 0, "coinbase -> valId should be cleared");
    }

    function test_ValidatorRegistry_addValidator_revertsForZeroValidatorId() public {
        address validator = makeAddr("validatorZeroId");

        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, uint256(0)));
        shMonad.addValidator(0, validator);
        vm.stopPrank();
    }

    function test_ValidatorRegistry_addValidator_revertsForUnknownValidatorId() public {
        address validator = makeAddr("validatorUnknown");
        uint64 valId = 999_999;

        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.ValidatorNotFoundInPrecompile.selector, valId));
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
    }

    function test_ValidatorRegistry_addValidator_revertsForReservedUnknownAddress() public {
        uint64 valId = 1;

        vm.startPrank(deployer);
        // When the UNKNOWN placeholder is active, reusing its address should revert.
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorAddress.selector, UNKNOWN_VAL_ADDRESS));
        shMonad.addValidator(valId, UNKNOWN_VAL_ADDRESS);
        vm.stopPrank();
    }

    function test_ValidatorRegistry_addValidator_revertsForFirstSentinel() public {
        address validator = makeAddr("sentinelFirst");
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, FIRST_VAL_ID));
        shMonad.addValidator(FIRST_VAL_ID, validator);
        vm.stopPrank();
    }

    function test_ValidatorRegistry_addValidator_revertsForLastSentinel() public {
        address validator = makeAddr("sentinelLast");

        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, LAST_VAL_ID));
        shMonad.addValidator(LAST_VAL_ID, validator);
        vm.stopPrank();
    }

    function test_ValidatorRegistry_addValidator_initializesRingBuffersAndRewards() public {
        address validator = makeAddr("validatorInit");
        uint64 valId = staking.registerValidator(validator);

        uint64 internalEpochBefore = testShMonad.exposeInternalEpoch();

        vm.prank(deployer);
        shMonad.addValidator(valId, validator);

        ValidatorStats memory stats = shMonad.getValidatorStats(valId);
        assertTrue(stats.isActive, "validator should be active after add");
        assertEq(stats.coinbase, validator, "coinbase should match");
        assertEq(stats.rewardsPayableCurrent, 0, "current rewards should be zeroed");
        assertEq(stats.rewardsPayableLast, 0, "last rewards should be zeroed");
        assertEq(stats.earnedRevenueCurrent, 0, "current revenue should be zeroed");
        assertEq(stats.earnedRevenueLast, 0, "last revenue should be zeroed");

        // Epoch ring buffer for -1/-2 should trail the current internal epoch when possible.
        Epoch memory epochMinusOne = testShMonad.exposeValidatorEpochLast(validator);
        Epoch memory epochMinusTwo = testShMonad.exposeValidatorEpochLastLast(validator);

        uint64 expectedMinusOne = internalEpochBefore > 0 ? internalEpochBefore - 1 : 0;
        uint64 expectedMinusTwo = internalEpochBefore > 1 ? internalEpochBefore - 2 : 0;

        assertEq(epochMinusOne.epoch, expectedMinusOne, "epoch -1 should trail internal epoch");
        assertEq(epochMinusTwo.epoch, expectedMinusTwo, "epoch -2 should trail internal epoch twice");
        assertEq(epochMinusOne.withdrawalId, 1, "withdrawal id should be initialized");
        assertEq(epochMinusTwo.withdrawalId, 1, "withdrawal id should be initialized for older slot");
        assertFalse(epochMinusOne.hasDeposit, "hasDeposit should default false");
        assertFalse(epochMinusTwo.hasDeposit, "hasDeposit should default false");
        assertFalse(epochMinusOne.hasWithdrawal, "hasWithdrawal should default false");
        assertFalse(epochMinusTwo.hasWithdrawal, "hasWithdrawal should default false");
        assertTrue(epochMinusOne.wasCranked, "wasCranked should default true for past epochs");
        assertTrue(epochMinusTwo.wasCranked, "wasCranked should default true for older epochs");
    }

    // -------------------------------------------------- //
    //            processCoinbaseByAuth() Tests           //
    // -------------------------------------------------- //

    function test_ValidatorRegistry_processCoinbaseByAuth_revertsWhenFrozen() public {
        address validatorAuth = makeAddr("processFrozenAuth");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        shMonad.addValidator(valId);

        vm.prank(deployer);
        shMonad.setFrozenStatus(true);

        vm.prank(validatorAuth);
        vm.expectRevert(ShMonadErrors.NotWhenFrozen.selector);
        shMonad.processCoinbaseByAuth(valId);
    }

    function test_ValidatorRegistry_processCoinbaseByAuth_revertsForInvalidValidatorIds() public {
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, uint256(0)));
        shMonad.processCoinbaseByAuth(0);

        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, uint256(UNKNOWN_VAL_ID)));
        shMonad.processCoinbaseByAuth(uint64(UNKNOWN_VAL_ID));
    }

    function test_ValidatorRegistry_processCoinbaseByAuth_revertsWhenValidatorNotAdded() public {
        address validatorAuth = makeAddr("processMissingAuth");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(validatorAuth);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, uint256(valId)));
        shMonad.processCoinbaseByAuth(valId);
    }

    function test_ValidatorRegistry_processCoinbaseByAuth_revertsForNonContractCoinbase() public {
        address validatorAuth = makeAddr("processEOAAuth");
        address eoaCoinbase = makeAddr("processEOACoinbase");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        shMonad.addValidator(valId, eoaCoinbase);

        vm.prank(validatorAuth);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorAddress.selector, eoaCoinbase));
        shMonad.processCoinbaseByAuth(valId);
    }

    function test_ValidatorRegistry_processCoinbaseByAuth_revertsForNonAuthCaller() public {
        address validatorAuth = makeAddr("processAuth");
        address attacker = makeAddr("processAttacker");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        shMonad.addValidator(valId);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.OnlyCoinbaseAuth.selector, valId, attacker));
        shMonad.processCoinbaseByAuth(valId);
    }

    function test_ValidatorRegistry_processCoinbaseByAuth_processesCoinbase() public {
        address validatorAuth = makeAddr("processSuccessAuth");
        address recipient = makeAddr("processRecipient");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        address coinbaseAddr = shMonad.addValidator(valId);
        Coinbase coinbase = Coinbase(payable(coinbaseAddr));

        // Force all proceeds to the recipient to make the effects easy to assert.
        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(SCALE);
        coinbase.updateCommissionRecipient(recipient);
        vm.stopPrank();

        uint256 amount = 2 ether;
        vm.deal(address(this), amount);
        (bool ok,) = coinbaseAddr.call{ value: amount }("");
        assertTrue(ok, "funding coinbase should succeed");

        uint256 recipientBefore = recipient.balance;

        vm.prank(validatorAuth);
        shMonad.processCoinbaseByAuth(valId);

        assertEq(recipient.balance - recipientBefore, amount, "commission should be paid out");
        assertEq(coinbaseAddr.balance, 0, "coinbase balance should be cleared");
    }

    function test_ValidatorRegistry_processCoinbaseByAuth_allowsOwner() public {
        address validatorAuth = makeAddr("processOwnerAuth");
        address recipient = makeAddr("processOwnerRecipient");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        address coinbaseAddr = shMonad.addValidator(valId);
        Coinbase coinbase = Coinbase(payable(coinbaseAddr));

        // Route all proceeds to the recipient so the owner-triggered process is easy to assert.
        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(SCALE);
        coinbase.updateCommissionRecipient(recipient);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        (bool ok,) = coinbaseAddr.call{ value: amount }("");
        assertTrue(ok, "funding coinbase should succeed");

        uint256 recipientBefore = recipient.balance;

        vm.prank(deployer);
        shMonad.processCoinbaseByAuth(valId);

        assertEq(recipient.balance - recipientBefore, amount, "commission should be paid out by owner");
        assertEq(coinbaseAddr.balance, 0, "coinbase balance should be cleared");
    }

    function test_ValidatorRegistry_processCoinbaseByAuthByAddress_revertsWhenFrozen() public {
        address validatorAuth = makeAddr("processFrozenAuthByAddress");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        address coinbaseAddr = shMonad.addValidator(valId);

        vm.prank(deployer);
        shMonad.setFrozenStatus(true);

        vm.prank(deployer);
        vm.expectRevert(ShMonadErrors.NotWhenFrozen.selector);
        shMonad.processCoinbaseByAuth(coinbaseAddr);
    }

    function test_ValidatorRegistry_processCoinbaseByAuthByAddress_revertsForZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorAddress.selector, address(0)));
        shMonad.processCoinbaseByAuth(address(0));
    }

    function test_ValidatorRegistry_processCoinbaseByAuthByAddress_revertsForNonContract() public {
        address coinbase = makeAddr("nonContractCoinbase");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorAddress.selector, coinbase));
        shMonad.processCoinbaseByAuth(coinbase);
    }

    function test_ValidatorRegistry_processCoinbaseByAuthByAddress_revertsForInvalidValId() public {
        FakeCoinbaseInvalidValId fake = new FakeCoinbaseInvalidValId();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorId.selector, uint256(0)));
        shMonad.processCoinbaseByAuth(address(fake));
    }

    function test_ValidatorRegistry_processCoinbaseByAuthByAddress_revertsForWrongShMonad() public {
        // Deploy a Coinbase from this test contract to force SHMONAD != address(shMonad).
        address validatorAuth = makeAddr("processWrongShMonadAuth");
        uint64 valId = staking.registerValidator(validatorAuth);
        Coinbase rogue = new Coinbase(valId);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ShMonadErrors.InvalidValidatorAddress.selector, address(rogue)));
        shMonad.processCoinbaseByAuth(address(rogue));
    }

    function test_ValidatorRegistry_processCoinbaseByAuthByAddress_allowsUnlinkedCoinbase() public {
        address validatorAuth = makeAddr("processUnlinkedAuth");
        address recipient = makeAddr("processUnlinkedRecipient");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        address coinbaseAddr = shMonad.addValidator(valId);
        Coinbase coinbase = Coinbase(payable(coinbaseAddr));

        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(SCALE);
        coinbase.updateCommissionRecipient(recipient);
        vm.stopPrank();

        vm.prank(deployer);
        shMonad.deactivateValidator(valId);

        // Advance epochs to complete deactivation so the registry unlinks the coinbase.
        for (uint256 i = 0; i < 7; ++i) {
            _crankEpochForValidator(valId);
        }

        assertEq(shMonad.getValidatorCoinbase(valId), address(0), "coinbase should be unlinked");

        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        (bool ok,) = coinbaseAddr.call{ value: amount }("");
        assertTrue(ok, "funding coinbase should succeed");

        uint256 recipientBefore = recipient.balance;

        // Owner can still process unlinked coinbases by address
        vm.prank(deployer);
        shMonad.processCoinbaseByAuth(coinbaseAddr);

        assertEq(recipient.balance - recipientBefore, amount, "commission should be paid out");
        assertEq(coinbaseAddr.balance, 0, "coinbase balance should be cleared");
    }

    function test_ValidatorRegistry_processCoinbaseByAuthByAddress_allowsOwner() public {
        address validatorAuth = makeAddr("processOwnerByAddressAuth");
        address recipient = makeAddr("processOwnerByAddressRecipient");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        address coinbaseAddr = shMonad.addValidator(valId);
        Coinbase coinbase = Coinbase(payable(coinbaseAddr));

        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(SCALE);
        coinbase.updateCommissionRecipient(recipient);
        vm.stopPrank();

        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        (bool ok,) = coinbaseAddr.call{ value: amount }("");
        assertTrue(ok, "funding coinbase should succeed");

        uint256 recipientBefore = recipient.balance;

        vm.prank(deployer);
        shMonad.processCoinbaseByAuth(coinbaseAddr);

        assertEq(recipient.balance - recipientBefore, amount, "commission should be paid out by owner");
        assertEq(coinbaseAddr.balance, 0, "coinbase balance should be cleared");
    }

    function test_ValidatorRegistry_processCoinbaseByAuthByAddress_revertsForNonOwner() public {
        address validatorAuth = makeAddr("processNonOwnerByAddressAuth");
        address attacker = makeAddr("processNonOwnerAttacker");
        uint64 valId = staking.registerValidator(validatorAuth);

        vm.prank(deployer);
        address coinbaseAddr = shMonad.addValidator(valId);

        // Non-owner (including the validator's auth address) cannot call this function
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        shMonad.processCoinbaseByAuth(coinbaseAddr);

        // Even the validator's own auth address cannot call this function
        vm.prank(validatorAuth);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", validatorAuth));
        shMonad.processCoinbaseByAuth(coinbaseAddr);
    }

    // --------------------------------------------- //
    //               View Function Tests             //
    // --------------------------------------------- //
    function test_ValidatorRegistry_validatorViews_basic() public {
        address validator = makeAddr("validatorView");
        uint64 valId = staking.registerValidator(validator);

        vm.prank(deployer);
        shMonad.addValidator(valId, validator);

        // getActiveValidatorCount and listActiveValidators
        uint256 count = shMonad.getActiveValidatorCount();
        (uint64[] memory ids, address[] memory coinbases) = shMonad.listActiveValidators();
        assertEq(ids.length, coinbases.length, "ids and coinbases length mismatch");
        assertEq(count, ids.length, "active count should equal list length");

        // getValidatorData
        (
            , uint64 id, bool isPlaceholder, bool isActive, , , address cb
        ) = shMonad.getValidatorData(valId);
        assertEq(id, valId, "id should match");
        assertFalse(isPlaceholder, "real validator should not be placeholder");
        assertTrue(isActive, "validator should be active");
        assertEq(cb, validator, "coinbase should match");

        // Epochs view: last/current should be readable; current >= last
        (uint64 lastEpoch, , uint64 currEpoch, ) = shMonad.getValidatorEpochs(valId);
        assertGe(currEpoch, lastEpoch, "current epoch should be >= last");

        // Pending escrow (likely zero in fresh state)
        (uint120 lastPS, uint120 lastPU, uint120 currPS, uint120 currPU) = shMonad.getValidatorPendingEscrow(valId);
        assertTrue(lastPS >= 0 && lastPU >= 0 && currPS >= 0 && currPU >= 0, "escrow values readable");

        // Rewards (likely zero in fresh state)
        (uint120 lastRP, uint120 lastER, uint120 currRP, uint120 currER) = shMonad.getValidatorRewards(valId);
        assertTrue(lastRP >= 0 && lastER >= 0 && currRP >= 0 && currER >= 0, "reward values readable");

        // Neighbors and next crank cursor are readable
        shMonad.getValidatorNeighbors(valId);
        shMonad.getNextValidatorToCrank();
    }

    // Scenario: On addValidator (not in delay), we seed inActiveSet_Current from consensusStake>0.
    // We pre-delegate to the valId in the precompile so getValidator() reports a positive consensus stake.
    function test_ValidatorRegistry_addValidator_setsActiveFlagFromConsensus() public {
        address validator = makeAddr("activeFlagConsensus");
        uint64 valId = staking.registerValidator(validator);

        // Delegate a small amount so consensusStake > 0 after epoch change
        vm.deal(address(this), 1 ether);
        staking.delegate{ value: 0.5 ether }(valId);
        // Activate scheduled stake; no delay period
        staking.harnessSyscallOnEpochChange(false);

        vm.prank(deployer);
        shMonad.addValidator(valId, validator);

        (, , , , bool inActiveSet_Current, ,) = shMonad.getValidatorData(valId);
        assertTrue(inActiveSet_Current, "consensus>0 -> inActiveSet_Current = true");
    }

    // Scenario: During the delay window, addValidator seeds `inActiveSet_Current` from snapshot stake.
    // We fund and delegate enough to cross the mock's ACTIVE_VALIDATOR_STAKE threshold (50,000,000 ether),
    // activate the stake, take a snapshot, and then enter delay. The seeded flag should be true.
    function test_ValidatorRegistry_addValidator_setsActiveFlagFromSnapshotDuringDelay() public {
        address validator = makeAddr("activeFlagSnapshot");
        uint64 valId = staking.registerValidator(validator);

        // Ensure delegation exceeds consensus activation threshold in the mock (50,000,000 ether)
        vm.deal(address(this), 100_000_000 ether);
        staking.delegate{ value: 51_000_000 ether }(valId);

        // Activate scheduled stake and snapshot the validator set
        staking.harnessSyscallOnEpochChange(false); // not in delay; promotes scheduled stake to active
        staking.harnessSyscallSnapshot(); // sets snapshotStake = consensusStake for current set

        // Enter the delay window to force the helper to read snapshotStake
        staking.harnessSyscallOnEpochChange(true);

        vm.prank(deployer);
        shMonad.addValidator(valId, validator);

        (, , , , bool inActiveSet_Current, ,) = shMonad.getValidatorData(valId);
        assertTrue(inActiveSet_Current, "snapshot>0 during delay -> inActiveSet_Current = true");
    }

    function test_ValidatorRegistry_markValidatorNotInActiveSet_skipsWhenValidatorStillActive() public {
        (, uint64 valId) = _addActiveValidator("hotPathSkip");

        (, , , , bool inActiveSet_Current,,) = shMonad.getValidatorData(valId);
        assertTrue(inActiveSet_Current, "validator should start marked active");

        vm.prank(deployer);
        testShMonad.harnessMarkValidatorNotInActiveSet(valId, 1);

        (, , , , bool inActiveSetAfter,,) = shMonad.getValidatorData(valId);
        assertTrue(inActiveSetAfter, "active validator must remain active after false positive detection");
    }

    function _addActiveValidator(
        string memory label
    )
        internal
        returns (address validator, uint64 valId)
    {
        validator = makeAddr(label);
        valId = staking.registerValidator(validator);

        uint256 stakeAmount = staking.ACTIVE_VALIDATOR_STAKE() + 1 ether;
        vm.deal(validator, stakeAmount);
        vm.prank(validator);
        staking.delegate{ value: stakeAmount }(valId);

        staking.harnessSyscallOnEpochChange(false);
        staking.harnessSyscallSnapshot();
        staking.harnessSyscallOnEpochChange(false);

        vm.startPrank(deployer);
        shMonad.addValidator(valId, validator);
        vm.stopPrank();
    }

    // -------------------------------------------------- //
    //           Linked List (ID-based) Semantics         //
    // -------------------------------------------------- //

    function test_ValidatorRegistry_linkedListById_neighborsAndListing() public {
        // Goal: After adding validators, the ID-based crank list preserves insertion order
        // and getValidatorNeighbors returns coinbase addresses for real neighbors, and
        // address(0) when the neighbor is a sentinel (FIRST/LAST).

        (address coinbaseA, uint64 idA) = _addActiveValidator("valA");
        (address coinbaseB, uint64 idB) = _addActiveValidator("valB");
        (address coinbaseC, uint64 idC) = _addActiveValidator("valC");

        // listActiveValidators returns ids and coinbases in crank order (FIRST -> A -> B -> C -> LAST)
        (uint64[] memory ids, address[] memory coinbases) = shMonad.listActiveValidators();
        // Do not assume a clean slate; Setup may have pre-added validators.
        // Instead, assert that the tail of the list contains our 3 new validators in order.
        require(ids.length >= 3, "insufficient active validators for test");
        uint256 n = ids.length;
        assertEq(ids[n - 3], idA, "tail[0] should be A");
        assertEq(ids[n - 2], idB, "tail[1] should be B");
        assertEq(ids[n - 1], idC, "tail[2] should be C");
        assertEq(coinbases[n - 3], coinbaseA, "tail[0] coinbase should be A");
        assertEq(coinbases[n - 2], coinbaseB, "tail[1] coinbase should be B");
        assertEq(coinbases[n - 1], coinbaseC, "tail[2] coinbase should be C");

        // A is at the head (previous sentinel), C is at the tail (next sentinel)
        (, address nextA) = shMonad.getValidatorNeighbors(idA);
        // Do not assert on prevA (there may be pre-existing validators).
        assertEq(nextA, coinbaseB, "A.next should be B");

        (address prevB, address nextB) = shMonad.getValidatorNeighbors(idB);
        assertEq(prevB, coinbaseA, "B.prev should be A");
        assertEq(nextB, coinbaseC, "B.next should be C");

        (address prevC, ) = shMonad.getValidatorNeighbors(idC);
        assertEq(prevC, coinbaseB, "C.prev should be B");
        // Do not assert on nextC (tail may not be sentinel if other tests append later).
    }

    function test_ValidatorRegistry_getNextValidatorToCrank_peeksFirstRealCoinbase() public {
        // Goal: When the internal cursor is set to the FIRST_VAL_ID sentinel, the view should
        // return the first real validator's coinbase instead of a sentinel placeholder.
        _addActiveValidator("firstVal");
        _addActiveValidator("secondVal");

        // Put the cursor at the FIRST_VAL_ID sentinel; view should return A's coinbase
        vm.prank(deployer);
        TestShMonad(payable(address(shMonad))).harnessSetNextValidatorCursorToFirst();

        (, address[] memory coinbases) = shMonad.listActiveValidators();
        address expectedFirst = coinbases[0];
        address nextCoinbase = shMonad.getNextValidatorToCrank();
        assertEq(nextCoinbase, expectedFirst, "next to crank should be first active validator's coinbase");
    }

    function test_ValidatorRegistry_unknownIsFirstAfterSentinel_andSkippedInViews() public {
        // UNKNOWN placeholder must always be immediately after FIRST_VAL_ID and should
        // not appear in the active validators list or as next-to-crank.
        TestShMonad viewC = TestShMonad(payable(address(shMonad)));

        // Verify UNKNOWN sits immediately after FIRST_VAL_ID
        uint64 firstAfterSentinel = viewC.exposeFirstAfterSentinel();
        assertEq(firstAfterSentinel, UNKNOWN_VAL_ID, "UNKNOWN should be first after FIRST_VAL_ID");
        assertEq(viewC.exposePrevId(UNKNOWN_VAL_ID), FIRST_VAL_ID, "prev(UNKNOWN) must be FIRST_VAL_ID");

        // UNKNOWN must not appear in listActiveValidators results
        (uint64[] memory ids, ) = shMonad.listActiveValidators();
        for (uint256 i = 0; i < ids.length; ++i) {
            assertTrue(ids[i] != UNKNOWN_VAL_ID, "UNKNOWN must be excluded from active validators list");
        }

        // getValidatorCoinbase(UNKNOWN_VAL_ID) should equal the reserved UNKNOWN address
        assertEq(shMonad.getValidatorCoinbase(UNKNOWN_VAL_ID), UNKNOWN_VAL_ADDRESS, "coinbase(UNKNOWN) mismatch");

        // When the internal cursor is explicitly set to UNKNOWN, next-to-crank must skip it
        vm.prank(deployer);
        viewC.harnessSetNextValidatorCursorToUnknown();

        address nextCoinbase = shMonad.getNextValidatorToCrank();
        // If there are no active validators, address(0) is expected; otherwise some real coinbase
        // should be returned (non-zero).
        if (ids.length > 0) {
            assertTrue(nextCoinbase != address(0), "should return a real validator coinbase when available");
        }
    }
}
