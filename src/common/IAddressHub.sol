//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IAddressHub {
    function shMonad() external view returns (address);

    function validatorAuction() external view returns (address);

    function atlas() external view returns (address);

    function clearingHouse() external view returns (address);

    function taskManager() external view returns (address);

    function capitalAllocator() external view returns (address);

    function stakingHub() external view returns (address);

    function paymaster4337() external view returns (address);

    function getAddressFromPointer(uint256 pointer) external view returns (address);

    function getPointerFromAddress(address target) external view returns (uint256);

    function isOwner(address caller) external view returns (bool);

    function isFastLane(address target) external view returns (bool);

    function intraFastLaneCall(uint256 pointer, bytes calldata data) external payable returns (bool, bytes memory);

    function intraFastLaneStaticCall(uint256 pointer, bytes calldata data) external view returns (bool, bytes memory);
}
