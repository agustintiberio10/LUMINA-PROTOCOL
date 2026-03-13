// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockUSDY} from "../src/mocks/MockUSDY.sol";
import {LuminaOracle} from "../src/oracles/LuminaOracle.sol";
import {LuminaPhalaVerifier} from "../src/oracles/LuminaPhalaVerifier.sol";

// Import proxies for UUPS
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployLumina is Script {

    // Deployer = owner = fee receiver for testnet
    // Oracle key = deployer key for testnet (signs quotes)
    // Phala worker = deployer key for testnet (signs attestations)

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════
        // 1. MockUSDY (testnet only)
        // ═══════════════════════════════════════════
        MockUSDY usdy = new MockUSDY();
        usdy.mint(deployer, 1_000_000e6); // 1M USDY for testing
        console.log("MockUSDY:", address(usdy));

        // ═══════════════════════════════════════════
        // 2. Oracle (non-upgradeable)
        // ═══════════════════════════════════════════
        LuminaOracle oracle = new LuminaOracle(
            deployer,           // owner
            deployer,           // oracleKey (deployer signs quotes on testnet)
            address(0)          // no sequencer feed on testnet
        );
        console.log("LuminaOracle:", address(oracle));

        // Register Chainlink feeds (Base Sepolia)
        // Note: Base Sepolia may not have all feeds. Use address(0) and skip for now.
        // We'll register real feeds after verifying availability.

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
        console.log("MockUSDY:", address(usdy));
        console.log("Oracle:", address(oracle));
        console.log("PhalaVerifier:", address(phala));
        console.log("---");
        console.log("NEXT: Deploy UUPS proxies for CoverRouter, PolicyManager, and Vaults");
        console.log("These require the above addresses as constructor args");

        vm.stopBroadcast();
    }
}
