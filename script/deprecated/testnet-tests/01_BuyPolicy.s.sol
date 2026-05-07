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
//  Minimal inline interfaces (no full contract imports)
// ═══════════════════════════════════════════════════════════════

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

interface ICoverRouterV2Minimal {
    function purchasePolicy(bytes32 productId, uint256 coverageAmount, bytes32 asset)
        external
        returns (uint256 policyId);
}

/**
 * @title 01_BuyPolicy
 * @notice Testnet script: Buy a FlashBTC1H policy on Base Sepolia.
 *
 * USAGE:
 *   forge script script/testnet-tests/01_BuyPolicy.s.sol \
 *     --rpc-url base-sepolia \
 *     --broadcast
 *
 * REQUIRED ENV:
 *   PRIVATE_KEY  - deployer/tester private key (must have ETH + mUSDC)
 *
 * OPTIONAL ENV:
 *   COVERAGE_AMOUNT - coverage in USDC raw units (default: 1000e6 = $1,000)
 */
contract BuyPolicyScript is Script {
    // ─── Base Sepolia deployed addresses ───
    address constant COVER_ROUTER = 0x71DBcE71AA36370f7357F6D8E0c8ba96343C8306;
    address constant MOCK_USDC = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;

    // ─── Product constants ───
    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-001");
    bytes32 constant ASSET_BTC = "BTC";

    // ─── Default coverage: $1,000 USDC (6 decimals) ───
    uint256 constant DEFAULT_COVERAGE = 1000e6;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address buyer = vm.addr(privateKey);

        // Allow override via env
        uint256 coverageAmount = vm.envOr("COVERAGE_AMOUNT", DEFAULT_COVERAGE);

        console.log("=== LUMINA Testnet: Buy FlashBTC1H Policy ===");
        console.log("Buyer:           ", buyer);
        console.log("Coverage (raw):  ", coverageAmount);
        console.log("Coverage (USD):  $%s", coverageAmount / 1e6);
        console.log("");

        IERC20Minimal usdc = IERC20Minimal(MOCK_USDC);
        ICoverRouterV2Minimal router = ICoverRouterV2Minimal(COVER_ROUTER);

        // Check balance
        uint256 balance = usdc.balanceOf(buyer);
        console.log("mUSDC balance:   ", balance);

        // If insufficient balance, mint more (MockUSDC has public mint)
        if (balance < coverageAmount) {
            console.log(">> Minting mUSDC to cover premium...");
            vm.startBroadcast(privateKey);
            usdc.mint(buyer, coverageAmount * 2);
            vm.stopBroadcast();
            console.log(">> Minted. New balance:", usdc.balanceOf(buyer));
        }

        vm.startBroadcast(privateKey);

        // Step 1: Approve CoverRouter to spend USDC (premium)
        // Approve a generous amount to avoid re-approvals
        usdc.approve(COVER_ROUTER, type(uint256).max);
        console.log("[1/2] Approved CoverRouter for mUSDC");

        // Step 2: Purchase policy
        uint256 policyId = router.purchasePolicy(PRODUCT_ID, coverageAmount, ASSET_BTC);

        console.log("[2/2] Policy purchased!");
        console.log("");
        console.log("========================================");
        console.log("  POLICY ID: ", policyId);
        console.log("========================================");
        console.log("");
        console.log("Save this policy ID for the next scripts:");
        console.log("  export POLICY_ID=%s", policyId);

        vm.stopBroadcast();
    }
}
