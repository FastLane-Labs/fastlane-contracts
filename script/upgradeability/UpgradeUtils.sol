//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { VmSafe } from "forge-std/Vm.sol";

import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";

library UpgradeUtils {
    /// @notice Deploys a TransparentUpgradeableProxy pointed at the given implementation contract. This function also
    /// extracts the ProxyAdmin contract address from the logs.
    /// @param vm The Vm instance used to access the recordLogs cheatcode.
    /// @param impl The address of the already-deployed implementation contract.
    /// @param proxyAdminOwner The address that will own the ProxyAdmin contract.
    /// @param initCalldata The calldata to use when initializing the proxy contract.
    /// @dev Activate vm.startPrank() or vm.startBroadcast() before calling this function.
    /// @return proxy The new TransparentUpgradeableProxy contract.
    /// @return proxyAdmin The new ProxyAdmin contract of the new proxy contract.
    function deployProxy(
        VmSafe vm,
        address impl,
        address proxyAdminOwner,
        bytes memory initCalldata
    )
        internal
        returns (TransparentUpgradeableProxy proxy, ProxyAdmin proxyAdmin)
    {
        vm.recordLogs(); // Record events to find new ProxyAdmin address

        proxy = new TransparentUpgradeableProxy(impl, proxyAdminOwner, initCalldata);

        VmSafe.Log[] memory entries = vm.getRecordedLogs();

        address proxyAdminAddress;
        bytes32 AdminChangedEvent = IERC1967.AdminChanged.selector;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == AdminChangedEvent) {
                (, proxyAdminAddress) = abi.decode(entries[i].data, (address, address));
                break;
            }
        }

        if (proxyAdminAddress == address(0)) {
            revert("ProxyAdmin not found in logs");
        }

        proxyAdmin = ProxyAdmin(proxyAdminAddress);
    }
}
