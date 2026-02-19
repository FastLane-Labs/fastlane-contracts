// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { BaseTest } from "../base/BaseTest.t.sol";
import { Coinbase } from "../../src/shmonad/Coinbase.sol";
import { IMonadStaking } from "../../src/shmonad/interfaces/IMonadStaking.sol";
import { SCALE, MIN_VALIDATOR_DEPOSIT, MAX_EXTERNAL_REWARD } from "../../src/shmonad/Constants.sol";
import { MockMonadStakingPrecompile } from "../../src/shmonad/mocks/MockMonadStakingPrecompile.sol";

/// @notice Helper recipient that always reverts on receiving ETH to simulate transfer failure
contract RevertingRecipient {
    receive() external payable {
        revert("nope");
    }
}

contract CoinbaseTest is BaseTest {
    // Primary validator/auth for the default deployed Coinbase in setUp
    address internal validatorAuth;
    uint64 internal valId;
    Coinbase internal coinbase;

    function setUp() public override {
        super.setUp();

        // Mirror ValidatorRegistry.addValidator() flow to deploy a Coinbase via CREATE2
        // 1) Register a validator in the staking precompile mock
        validatorAuth = makeAddr("validatorAuth_Main");
        valId = staking.registerValidator(validatorAuth);

        // 2) Deploy the Coinbase contract using ShMonad's addValidator(validatorId) entrypoint
        address predicted = shMonad.previewCoinbaseAddress(valId);
        vm.startPrank(deployer);
        address deployed = shMonad.addValidator(valId);
        vm.stopPrank();

        // 3) Sanity: deterministic address matches prediction and cast for tests
        assertEq(deployed, predicted, "CREATE2 address should match preview");
        coinbase = Coinbase(payable(deployed));

        // 4) Minimal stake so the validator has non-zero epoch stake after one epoch change
        vm.deal(validatorAuth, 2 ether);
        vm.prank(validatorAuth);
        staking.delegate{ value: 2 ether }(valId);
        staking.harnessSyscallOnEpochChange(false);
    }

    // -------------------------------------------------- //
    //                    Constructor                      
    // -------------------------------------------------- //

    function test_Coinbase_constructor_emitsInitialEventsAndSetsState() public {
        // Goal: Deploy a fresh Coinbase via addValidator and validate constructor behavior:
        // - Emits PriorityCommissionRateUpdated(0, initial)
        // - Emits MEVCommissionRateUpdated(0, initial)
        // - Emits CommissionRecipientUpdated(0, authAddress)
        // - Sets SHMONAD, VAL_ID, AUTH_ADDRESS, and initial config correctly

        address newAuth = makeAddr("validatorAuth_New");
        uint64 newValId = staking.registerValidator(newAuth);

        // Set a non-zero commission in the precompile so constructor picks it up
        vm.prank(newAuth);
        staking.changeCommission(newValId, 20e16); // 20%

        address predicted = shMonad.previewCoinbaseAddress(newValId);

        // Expect the two constructor events from the soon-to-be-deployed coinbase
        vm.expectEmit(true, true, false, true, predicted);
        emit Coinbase.PriorityCommissionRateUpdated(0, 20e16);

        vm.expectEmit(true, true, false, true, predicted);
        emit Coinbase.MEVCommissionRateUpdated(0, 20e16);

        vm.expectEmit(true, true, false, true, predicted);
        emit Coinbase.CommissionRecipientUpdated(address(0), newAuth);

        vm.startPrank(deployer);
        address deployed = shMonad.addValidator(newValId);
        vm.stopPrank();

        Coinbase c = Coinbase(payable(deployed));

        // State checks
        assertEq(address(c.SHMONAD()), address(shMonad), "SHMONAD should be ShMonad");
        assertEq(c.VAL_ID(), newValId, "VAL_ID should match");
        assertEq(c.AUTH_ADDRESS(), newAuth, "AUTH_ADDRESS should match precompile auth");
        assertEq(c.getPriorityCommissionRate(), 20e16, "initial commission should come from precompile");
        assertEq(c.getMEVCommissionRate(), 20e16, "initial MEV commission should come from precompile");
        assertEq(c.getCommissionRecipient(), newAuth, "initial recipient should be validator auth");
    }

    function test_Coinbase_constructor_revertsForUnknownValidator() public {
        // Goal: Constructor should revert if validatorId is not found in precompile
        uint64 unknownValId = 999_999;
        vm.expectRevert(abi.encodeWithSelector(Coinbase.ValidatorNotFoundInPrecompile.selector, unknownValId));
        new Coinbase(unknownValId);
    }

    // -------------------------------------------------- //
    //                      Process()                     
    // -------------------------------------------------- //

    function test_Coinbase_process_success_DistributesRewardsAndPaysCommission() public {
        // Goal: process() should pay commission, then forward the remainder via externalReward
        // Steps:
        // 1) Set commission rate and recipient by AUTH_ADDRESS
        // 2) Fund coinbase > 1 MON to satisfy precompile minimum
        // 3) Call process() as ShMonad and validate balances + unclaimedRewards

        address recipient = makeAddr("commissionRecipient");

        uint256 commissionRate = 10e16; // 10%
        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(commissionRate);
        coinbase.updateCommissionRecipient(recipient);
        vm.stopPrank();

        // Fund the coinbase contract with 11 ETH
        vm.deal(address(this), 11 ether);
        (bool ok,) = address(coinbase).call{ value: 11 ether }("");
        assertTrue(ok, "funding coinbase should succeed");

        // Process as ShMonad (onlyShMonad)
        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertTrue(success, "process should succeed");

        // Commission = 10% of 11 ETH = 1.1 ETH
        assertEq(recipient.balance, 1.1 ether, "commission recipient should receive 10%");

        // Remainder (9.9 ETH) is sent to precompile and tracked as unclaimed rewards
        (
            ,
            ,
            ,
            ,
            ,
            uint256 unclaimedRewards,
            ,
            ,
            ,
            ,
            ,
            
        ) = staking.getValidator(valId);
        assertEq(unclaimedRewards, 9.9 ether, "unclaimed rewards should equal the remainder");

        // Coinbase should be emptied
        assertEq(address(coinbase).balance, 0, "coinbase should forward all funds");
    }

    function test_Coinbase_handleMEVPayable_revertsWhenZero() public {
        // Goal: handleMEVPayable should reject zero-value MEV transfers
        vm.prank(address(shMonad));
        vm.expectRevert(Coinbase.MEVMustExceedZero.selector);
        coinbase.handleMEVPayable();
    }

    function test_Coinbase_handleMEVPayable_splitsCommissionAndRewards() public {
        // Goal: MEV payables should be split by mevCommissionRate and paid out on process()
        address recipient = makeAddr("mevRecipient");
        uint256 mevCommissionRate = 25e16; // 25%
        uint256 mevAmount = 4 ether;

        vm.startPrank(validatorAuth);
        coinbase.updateMEVCommissionRate(mevCommissionRate);
        coinbase.updateCommissionRecipient(recipient);
        vm.stopPrank();

        // Fund ShMonad so it can forward MEV to the coinbase contract.
        vm.deal(address(shMonad), mevAmount);
        vm.prank(address(shMonad));
        coinbase.handleMEVPayable{ value: mevAmount }();

        uint256 recipientBefore = recipient.balance;
        (, , , , , uint256 beforeUnclaimed, , , , , , ) = staking.getValidator(valId);

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertTrue(success, "process should succeed");

        uint256 expectedCommission = mevAmount * mevCommissionRate / SCALE;
        uint256 expectedRewards = mevAmount - expectedCommission;

        assertEq(recipient.balance - recipientBefore, expectedCommission, "MEV commission should be paid");
        (, , , , , uint256 afterUnclaimed, , , , , , ) = staking.getValidator(valId);
        assertEq(afterUnclaimed - beforeUnclaimed, expectedRewards, "MEV rewards should be applied");
        assertEq(address(coinbase).balance, 0, "coinbase should be emptied after process");
    }

    function test_Coinbase_process_returnsFalseWhenRewardBelowMinPayout() public {
        // Goal: If rewardPortion < MIN_VALIDATOR_DEPOSIT, process returns false and pays no commission
        // Steps:
        // 1) Set commission to zero so rewardPortion == balance
        // 2) Fund just below MIN_VALIDATOR_DEPOSIT and call process()

        // Ensure recipient unchanged
        address beforeRecipient = coinbase.getCommissionRecipient();

        vm.prank(validatorAuth);
        coinbase.updatePriorityCommissionRate(0);

        // Fund with just below the payout floor
        uint256 tiny = MIN_VALIDATOR_DEPOSIT - 1;
        vm.deal(address(this), tiny);
        (bool ok,) = address(coinbase).call{ value: tiny }("");
        assertTrue(ok, "funding coinbase with tiny amount should succeed");

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertFalse(success, "process should return false for dust");

        // No commission should be paid
        assertEq(coinbase.getCommissionRecipient(), beforeRecipient, "recipient unchanged");
        assertEq(beforeRecipient.balance, 0, "no commission should be paid for dust");
        // Funds remain in coinbase (no transfers)
        assertEq(address(coinbase).balance, tiny, "coinbase keeps dust on failed process");
    }

    function test_Coinbase_process_capsRewardBelowExternalLimitAndSucceeds() public {
        // Goal: If available rewards exceed MAX_EXTERNAL_REWARD, process caps the payout to limit-1 MON,
        // sends exactly one externalReward call, and leaves the remainder unpaid for next process.

        vm.prank(validatorAuth);
        coinbase.updatePriorityCommissionRate(0);

        // Snapshot unclaimed rewards before
        (, , , , , uint256 beforeUnclaimed, , , , , , ) = staking.getValidator(valId);

        // Fund above the precompile limit
        uint256 funded = MAX_EXTERNAL_REWARD + 5 * MIN_VALIDATOR_DEPOSIT;
        vm.deal(address(this), funded);
        (bool ok,) = address(coinbase).call{ value: funded }("");
        assertTrue(ok, "funding coinbase should succeed");

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertTrue(success, "process should succeed when capping reward");

        uint256 expectedPayout = MAX_EXTERNAL_REWARD - MIN_VALIDATOR_DEPOSIT;
        uint256 expectedRemainder = funded - expectedPayout;

        // Unclaimed rewards should increase by the capped payout
        (, , , , , uint256 afterUnclaimed, , , , , , ) = staking.getValidator(valId);
        assertEq(afterUnclaimed - beforeUnclaimed, expectedPayout, "applied rewards should match capped payout");

        // Remainder stays on coinbase for next cycle
        assertEq(address(coinbase).balance, expectedRemainder, "remainder should stay in coinbase");
    }

    function test_Coinbase_process_returnsFalseWhenCommissionTransferFails() public {
        // Goal: If commission recipient cannot receive ETH, process returns false and keeps funds
        // Steps:
        // 1) Set commission rate and recipient to a reverting contract
        // 2) Fund coinbase sufficiently large
        // 3) Call process() as ShMonad and expect partial success: rewards paid, commission withheld/unpaid

        RevertingRecipient badRecipient = new RevertingRecipient();

        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(50e16); // 50%
        coinbase.updateCommissionRecipient(address(badRecipient));
        vm.stopPrank();

        // Snapshot unclaimed rewards before
        (
            ,
            ,
            ,
            ,
            ,
            uint256 beforeUnclaimed,
            ,
            ,
            ,
            ,
            ,
            
        ) = staking.getValidator(valId);

        vm.deal(address(this), 2 ether);
        (bool ok,) = address(coinbase).call{ value: 2 ether }("");
        assertTrue(ok, "funding coinbase should succeed");

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertFalse(success, "commission transfer failure should return false");

        // Rewards applied, commission kept as unpaid (1 ether each)
        assertEq(address(coinbase).balance, 1 ether, "commission retained on failure");
        assertEq(address(badRecipient).balance, 0, "recipient should not receive funds");

        // Rewards should still be applied even when commission fails
        (
            ,
            ,
            ,
            ,
            ,
            uint256 afterUnclaimed,
            ,
            ,
            ,
            ,
            ,
            
        ) = staking.getValidator(valId);
        assertEq(afterUnclaimed - beforeUnclaimed, 1 ether, "rewards should still be applied");
    }

    function test_Coinbase_process_capsRewardAndStillPaysCommission() public {
        // Goal: When rewards exceed the precompile limit, we cap the payout but still pay commission once.
        address recipient = makeAddr("commissionRecipient2");

        uint256 commissionRate = 10e16; // 10%
        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(commissionRate);
        coinbase.updateCommissionRecipient(recipient);
        vm.stopPrank();

        // Balance large enough to exceed MAX_EXTERNAL_REWARD once commission is applied
        uint256 targetReward = MAX_EXTERNAL_REWARD + 1;
        uint256 funded = (targetReward * SCALE) / (SCALE - commissionRate) + 1;
        vm.deal(address(this), funded);
        (bool ok,) = address(coinbase).call{ value: funded }("");
        assertTrue(ok, "funding coinbase should succeed");

        // Snapshot before
        (, , , , , uint256 beforeUnclaimed, , , , , , ) = staking.getValidator(valId);
        uint256 recipientBefore = recipient.balance;

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertTrue(success, "process should succeed when capping reward");

        // Commission paid once
        uint256 expectedCommission = funded * commissionRate / SCALE;
        assertEq(recipient.balance - recipientBefore, expectedCommission, "commission should be paid");

        // Rewards applied only up to capped amount
        (, , , , , uint256 afterUnclaimed, , , , , , ) = staking.getValidator(valId);
        uint256 expectedPayout = MAX_EXTERNAL_REWARD - MIN_VALIDATOR_DEPOSIT;
        assertEq(afterUnclaimed - beforeUnclaimed, expectedPayout, "rewards should be capped payout");
    }

    function test_Coinbase_process_paysAccumulatedRewardsWithoutDoubleCounting() public {
        // Goal: unpaid rewards from prior shortfall are added once and not double-counted in payout math
        vm.prank(validatorAuth);
        coinbase.updatePriorityCommissionRate(0);

        // Step 1: fund below MIN_VALIDATOR_DEPOSIT; process should fail and keep funds as unpaid
        uint256 first = MIN_VALIDATOR_DEPOSIT / 2;
        vm.deal(address(this), first);
        (bool ok1,) = address(coinbase).call{ value: first }("");
        assertTrue(ok1, "funding coinbase should succeed");

        vm.prank(address(shMonad));
        bool success1 = coinbase.process();
        assertFalse(success1, "process should return false for dust");
        assertEq(address(coinbase).balance, first, "dust retained as unpaid");

        // Step 2: add more to cross the threshold; expect single payout of total first+second
        uint256 second = MIN_VALIDATOR_DEPOSIT - first + 0.1 ether; // small extra over the minimum
        vm.deal(address(this), second);
        (bool ok2,) = address(coinbase).call{ value: second }("");
        assertTrue(ok2, "second funding should succeed");

        (, , , , , uint256 beforeUnclaimed, , , , , , ) = staking.getValidator(valId);

        vm.prank(address(shMonad));
        bool success2 = coinbase.process();
        assertTrue(success2, "process should succeed when total exceeds minimum");

        uint256 totalFunded = first + second;
        (, , , , , uint256 afterUnclaimed, , , , , , ) = staking.getValidator(valId);
        assertEq(afterUnclaimed - beforeUnclaimed, totalFunded, "all funds applied once");
        assertEq(address(coinbase).balance, 0, "coinbase emptied after payout");
    }

    function test_Coinbase_process_paysUnpaidCommissionOnNextRun() public {
        // Goal: commission that failed previously is tracked as unpaid and paid out on the next process()
        RevertingRecipient badRecipient = new RevertingRecipient();
        address goodRecipient = makeAddr("goodRecipient");
        uint256 commissionRate = 50e16; // 50%

        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(commissionRate);
        coinbase.updateCommissionRecipient(address(badRecipient));
        vm.stopPrank();

        vm.deal(address(this), 2 ether);
        (bool ok1,) = address(coinbase).call{ value: 2 ether }("");
        assertTrue(ok1, "funding coinbase should succeed");

        vm.prank(address(shMonad));
        bool success1 = coinbase.process();
        assertFalse(success1, "commission failure should make process return false");
        // Rewards paid (1 ether) but commission kept unpaid (1 ether)
        assertEq(address(coinbase).balance, 1 ether, "commission retained for retry");

        // Switch to good recipient and add new revenue so rewards path also succeeds
        vm.prank(validatorAuth);
        coinbase.updateCommissionRecipient(goodRecipient);

        uint256 before = goodRecipient.balance;
        uint256 rewardsBefore;
        uint256 rewardsAfter;
        (, , , , , rewardsBefore, , , , , , ) = staking.getValidator(valId);

        // Add fresh revenue to trigger rewards success on next process
        // Need enough new revenue so rewards after commission exceed MIN_VALIDATOR_DEPOSIT
        uint256 topUp = 2 ether;
        vm.deal(address(this), topUp);
        (bool ok2,) = address(coinbase).call{ value: topUp }("");
        assertTrue(ok2, "topping up coinbase should succeed");

        vm.prank(address(shMonad));
        bool success2 = coinbase.process();
        assertTrue(success2, "process should succeed after commission recipient fixed");

        // Commission includes unpaid (1 ether) + new commission (1 ether on 2 ether top-up)
        assertEq(goodRecipient.balance - before, 2 ether, "unpaid + new commission should be paid");

        (, , , , , rewardsAfter, , , , , , ) = staking.getValidator(valId);
        assertEq(rewardsAfter - rewardsBefore, 1 ether, "rewards from top-up should be applied");

        assertEq(address(coinbase).balance, 0, "coinbase cleared after payout");
    }

    function test_Coinbase_process_donationFailureDoesNotDoublePayCommission() public {
        // Goal: If donation transfer to ShMonad fails after commission succeeds, we must not re-pay commission on retry.
        address recipient = makeAddr("donationTestRecipient");
        uint256 commissionRate = 20e16; // 20%
        uint256 donationRate = 10e16; // 10%

        vm.startPrank(validatorAuth);
        coinbase.updatePriorityCommissionRate(commissionRate);
        coinbase.updateCommissionRecipient(recipient);
        coinbase.updateShMonadDonationRate(donationRate);
        vm.stopPrank();

        // Snapshot original ShMonad runtime code and replace with a reverting receiver to force donation failure.
        bytes memory originalCode = address(shMonad).code;
        RevertingRecipient badDonationReceiver = new RevertingRecipient();
        vm.etch(address(shMonad), address(badDonationReceiver).code);

        uint256 funded = 10 ether;
        vm.deal(address(this), funded);
        (bool ok,) = address(coinbase).call{ value: funded }("");
        assertTrue(ok, "funding coinbase should succeed");

        uint256 recipientBefore = recipient.balance;
        (, , , , , uint256 beforeUnclaimed, , , , , , ) = staking.getValidator(valId);

        vm.prank(address(shMonad));
        bool success1 = coinbase.process();
        assertFalse(success1, "donation failure should return false");

        uint256 expectedCommission = funded * commissionRate / SCALE;
        uint256 expectedDonation = funded * donationRate / SCALE;
        uint256 expectedRewards = funded - expectedCommission - expectedDonation;

        // Commission paid once, rewards applied, donation retained as unpaid.
        assertEq(recipient.balance - recipientBefore, expectedCommission, "commission should be paid once");
        (, , , , , uint256 afterUnclaimed, , , , , , ) = staking.getValidator(valId);
        assertEq(afterUnclaimed - beforeUnclaimed, expectedRewards, "rewards should be applied");
        assertEq(address(coinbase).balance, expectedDonation, "donation retained for retry");

        // Restore ShMonad code.
        vm.etch(address(shMonad), originalCode);

        // Disable donation so the leftover amount is treated as normal accrual on retry.
        vm.prank(validatorAuth);
        coinbase.updateShMonadDonationRate(0);

        uint256 recipientMid = recipient.balance;

        vm.prank(address(shMonad));
        bool success2 = coinbase.process();
        assertFalse(success2, "retry on leftover donation alone should return false");

        // Commission is only charged on the leftover amount, not re-paid on the original accrual.
        uint256 expectedCommission2 = expectedDonation * commissionRate / SCALE;
        assertEq(recipient.balance - recipientMid, expectedCommission2, "commission on leftover only");

        // Leftover after commission is below MIN_VALIDATOR_DEPOSIT, so it remains as unpaid rewards.
        assertEq(
            address(coinbase).balance,
            expectedDonation - expectedCommission2,
            "leftover treated as unpaid rewards"
        );
    }

    function test_Coinbase_process_success_WithZeroCommission() public {
        // Goal: With 0% commission, rewards should still be applied and process returns true
        vm.prank(validatorAuth);
        coinbase.updatePriorityCommissionRate(0);

        vm.deal(address(this), 2 ether);
        (bool ok,) = address(coinbase).call{ value: 2 ether }("");
        assertTrue(ok, "funding coinbase should succeed");

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertTrue(success, "process should succeed with zero commission");

        // Unclaimed rewards should increase by full amount
        (
            ,
            ,
            ,
            ,
            ,
            uint256 unclaimedRewards,
            ,
            ,
            ,
            ,
            ,
            
        ) = staking.getValidator(valId);
        assertEq(unclaimedRewards, 2 ether, "all funds should be applied as rewards");
        assertEq(address(coinbase).balance, 0, "coinbase should be emptied");
    }

    function test_Coinbase_sendCommissionAndDonation_revertsForExternalCaller() public {
        // Goal: sendCommissionAndRewards is internal-only via onlySelf and must revert for external calls
        vm.expectRevert(Coinbase.OnlySelfCaller.selector);
        coinbase.sendCommissionAndDonation(address(0xBEEF), 1, 1);
    }

    function test_Coinbase_sendRewardsToDelegates_revertsForExternalCaller() public {
        // Goal: sendCommissionAndRewards is internal-only via onlySelf and must revert for external calls
        vm.expectRevert(Coinbase.OnlySelfCaller.selector);
        coinbase.sendRewardsToDelegates(1);
    }

    function test_Coinbase_process_revertsForNonShMonadCaller() public {
        // Goal: onlyShMonad modifier should block external callers
        vm.expectRevert(Coinbase.OnlyShMonadCaller.selector);
        coinbase.process();
    }

    // -------------------------------------------------- //
    //               Commission Configuration             
    // -------------------------------------------------- //

    function test_Coinbase_updateCommissionRate_succeedsAndEmits() public {
        // Goal: AUTH_ADDRESS can update commission rate within [0, SCALE]
        vm.expectEmit(true, true, false, true, address(coinbase));
        emit Coinbase.PriorityCommissionRateUpdated(0, 15e16);

        vm.prank(validatorAuth);
        coinbase.updatePriorityCommissionRate(15e16); // 15%

        assertEq(coinbase.getPriorityCommissionRate(), 15e16, "commission rate should be updated");
    }

    function test_Coinbase_updateMEVCommissionRate_succeedsAndEmits() public {
        // Goal: AUTH_ADDRESS can update MEV commission rate within [0, SCALE]
        vm.expectEmit(true, true, false, true, address(coinbase));
        emit Coinbase.MEVCommissionRateUpdated(0, 12e16);

        vm.prank(validatorAuth);
        coinbase.updateMEVCommissionRate(12e16); // 12%

        assertEq(coinbase.getMEVCommissionRate(), 12e16, "MEV commission rate should be updated");
    }

    function test_Coinbase_updateCommissionRate_revertsWhenOverScale() public {
        // Goal: New commission must be <= SCALE
        vm.prank(validatorAuth);
        vm.expectRevert(Coinbase.InvalidCommissionRate.selector);
        coinbase.updatePriorityCommissionRate(SCALE + 1);
    }

    function test_Coinbase_updateMEVCommissionRate_revertsWhenOverScale() public {
        // Goal: New MEV commission must be <= SCALE
        vm.prank(validatorAuth);
        vm.expectRevert(Coinbase.InvalidCommissionRate.selector);
        coinbase.updateMEVCommissionRate(SCALE + 1);
    }

    function test_Coinbase_updateCommissionRate_revertsWhenUnauthorized() public {
        // Goal: Only AUTH_ADDRESS may change the commission rate
        address notAuth = makeAddr("notAuth");
        vm.prank(notAuth);
        vm.expectRevert(Coinbase.OnlyAuthAddress.selector);
        coinbase.updatePriorityCommissionRate(5e16);
    }

    function test_Coinbase_updateMEVCommissionRate_revertsWhenUnauthorized() public {
        // Goal: Only AUTH_ADDRESS may change the MEV commission rate
        address notAuth = makeAddr("notAuthMEV");
        vm.prank(notAuth);
        vm.expectRevert(Coinbase.OnlyAuthAddress.selector);
        coinbase.updateMEVCommissionRate(5e16);
    }

    function test_Coinbase_updateShMonadDonationRate_succeedsAndEmits() public {
        // Goal: AUTH_ADDRESS can update donation rate within [0, SCALE - commission]
        vm.expectEmit(true, true, false, true, address(coinbase));
        emit Coinbase.DonationRateUpdated(0, 5e16);

        vm.prank(validatorAuth);
        coinbase.updateShMonadDonationRate(5e16); // 5%

        assertEq(_getDonationRate(), 5e16, "donation rate should be updated");
    }

    function test_Coinbase_updateCommissionRecipient_succeedsAndEmits() public {
        // Goal: AUTH_ADDRESS can update commission recipient
        address newRecipient = makeAddr("newRecipient");
        address oldRecipient = coinbase.getCommissionRecipient();

        vm.expectEmit(true, true, false, true, address(coinbase));
        emit Coinbase.CommissionRecipientUpdated(oldRecipient, newRecipient);

        vm.prank(validatorAuth);
        coinbase.updateCommissionRecipient(newRecipient);

        assertEq(coinbase.getCommissionRecipient(), newRecipient, "recipient should be updated");
    }

    function test_Coinbase_updateCommissionRecipient_revertsWhenUnauthorized() public {
        // Goal: Only AUTH_ADDRESS may change the commission recipient
        address newRecipient = makeAddr("unauthRecipient");
        address notAuth = makeAddr("notAuth2");

        vm.prank(notAuth);
        vm.expectRevert(Coinbase.OnlyAuthAddress.selector);
        coinbase.updateCommissionRecipient(newRecipient);
    }

    function test_Coinbase_updateCommissionRecipient_revertsForZeroAddress() public {
        // Goal: Reject setting commission recipient to address(0)
        vm.prank(validatorAuth);
        vm.expectRevert(Coinbase.RecipientCannotBeZeroAddress.selector);
        coinbase.updateCommissionRecipient(address(0));
    }

    function test_Coinbase_updateCommissionRateFromStakingConfig_succeeds() public {
        // Goal: AUTH_ADDRESS can sync commission rate from precompile
        // Note: Mock sets snapshot/consensus equal, so boundary window has no effect here.

        // Set a distinct commission in precompile first
        vm.prank(validatorAuth);
        staking.changeCommission(valId, 7e16); // 7%

        vm.prank(validatorAuth);
        vm.expectEmit(true, true, false, true, address(coinbase));
        emit Coinbase.PriorityCommissionRateUpdated(0, 7e16);
        coinbase.updateCommissionRateFromStakingConfig();

        assertEq(coinbase.getPriorityCommissionRate(), 7e16, "commission rate should match precompile");
        assertEq(coinbase.getMEVCommissionRate(), 7e16, "MEV commission rate should match precompile");
    }

    function test_Coinbase_updateCommissionRateFromStakingConfig_capsDonationWhenOverScale() public {
        // Goal: Syncing commission from precompile should trim donation so sum <= SCALE
        vm.prank(validatorAuth);
        coinbase.updateShMonadDonationRate(30e16); // 30%

        vm.prank(validatorAuth);
        staking.changeCommission(valId, 80e16); // 80% -> would make total 110%

        vm.expectEmit(true, true, false, true, address(coinbase));
        emit Coinbase.DonationRateUpdated(30e16, 20e16);
        vm.expectEmit(true, true, false, true, address(coinbase));
        emit Coinbase.PriorityCommissionRateUpdated(0, 80e16);

        vm.prank(validatorAuth);
        coinbase.updateCommissionRateFromStakingConfig();

        assertEq(coinbase.getPriorityCommissionRate(), 80e16, "commission rate should match precompile");
        assertEq(coinbase.getMEVCommissionRate(), 80e16, "MEV commission rate should match precompile");
        assertEq(_getDonationRate(), 20e16, "donation rate should be capped to keep total at SCALE");
    }

    // -------------------------------------------------- //
    //                        Misc                        
    // -------------------------------------------------- //

    function test_Coinbase_receive_acceptsEth() public {
        // Goal: Contract should accept plain ETH transfers via receive()
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(coinbase).call{ value: 1 ether }("");
        assertTrue(ok, "ETH transfer to coinbase should succeed");
        assertEq(address(coinbase).balance, 1 ether, "balance should increase by 1 ETH");
    }

    function test_Coinbase_getShMonadDonationRate_returnsCurrentRate() public {
        // Goal: donation rate getter reflects the latest configured value
        assertEq(coinbase.getShMonadDonationRate(), 0, "initial donation rate should be 0");

        vm.prank(validatorAuth);
        coinbase.updateShMonadDonationRate(5e16); // 5%

        assertEq(coinbase.getShMonadDonationRate(), 5e16, "donation rate getter should update");
    }

    function test_Coinbase_getUnpaidBalances_tracksMEVAccrualAndSettlement() public {
        // Goal: unpaid balances getter reflects MEV accrual and clears after successful process
        (uint256 commission, uint256 rewards) = coinbase.getUnpaidBalances();
        assertEq(commission, 0, "initial unpaid commission should be 0");
        assertEq(rewards, 0, "initial unpaid rewards should be 0");

        uint256 mevCommissionRate = 25e16; // 25%
        vm.prank(validatorAuth);
        coinbase.updateMEVCommissionRate(mevCommissionRate);

        uint256 mevAmount = MIN_VALIDATOR_DEPOSIT * 4;
        vm.deal(address(shMonad), mevAmount);
        vm.prank(address(shMonad));
        coinbase.handleMEVPayable{ value: mevAmount }();

        uint256 expectedCommission = mevAmount * mevCommissionRate / SCALE;
        uint256 expectedRewards = mevAmount - expectedCommission;

        (commission, rewards) = coinbase.getUnpaidBalances();
        assertEq(commission, expectedCommission, "unpaid commission should track MEV split");
        assertEq(rewards, expectedRewards, "unpaid rewards should track MEV split");

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertTrue(success, "process should succeed");

        (commission, rewards) = coinbase.getUnpaidBalances();
        assertEq(commission, 0, "unpaid commission should clear after process");
        assertEq(rewards, 0, "unpaid rewards should clear after process");
    }

    function _getDonationRate() internal view returns (uint256 donationRate) {
        // s_config is slot 0/1; donationRate sits in the first 96 bits of slot 1
        bytes32 slot1 = vm.load(address(coinbase), bytes32(uint256(1)));
        donationRate = uint256(uint96(uint256(slot1)));
    }
}
