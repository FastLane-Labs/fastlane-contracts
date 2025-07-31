// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

// Lib imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Atlas imports
import { Atlas } from "../../../src/atlas/core/Atlas.sol";
import { AtlasVerification } from "../../../src/atlas/core/AtlasVerification.sol";
import { Simulator } from "../../../src/atlas/helpers/Simulator.sol";

// Test Atlas imports - always use test versions for better test coverage
import { TestAtlas } from "../../../test/atlas/helpers/TestAtlas.sol";
import { TestAtlasVerification } from "../../../test/atlas/helpers/TestAtlasVerification.sol";
import { TestSimulator } from "../../../test/atlas/helpers/TestSimulator.sol";
import { Sorter } from "../../../src/atlas/helpers/Sorter.sol";
import { GovernanceBurner } from "../../../src/atlas/helpers/GovernanceBurner.sol";
import { FactoryLib } from "../../../src/atlas/core/FactoryLib.sol";
import { ExecutionEnvironment } from "../../../src/atlas/common/ExecutionEnvironment.sol";
import { UserOperation } from "../../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../../src/atlas/types/SolverOperation.sol";

// Other local imports
import { AddressHub } from "../../../src/common/AddressHub.sol";
import { Directory } from "../../../src/common/Directory.sol";
import { ShMonad } from "../../../src/shmonad/ShMonad.sol";

contract SetupAtlas is Test {
    uint256 DEFAULT_ATLAS_ESCROW_DURATION = 240;
    uint256 DEFAULT_ATLAS_SURCHARGE_RATE = 2_500; // 25% (out of 10_000)
    uint256 DEFAULT_BUNDLER_SURCHARGE_RATE = 5_000; // 50% (out of 10_000)
    uint256 DEFAULT_USER_OP_GAS_LIMIT = 1_000_000;

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    Sig sig;

    uint256 userPK;
    address userEOA;
    uint256 governancePK;
    address governanceEOA;
    uint256 bundlerPK;
    address bundlerEOA;
    uint256 solverOnePK;
    address solverOneEOA;
    uint256 solverTwoPK;
    address solverTwoEOA;
    uint256 solverThreePK;
    address solverThreeEOA;
    uint256 solverFourPK;
    address solverFourEOA;
    uint256 solverFivePK;
    address solverFiveEOA;

    address bidRecipient = makeAddr("BidRecipient");
    address gasRefundBeneficiary = makeAddr("GasRefundBeneficiary");

    Atlas atlas;
    AtlasVerification atlasVerification;
    Simulator simulator;
    Sorter sorter;
    GovernanceBurner govBurner;

    uint64 atlasPolicyID;

    function __setUpAtlas(address deployer, AddressHub addressHub, ShMonad shMonad, address taskManager) internal {
        __createAccountsAtlas();
        __deployContractsAtlas(deployer, addressHub, shMonad, taskManager);
        __initialBalancesAtlas(shMonad);
    }

    // --------------------------------------------- //
    //                 Setup Helpers                 //
    // --------------------------------------------- //

    function __createAccountsAtlas() internal {
        (userEOA, userPK) = makeAddrAndKey("userEOA");
        (governanceEOA, governancePK) = makeAddrAndKey("govEOA");
        (bundlerEOA, bundlerPK) = makeAddrAndKey("bundlerEOA");
        (solverOneEOA, solverOnePK) = makeAddrAndKey("solverOneEOA");
        (solverTwoEOA, solverTwoPK) = makeAddrAndKey("solverTwoEOA");
        (solverThreeEOA, solverThreePK) = makeAddrAndKey("solverThreeEOA");
        (solverFourEOA, solverFourPK) = makeAddrAndKey("solverFourEOA");
        (solverFiveEOA, solverFivePK) = makeAddrAndKey("solverFiveEOA");
    }

    function __deployContractsAtlas(address deployer, AddressHub addressHub, ShMonad shMonad, address taskManager) internal {
        vm.startPrank(deployer);
        // Deploy TestSimulator for test access to internal functions
        simulator = new TestSimulator();

        // Create the Atlas policy in ShMonad
        // 240 blocks = 120 seconds = 2 mins unbonding time on Monad
        (atlasPolicyID,) = shMonad.createPolicy(uint48(DEFAULT_ATLAS_ESCROW_DURATION));

        // Computes the addresses at which AtlasVerification will be deployed
        address expectedAtlasAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        address expectedAtlasVerificationAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        ExecutionEnvironment execEnvTemplate = new ExecutionEnvironment(expectedAtlasAddr);

        // Deploy FactoryLib using precompile from Atlas v1.3 - avoids adjusting Mimic assembly
        FactoryLib factoryLib = FactoryLib(
            deployCode("src/atlas/precompiles/FactoryLib.sol/FactoryLib.json", abi.encode(address(execEnvTemplate)))
        );

        // Deploy TestAtlas for test access to internal functions
        atlas = new TestAtlas({
            atlasSurchargeRate: DEFAULT_ATLAS_SURCHARGE_RATE,
            verification: expectedAtlasVerificationAddr,
            simulator: address(simulator),
            initialSurchargeRecipient: deployer,
            l2GasCalculator: address(0),
            factoryLib: address(factoryLib),
            taskManager: address(taskManager),
            shMonad: addressHub.shMonad(),
            shMonadPolicyID: atlasPolicyID
        });
        // Deploy TestAtlasVerification for test access to internal functions
        atlasVerification = new TestAtlasVerification(address(atlas), address(0));
        simulator.setAtlas(address(atlas));
        sorter = new Sorter(address(atlas));
        govBurner = new GovernanceBurner();

        // Register Atlas' address in the AddressHub
        addressHub.addPointerAddress(Directory._ATLAS, address(atlas), "atlas");

        // Make Atlas a policy agent of its policy in ShMonad
        shMonad.addPolicyAgent(atlasPolicyID, address(atlas));

        vm.stopPrank();

        // Give the Simulator 1000 MON to simulate metacalls where userOp.value > 0
        vm.deal(address(simulator), 1000e18);

        vm.label(address(atlas), "Atlas");
        vm.label(address(atlasVerification), "AtlasVerification");
        vm.label(address(simulator), "Simulator");
        vm.label(address(sorter), "Sorter");
        vm.label(address(govBurner), "GovBurner");
    }

    function __initialBalancesAtlas(ShMonad shMonad) internal {
        // All solverEOAs start with 100 MON and 1 MON deposited in ShMonad
        hoax(solverOneEOA, 100e18);
        shMonad.deposit{ value: 1e18 }(1e18, solverOneEOA);
        hoax(solverTwoEOA, 100e18);
        shMonad.deposit{ value: 1e18 }(1e18, solverTwoEOA);
        hoax(solverThreeEOA, 100e18);
        shMonad.deposit{ value: 1e18 }(1e18, solverThreeEOA);
        // In Atlas-specific tests, these solvers would likely bond to the Atlas policy in setUp
    }

    // --------------------------------------------- //
    //                  Test Helpers                 //
    // --------------------------------------------- //

    function _gasLim(
        UserOperation memory userOp,
        SolverOperation[] memory solverOps
    )
        internal
        view
        returns (uint256 metacallGasLim)
    {
        metacallGasLim = simulator.estimateMetacallGasLimit(userOp, solverOps);
    }
}
