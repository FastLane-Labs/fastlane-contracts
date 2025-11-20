// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import "../../src/shmonad/PrecompileHelpers.sol";
import "../../src/shmonad/interfaces/IMonadStaking.sol";
import "../../src/shmonad/Constants.sol"; // thresholds

/*//////////////////////////////////////////////////////////////
                               MOCK
  A minimal IMonadStaking mock with configurable behavior.
  Deployed once and code-copied (vm.etch) to a fixed "precompile" address
  used by the harness so PrecompileHelpers.STAKING_PRECOMPILE() can be `pure`.
//////////////////////////////////////////////////////////////*/

contract MockMonadStaking is IMonadStaking {
    // Epoch state
    uint64 public mockEpoch;
    bool public mockInDelay;

    // Toggle success / revert behaviors
    bool public delegateSuccess = true;
    bool public undelegateSuccess = true;
    bool public withdrawSuccess = true;
    bool public claimRewardsSuccess = true;
    bool public externalRewardSuccess = true;

    bool public revertDelegate;
    bool public revertUndelegate;
    bool public revertWithdraw;
    bool public revertClaimRewards;
    bool public revertExternalReward;
    bool public revertGetValidator;

    // Per-valId amounts for claimRewards / withdraw transfers
    mapping(uint64 => uint256) public claimAmountByVal;
    mapping(uint64 => uint256) public withdrawPayoutByVal;
    mapping(uint64 => uint256) public consensusStakeByVal;
    mapping(uint64 => uint256) public snapshotStakeByVal;

    // Delegator info & withdrawal requests
    mapping(uint64 => mapping(address => DelInfo)) internal delegators;
    mapping(bytes32 => WithdrawalRequest) internal wreq;

    // Call counters and last msg.value for assertions
    uint256 public delegateCalls;
    uint256 public undelegateCalls;
    uint256 public withdrawCalls;
    uint256 public claimCalls;
    uint256 public externalRewardCalls;
    uint256 public lastValue;

    /* -------------------- admin setters -------------------- */

    function setEpoch(uint64 e, bool inDelay) external {
        mockEpoch = e;
        mockInDelay = inDelay;
    }

    function setDelegator(uint64 valId, address delegator, uint256 stake) external {
        delegators[valId][delegator] = DelInfo({
            stake: stake,
            lastAccumulator: 0,
            rewards: 0,
            deltaStake: 0,
            nextDeltaStake: 0,
            deltaEpoch: 0,
            nextDeltaEpoch: 0
        });
    }

    function setWithdrawalRequest(uint64 valId, address delegator, uint8 wid, uint256 amount, uint64 epoch) external {
        bytes32 key = keccak256(abi.encode(valId, delegator, wid));
        wreq[key] = WithdrawalRequest({amount: amount, accumulator: 0, epoch: epoch});
    }

    function setClaimRewardsConfig(uint64 valId, uint256 amount, bool success, bool willRevert) external payable {
        claimAmountByVal[valId] = amount;
        claimRewardsSuccess = success;
        revertClaimRewards = willRevert;
    }

    function setWithdrawConfig(uint64 valId, uint256 payout, bool success, bool willRevert) external payable {
        withdrawPayoutByVal[valId] = payout;
        withdrawSuccess = success;
        revertWithdraw = willRevert;
    }

    function setDelegateBehavior(bool success, bool willRevert) external {
        delegateSuccess = success;
        revertDelegate = willRevert;
    }

    function setUndelegateBehavior(bool success, bool willRevert) external {
        undelegateSuccess = success;
        revertUndelegate = willRevert;
    }

    function setExternalRewardBehavior(bool success, bool willRevert) external {
        externalRewardSuccess = success;
        revertExternalReward = willRevert;
    }

    // Configure getValidator() behavior in tests
    function setGetValidatorBehavior(bool willRevert) external {
        revertGetValidator = willRevert;
    }

    function setStakes(uint64 valId, uint256 consensusStake, uint256 snapshotStake) external {
        consensusStakeByVal[valId] = consensusStake;
        snapshotStakeByVal[valId] = snapshotStake;
    }

    /* -------------------- IMonadStaking -------------------- */

    function addValidator(
        bytes calldata,
        bytes calldata,
        bytes calldata
    ) external payable returns (uint64) {
        revert("unused");
    }

    function delegate(uint64) external payable returns (bool) {
        if (revertDelegate) revert("delegate/revert");
        ++delegateCalls;
        lastValue = msg.value;
        return delegateSuccess;
    }

    function undelegate(uint64 valId, uint256 amount, uint8) external returns (bool) {
        if (revertUndelegate) {
            uint256 stake = delegators[valId][msg.sender].stake;
            if (stake == 0 || amount > stake) {
                revert("undelegate/revert");
            }
        }
        ++undelegateCalls;
        return undelegateSuccess;
    }

    function compound(uint64) external pure returns (bool) {
        return true;
    }

    function withdraw(uint64 valId, uint8) external returns (bool) {
        if (revertWithdraw) revert("withdraw/revert");
        ++withdrawCalls;
        if (withdrawSuccess) {
            uint256 amt = withdrawPayoutByVal[valId];
            if (amt > 0) {
                (bool ok, ) = payable(msg.sender).call{value: amt}("");
                require(ok, "withdraw/payout-xfer");
            }
        }
        return withdrawSuccess;
    }

    function claimRewards(uint64 valId) external returns (bool) {
        if (revertClaimRewards) revert("claim/revert");
        ++claimCalls;
        if (claimRewardsSuccess) {
            uint256 amt = claimAmountByVal[valId];
            if (amt > 0) {
                (bool ok, ) = payable(msg.sender).call{value: amt}("");
                require(ok, "claim/xfer");
            }
        }
        return claimRewardsSuccess;
    }

    function changeCommission(uint64, uint256) external pure returns (bool) {
        return true;
    }

    function externalReward(uint64) external payable returns (bool) {
        if (revertExternalReward) revert("extReward/revert");
        ++externalRewardCalls;
        lastValue = msg.value;
        return externalRewardSuccess;
    }

    function getValidator(uint64 valId)
        external
        override
        returns (
            address authAddress,
            uint64 flags,
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 commission,
            uint256 unclaimedRewards,
            uint256 consensusStake,
            uint256 consensusCommission,
            uint256 snapshotStake,
            uint256 snapshotCommission,
            bytes memory secpPubkey,
            bytes memory blsPubkey
        )
    {
        if (revertGetValidator) revert("getValidator/revert");
        authAddress = address(0);
        flags = 0;
        stake = 0;
        accRewardPerToken = 0;
        commission = 0;
        unclaimedRewards = 0;
        consensusStake = consensusStakeByVal[valId];
        consensusCommission = 0;
        snapshotStake = snapshotStakeByVal[valId];
        snapshotCommission = 0;
        secpPubkey = "";
        blsPubkey = "";
    }

    function getDelegator(uint64 valId, address delegator)
        external
        override
        returns (
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 unclaimedRewards,
            uint256 deltaStake,
            uint256 nextDeltaStake,
            uint64 deltaEpoch,
            uint64 nextDeltaEpoch
        )
    {
        DelInfo memory info = delegators[valId][delegator];
        stake = info.stake;
        accRewardPerToken = info.lastAccumulator;
        unclaimedRewards = info.rewards;
        deltaStake = info.deltaStake;
        nextDeltaStake = info.nextDeltaStake;
        deltaEpoch = info.deltaEpoch;
        nextDeltaEpoch = info.nextDeltaEpoch;
    }

    function getWithdrawalRequest(
        uint64 valId,
        address delegator,
        uint8 wid
    )
        external
        override
        returns (uint256 withdrawalAmount, uint256 accRewardPerToken, uint64 withdrawEpoch)
    {
        WithdrawalRequest memory request = wreq[keccak256(abi.encode(valId, delegator, wid))];
        withdrawalAmount = request.amount;
        accRewardPerToken = request.accumulator;
        withdrawEpoch = request.epoch;
    }

    function getConsensusValidatorSet(uint32) external pure returns (bool, uint32, uint64[] memory) {
        return (true, 0, new uint64[](0));
    }

    function getSnapshotValidatorSet(uint32) external pure returns (bool, uint32, uint64[] memory) {
        return (true, 0, new uint64[](0));
    }

    function getExecutionValidatorSet(uint32) external pure returns (bool, uint32, uint64[] memory) {
        return (true, 0, new uint64[](0));
    }

    function getDelegations(address, uint64) external pure returns (bool, uint64, uint64[] memory) {
        return (true, 0, new uint64[](0));
    }

    function getDelegators(uint64, address) external pure returns (bool, address, address[] memory) {
        return (true, address(0), new address[](0));
    }

    function getEpoch() external view returns (uint64 epoch, bool inEpochDelayPeriod) {
        return (mockEpoch, mockInDelay);
    }

    function getProposerValId() external pure returns (uint64 val_id) {
        return 123;
    }

    function syscallOnEpochChange(uint64) external {}
    function syscallReward(address) external {}
    function syscallSnapshot() external {}
}

/*//////////////////////////////////////////////////////////////
                             HARNESS
  Concrete contract to expose PrecompileHelpers' internal funcs.
  STAKING_PRECOMPILE() must be pure -> returns a fixed address.
//////////////////////////////////////////////////////////////*/

contract PrecompileHelpersHarness is PrecompileHelpers {
    // Fixed "precompile" address; tests vm.etch() the mock code into this address.
    address internal constant STAKING_ADDR = address(0x5301);

    // expose internal helpers via wrappers
    function call_claimRewards(uint64 valId) external expectsStakingRewards returns (uint120, bool) {
        return _claimRewards(valId);
    }

    function call_initiateWithdrawal(uint64 valId, uint128 amount, uint8 wid) external returns (bool, uint128) {
        return _initiateWithdrawal(valId, amount, wid);
    }

    function call_initiateStaking(uint64 valId, uint128 amount) external returns (bool, uint128) {
        return _initiateStaking(valId, amount);
    }

    function call_completeWithdrawal(uint64 valId, uint8 wid)
        external
        expectsUnstakingSettlement
        returns (uint128, bool, bool)
    {
        return _completeWithdrawal(valId, wid);
    }

    function call_sendRewards(uint64 valId, uint128 amount) external returns (bool, uint120) {
        return _sendRewards(valId, amount);
    }

    function call_getEpoch() external returns (uint64) {
        return _getEpoch();
    }

    function call_getEpochBarrierAdj() external returns (uint64) {
        return _getEpochBarrierAdj();
    }

    function call_inEpochDelay() external returns (bool) {
        return _inEpochDelayPeriod();
    }

    // Expose `_isValidatorInActiveSet` for unit testing
    function call_isValidatorInActiveSet(uint64 valId) external returns (bool) {
        return _isValidatorInActiveSet(valId);
    }

    // required overrides
    function STAKING_PRECOMPILE() public pure override returns (IMonadStaking) {
        return IMonadStaking(STAKING_ADDR);
    }

    modifier expectsUnstakingSettlement() override { _; }
    modifier expectsStakingRewards() override { _; }

    function _totalEquity(bool) internal view override returns (uint256) {
        return address(this).balance; // harmless stub for completeness
    }

    function _validatorIdForCoinbase(address coinbase) internal view override returns (uint64) {
        // Returns coinbase address in the form of a uint64 for testing
        return uint64(uint160(coinbase));
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                              TESTS
//////////////////////////////////////////////////////////////*/

contract PrecompileHelpersTest is Test {
    MockMonadStaking internal mockImpl;
    PrecompileHelpersHarness internal harness;
    address internal constant STAKING_ADDR = address(0x5301);

    function setUp() public {
        harness = new PrecompileHelpersHarness();

        mockImpl = new MockMonadStaking();
        // place mock code at the fixed address used by the harness
        vm.etch(STAKING_ADDR, address(mockImpl).code);

        // default epoch
        MockMonadStaking(STAKING_ADDR).setEpoch(100, false);
    }

    // Scenario: Successful reward claims return the balance delta emitted by the precompile.
    // Steps:
    // 1) Fund the mock precompile and configure a non-zero reward transfer.
    // 2) Call `_claimRewards` through the harness and assert the returned amount equals the transfer.
    // 3) Verify the harness balance increased by the same delta to confirm bookkeeping.
    function test_claimRewards_SuccessDelta() public {
        uint64 valId = 77;

        // Fund mock and configure payout
        vm.deal(STAKING_ADDR, 1 ether);
        MockMonadStaking(STAKING_ADDR).setClaimRewardsConfig{value: 0}(valId, 0.6 ether, true, false);

        uint256 before = address(harness).balance;

        (uint120 amount, bool success) = harness.call_claimRewards(valId);
        assertTrue(success, "claim should succeed");
        assertEq(uint256(amount), 0.6 ether, "delta must equal transferred amount");

        assertEq(address(harness).balance - before, 0.6 ether, "balance delta mismatch");
    }

    // Scenario: Reward claims tolerate missing delegations by returning zero without reverting.
    // Steps:
    // 1) Configure the mock to revert on `claimRewards`, simulating a missing delegation.
    // 2) Invoke the helper and ensure it reports `(0, false)` rather than bubbling the revert.
    // 3) Confirm no balance changes occurred on the harness.
    function test_claimRewards_NoActiveDelegation() public {
        uint64 valId = 88;

        // Force revert path
        MockMonadStaking(STAKING_ADDR).setClaimRewardsConfig(valId, 0.5 ether, true, true);

        (uint120 amount, bool success) = harness.call_claimRewards(valId);
        assertFalse(success, "reverted claim -> false");
        assertEq(amount, 0, "no delta on failure");
    }
    
    // Scenario: Withdrawal initiation retries with the visible stake when the first attempt reverts.
    // Steps:
    // 1) Configure the mock to revert on `undelegate` when the requested amount exceeds stake.
    // 2) Seed the delegator record with a smaller stake to mimic slashing.
    // 3) Invoke the helper and ensure it retries with the reduced amount, succeeding with that value.
    function test_initiateWithdrawal_RetryOnPartial() public {
        uint64 valId = 9;
        uint8 wid = 1;
        uint128 requested = 10 ether;

        // First undelegate should revert -> fallback to getDelegator()
        MockMonadStaking(STAKING_ADDR).setUndelegateBehavior(true, true);
        // Delegator has only 7 ether staked (simulate slashing)
        MockMonadStaking(STAKING_ADDR).setDelegator(valId, address(harness), 7 ether);

        (bool success, uint128 actual) = harness.call_initiateWithdrawal(valId, requested, wid);
        assertTrue(success, "retry succeeds");
        assertEq(uint256(actual), 7 ether, "actual equals visible stake");
    }

    // Scenario: Failed withdrawals surface delay information via `getWithdrawalRequest`.
    // Steps:
    // 1) Force the mock withdraw to revert to simulate an unavailable withdrawal.
    // 2) Program the pending request with a future epoch greater than the current epoch.
    // 3) Assert the helper returns the request amount, reports failure, and flags the delay.
    function test_completeWithdrawal_Delayed() public {
        uint64 valId = 5;
        uint8 wid = 2;

        // Force withdraw revert
        MockMonadStaking(STAKING_ADDR).setWithdrawConfig(valId, 0, false, true);

        // Epochs: request becomes available at epoch+2 (delayed)
        MockMonadStaking(STAKING_ADDR).setEpoch(200, false);
        MockMonadStaking(STAKING_ADDR).setWithdrawalRequest(valId, address(harness), wid, 3.3 ether, 203);

        (uint128 amt, bool ok, bool delayed) = harness.call_completeWithdrawal(valId, wid);
        assertFalse(ok, "withdraw fails");
        assertTrue(delayed, "request is delayed");
        assertEq(uint256(amt), 3.3 ether, "amount read from request");
    }

    // Scenario: Successful withdrawals return the received transfer amount.
    // Steps:
    // 1) Fund the mock precompile and configure a successful withdraw payout.
    // 2) Capture the harness balance before executing `_completeWithdrawal`.
    // 3) Verify the helper returns the transfer size, marks success, and the balance delta matches.
    function test_completeWithdrawal_SettledSuccess() public {
        uint64 valId = 12;
        uint8 wid = 3;

        // Configure successful withdraw that transfers 2.25 ether
        vm.deal(STAKING_ADDR, 3 ether);
        MockMonadStaking(STAKING_ADDR).setWithdrawConfig{value: 0}(valId, 2.25 ether, true, false);

        uint256 before = address(harness).balance;

        (uint128 amt, bool ok, bool delayed) = harness.call_completeWithdrawal(valId, wid);
        assertTrue(ok, "withdraw success");
        assertFalse(delayed, "not delayed");
        assertEq(uint256(amt), 2.25 ether, "amount is delta");
        assertEq(address(harness).balance - before, 2.25 ether, "balance delta matches");
    }

    // Scenario: Reward sends respect the minimum validator payout threshold and available balance caps.
    // Steps:
    // 1) Call `_sendRewards` with `MIN_VALIDATOR_DEPOSIT - 1` and confirm it short-circuits.
    // 2) Fund the harness with less than the requested amount (but still >= MIN) and trigger a send.
    // 3) Ensure the mock receives exactly the capped value and records a single call.
    function test_sendRewards_MinThresholdAndCapByBalance() public {
        uint64 valId = 42;

        // Threshold skip
        (bool okSkip, uint120 sentSkip) =
            harness.call_sendRewards(valId, uint128(MIN_VALIDATOR_DEPOSIT - 1));
        assertTrue(okSkip, "threshold skip returns true");
        assertEq(sentSkip, 0, "no value sent below threshold");
        assertEq(MockMonadStaking(STAKING_ADDR).externalRewardCalls(), 0, "no externalReward call below threshold");

        // Cap by balance (requested > balance, but balance >= MIN so call proceeds)
        uint256 available = MIN_VALIDATOR_DEPOSIT + 0.5 ether;
        vm.deal(address(harness), available);
        MockMonadStaking(STAKING_ADDR).setExternalRewardBehavior(true, false);

        (bool ok, uint120 sent) = harness.call_sendRewards(valId, uint128(MIN_VALIDATOR_DEPOSIT + 0.8 ether));
        assertTrue(ok, "sendRewards success");
        assertEq(uint256(sent), available, "sent amount capped by balance");
        assertEq(MockMonadStaking(STAKING_ADDR).externalRewardCalls(), 1, "one call");
        assertEq(MockMonadStaking(STAKING_ADDR).lastValue(), available, "msg.value forwarded exactly");
    }

    // Scenario: Epoch helpers mirror the precompile view and adjust for delay periods.
    // Steps:
    // 1) Set the mock to a normal epoch and confirm the helpers return raw values with no delay.
    // 2) Switch the mock into delay mode and check `_getEpochBarrierAdj` increments by one.
    // 3) Ensure `_inEpochDelayPeriod` reflects the delay flag accurately in both cases.
    function test_EpochHelpers() public {
        // No delay
        MockMonadStaking(STAKING_ADDR).setEpoch(321, false);
        assertEq(harness.call_getEpoch(), 321, "epoch passthrough");
        assertEq(harness.call_getEpochBarrierAdj(), 321, "no barrier increment");
        assertFalse(harness.call_inEpochDelay(), "no delay");

        // Delay -> barrier increments by 1
        MockMonadStaking(STAKING_ADDR).setEpoch(400, true);
        assertEq(harness.call_getEpoch(), 400, "epoch passthrough");
        assertEq(harness.call_getEpochBarrierAdj(), 401, "barrier +1 during delay");
        assertTrue(harness.call_inEpochDelay(), "delay true");
    }

    // Scenario: Active-set helper checks consensus stake when not in delay period.
    function test_isValidatorInActiveSet_ConsensusPath() public {
        uint64 valId = 111;
        MockMonadStaking(STAKING_ADDR).setEpoch(1000, false); // not in delay
        MockMonadStaking(STAKING_ADDR).setStakes(valId, 1 wei, 0);
        assertTrue(harness.call_isValidatorInActiveSet(valId), "consensus>0 -> active");

        MockMonadStaking(STAKING_ADDR).setStakes(valId, 0, 123);
        assertFalse(harness.call_isValidatorInActiveSet(valId), "consensus=0 -> inactive when not in delay");
    }

    // Scenario: Active-set helper checks snapshot stake during the epoch delay window.
    function test_isValidatorInActiveSet_SnapshotPathDuringDelay() public {
        uint64 valId = 112;
        MockMonadStaking(STAKING_ADDR).setEpoch(1001, true); // in delay
        MockMonadStaking(STAKING_ADDR).setStakes(valId, 0, 2 wei);
        assertTrue(harness.call_isValidatorInActiveSet(valId), "snapshot>0 during delay -> active");

        MockMonadStaking(STAKING_ADDR).setStakes(valId, 5, 0);
        assertFalse(harness.call_isValidatorInActiveSet(valId), "snapshot=0 during delay -> inactive");
    }

    // Scenario: Active-set helper tolerates precompile failure and returns false.
    function test_isValidatorInActiveSet_RevertSafe() public {
        uint64 valId = 113;
        MockMonadStaking(STAKING_ADDR).setEpoch(1002, false);
        MockMonadStaking(STAKING_ADDR).setGetValidatorBehavior(true);
        assertFalse(harness.call_isValidatorInActiveSet(valId), "revert -> inactive");
        MockMonadStaking(STAKING_ADDR).setGetValidatorBehavior(false);
    }
}
