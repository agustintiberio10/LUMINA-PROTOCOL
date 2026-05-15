// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {LuminaTokenV2_PostRescueV2} from "../../src/token/LuminaTokenV2_PostRescueV2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Sprint Z.2 — UUPS upgrade of LuminaTokenV2 proxy from RescueV1
///         to PostRescueV2 (drops emergencyRecover from public ABI but keeps
///         the storage slot so future upgrades don't collide).
contract UpgradeToPostRescueV2 is Script {
    address constant LUMINA_PROXY = 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);

        LuminaTokenV2 token = LuminaTokenV2(LUMINA_PROXY);
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), sender), "Sender must hold DEFAULT_ADMIN_ROLE");

        vm.startBroadcast(pk);
        LuminaTokenV2_PostRescueV2 newImpl = new LuminaTokenV2_PostRescueV2();
        console.log("New impl (PostRescueV2):", address(newImpl));
        UUPSUpgradeable(LUMINA_PROXY).upgradeToAndCall(address(newImpl), bytes(""));
        vm.stopBroadcast();

        // Post-condition: emergencyRecover selector must no longer be callable.
        (bool ok,) = LUMINA_PROXY.call(abi.encodeWithSignature("emergencyRecover(address,address,uint256)", address(0), address(0), 0));
        require(!ok, "emergencyRecover still callable after downgrade");

        console.log("=== LuminaTokenV2 downgraded to PostRescueV2 ===");
        console.log("Proxy:                ", LUMINA_PROXY);
        console.log("Implementation (new): ", address(newImpl));
        console.log("totalSupply:          ", LuminaTokenV2(LUMINA_PROXY).totalSupply());
    }
}
