// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/Test.sol";
import { BaseTest } from "../base/BaseTest.t.sol";

import { TestDAppControl } from "./helpers/TestDAppControl.sol";
import { TestSolver } from "./helpers/TestSolver.sol";

import { AtlasConstants } from "../../src/atlas/types/AtlasConstants.sol";
import { CallVerification } from "../../src/atlas/libraries/CallVerification.sol";
import { AccountingMath } from "../../src/atlas/libraries/AccountingMath.sol";
import { GasAccLib } from "../../src/atlas/libraries/GasAccLib.sol";
import { CallConfig } from "../../src/atlas/types/ConfigTypes.sol";
import { UserOperation } from "../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../src/atlas/types/SolverOperation.sol";
import { DAppOperation } from "../../src/atlas/types/DAppOperation.sol";
import { AccountAnalytics } from "../../src/atlas/types/EscrowTypes.sol";

// TODO refactor out into separate Atlas-related test files

contract AtlasScenariosTest is BaseTest, AtlasConstants {
    using AccountingMath for uint256;

    // Used in place of winningSolverIdx when no winner expected
    uint256 constant ALL_FAIL = type(uint256).max;
    uint256 constant WRITEOFF_GAS_PER_UNREACHED_SOLVER = 45_000;

    CallConfig callConfig;
    TestDAppControl control;

    struct Before {
        uint256 monPerShMonRate;
        uint256 monInShMonad;
        uint256 gasRefundBeneficiaryMon;
        uint256 bidRecipientBidTokens;
        uint256[] solversBondedInMon;
        AccountAnalytics[] solversAnalytics;
    }

    struct Expected {
        bool auctionWon;
        uint256 winningSolverIdx;
        uint256 bundlerGasRefund;
        uint256 atlasSurcharge;
        uint256 gasLimit;
    }

    struct Args {
        UserOperation userOp;
        SolverOperation[] solverOps;
        DAppOperation dAppOp;
    }

    struct TestSolverConfig {
        uint256 gasLimit;
        uint256 bidAmount;
        uint256 failMode; // 0 = success, 1 = bundler fault, 2 = solver fault
    }

    Before before;
    Expected expected;
    Args args;
    TestSolverConfig[] solverConfigs;
    Account[] solvers;

    function setUp() public override {
        BaseTest.setUp();

        _setCallConfig();

        // Deploy Test DAppControl and initialize with AtlasVerification
        vm.startPrank(governanceEOA);
        control = new TestDAppControl(address(atlas), governanceEOA, bidRecipient, callConfig);
        atlasVerification.initializeGovernance(address(control));
        vm.stopPrank();
    }

    // --------------------------------------------- //
    //                 Metacall Tests                //
    // --------------------------------------------- //

    function test_Atlas_ZeroSolvers() public {
        // No solvers, no gas refunds, no surcharges
        _buildUserOp();
        _snapshotBalancesBefore();
        _buildDAppOp();
        _checkSimulationsPass();

        expected.winningSolverIdx = ALL_FAIL;
        _doMetacallAndChecks();
    }

    function test_Atlas_FiveSolvers() public {
        // Five Solvers with different outcomes to measure gas accounting:
        // - Solver 1 fails due to bundler fault -> gas written off
        // - Solver 2 fails due to solver fault -> solverOp.gas taken with surcharges
        // - Solver 3 wins -> solverOp.gas + non-solver gas, taken with surcharges
        // - Solver 4 unreached -> only bas gas (C + E) taken
        // - Solver 5 unreached -> only bas gas (C + E) taken

        _buildUserOp();
        solverConfigs = [
            TestSolverConfig({ gasLimit: 600_000, bidAmount: 5e18, failMode: 1 }),
            TestSolverConfig({ gasLimit: 700_000, bidAmount: 4e18, failMode: 2 }),
            TestSolverConfig({ gasLimit: 800_000, bidAmount: 3e18, failMode: 0 }),
            TestSolverConfig({ gasLimit: 900_000, bidAmount: 2e18, failMode: 0 }),
            TestSolverConfig({ gasLimit: 1_000_000, bidAmount: 1e18, failMode: 0 })
        ];
        _setUpSolversFromConfig();

        _causeBundlerFaultFail({ solverIdx: 0 });
        _causeSolverFaultFail({ solverIdx: 1 });

        _snapshotBalancesBefore();
        _buildDAppOp();
        _checkSimulationsPass();

        expected.winningSolverIdx = 2; // Solver 3 wins
        _doMetacallAndChecks();
    }

    // --------------------------------------------- //
    //                Helper Functions               //
    // --------------------------------------------- //

    // TODO refactor to generic versions in SetupAtlas.t.sol

    function _doMetacallAndChecks() internal {
        expected.auctionWon = expected.winningSolverIdx != ALL_FAIL;
        expected.gasLimit = _gasLim(args.userOp, args.solverOps);

        // Metacall
        vm.startPrank(bundlerEOA);
        uint256 gasUsed = gasleft();
        bool auctionWon =
            atlas.metacall{ gas: expected.gasLimit }(args.userOp, args.solverOps, args.dAppOp, gasRefundBeneficiary);
        gasUsed -= gasleft();
        vm.stopPrank();

        // Check if there was a winning solver, if one was expected
        assertEq(auctionWon, expected.auctionWon, "auctionWon not as expected");

        // Checks below are only relevant if there are some solvers
        if (args.solverOps.length == 0) return;

        // Check all solvers' bonded MON balances and analytics data changed correctly
        (expected.bundlerGasRefund, expected.atlasSurcharge) = _checkSolversBalancesAndAnalytics();

        // Check gas refund beneficiary received the expected refund
        _checkGasRefundBeneficiaryRefunded();

        // Check amount of underlying MON in ShMonad changed as expected
        _checkMonChangeInShMonad();

        // Checks below are only relevant if there is a winning solver
        if (!expected.auctionWon) return;

        // Check bid recipient received the winning bid amount
        assertEq(
            _bidTokenBalanceOf(bidRecipient),
            before.bidRecipientBidTokens + solverConfigs[expected.winningSolverIdx].bidAmount,
            "bidRecipient balance did not increase by bidAmount"
        );
    }

    function _setCallConfig() internal {
        callConfig.userNoncesSequential = false;
        callConfig.dappNoncesSequential = false;
        callConfig.requirePreOps = true;
        callConfig.trackPreOpsReturnData = false;
        callConfig.trackUserReturnData = true;
        callConfig.delegateUser = false;
        callConfig.requirePreSolver = false;
        callConfig.requirePostSolver = false;
        callConfig.zeroSolvers = false;
        callConfig.reuseUserOp = false;
        callConfig.userAuctioneer = false;
        callConfig.solverAuctioneer = false;
        callConfig.unknownAuctioneer = false;
        callConfig.verifyCallChainHash = true;
        callConfig.forwardReturnData = true;
        callConfig.requireFulfillment = true;
        callConfig.trustedOpHash = false;
        callConfig.invertBidValue = false;
        callConfig.exPostBids = false;
    }

    function _buildUserOp() internal {
        args.userOp = UserOperation({
            from: userEOA,
            to: address(atlas),
            value: 0,
            gas: DEFAULT_USER_OP_GAS_LIMIT,
            maxFeePerGas: tx.gasprice,
            nonce: 1,
            deadline: block.number + 1000,
            dapp: address(control),
            control: address(control),
            callConfig: control.CALL_CONFIG(),
            dappGasLimit: control.getDAppGasLimit(),
            solverGasLimit: control.getSolverGasLimit(),
            bundlerSurchargeRate: control.getBundlerSurchargeRate(),
            sessionKey: address(0),
            data: abi.encodeCall(TestDAppControl.userOperationCall, (4)),
            signature: new bytes(0)
        });

        // User signs userOp - separate bundler will bundle the metacall
        (sig.v, sig.r, sig.s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(args.userOp));
        args.userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    function _setUpSolversFromConfig() internal {
        for (uint256 i = 0; i < solverConfigs.length; i++) {
            (address eoa, uint256 pk) = makeAddrAndKey(string.concat("Solver ", vm.toString(i + 1), " EOA"));
            solvers.push(Account({ addr: eoa, key: pk }));

            _setUpSolver(eoa, pk, solverConfigs[i].bidAmount, solverConfigs[i].gasLimit);
        }
    }

    function _setUpSolver(
        address solverEOA,
        uint256 solverPK,
        uint256 bidAmount,
        uint256 gasLimit
    )
        internal
        returns (address solverContract)
    {
        vm.startPrank(solverEOA);

        // Make sure solver has exactly 1 shMON bonded in Atlas policy.
        // ShMonad exchange rate may require more than 1e18 MON to mint 1e18 shMON
        uint256 monRequired = shMonad.convertToAssets(1e18);
        deal(solverEOA, monRequired);
        shMonad.depositAndBond{value: monRequired}(atlasPolicyID, solverEOA, type(uint256).max);

        // Deploy solver contract
        solverContract = address(new TestSolver(address(atlas)));

        // Create signed solverOp
        SolverOperation memory solverOp = _buildSolverOp(solverEOA, solverPK, solverContract, bidAmount, gasLimit);
        vm.stopPrank();

        // Give solver contract enough MON to pay bid
        vm.deal(solverContract, bidAmount);

        // add to solverOps array and return solver contract address
        args.solverOps.push(solverOp);
        return solverContract;
    }

    function _buildSolverOp(
        address solverEOA,
        uint256 solverPK,
        address solverContract,
        uint256 bidAmount,
        uint256 gasLimit
    )
        internal
        returns (SolverOperation memory solverOp)
    {
        solverOp = SolverOperation({
            from: solverEOA,
            to: address(atlas),
            value: 0,
            gas: gasLimit,
            maxFeePerGas: args.userOp.maxFeePerGas,
            deadline: args.userOp.deadline,
            solver: solverContract,
            control: address(control),
            userOpHash: atlasVerification.getUserOperationHash(args.userOp),
            bidToken: control.getBidFormat(args.userOp),
            bidAmount: bidAmount,
            data: "",
            signature: new bytes(0)
        });
        // Sign solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    function _causeBundlerFaultFail(uint256 solverIdx) internal {
        // SolverOp with invalid sig is blamed on bundler
        args.solverOps[solverIdx].signature = new bytes(0);
    }

    function _causeSolverFaultFail(uint256 solverIdx) internal {
        // Solver contract reverting is blamed on solver
        TestSolver(args.solverOps[solverIdx].solver).setShouldRevert(true);
    }

    function _buildDAppOp() internal {
        args.dAppOp = DAppOperation({
            from: governanceEOA,
            to: address(atlas),
            nonce: 1,
            deadline: args.userOp.deadline,
            control: address(control),
            bundler: bundlerEOA,
            userOpHash: atlasVerification.getUserOperationHash(args.userOp),
            callChainHash: CallVerification.getCallChainHash(args.userOp, args.solverOps),
            signature: new bytes(0)
        });

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(args.dAppOp));
        args.dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    function _checkSimulationsPass() internal {
        bool success;

        (success,,) = simulator.simUserOperation(args.userOp);
        assertEq(success, true, "simUserOperation failed");

        if (args.solverOps.length > 0) {
            (success,,) = simulator.simSolverCalls(args.userOp, args.solverOps, args.dAppOp);
            assertEq(success, true, "simSolverCalls failed");
        }
    }

    function _checkSolversBalancesAndAnalytics()
        internal
        view
        returns (uint256 expectedBundlerRefund, uint256 expectedAtlasSurcharge)
    {
        // NOTE: This uses the TestSolverConfigs array and the Before struct, to predict what the expected MON charge
        // should be per solver, and compares against what actually happened.

        AccountAnalytics memory analytics;
        uint256 solverCount = solverConfigs.length;
        bool shouldBeReached = true; // Starts true, changes to false after expected winner

        for (uint256 i = 0; i < solverCount; i++) {
            uint256 expectedMonCharged;
            uint256 bundlerPortion;
            uint256 atlasPortion;
            uint256 solverOnlyGas;
            uint256 actualMonCharged =
                before.solversBondedInMon[i] - _toMon(shMonad.balanceOfBonded(atlasPolicyID, args.solverOps[i].from));

            {
                // Calculate solver's solverOp-only base gas cost in MON
                uint256 executionGas = solverConfigs[i].gasLimit;
                uint256 calldataGas = _solverCalldataGas(args.solverOps[i]);
                solverOnlyGas = executionGas + calldataGas;
            }

            analytics = _getAccountAnalytics(solvers[i].addr);

            string memory errString = string.concat(
                "solverOp[",
                vm.toString(i),
                "]",
                "\nExpected Fail Mode = ",
                vm.toString(solverConfigs[i].failMode),
                "\nExpected to be reached = ",
                vm.toString(shouldBeReached),
                "\n"
            );

            if (solverConfigs[i].failMode == 2) {
                // Fail Mode 2 == Solver fault --> charged for own gas + surcharges
                (expectedMonCharged, bundlerPortion, atlasPortion) = _expectedMonCharge(
                    solverOnlyGas  + _SOLVER_FAULT_OFFSET, true
                );
                expectedBundlerRefund += bundlerPortion;
                expectedAtlasSurcharge += atlasPortion;

                assertEq(
                    analytics.auctionWins,
                    before.solversAnalytics[i].auctionWins,
                    string.concat(errString, "auctionWins changed")
                );
                assertEq(
                    analytics.auctionFails,
                    before.solversAnalytics[i].auctionFails + 1,
                    string.concat(errString, "auctionFails not incremented")
                );
                assertEq(
                    analytics.lastAccessedBlock, block.number, string.concat(errString, "lastAccessedBlock not updated")
                );
                assertEq(
                    analytics.totalGasValueUsed,
                    before.solversAnalytics[i].totalGasValueUsed + (expectedMonCharged / _GAS_VALUE_DECIMALS_TO_DROP),
                    string.concat(errString, "totalGasValueUsed update incorrect")
                );
            } else if (solverConfigs[i].failMode == 1) {
                // Fail Mode 1 == Bundler fault --> gas written off
                expectedMonCharged = 0;

                assertEq(
                    analytics.auctionWins,
                    before.solversAnalytics[i].auctionWins,
                    string.concat(errString, "auctionWins changed")
                );
                assertEq(
                    analytics.auctionFails,
                    before.solversAnalytics[i].auctionFails,
                    string.concat(errString, "auctionFails changed")
                );
                assertEq(
                    analytics.lastAccessedBlock,
                    before.solversAnalytics[i].lastAccessedBlock,
                    string.concat(errString, "lastAccessedBlock changed")
                );
                assertEq(
                    analytics.totalGasValueUsed,
                    before.solversAnalytics[i].totalGasValueUsed,
                    string.concat(errString, "totalGasValueUsed changed")
                );
            } else if (shouldBeReached) {
                // Fail Mode 0 AND reached == Winner --> charged for own gas + non-solver gas + surcharges
                (expectedMonCharged, bundlerPortion, atlasPortion) = _solverWinGasCharge(i);
                expectedBundlerRefund += bundlerPortion;
                expectedAtlasSurcharge += atlasPortion;

                assertEq(
                    analytics.auctionWins,
                    before.solversAnalytics[i].auctionWins + 1,
                    string.concat(errString, "auctionWins not incremented for winner")
                );
                assertEq(
                    analytics.auctionFails,
                    before.solversAnalytics[i].auctionFails,
                    string.concat(errString, "auctionFails changed for winner")
                );
                assertEq(
                    analytics.lastAccessedBlock, block.number, string.concat(errString, "lastAccessedBlock not updated")
                );
                assertApproxEqRel(
                    analytics.totalGasValueUsed,
                    before.solversAnalytics[i].totalGasValueUsed + (expectedMonCharged / _GAS_VALUE_DECIMALS_TO_DROP),
                    0.02e18,
                    string.concat(errString, "totalGasValueUsed update incorrect")
                );
            } else {
                // Fail Mode 0 AND unreached --> charged for own gas, no surcharges
                (expectedMonCharged, bundlerPortion, atlasPortion) = _expectedMonCharge(solverOnlyGas, false);
                expectedBundlerRefund += bundlerPortion;

                assertEq(
                    analytics.auctionWins,
                    before.solversAnalytics[i].auctionWins,
                    string.concat(errString, "auctionWins changed")
                );
                assertEq(
                    analytics.auctionFails,
                    before.solversAnalytics[i].auctionFails,
                    string.concat(errString, "auctionFails changed")
                );
                assertEq(
                    analytics.lastAccessedBlock,
                    before.solversAnalytics[i].lastAccessedBlock,
                    string.concat(errString, "lastAccessedBlock changed")
                );
                assertEq(
                    analytics.totalGasValueUsed,
                    before.solversAnalytics[i].totalGasValueUsed,
                    string.concat(errString, "totalGasValueUsed changed")
                );
            }

            if (i == expected.winningSolverIdx) {
                // Only the winner solver's charge is hard to predict exactly, due to:
                // - calldata gas deducted before start of metacall logic
                // - unreached solver charge loop gas written off
                // --> 2% tolerance for diff between expected and actual MON taken
                assertApproxEqRel(
                    expectedMonCharged, actualMonCharged, 0.02e18, string.concat(errString, "bonded MON charged")
                );
            } else {
                // All failed or unreached solvers' MON charges should be perfectly predictable.
                // NOTE: The 1 wei margin of error accounts for off-by-one errors in the shMON/MON rate
                // and the prediction calculation in this test.
                assertApproxEqAbs(
                    expectedMonCharged, actualMonCharged, 1, string.concat(errString,"bonded MON charged")
                );
            }

            // Once first non-failing solver is found, toggle shouldBeReached to false to next solvers
            if (shouldBeReached && solverConfigs[i].failMode == 0) {
                shouldBeReached = false;
            }
        }
    }

    function _checkGasRefundBeneficiaryRefunded() internal {
        uint256 actualBundlerRefund = gasRefundBeneficiary.balance - before.gasRefundBeneficiaryMon;

        assertApproxEqRel(
            actualBundlerRefund, expected.bundlerGasRefund, 0.01e18, "bundler refund not within 1% of expected"
        );

        if (expected.auctionWon) {
            // Refund should be higher than estimated gas cost due to surcharges
            assertGt(actualBundlerRefund, expected.gasLimit * tx.gasprice, "refund not higher than gas cost");
        } else {
            // Refund should be lower than estimated gas cost due to 80% cap
            assertLt(actualBundlerRefund, expected.gasLimit * tx.gasprice, "refund not less than gas cost");
        }
    }

    function _checkMonChangeInShMonad() internal {
        assertApproxEqRel(
            before.monInShMonad + expected.atlasSurcharge - expected.bundlerGasRefund,
            address(shMonad).balance,
            0.01e18,
            "MON in ShMonad not changed as expected"
        );
    }

    // Returns the expected MON taken from an account's bonded shMON balance, given the amount of gas charged,
    // and if surcharges should be added
    function _expectedMonCharge(
        uint256 gas,
        bool addSurcharges
    )
        internal
        view
        returns (uint256 monCharge, uint256 bundlerPortion, uint256 atlasPortion)
    {
        monCharge = gas * tx.gasprice;
        bundlerPortion = monCharge; // If no surcharges, bundler gets full base cost

        if (addSurcharges) {
            atlasPortion = monCharge.getSurcharge(atlas.getAtlasSurchargeRate());
            bundlerPortion = monCharge.withSurcharge(control.getBundlerSurchargeRate());
            monCharge = atlasPortion + bundlerPortion;
        }
    }

    function _solverCalldataGas(SolverOperation memory solverOp) internal view returns (uint256) {
        // No L2 Gas Calculator on Monad - set to address(0)
        return GasAccLib.solverOpCalldataGas(solverOp.data.length, address(0));
    }

    function _solverWinGasCharge(uint256 solverIdx)
        internal
        view
        returns (uint256 monCharge, uint256 bundlerPortion, uint256 atlasPortion)
    {
        // Winner pays for their own (C + E) gas
        uint256 solverOnlyGas = solverConfigs[solverIdx].gasLimit + _solverCalldataGas(args.solverOps[solverIdx]);

        // Winner also pays for non-solver (C + E) gas, besides the unreached solver charge loop gas which is written
        // off (negligible)
        uint256 nonSolverGas = 
            args.userOp.gas + control.getDAppGasLimit() + _BASE_TX_GAS_USED + 
            _PRE_EXECUTE_METACALL_GAS + _POST_SETTLE_METACALL_GAS;
        
        nonSolverGas += abi.encode(args.userOp, args.dAppOp, gasRefundBeneficiary).length * _GAS_PER_CALLDATA_BYTE;

        // Winning solver doesn't pay for loop to charge unreached solvers
        uint256 estWriteoffGas = (solverConfigs.length - solverIdx - 1) * WRITEOFF_GAS_PER_UNREACHED_SOLVER;

        // Use helper to add surcharges and tx.gasprice scaling
        return _expectedMonCharge(solverOnlyGas + nonSolverGas - estWriteoffGas, true);
    }

    function _bidTokenBalanceOf(address account) internal view returns (uint256) {
        address bidToken = control.getBidFormat(args.userOp);

        if (bidToken == address(0)) {
            return account.balance;
        } else {
            return IERC20(bidToken).balanceOf(account);
        }
    }

    function _snapshotBalancesBefore() internal {
        before.monPerShMonRate = shMonad.convertToAssets(1e18);
        before.monInShMonad = address(shMonad).balance;
        before.gasRefundBeneficiaryMon = gasRefundBeneficiary.balance;
        before.bidRecipientBidTokens = _bidTokenBalanceOf(bidRecipient);

        for (uint256 i = 0; i < solverConfigs.length; i++) {
            uint256 shMonBonded = shMonad.balanceOfBonded(atlasPolicyID, args.solverOps[i].from);
            before.solversBondedInMon.push(shMonBonded * before.monPerShMonRate / SCALE);

            // Track each solver's AccountAnalytics data before metacall
            before.solversAnalytics.push(_getAccountAnalytics(args.solverOps[i].from));
        }
    }

    // Converts from a shMON amount to MON amount, using exchange rate stored in the Before snapshot.
    function _toMon(uint256 shMonAmount) internal view returns (uint256) {
        return shMonAmount * before.monPerShMonRate / SCALE;
    }

    function _getAccountAnalytics(address account) internal view returns (AccountAnalytics memory) {
        (uint32 lastAccessedBlock, uint24 auctionWins, uint24 auctionFails, uint64 totalGasValueUsed) =
            atlas.accessData(account);

        return AccountAnalytics({
            lastAccessedBlock: lastAccessedBlock,
            auctionWins: auctionWins,
            auctionFails: auctionFails,
            totalGasValueUsed: totalGasValueUsed
        });
    }
}
