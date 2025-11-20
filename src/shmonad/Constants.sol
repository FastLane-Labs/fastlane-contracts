//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { IMonadStaking } from "./interfaces/IMonadStaking.sol";

IMonadStaking constant STAKING = IMonadStaking(0x0000000000000000000000000000000000001000);

// NOTE: These constants exist internally in the precompile but are NOT exposed as view functions.
// Only constants used in production code are defined here. Test-only constants remain in MockMonadStakingPrecompile.
uint256 constant DUST_THRESHOLD = 1e9; // Minimum stake amount (1 gwei)
uint256 constant WITHDRAWAL_DELAY = 1; // Epochs

address constant NATIVE_TOKEN = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
address constant OWNER_COMMISSION_ACCOUNT = address(0x1111111111111111111111111111111111111111);

// Deterministic deployment salt namespace for Coinbase contracts
uint256 constant COINBASE_PROCESS_GAS_LIMIT = 100_000;
bytes32 constant COINBASE_SALT = keccak256("SHMONAD_COINBASE");
uint256 constant TRANSFER_GAS_LIMIT = 50_000; // gas headroom for multisig recipient support

// Monad staking precompile gas guidance (docs.monad.xyz) + adjustable buffer for mocks/in-flight gas bumps
uint256 constant STAKING_GAS_BUFFER = 10_000;
uint256 constant STAKING_GAS_CLAIM_REWARDS = 155_375;
uint256 constant STAKING_GAS_EXTERNAL_REWARD = 62_300;
uint256 constant STAKING_GAS_DELEGATE = 260_850;
uint256 constant STAKING_GAS_UNDELEGATE = 147_750;
uint256 constant STAKING_GAS_WITHDRAW = 68_675;
uint256 constant STAKING_GAS_GET_WITHDRAWAL_REQUEST = 24_300;
uint256 constant STAKING_GAS_GET_DELEGATOR = 184_900;
uint256 constant STAKING_GAS_GET_VALIDATOR = 97_200;
uint256 constant STAKING_GAS_PROPOSER_VAL_ID = 100;

// EIP-1967 admin slot: bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
bytes32 constant EIP1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
// NOTE: Top-up period duration is compared against `block.number` in policy logic and is measured in blocks.
// Set to ~1 day on Monad (0.4s blocks): 24*60*60 / 0.4 = 216_000 blocks.
uint32 constant MIN_TOP_UP_PERIOD_BLOCKS = 216_000;
bytes32 constant PERMIT_TYPEHASH =
    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

uint256 constant ZERO = 0;
uint16 constant BPS_SCALE = 10_000; // Still used for percentage weights/targets outside fee curve math
uint256 constant MIN_VALIDATOR_DEPOSIT = 1e18; // Min amount to do a validator deposit
uint256 constant STAKE_ITERATION_MIN_GAS = 100_000; // Min gas for 1 stake iteration in loop
uint88 constant UNSTAKE_BLOCK_DELAY = 1_209_600; // 7 days if block time is 0.5 seconds
uint256 constant SLASHING_FREEZE_THRESHOLD = 7e16; // 7% of total equity, out of SCALE
uint256 constant ATOMIC_MIN_FEE_WEI = 1e9; // 1 gwei floor for atomic paths

uint256 constant EPOCHS_TRACKED = 8; // Must be a power of 2
uint256 constant MONAD_EPOCH_LENGTH = 50_000; // Measured in blocks
uint256 constant MONAD_EPOCH_DELAY_PERIOD = 5000; // Measured in blocks
uint256 constant MIN_FREE_WITHDRAW_IDS = 8; // Min free withdraw IDs to keep available per validator
uint256 constant SHMONAD_VALIDATOR_DEACTIVATION_PERIOD = 7; // How long it takes to cycle out an inactive validator

uint256 constant SCALE = 1e18; // 100%
uint256 constant TARGET_FLOAT = 2e16; // 2%
uint256 constant FLOAT_REBALANCE_SENSITIVITY = 1e14; // 1bp
uint256 constant FLOAT_PLACEHOLDER = 1;

uint64 constant UNKNOWN_VAL_ID = type(uint64).max - 1;
address constant UNKNOWN_VAL_ADDRESS = address(uint160(type(uint160).max - 1));
// ID-based sentinels for validator crank linked list
uint64 constant FIRST_VAL_ID = 1_111_111_111_111_111_111; // 1.111e18 sentinel (fits in uint64)
uint64 constant LAST_VAL_ID = 9_999_999_999_999_999_999; // 9.999e18 sentinel (fits in uint64)

uint256 constant UINT120_MASK = type(uint120).max;

// feeLib constant
uint256 constant RAY = 1e27;

// Default affine fee curve parameters (Ray precision)
// Fee curve: r(u) = m*u + c with
// - c = 8% / 1600 = 1/20000 = 0.005%
// - m chosen so r(1) = 1% + c  => m = 1%
// Therefore: at u = 0 => 0.005%; at u = 1 => 1.005%
uint128 constant DEFAULT_SLOPE_RATE_RAY = uint128(RAY / 100); // m = 1.00%
uint128 constant DEFAULT_Y_INTERCEPT_RAY = uint128(RAY / 20_000); // c = 0.005%
