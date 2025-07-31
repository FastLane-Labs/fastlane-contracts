// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { UserOperation } from "../../../src/atlas/types/UserOperation.sol";
import { SolverOperation } from "../../../src/atlas/types/SolverOperation.sol";
import "../../../src/atlas/types/DAppOperation.sol";

import { CallVerification } from "../../../src/atlas/libraries/CallVerification.sol";

import { IDAppControl } from "../../../src/atlas/interfaces/IDAppControl.sol";
import { IAtlasVerification } from "../../../src/atlas/interfaces/IAtlasVerification.sol";
import { IAtlas } from "../../../src/atlas/interfaces/IAtlas.sol";

import "../../../src/atlas/types/ConfigTypes.sol";

contract DAppOperationBuilder is Test {
    using CallVerification for UserOperation;

    DAppOperation dappOperation;

    function withFrom(address from) public returns (DAppOperationBuilder) {
        dappOperation.from = from;
        return this;
    }

    function withTo(address to) public returns (DAppOperationBuilder) {
        dappOperation.to = to;
        return this;
    }

    function withNonce(uint256 nonce) public returns (DAppOperationBuilder) {
        dappOperation.nonce = nonce;
        return this;
    }

    function withNonce(address atlasVerification, address account) public returns (DAppOperationBuilder) {
        // Assumes dappNoncesSequential = true.
        dappOperation.nonce = IAtlasVerification(atlasVerification).getDAppNextNonce(account);
        return this;
    }

    function withDeadline(uint256 deadline) public returns (DAppOperationBuilder) {
        dappOperation.deadline = deadline;
        return this;
    }

    function withControl(address control) public returns (DAppOperationBuilder) {
        dappOperation.control = control;
        return this;
    }

    function withBundler(address bundler) public returns (DAppOperationBuilder) {
        dappOperation.bundler = bundler;
        return this;
    }

    function withUserOpHash(bytes32 userOpHash) public returns (DAppOperationBuilder) {
        dappOperation.userOpHash = userOpHash;
        return this;
    }

    function withUserOpHash(UserOperation memory userOperation) public returns (DAppOperationBuilder) {
        address verification = IAtlas(userOperation.to).VERIFICATION();
        dappOperation.userOpHash = IAtlasVerification(verification).getUserOperationHash(userOperation);
        return this;
    }

    function withCallChainHash(bytes32 callChainHash) public returns (DAppOperationBuilder) {
        dappOperation.callChainHash = callChainHash;
        return this;
    }

    function withCallChainHash(
        UserOperation memory useroperation,
        SolverOperation[] memory solverOperations
    )
        public
        returns (DAppOperationBuilder)
    {
        dappOperation.callChainHash = CallVerification.getCallChainHash(useroperation, solverOperations);
        return this;
    }

    function withSignature(bytes memory signature) public returns (DAppOperationBuilder) {
        dappOperation.signature = signature;
        return this;
    }

    function sign(address atlasVerification, uint256 privateKey) public returns (DAppOperationBuilder) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(privateKey, IAtlasVerification(atlasVerification).getDAppOperationPayload(dappOperation));
        dappOperation.signature = abi.encodePacked(r, s, v);
        return this;
    }

    function build() public view returns (DAppOperation memory) {
        return dappOperation;
    }

    function signAndBuild(address atlasVerification, uint256 privateKey) public returns (DAppOperation memory) {
        sign(atlasVerification, privateKey);
        return build();
    }
}
