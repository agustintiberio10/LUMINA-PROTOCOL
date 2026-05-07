// ==============================================================
// [DEPRECATED — 2026-05-07]
// This script targets V1 / intermediate contract addresses (pre-V5.1
// redeploy). Do NOT execute against the current Sepolia deployment;
// running it would broadcast transactions to contracts that no longer
// exist or are no longer in the canonical registry. Kept here for
// historical reference only.
//
// Live addresses: GET https://lumina-api-production-ac85.up.railway.app/health
// ==============================================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

// ═══════════════════════════════════════════════════════════════
//  Minimal inline interfaces
// ═══════════════════════════════════════════════════════════════

/// @dev MockShieldOracle stores prices in a public mapping:
///      mapping(bytes32 => int256) public prices;
///      At construction it sets both keccak256(abi.encodePacked("BTC")) AND "BTC" keys.
///      The mock does NOT have a setPrice() by default. This script assumes
///      a setPrice(bytes32,int256) function has been added to the deployed mock,
///      OR that the deployer redeploys the mock with the function below.
///
///      If the deployed MockShieldOracle lacks setPrice(), you must either:
///        (a) Add `function setPrice(bytes32 k, int256 v) external { prices[k] = v; }`
///            to MockShieldOracle and redeploy, OR
///        (b) Use vm.store() in a local fork test (Foundry cheatcode, not on-chain).
interface IMockShieldOracle {
    function prices(bytes32 key) external view returns (int256);
    function setPrice(bytes32 key, int256 price) external;
    function getLatestPrice(bytes32 asset) external view returns (int256);
}

/**
 * @title 02_TriggerPolicy
 * @notice Testnet script: Manipulate MockShieldOracle BTC price to simulate a crash.
 *
 *         Sets BTC price to $30,000 (from default $65,000) -- a >50% crash,
 *         which exceeds the 5% trigger threshold for FlashBTC shields.
 *
 * USAGE:
 *   forge script script/testnet-tests/02_TriggerPolicy.s.sol \
 *     --rpc-url base-sepolia \
 *     --broadcast
 *
 * REQUIRED ENV:
 *   PRIVATE_KEY - deployer private key (must be mock owner / no access control on mock)
 *
 * OPTIONAL ENV:
 *   CRASH_PRICE - BTC crash price in 8 decimals (default: 30000e8 = $30,000)
 *
 * NOTE: The MockShieldOracle uses TWO key formats for BTC:
 *   1. keccak256(abi.encodePacked("BTC"))  -- used by some internal lookups
 *   2. bytes32("BTC")                      -- used by getLatestPrice in shields
 *   This script updates BOTH keys to ensure the crash price is read correctly.
 */
contract TriggerPolicyScript is Script {
    // ─── Base Sepolia deployed addresses ───
    address constant MOCK_SHIELD_ORACLE = 0xF11dDA1E81Ec766c98B673DFA7e26c75c9A1e453;

    // ─── Price constants (8 decimals, Chainlink format) ───
    int256 constant DEFAULT_CRASH_PRICE = 30_000e8; // $30,000 (>50% drop from $65K)
    int256 constant ORIGINAL_PRICE = 65_000e8; // $65,000 (original mock price)

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        int256 crashPrice = vm.envOr("CRASH_PRICE", DEFAULT_CRASH_PRICE);

        IMockShieldOracle oracle = IMockShieldOracle(MOCK_SHIELD_ORACLE);

        console.log("=== LUMINA Testnet: Trigger BTC Crash ===");
        console.log("Deployer:        ", deployer);
        console.log("");

        // Read current prices
        bytes32 keyHash = keccak256(abi.encodePacked("BTC"));
        bytes32 keyDirect = bytes32("BTC");

        int256 currentPriceHash = oracle.prices(keyHash);
        int256 currentPriceDirect = oracle.prices(keyDirect);
        int256 latestPrice = oracle.getLatestPrice(keyDirect);

        console.log("Current price (keccak key):", uint256(currentPriceHash));
        console.log("Current price (direct key):", uint256(currentPriceDirect));
        console.log("getLatestPrice('BTC'):     ", uint256(latestPrice));
        console.log("");
        console.log("Setting crash price:       ", uint256(crashPrice));
        console.log("Drop percentage:            %s%%", uint256((ORIGINAL_PRICE - crashPrice) * 100 / ORIGINAL_PRICE));

        vm.startBroadcast(privateKey);

        // Update BOTH key formats
        // Key 1: keccak256(abi.encodePacked("BTC"))
        oracle.setPrice(keyHash, crashPrice);
        console.log("[1/2] Set price for keccak256('BTC') key");

        // Key 2: bytes32("BTC") -- the raw bytes32 literal
        oracle.setPrice(keyDirect, crashPrice);
        console.log("[2/2] Set price for direct 'BTC' key");

        vm.stopBroadcast();

        // Verify
        int256 newPrice = oracle.getLatestPrice(keyDirect);
        console.log("");
        console.log("========================================");
        console.log("  BTC PRICE CRASHED TO: $%s", uint256(newPrice) / 1e8);
        console.log("========================================");
        console.log("");
        console.log("The oracle now reports a crash price.");
        console.log("Any active FlashBTC policies with a >5%% trigger will now be triggerable.");
        console.log("");
        console.log("IMPORTANT: To restore the price after testing, run:");
        console.log(
            "  CRASH_PRICE=6500000000000 forge script script/testnet-tests/02_TriggerPolicy.s.sol --rpc-url base-sepolia --broadcast"
        );
    }
}
