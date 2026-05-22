// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title UpgradePolicyManagerV2
/// @notice Sprint Cleanup — UUPS upgrade of the live PolicyManagerV2 proxy on
///         Base Sepolia to a fresh implementation that ships removeProduct +
///         removeProductBatch. No storage-layout change; only function-table
///         additions + 1 event. Owner-gated `_authorizeUpgrade` is inherited
///         from the existing impl, so the founder EOA (current owner) can
///         submit the upgrade directly.
contract UpgradePolicyManagerV2 is Script {
    address constant PROXY = 0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8;

    function run() external returns (address newImpl) {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        PolicyManagerV2 impl = new PolicyManagerV2();
        newImpl = address(impl);
        IUUPSUpgradeable(PROXY).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        console2.log("=== Sprint Cleanup: PolicyManagerV2 upgraded ===");
        console2.log("Proxy:           ", PROXY);
        console2.log("New impl:        ", newImpl);
    }
}
