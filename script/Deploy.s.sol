// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaOracle} from "../src/oracles/LuminaOracle.sol";
import {LuminaPhalaVerifier} from "../src/oracles/LuminaPhalaVerifier.sol";

contract DeployLumina is Script {

    // Deployer = owner = fee receiver for testnet
    // Oracle key = deployer key for testnet (signs quotes)
    // Phala worker = deployer key for testnet (signs attestations)

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════
        // 1. USDC token reference (native USDC on Base)
        // ═══════════════════════════════════════════
        // NOTE: On mainnet, use the actual USDC contract address on Base
        // For testnet, deploy a mock ERC20 separately
        address usdc = vm.envAddress("USDC_ADDRESS");
        console.log("USDC:", usdc);

        // ═══════════════════════════════════════════
        // 2. Oracle (non-upgradeable)
        // ═══════════════════════════════════════════
        LuminaOracle oracle = new LuminaOracle(
            deployer,           // owner
            deployer,           // oracleKey (deployer signs quotes on testnet)
            address(0)          // no sequencer feed on testnet
        );
        console.log("LuminaOracle:", address(oracle));

        // ═══════════════════════════════════════════
        // 3. PhalaVerifier (non-upgradeable)
        // ═══════════════════════════════════════════
        LuminaPhalaVerifier phala = new LuminaPhalaVerifier(
            deployer,           // owner
            deployer            // initial worker (deployer signs attestations on testnet)
        );
        console.log("PhalaVerifier:", address(phala));

        // ═══════════════════════════════════════════
        // 4. Log all addresses
        // ═══════════════════════════════════════════
        console.log("--- DEPLOYMENT COMPLETE ---");
        console.log("Deployer:", deployer);
        console.log("USDC:", usdc);
        console.log("Oracle:", address(oracle));
        console.log("PhalaVerifier:", address(phala));
        console.log("---");
        console.log("NEXT: Run DeployUUPS.s.sol with these addresses as env vars");

        vm.stopBroadcast();
    }
}
