// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {LuminaTokenV2_RescueV1} from "../../src/token/LuminaTokenV2_RescueV1.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Sprint Z.2 — UUPS upgrade of LuminaTokenV2 proxy to RescueV1
///         (one-shot emergencyRecover for the 8M LUMINA misrouted to FV legacy).
///         Pair script: ExecuteRescue.s.sol (the recover call) → UpgradeToPostRescueV2.s.sol (drop the function).
contract UpgradeToRescueV1 is Script {
    // Base Sepolia canonical LuminaTokenV2 proxy (SET A, 2026-04-27 deploy + Oracle V2 sprint).
    address constant LUMINA_PROXY = 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);

        LuminaTokenV2 token = LuminaTokenV2(LUMINA_PROXY);
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), sender), "Sender must hold DEFAULT_ADMIN_ROLE");

        vm.startBroadcast(pk);
        LuminaTokenV2_RescueV1 newImpl = new LuminaTokenV2_RescueV1();
        console.log("New impl (RescueV1):", address(newImpl));
        UUPSUpgradeable(LUMINA_PROXY).upgradeToAndCall(address(newImpl), bytes(""));
        vm.stopBroadcast();

        LuminaTokenV2_RescueV1 t = LuminaTokenV2_RescueV1(LUMINA_PROXY);
        console.log("=== LuminaTokenV2 upgraded to RescueV1 ===");
        console.log("Proxy:                  ", LUMINA_PROXY);
        console.log("Implementation (new):   ", address(newImpl));
        console.log("totalSupply (post):     ", t.totalSupply());
        console.log("emergencyRecoverUsed:   ", t.emergencyRecoverUsed());
        require(t.totalSupply() == 100_000_000 * 1e18, "totalSupply drift after upgrade");
        require(!t.emergencyRecoverUsed(), "flag must be false pre-rescue");
    }
}
