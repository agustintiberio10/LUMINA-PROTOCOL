// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title UpgradeTWAPBurner
/// @notice Sprint CR-USDC-Reconfig — UUPS upgrade of the live TWAPBurner
///         proxy on Base Sepolia to ship the new `setUsdc(address)` admin
///         function (mirrors CoverRouterV2 change). Owner-gated upgrade.
contract UpgradeTWAPBurner is Script {
    address constant PROXY = 0x242d76082856901b4ba1E7c50C022D46a6941bC0;

    function run() external returns (address newImpl) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);
        TWAPBurner impl = new TWAPBurner();
        newImpl = address(impl);
        IUUPSUpgradeable(PROXY).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        console2.log("=== Sprint CR-USDC-Reconfig: TWAPBurner upgraded ===");
        console2.log("Proxy:           ", PROXY);
        console2.log("New impl:        ", newImpl);
    }
}
