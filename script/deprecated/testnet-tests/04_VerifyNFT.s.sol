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

interface IClaimBondMinimal {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function epochExists(uint256 epochId) external view returns (bool);
    function maturityDate(uint256 epochId) external view returns (uint256);
    function totalSupply(uint256 id) external view returns (uint256);
    function uri(uint256 id) external view returns (string memory);
}

/**
 * @title 04_VerifyNFT
 * @notice View-only script (no broadcast): Check ClaimBond (ERC-1155) balance.
 *
 *         ClaimBond tokens represent $1 USD of future payout per token.
 *         Token IDs are epoch-based: YYYYMM format (e.g., 202604 = April 2026).
 *
 * USAGE:
 *   HOLDER=0xYourAddress EPOCH_ID=202604 \
 *     forge script script/testnet-tests/04_VerifyNFT.s.sol \
 *     --rpc-url base-sepolia
 *
 * REQUIRED ENV:
 *   HOLDER   - address to check balance for
 *   EPOCH_ID - epoch/token ID to query (YYYYMM format, e.g., 202604)
 *
 * NOTE: This is a VIEW script -- no broadcast, no gas, no signing needed.
 *       It only reads state from the blockchain.
 */
contract VerifyNFTScript is Script {
    // ─── Base Sepolia deployed addresses ───
    address constant CLAIM_BOND = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025;

    // ─── Base Sepolia chain info ───
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;

    function run() external view {
        address holder = vm.envAddress("HOLDER");
        uint256 epochId = vm.envUint("EPOCH_ID");

        IClaimBondMinimal bond = IClaimBondMinimal(CLAIM_BOND);

        console.log("=== LUMINA Testnet: Verify ClaimBond NFT ===");
        console.log("ClaimBond:   ", CLAIM_BOND);
        console.log("Holder:      ", holder);
        console.log("Epoch ID:    ", epochId);
        console.log("");

        // Check if epoch exists
        bool exists = bond.epochExists(epochId);
        console.log("Epoch exists:", exists);

        if (!exists) {
            console.log("");
            console.log("This epoch has not been created yet.");
            console.log("Bonds are only minted when a policy triggers a payout.");
            console.log("Run scripts 01-03 first to create a triggered policy.");
            return;
        }

        // Read maturity date
        uint256 maturity = bond.maturityDate(epochId);
        console.log("Maturity:    ", maturity);

        // Read balance
        uint256 balance = bond.balanceOf(holder, epochId);
        console.log("");
        console.log("========================================");
        console.log("  BOND BALANCE: %s tokens", balance);
        console.log("  USD VALUE:    $%s", balance);
        console.log("========================================");

        if (balance == 0) {
            console.log("");
            console.log("No bonds found for this holder/epoch combination.");
            console.log("Possible reasons:");
            console.log("  - Policy was not triggered (expired without crash)");
            console.log("  - Wrong epoch ID (try a different YYYYMM)");
            console.log("  - Wrong holder address");
        } else {
            console.log("");
            console.log("Bonds found! To verify on-chain and in wallet:");
        }

        // Read total supply for this epoch
        uint256 supply = bond.totalSupply(epochId);
        console.log("");
        console.log("Total supply for epoch %s: %s tokens", epochId, supply);

        // Instructions for MetaMask
        console.log("");
        console.log("=== HOW TO SEE IN METAMASK ===");
        console.log("");
        console.log("1. Open MetaMask and switch to Base Sepolia network");
        console.log("2. Go to NFTs tab");
        console.log("3. Click 'Import NFT'");
        console.log("4. Enter:");
        console.log("   Contract: 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025");
        console.log("   Token ID: %s", epochId);
        console.log("5. Click 'Import'");
        console.log("");
        console.log("NOTE: MetaMask may show ERC-1155 tokens under 'NFTs'.");
        console.log("      Each token = $1 USD of claim bond at maturity.");
        console.log("");
        console.log("=== HOW TO SEE ON BASESCAN ===");
        console.log("");
        console.log("Visit:");
        console.log("  https://sepolia.basescan.org/address/0xd5f8678A0F2149B6342F9014CCe6d743234Ca025");
        console.log("");
        console.log("Or check holder's token page:");
        console.log("  https://sepolia.basescan.org/token/0xd5f8678A0F2149B6342F9014CCe6d743234Ca025?a=%s", holder);
    }
}
