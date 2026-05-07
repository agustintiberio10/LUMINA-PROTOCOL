// ==============================================================
// [DEPRECATED — 2026-05-07]
// This script targets V1 / intermediate contract addresses (pre-V5.1
// redeploy). Do NOT execute against the current Sepolia deployment;
// running it would broadcast transactions to contracts that no longer
// exist or are no longer in the canonical registry. Kept here for
// historical reference only.
//
// Live addresses: GET https://lumina-api-production-ac85.up.railway.app/health
// ==============================================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Direct UUPS upgrade of CoverRouterV2 — NO TimelockController.
///         The owner of the proxy (= deployer/multisig) calls upgradeToAndCall
///         directly. Timelock is intentionally not installed in any environment
///         per repo policy; it will be set up manually when the founder decides.
///
///         The upgrade carries the [Fix RELAYER-PAYMENT] change: USDC premium
///         is now pulled from `buyer`, not from `msg.sender`.
contract UpgradeCoverRouterV2 is Script {
    // Base Sepolia proxy address (chainId 84532, deploy 2026-04-27).
    address constant PROXY = 0x60447F880Fad94fe1E17DBe9A0Cb39923bC9f316;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);

        // Sanity: the sender must be the current owner of the proxy.
        address owner = CoverRouterV2(PROXY).owner();
        require(owner == sender, "Sender is not the proxy owner");

        vm.startBroadcast(pk);

        // Deploy fresh implementation. The proxy keeps its storage and address.
        CoverRouterV2 newImpl = new CoverRouterV2();
        console.log("New CoverRouterV2 implementation deployed at:", address(newImpl));

        // Direct upgrade — no timelock, no scheduling. The owner immediately
        // points the proxy at the new implementation. No re-init call needed
        // because no new storage is being added; the fix is pure logic.
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console.log("=== CoverRouterV2 UPGRADED ===");
        console.log("Proxy:               ", PROXY);
        console.log("Implementation (new):", address(newImpl));
        console.log("Network chainId:     ", block.chainid);
    }
}
