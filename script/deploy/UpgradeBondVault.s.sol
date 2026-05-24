// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title UpgradeBondVault
/// @notice Sprint upgrade-bondvault-on-chain — UUPS upgrade of the live
///         BondVault proxy on Base Sepolia to ship the R1 code from PR #149
///         (CEX auto-injection branch + LUMINA floor pause). The CEX Reserve
///         is intentionally NOT wired (cexReserve stays 0x0) per founder
///         decision: auto-injection branch remains inactive; floor pause is
///         active. Owner-gated `_authorizeUpgrade` is inherited from the
///         existing BondVault; the founder EOA submits the upgrade directly.
contract UpgradeBondVault is Script {
    address constant PROXY = 0x193acBc1EdC5E565a4aBE96941C7E7AeF637B6EC;

    function run() external returns (address newImpl) {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        BondVault impl = new BondVault();
        newImpl = address(impl);
        IUUPSUpgradeable(PROXY).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        console2.log("=== Sprint upgrade-bondvault-on-chain: BondVault upgraded ===");
        console2.log("Proxy:           ", PROXY);
        console2.log("New impl:        ", newImpl);
    }
}
