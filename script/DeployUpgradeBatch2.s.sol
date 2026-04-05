// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CoverRouter} from "../src/core/CoverRouter.sol";
import {PolicyManager} from "../src/core/PolicyManager.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {StableLongVault} from "../src/vaults/StableLongVault.sol";

/**
 * @title DeployUpgradeBatch2
 * @notice Deploy new UUPS implementations for all security fixes.
 *         After deploy, upgrade proxies via Gnosis Safe + TimelockController.
 *
 * Proxies upgraded:
 *   - CoverRouter: Option E veto, H-3 two-phase, N-4 fallback, L-2 dedup
 *   - PolicyManager: C-2 gap, M-5 underflow event, L-3 cleanProductIds
 *   - 4 Vaults: Option E no-pause payout, H-7 try/catch, M-4 irrevocable
 *
 * NOT upgraded (non-upgradeable, need fresh deploy separately):
 *   - LuminaOracle, EmergencyPause, 4 Shields
 */
contract DeployUpgradeBatch2 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

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
        console.log("=== UPGRADE BATCH 2 - NEW IMPLEMENTATIONS ===");
        console.log("CoverRouter:  ", address(routerImpl));
        console.log("PolicyManager:", address(pmImpl));
        console.log("VolatileShort:", address(vsImpl));
        console.log("VolatileLong: ", address(vlImpl));
        console.log("StableShort:  ", address(ssImpl));
        console.log("StableLong:   ", address(slImpl));
    }
}
