// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {EmergencyPause} from "../src/core/EmergencyPause.sol";
import {CoverRouter} from "../src/core/CoverRouter.sol";
import {PolicyManager} from "../src/core/PolicyManager.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {StableLongVault} from "../src/vaults/StableLongVault.sol";

/**
 * @title DeployUpgradeBatch
 * @notice Deploy EmergencyPause + new implementations for all UUPS proxies.
 *         After this, upgrade proxies + configure via Gnosis Safe.
 */
contract DeployUpgradeBatch is Script {
    address constant TIMELOCK = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;
    address constant SAFE = 0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Deploy EmergencyPause (non-upgradeable, owner = Timelock)
        EmergencyPause ep = new EmergencyPause(TIMELOCK, 1 hours);
        console.log("EmergencyPause:", address(ep));

        // 2. Deploy new implementations
        CoverRouter routerImpl = new CoverRouter();
        console.log("CoverRouter impl:", address(routerImpl));

        PolicyManager pmImpl = new PolicyManager();
        console.log("PolicyManager impl:", address(pmImpl));

        VolatileShortVault vsImpl = new VolatileShortVault();
        console.log("VolatileShort impl:", address(vsImpl));

        VolatileLongVault vlImpl = new VolatileLongVault();
        console.log("VolatileLong impl:", address(vlImpl));

        StableShortVault ssImpl = new StableShortVault();
        console.log("StableShort impl:", address(ssImpl));

        StableLongVault slImpl = new StableLongVault();
        console.log("StableLong impl:", address(slImpl));

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("EmergencyPause:    ", address(ep));
        console.log("CoverRouter impl:  ", address(routerImpl));
        console.log("PolicyManager impl:", address(pmImpl));
        console.log("VolatileShort impl:", address(vsImpl));
        console.log("VolatileLong impl: ", address(vlImpl));
        console.log("StableShort impl:  ", address(ssImpl));
        console.log("StableLong impl:   ", address(slImpl));
        console.log("");
        console.log("NEXT STEPS via Gnosis Safe:");
        console.log("1. Upgrade 6 proxies (schedule+execute upgradeToAndCall)");
        console.log("2. Grant EMERGENCY_ROLE to Safe on EmergencyPause");
        console.log("3. Set EmergencyPause address on CoverRouter + 4 vaults");
        console.log("4. Set cooldown durations (37/97/97/372)");
    }
}
