// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/products/BTCCatastropheShield.sol";
import "../src/products/ETHApocalypseShield.sol";

contract DeployBCSEAS is Script {
    function run() external {
        // Production addresses (Base mainnet)
        address router = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025;
        address oracle = 0x4d1140Ac8F8cB9d4fB4f16cAe9C9cBA13C44bC87;

        vm.startBroadcast();

        BTCCatastropheShield bcs = new BTCCatastropheShield(router, oracle);
        console.log("BCS deployed at:", address(bcs));

        ETHApocalypseShield eas = new ETHApocalypseShield(router, oracle);
        console.log("EAS deployed at:", address(eas));

        vm.stopBroadcast();

        console.log("--- VERIFICATION ---");
        console.log("BCS PRODUCT_ID:");
        console.logBytes32(bcs.PRODUCT_ID());
        console.log("BCS TRIGGER_DROP_BPS:", bcs.TRIGGER_DROP_BPS());
        console.log("BCS MAX_ALLOCATION_BPS:", bcs.MAX_ALLOCATION_BPS());
        console.log("EAS PRODUCT_ID:");
        console.logBytes32(eas.PRODUCT_ID());
        console.log("EAS TRIGGER_DROP_BPS:", eas.TRIGGER_DROP_BPS());
        console.log("EAS MAX_ALLOCATION_BPS:", eas.MAX_ALLOCATION_BPS());
    }
}
