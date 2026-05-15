// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {LuminaTokenV2_RescueV1} from "../../src/token/LuminaTokenV2_RescueV1.sol";

/// @notice Sprint Z.2 — execute the one-shot emergencyRecover after the proxy
///         has been upgraded to RescueV1. Moves the 8M LUMINA from the legacy
///         FounderVesting (wrong-oracle, immutable) to the new FounderVestingV2.
contract ExecuteRescue is Script {
    address constant LUMINA_PROXY = 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02;
    address constant FV_LEGACY = 0xa3e7685E21A141930F63432E927D679fD3FDE876;
    uint256 constant AMOUNT = 8_000_000 * 1e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);

        address fvNew = vm.envAddress("FOUNDER_VESTING_V2_ADDRESS");
        require(fvNew != address(0), "FOUNDER_VESTING_V2_ADDRESS env var required");

        LuminaTokenV2_RescueV1 token = LuminaTokenV2_RescueV1(LUMINA_PROXY);
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), sender), "Sender must hold DEFAULT_ADMIN_ROLE");
        require(!token.emergencyRecoverUsed(), "Rescue already used - check on-chain state");
        uint256 balLegacyBefore = token.balanceOf(FV_LEGACY);
        uint256 balNewBefore = token.balanceOf(fvNew);
        require(balLegacyBefore >= AMOUNT, "Legacy FV does not hold the full 8M");

        vm.startBroadcast(pk);
        token.emergencyRecover(FV_LEGACY, fvNew, AMOUNT);
        vm.stopBroadcast();

        require(token.balanceOf(FV_LEGACY) == balLegacyBefore - AMOUNT, "Legacy delta mismatch");
        require(token.balanceOf(fvNew) == balNewBefore + AMOUNT, "New FV delta mismatch");
        require(token.emergencyRecoverUsed(), "Flag did not flip");

        console.log("=== Rescue executed ===");
        console.log("From:           ", FV_LEGACY);
        console.log("To:             ", fvNew);
        console.log("Amount:         ", AMOUNT);
        console.log("Legacy after:   ", token.balanceOf(FV_LEGACY));
        console.log("New FV after:   ", token.balanceOf(fvNew));
    }
}
