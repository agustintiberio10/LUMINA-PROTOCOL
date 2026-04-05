// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {LuminaOracle} from "../src/oracles/LuminaOracle.sol";
import {EmergencyPause} from "../src/core/EmergencyPause.sol";
import {BlackSwanShield} from "../src/products/BlackSwanShield.sol";
import {DepegShield} from "../src/products/DepegShield.sol";
import {ILIndexCover} from "../src/products/ILIndexCover.sol";
import {ExploitShield} from "../src/products/ExploitShield.sol";

/**
 * @title DeployFreshBatch
 * @notice Fresh deploy of non-upgradeable contracts with all security fixes.
 *         Oracle, EmergencyPause, 4 Shields.
 */
contract DeployFreshBatch is Script {
    // Production addresses
    address constant TIMELOCK = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;
    address constant SAFE = 0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD;
    address constant COVER_ROUTER = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025;
    address constant ORACLE_KEY = 0x933b15dd4F42bd2EE2794C1D188882aBCCDa977E;
    address constant SEQ_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant PHALA_VERIFIER = 0x468b9D2E9043c80467B610bC290b698ae23adb9B;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Deploy LuminaOracle (owner = Timelock)
        LuminaOracle oracle = new LuminaOracle(TIMELOCK, ORACLE_KEY, SEQ_UPTIME);
        console.log("LuminaOracle:", address(oracle));

        // 2. Deploy EmergencyPause (owner = Timelock, cooldown = 1h)
        EmergencyPause ep = new EmergencyPause(TIMELOCK, 1 hours);
        console.log("EmergencyPause:", address(ep));

        // 3. Deploy 4 Shields (router = CoverRouter proxy, oracle = new oracle)
        BlackSwanShield bss = new BlackSwanShield(COVER_ROUTER, address(oracle));
        console.log("BlackSwanShield:", address(bss));

        DepegShield depeg = new DepegShield(COVER_ROUTER, address(oracle));
        console.log("DepegShield:", address(depeg));

        ILIndexCover il = new ILIndexCover(COVER_ROUTER, address(oracle));
        console.log("ILIndexCover:", address(il));

        ExploitShield exploit = new ExploitShield(COVER_ROUTER, address(oracle), PHALA_VERIFIER, AAVE_POOL);
        console.log("ExploitShield:", address(exploit));

        vm.stopBroadcast();

        console.log("");
        console.log("=== FRESH DEPLOY BATCH ===");
        console.log("LuminaOracle:    ", address(oracle));
        console.log("EmergencyPause:  ", address(ep));
        console.log("BlackSwanShield: ", address(bss));
        console.log("DepegShield:     ", address(depeg));
        console.log("ILIndexCover:    ", address(il));
        console.log("ExploitShield:   ", address(exploit));
        console.log("");
        console.log("NEXT: Via Gnosis Safe (Timelock schedule+execute):");
        console.log("1. Oracle: registerFeed x5, grantEmergencyRole to Safe");
        console.log("2. CoverRouter: setOracle, register new products");
        console.log("3. Vaults: setEmergencyPause to new EP");
    }
}
