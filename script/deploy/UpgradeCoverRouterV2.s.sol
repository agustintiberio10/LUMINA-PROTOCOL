// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title UpgradeCoverRouterV2
/// @notice Sprint CR-USDC-Reconfig — UUPS upgrade of the live CoverRouterV2
///         proxy on Base Sepolia to ship the new `setUsdc(address)` admin
///         function. No storage-layout change; only one new function + one
///         new event. Owner-gated `_authorizeUpgrade` is inherited; the
///         founder EOA (current owner) submits the upgrade directly.
contract UpgradeCoverRouterV2 is Script {
    address constant PROXY = 0xcdB70B40e6a3DEac3189185d947A0e458518F566;

    function run() external returns (address newImpl) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);
        CoverRouterV2 impl = new CoverRouterV2();
        newImpl = address(impl);
        IUUPSUpgradeable(PROXY).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        console2.log("=== Sprint CR-USDC-Reconfig: CoverRouterV2 upgraded ===");
        console2.log("Proxy:           ", PROXY);
        console2.log("New impl:        ", newImpl);
    }
}
