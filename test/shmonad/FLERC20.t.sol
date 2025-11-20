// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Vm } from "forge-std/Vm.sol";
import { stdStorage, StdStorage } from "forge-std/StdStorage.sol";
import { BaseTest } from "../base/BaseTest.t.sol";
import { ShMonad } from "../../src/shmonad/ShMonad.sol";
import { PERMIT_TYPEHASH } from "../../src/shmonad/Constants.sol";

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Minimal ERC-1271 smart wallet that accepts signatures from a designated EOA.
contract MockERC1271Wallet {
    using ECDSA for bytes32;

    // ERC-1271 magic values
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;
    bytes4 internal constant FAILVALUE  = 0xffffffff;

    address public immutable signer; // EOA allowed to sign for this wallet

    constructor(address _signer) {
        signer = _signer;
    }

    // ERC-1271: validate a signature for `hash`
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        address recovered = ECDSA.recover(hash, signature);
        return recovered == signer ? MAGICVALUE : FAILVALUE;
    }

    receive() external payable {}
}

contract FLERC20Test is BaseTest {
    using stdStorage for StdStorage;

    // Local mirrors for event assertions
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public override {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _signPermit(
        uint256 ownerPk,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal returns (uint8 v, bytes32 r, bytes32 s, uint256 nonce) {
        bytes32 domainSeparator = shMonad.DOMAIN_SEPARATOR();
        nonce = shMonad.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH,
            owner,
            spender,
            value,
            nonce,
            deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(ownerPk, digest);
    }

    function _countApprovalEvents(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        bytes32 APPROVAL_SIG = keccak256("Approval(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == APPROVAL_SIG) {
                unchecked {
                    ++n;
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        METADATA & BASIC FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_FLERC20_metadata() public view {
        // Scenario: Expose name/symbol/decimals for front-ends.
        // Step 1: Read ERC-20 metadata directly from `shMonad`.
        assertEq(shMonad.name(), "ShMonad");
        assertEq(shMonad.symbol(), "shMON");
        assertEq(shMonad.decimals(), 18);
    }

    function test_FLERC20_transferFrom_NoApprovalEventOnFiniteSpend() public {
        // Scenario: Spending a finite allowance should not emit Approval events.
        uint256 amount = 10 ether;

        // Step 1: Fund alice and mint shares via `shMonad.deposit`.
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: amount }(amount, alice);

        // Step 2: Approve bob for a finite allowance using `shMonad.approve`.
        uint256 spend = shares / 3;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Approval(alice, bob, spend);
        shMonad.approve(bob, spend);

        // Step 3: Capture logs while bob spends via `shMonad.transferFrom`.
        vm.recordLogs();
        vm.prank(bob);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Transfer(alice, bob, spend);
        shMonad.transferFrom(alice, bob, spend);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Step 4: Assert that `_countApprovalEvents` finds zero Approval emissions.
        assertEq(_countApprovalEvents(logs), 0, "no Approval on finite allowance spend");
    }

    function test_FLERC20_allowance_InfiniteToFiniteSequence() public {
        // Scenario: Infinite allowance remains unchanged until overwritten, finite allowance decrements on spend.
        uint256 amount = 7 ether;

        // Step 1: Fund alice and deposit into ShMonad.
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: amount }(amount, alice);

        // Step 2: Approve infinite allowance using `shMonad.approve`.
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Approval(alice, bob, type(uint256).max);
        shMonad.approve(bob, type(uint256).max);

        // Step 3: Spend a portion via `shMonad.transferFrom` and assert the allowance is still max.
        uint256 spend1 = shares / 5;
        vm.prank(bob);
        shMonad.transferFrom(alice, bob, spend1);
        assertEq(shMonad.allowance(alice, bob), type(uint256).max, "infinite allowance must remain max");

        // Step 4: Overwrite to a finite amount via `shMonad.approve`.
        uint256 finite = shares / 4;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Approval(alice, bob, finite);
        shMonad.approve(bob, finite);

        // Step 5: Spend from the finite allowance and assert decrementing behaviour.
        uint256 spend2 = finite - 1;
        vm.prank(bob);
        shMonad.transferFrom(alice, bob, spend2);
        assertEq(shMonad.allowance(alice, bob), 1, "finite allowance must decrement");
    }

    function test_FLERC20_approve_SelfAndSelfSpend() public {
        // Scenario: Accounts can self-approve and self-spend using transferFrom.
        uint256 amount = 3 ether;

        // Step 1: Seed alice and mint shares via `shMonad.deposit`.
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: amount }(amount, alice);

        // Step 2: Self-approve using `shMonad.approve`.
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Approval(alice, alice, shares);
        shMonad.approve(alice, shares);

        // Step 3: Self-spend via `shMonad.transferFrom`.
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Transfer(alice, bob, shares);
        shMonad.transferFrom(alice, bob, shares);

        // Step 4: Validate allowance and balances post-spend.
        assertEq(shMonad.allowance(alice, alice), 0, "self allowance consumed");
        assertEq(shMonad.balanceOf(bob), shares, "bob received shares");
    }

    function test_FLERC20_transferAndTransferFrom_PreserveSupply() public {
        // Scenario: transfer and transferFrom must conserve totalSupply.
        uint256 amount = 10 ether;

        // Step 1: Fund alice and mint shares.
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: amount }(amount, alice);
        uint256 supplyAfterDeposit = shMonad.totalSupply();

        // Step 2: Transfer part of the balance directly.
        uint256 directSend = shares / 4;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Transfer(alice, bob, directSend);
        shMonad.transfer(bob, directSend);

        // Step 3: Approve remaining shares to bob with `shMonad.approve`.
        uint256 allowanceAmount = shares - directSend;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Approval(alice, bob, allowanceAmount);
        shMonad.approve(bob, allowanceAmount);

        // Step 4: Spend allowance through `shMonad.transferFrom`.
        vm.prank(bob);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Transfer(alice, bob, allowanceAmount);
        shMonad.transferFrom(alice, bob, allowanceAmount);

        // Step 5: Assert supply conservation.
        assertEq(shMonad.totalSupply(), supplyAfterDeposit, "total supply should remain constant");
        assertEq(shMonad.balanceOf(bob), shares, "bob owns all shares");
    }

    function test_FLERC20_deposit_IncreasesSupplyByMintedShares() public {
        // Scenario: Depositing increases totalSupply by minted shares.
        uint256 amount = 11 ether;

        // Step 1: Record `shMonad.totalSupply` before minting.
        uint256 supplyBefore = shMonad.totalSupply();

        // Step 2: Seed alice and execute `shMonad.deposit`.
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 minted = shMonad.deposit{ value: amount }(amount, alice);

        // Step 3: Assert post-conditions on supply and balance.
        assertEq(shMonad.totalSupply(), supplyBefore + minted, "deposit should increase totalSupply by minted");
        assertEq(shMonad.balanceOf(alice), minted, "alice balance equals minted shares from zero");
    }

    /*//////////////////////////////////////////////////////////////
                          CONSERVATION CHECKS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_FLERC20_transfer_Conservation(uint256 amount) public {
        // Scenario: Direct transfers conserve supply and balances.
        amount = bound(amount, 1 wei, 1000 ether);

        // Step 1: Fund alice and mint via `shMonad.deposit`.
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: amount }(amount, alice);

        // Step 2: Capture pre-state for supply and balances.
        uint256 totalBefore = shMonad.totalSupply();
        uint256 aBefore = shMonad.balanceOf(alice);
        uint256 bBefore = shMonad.balanceOf(bob);

        // Step 3: Execute `shMonad.transfer` for half the shares.
        uint256 toSend = shares / 2;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Transfer(alice, bob, toSend);
        shMonad.transfer(bob, toSend);

        // Step 4: Assert supply and per-party conservation.
        assertEq(shMonad.totalSupply(), totalBefore, "supply must be conserved on transfer");
        assertEq(
            shMonad.balanceOf(alice) + shMonad.balanceOf(bob),
            aBefore + bBefore,
            "sum of balances must be conserved"
        );
    }

    function testFuzz_FLERC20_transferFrom_Conservation(uint256 amount, uint256 spend) public {
        // Scenario: Third-party transferFrom conserves supply and balances.
        amount = bound(amount, 1 ether, 1000 ether);

        // Step 1: Fund alice and mint via `shMonad.deposit`.
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: amount }(amount, alice);

        // Step 2: Approve carol as operator and snapshot state.
        vm.prank(alice);
        shMonad.approve(carol, shares);
        uint256 totalBefore = shMonad.totalSupply();
        uint256 aBefore = shMonad.balanceOf(alice);
        uint256 bBefore = shMonad.balanceOf(bob);

        // Step 3: Bound spend and perform `shMonad.transferFrom`.
        spend = bound(spend, 1, shares);
        vm.prank(carol);
        shMonad.transferFrom(alice, bob, spend);

        // Step 4: Assertions for conservation.
        assertEq(shMonad.totalSupply(), totalBefore, "supply must be conserved on transferFrom");
        assertEq(
            shMonad.balanceOf(alice) + shMonad.balanceOf(bob),
            aBefore + bBefore,
            "sum of balances must be conserved on transferFrom"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    UINT128 STORAGE LANE SAFETY
    //////////////////////////////////////////////////////////////*/

    function test_FLERC20_uint128OverflowGuard_OnRecipient() public {
        // Scenario: Recipient balance lane (uint128) must revert on overflow.
        uint256 nearMax = type(uint128).max - 10;

        // Step 1: Force bob close to max via `stdstore.checked_write`.
        stdstore.target(address(shMonad))
            .sig(shMonad.balanceOf.selector)
            .with_key(bob)
            .checked_write(nearMax);

        // Step 2: Fund alice and mint shares.
        vm.deal(alice, 20 ether);
        vm.prank(alice);
        shMonad.deposit{ value: 20 ether }(20 ether, alice);

        // Step 3: Attempt overflow transfer and expect revert.
        vm.prank(alice);
        vm.expectRevert();
        shMonad.transfer(bob, 11);

        // Step 4: Confirm safe transfer of 10 succeeds and caps at max.
        vm.prank(alice);
        shMonad.transfer(bob, 10);
        assertEq(shMonad.balanceOf(bob), nearMax + 10, "bob sits at exact max after safe transfer");
    }

    /*//////////////////////////////////////////////////////////////
                                PERMIT
    //////////////////////////////////////////////////////////////*/

    function test_FLERC20_permit_InvalidatingAnyFieldBreaksSig() public {
        // Scenario: Any signed-field mutation must invalidate permit signature.
        uint256 ownerPk = 0xA11CE_01;
        address owner = vm.addr(ownerPk);
        address spender = bob;
        uint256 value = 5 ether;
        uint256 deadline = block.timestamp + 1 days;

        // Step 1: Mint shares to owner via `shMonad.deposit`.
        vm.deal(owner, 6 ether);
        vm.prank(owner);
        shMonad.deposit{ value: 6 ether }(6 ether, owner);

        // Step 2: Produce baseline permit signature with `_signPermit`.
        (uint8 v, bytes32 r, bytes32 s,) = _signPermit(ownerPk, owner, spender, value, deadline);

        // Step 3: Mutate spender and expect ERC2612InvalidSigner revert.
        vm.prank(spender);
        vm.expectRevert();
        shMonad.permit(owner, carol, value, deadline, v, r, s);

        // Step 4: Mutate value and expect ERC2612InvalidSigner revert.
        vm.prank(spender);
        vm.expectRevert();
        shMonad.permit(owner, spender, value + 1, deadline, v, r, s);

        // Step 5: Call with canonical fields and expect Approval event.
        vm.prank(spender);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Approval(owner, spender, value);
        shMonad.permit(owner, spender, value, deadline, v, r, s);

        // Step 6: Replay must fail because nonce is consumed.
        vm.prank(spender);
        vm.expectRevert();
        shMonad.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_FLERC20_permit_DeadlineBoundary() public {
        // Scenario: Boundary deadlines validate at == now and revert when expired.
        uint256 ownerPk = 0xBEEFB0B;
        address owner = vm.addr(ownerPk);
        address spender = bob;

        // Step 1: Mint minimal shares to owner to keep account active.
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        shMonad.deposit{ value: 1 ether }(1 ether, owner);

        // Step 2: Sign with deadline == now and execute permit.
        uint256 deadNow = block.timestamp;
        (uint8 vNow, bytes32 rNow, bytes32 sNow,) = _signPermit(ownerPk, owner, spender, 1 ether, deadNow);
        vm.prank(spender);
        shMonad.permit(owner, spender, 1 ether, deadNow, vNow, rNow, sNow);

        // Step 3: Sign with deadline < now and assert revert.
        uint256 expired = block.timestamp - 1;
        (uint8 vExpired, bytes32 rExpired, bytes32 sExpired,) = _signPermit(ownerPk, owner, spender, 2 ether, expired);
        vm.prank(spender);
        vm.expectRevert();
        shMonad.permit(owner, spender, 2 ether, expired, vExpired, rExpired, sExpired);
    }

    function test_FLERC20_permit_DomainSeparatorStable() public view {
        // Scenario: DOMAIN_SEPARATOR must be stable within the same transaction.
        // Step 1: Read `shMonad.DOMAIN_SEPARATOR()` twice.
        bytes32 a = shMonad.DOMAIN_SEPARATOR();
        bytes32 b = shMonad.DOMAIN_SEPARATOR();

        // Step 2: Assert values are identical.
        assertEq(a, b, "domain separator must be stable within same tx");
    }

    function test_FLERC20_permitThenSpend_AllowanceZeroAfter() public {
        // Scenario: Permit followed by a spend should zero the allowance.
        uint256 ownerPk = 0xC0FFEE;
        address owner = vm.addr(ownerPk);
        address spender = bob;
        uint256 assets = 4 ether;
        uint256 deadline = block.timestamp + 1 days;

        // Step 1: Mint shares to owner.
        vm.deal(owner, assets);
        vm.prank(owner);
        uint256 mintedShares = shMonad.deposit{ value: assets }(assets, owner);

        // Step 2: Sign and submit permit for the exact minted shares.
        (uint8 v, bytes32 r, bytes32 s,) = _signPermit(ownerPk, owner, spender, mintedShares, deadline);
        vm.prank(spender);
        shMonad.permit(owner, spender, mintedShares, deadline, v, r, s);

        // Step 3: Spend full allowance via `shMonad.transferFrom`.
        vm.prank(spender);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Transfer(owner, spender, mintedShares);
        shMonad.transferFrom(owner, spender, mintedShares);

        // Step 4: Assert allowance fully consumed.
        assertEq(shMonad.allowance(owner, spender), 0, "allowance should be fully consumed");
    }

    function test_FLERC20_permit_ReplayProtectionAcrossIncreasingNonces() public {
        // Scenario: Increasing nonces allow multiple permits; replays fail.
        uint256 ownerPk = 0xBEEF01;
        address owner = vm.addr(ownerPk);
        address spender = bob;

        // Step 1: Prime owner with shares.
        vm.deal(owner, 5 ether);
        vm.prank(owner);
        shMonad.deposit{ value: 5 ether }(5 ether, owner);

        // Step 2: Execute two permits with increasing nonces.
        uint256 firstDeadline = block.timestamp + 1 days;
        (uint8 v1, bytes32 r1, bytes32 s1, uint256 nonce1) = _signPermit(ownerPk, owner, spender, 1 ether, firstDeadline);
        vm.prank(spender);
        shMonad.permit(owner, spender, 1 ether, firstDeadline, v1, r1, s1);
        assertEq(shMonad.nonces(owner), nonce1 + 1, "nonce increments after first permit");

        uint256 secondDeadline = block.timestamp + 2 days;
        (uint8 v2, bytes32 r2, bytes32 s2, uint256 nonce2) = _signPermit(ownerPk, owner, spender, 2 ether, secondDeadline);
        assertEq(nonce2, nonce1 + 1, "signing uses incremented nonce");
        vm.prank(spender);
        shMonad.permit(owner, spender, 2 ether, secondDeadline, v2, r2, s2);
        assertEq(shMonad.nonces(owner), nonce2 + 1, "nonce increments after second permit");

        // Step 3: Replay prior signature and expect revert.
        vm.prank(spender);
        vm.expectRevert();
        shMonad.permit(owner, spender, 1 ether, firstDeadline, v1, r1, s1);
    }

    /*//////////////////////////////////////////////////////////////
                         FUZZ: ALLOWANCE DRAIN
    //////////////////////////////////////////////////////////////*/

    function testFuzz_FLERC20_transferFrom_AllowanceConsumption(uint256 amount, uint256 fracNum) public {
        // Scenario: Spending arbitrary fractions reduces allowance appropriately.
        amount = bound(amount, 1 ether, 1000 ether);
        fracNum = bound(fracNum, 1, 1e6);

        // Step 1: Seed alice and mint shares.
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 shares = shMonad.deposit{ value: amount }(amount, alice);

        // Step 2: Compute allowance and spend slice.
        uint256 allowAmount = shares / 2;
        uint256 spend = (allowAmount * fracNum) / (fracNum + 3);
        if (spend == 0) spend = 1;

        // Step 3: Approve carol and perform transferFrom.
        vm.prank(alice);
        shMonad.approve(carol, allowAmount);
        vm.prank(carol);
        shMonad.transferFrom(alice, bob, spend);

        // Step 4: Assert allowance decrements by spend.
        assertEq(shMonad.allowance(alice, carol), allowAmount - spend, "allowance must reduce by spend");
    }

    function test_FLERC20_permit_EOAWithCode_StillAcceptsECDSA() public {
        // Scenario: A 7702-style EOA may have code at call-time. We must accept its ECDSA sig first,
        // not force ERC-1271. This test "etches" code onto an EOA and confirms permit still works.

        uint256 ownerPk = 0xA7702; // arbitrary private key
        address owner = vm.addr(ownerPk);
        address spender = bob;
        uint256 value = 3 ether;
        uint256 deadline = block.timestamp + 1 days;

        // Step 1: Keep the account "active" (optional, but mirrors other tests).
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        shMonad.deposit{ value: 2 ether }(2 ether, owner);

        // Step 2: Produce a canonical ECDSA signature from the owner's EOA key.
        (uint8 v, bytes32 r, bytes32 s, ) = _signPermit(ownerPk, owner, spender, value, deadline);

        // Step 3: Simulate a 7702-like state by giving the EOA address some runtime code.
        // Any non-empty bytecode will do; 0x00 is a single STOP opcode.
        bytes memory dummyRuntime = hex"00";
        vm.etch(owner, dummyRuntime);
        assertGt(owner.code.length, 0, "owner must have non-empty code");

        // Step 4: Call permit and expect success via the ECDSA path.
        vm.prank(spender);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Approval(owner, spender, value);
        shMonad.permit(owner, spender, value, deadline, v, r, s);

        // Step 5: Assert allowance was set (i.e., ECDSA accepted despite code presence).
        assertEq(shMonad.allowance(owner, spender), value, "permit must accept ECDSA even when owner has code");
    }

    function test_FLERC20_permit_ERC1271SmartWallet() public {
        // Scenario: A 4337-style smart wallet (contract account) validates via ERC-1271.
        // The token should accept permit by falling back to SignatureChecker / 1271 path.

        // --- setup signer EOA and smart wallet ---
        uint256 signerPk = 0x1271A11CE;                   // arbitrary private key
        address signerEOA = vm.addr(signerPk);            // EOA authorized by the wallet
        MockERC1271Wallet wallet = new MockERC1271Wallet(signerEOA);
        address owner = address(wallet);                  // owner is the smart wallet (contract)
        address spender = bob;
        uint256 value = 3 ether;
        uint256 deadline = block.timestamp + 1 days;

        // --- fund wallet and mint shares to it so it has balance ---
        vm.deal(owner, 5 ether);
        vm.prank(owner);
        uint256 minted = shMonad.deposit{ value: 5 ether }(5 ether, owner);
        require(minted > 0, "mint failed");

        // --- sign a permit using the EOA that the wallet trusts ---
        // Note: we sign the digest for `owner = wallet`, but with `signerPk` (EOA).
        (uint8 v, bytes32 r, bytes32 s, ) = _signPermit(signerPk, owner, spender, value, deadline);

        // --- execute permit: must pass via ERC-1271 path ---
        vm.prank(spender);
        vm.expectEmit(true, true, false, true, address(shMonad));
        emit Approval(owner, spender, value);
        shMonad.permit(owner, spender, value, deadline, v, r, s);

        // --- assert allowance set for the wallet owner ---
        assertEq(shMonad.allowance(owner, spender), value, "1271 permit should set allowance for smart wallet");
    }
}