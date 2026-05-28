// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {LuminaOracleV2} from "../src/oracles/LuminaOracleV2.sol";

contract DeployOracleV2Sepolia is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address signer = vm.envAddress("ORACLE_SIGNER_ADDRESS");
        address owner = vm.addr(deployerKey);

        console.log("=== Deploy LuminaOracleV2 (Base Sepolia 84532) ===");
        console.log("Owner:", owner);
        console.log("Signer:", signer);

        require(block.chainid == 84532, "wrong chain");

        vm.startBroadcast(deployerKey);
        LuminaOracleV2 oracle = new LuminaOracleV2(owner, signer, address(0));
        vm.stopBroadcast();

        console.log("LuminaOracleV2 deployed:", address(oracle));
        console.log("oracleKey():", oracle.oracleKey());
        require(oracle.oracleKey() == signer, "signer mismatch");
        console.log("OK signer matches");
    }
}
