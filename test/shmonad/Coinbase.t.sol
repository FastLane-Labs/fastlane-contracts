// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { BaseTest } from "../base/BaseTest.t.sol";
import { Coinbase } from "../../src/shmonad/Coinbase.sol";
import { IMonadStaking } from "../../src/shmonad/interfaces/IMonadStaking.sol";
import { SCALE, MIN_VALIDATOR_DEPOSIT } from "../../src/shmonad/Constants.sol";

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
        // - Emits CommissionRateUpdated(0, initial)
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
        emit Coinbase.CommissionRateUpdated(0, 20e16);

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
        assertEq(c.getCommissionRate(), 20e16, "initial commission should come from precompile");
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
        coinbase.updateCommissionRate(commissionRate);
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

    function test_Coinbase_process_returnsFalseWhenRewardBelowMinPayout() public {
        // Goal: If rewardPortion < MIN_VALIDATOR_DEPOSIT, process returns false and pays no commission
        // Steps:
        // 1) Set commission to zero so rewardPortion == balance
        // 2) Fund just below MIN_VALIDATOR_DEPOSIT and call process()

        // Ensure recipient unchanged
        address beforeRecipient = coinbase.getCommissionRecipient();

        vm.prank(validatorAuth);
        coinbase.updateCommissionRate(0);

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

    function test_Coinbase_process_returnsFalseWhenExternalRewardReverts() public {
        // Goal: If the staking precompile reverts despite meeting the minimum payout, process returns false
        // Steps:
        // 1) Commission 0 so rewardPortion == balance
        // 2) Force the mock precompile to revert on externalReward even for valid amounts
        // 3) Fund with >= MIN_VALIDATOR_DEPOSIT and ensure failure preserves funds

        vm.prank(validatorAuth);
        coinbase.updateCommissionRate(0);

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

        uint256 requiredReward = staking.MAX_EXTERNAL_REWARD() + 1;
        uint256 funded = requiredReward;
        vm.deal(address(this), funded);
        (bool ok,) = address(coinbase).call{ value: funded }("");
        assertTrue(ok, "funding coinbase should succeed");

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertFalse(success, "externalReward revert should cause process to return false");

        // Funds remain in coinbase
        assertEq(address(coinbase).balance, funded, "funds should remain on failure");

        // Unclaimed rewards should be unchanged
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
        assertEq(afterUnclaimed, beforeUnclaimed, "no rewards should be applied on failure");
    }

    function test_Coinbase_process_returnsFalseWhenCommissionTransferFails() public {
        // Goal: If commission recipient cannot receive ETH, process returns false and keeps funds
        // Steps:
        // 1) Set commission rate and recipient to a reverting contract
        // 2) Fund coinbase sufficiently large
        // 3) Call process() as ShMonad and expect false with no transfers

        RevertingRecipient badRecipient = new RevertingRecipient();

        vm.startPrank(validatorAuth);
        coinbase.updateCommissionRate(50e16); // 50%
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

        // Entire balance should remain
        assertEq(address(coinbase).balance, 2 ether, "coinbase retains funds on failure");
        assertEq(address(badRecipient).balance, 0, "recipient should not receive funds");

        // Rewards should not be applied when commission fails
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
        assertEq(afterUnclaimed, beforeUnclaimed, "no rewards should be applied on commission failure");
    }

    function test_Coinbase_process_returnsFalseWhenExternalRewardReverts_doesNotSendCommission() public {
        // Goal: When reward send fails (precompile revert), commission must not be sent either
        address recipient = makeAddr("commissionRecipient2");

        uint256 commissionRate = 10e16; // 10%
        vm.startPrank(validatorAuth);
        coinbase.updateCommissionRate(commissionRate);
        coinbase.updateCommissionRecipient(recipient);
        vm.stopPrank();

        // Balance large enough to exceed minimum payout so the revert comes from the mock behavior
        uint256 targetReward = staking.MAX_EXTERNAL_REWARD() + 1;
        uint256 funded = (targetReward * SCALE) / (SCALE - commissionRate) + 1;
        vm.deal(address(this), funded);
        (bool ok,) = address(coinbase).call{ value: funded }("");
        assertTrue(ok, "funding coinbase should succeed");

        // Snapshot unclaimed before
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

        vm.prank(address(shMonad));
        bool success = coinbase.process();
        assertFalse(success, "reward failure should cause process to return false");

        // Commission must not be sent
        assertEq(recipient.balance, 0, "no commission on reward failure");
        // Funds remain on coinbase
        assertEq(address(coinbase).balance, funded, "funds remain when process fails");
        // Unclaimed rewards unchanged
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
        assertEq(afterUnclaimed, beforeUnclaimed, "no rewards should be applied");
    }

    function test_Coinbase_process_success_WithZeroCommission() public {
        // Goal: With 0% commission, rewards should still be applied and process returns true
        vm.prank(validatorAuth);
        coinbase.updateCommissionRate(0);

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

    function test_Coinbase_sendCommissionAndRewards_revertsForExternalCaller() public {
        // Goal: sendCommissionAndRewards is internal-only via onlySelf and must revert for external calls
        vm.expectRevert(Coinbase.OnlySelfCaller.selector);
        coinbase.sendCommissionAndRewards(address(0xBEEF), 1, 1);
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
        emit Coinbase.CommissionRateUpdated(0, 15e16);

        vm.prank(validatorAuth);
        coinbase.updateCommissionRate(15e16); // 15%

        assertEq(coinbase.getCommissionRate(), 15e16, "commission rate should be updated");
    }

    function test_Coinbase_updateCommissionRate_revertsWhenOverScale() public {
        // Goal: New commission must be <= SCALE
        vm.prank(validatorAuth);
        vm.expectRevert(Coinbase.InvalidCommissionRate.selector);
        coinbase.updateCommissionRate(SCALE + 1);
    }

    function test_Coinbase_updateCommissionRate_revertsWhenUnauthorized() public {
        // Goal: Only AUTH_ADDRESS may change the commission rate
        address notAuth = makeAddr("notAuth");
        vm.prank(notAuth);
        vm.expectRevert(Coinbase.OnlyAuthAddress.selector);
        coinbase.updateCommissionRate(5e16);
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
        emit Coinbase.CommissionRateUpdated(0, 7e16);
        coinbase.updateCommissionRateFromStakingConfig();

        assertEq(coinbase.getCommissionRate(), 7e16, "commission rate should match precompile");
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
}
