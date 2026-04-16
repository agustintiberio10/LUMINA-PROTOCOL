// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {StableLongVault} from "../src/vaults/StableLongVault.sol";

/**
 * @title DeployNewImpls
 * @notice Deploy new vault implementations with setCooldownDuration + perfFee queue fix.
 *         After deploying, upgrade proxies via Gnosis Safe + TimelockController.
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=0x... \
 *   forge script script/DeployNewImpls.s.sol:DeployNewImpls \
 *     --rpc-url https://mainnet.base.org --broadcast -vvvv
 */
contract DeployNewImpls is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        vm.startBroadcast(deployerKey);

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
        console.log("=== NEW IMPLEMENTATIONS ===");
        console.log("VolatileShort:", address(vsImpl));
        console.log("VolatileLong:", address(vlImpl));
        console.log("StableShort:", address(ssImpl));
        console.log("StableLong:", address(slImpl));
        console.log("");
        console.log("Next: upgrade proxies via Gnosis Safe, then call setCooldownDuration on each");
    }
}
