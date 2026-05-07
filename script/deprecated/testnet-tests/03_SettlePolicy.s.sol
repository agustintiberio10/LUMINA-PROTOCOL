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

interface IFlashBTCShield1hMinimal {
    struct PolicyInfo {
        uint256 policyId;
        address insuredAgent;
        uint256 coverageAmount;
        uint256 premiumPaid;
        uint256 maxPayout;
        uint256 startTimestamp;
        uint256 waitingEndsAt;
        uint256 expiresAt;
        uint256 cleanupAt;
        uint8 status; // PolicyStatus enum
    }

    function checkAndSettlePolicy(uint256 policyId) external;
    function getPolicyInfo(uint256 policyId) external view returns (PolicyInfo memory);
    function getPolicyStatus(uint256 policyId) external view returns (uint8);

    struct BSSData {
        bytes32 asset;
        int256 strikePrice;
        int256 triggerPrice;
    }

    function getBSSData(uint256 policyId) external view returns (BSSData memory);
}

/**
 * @title 03_SettlePolicy
 * @notice Testnet script: Call checkAndSettlePolicy on FlashBTCShield1h.
 *
 *         This is the permissionless settlement path: anyone can call it
 *         after coverage_end + SAFETY_WINDOW (24 hours).
 *
 * USAGE:
 *   POLICY_ID=1 forge script script/testnet-tests/03_SettlePolicy.s.sol \
 *     --rpc-url base-sepolia \
 *     --broadcast
 *
 * REQUIRED ENV:
 *   PRIVATE_KEY - any wallet with Base Sepolia ETH (settlement is permissionless)
 *   POLICY_ID   - the policy ID to settle (from step 01)
 *
 * IMPORTANT:
 *   This will REVERT on real testnet if 25 hours have not passed since policy
 *   creation (1h coverage + 24h SAFETY_WINDOW). The BaseShield enforces:
 *     block.timestamp >= expiresAt + SAFETY_WINDOW
 *
 *   For immediate testing, use a local fork with vm.warp():
 *     forge script script/testnet-tests/03_SettlePolicy.s.sol \
 *       --fork-url base-sepolia
 */
contract SettlePolicyScript is Script {
    // ─── Base Sepolia deployed addresses ───
    address constant FLASH_BTC_1H = 0xDcac6614E6d8CAB79bD655649B5cfdA497f80aeD;

    // ─── Status enum labels ───
    string[6] statusLabels = ["NONEXISTENT", "WAITING", "ACTIVE", "EXPIRED", "PAID_OUT", "SETTLEMENT"];

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(privateKey);
        uint256 policyId = vm.envUint("POLICY_ID");

        IFlashBTCShield1hMinimal shield = IFlashBTCShield1hMinimal(FLASH_BTC_1H);

        console.log("=== LUMINA Testnet: Settle Policy ===");
        console.log("Caller:     ", caller);
        console.log("Policy ID:  ", policyId);
        console.log("");

        // Read policy info before settlement
        IFlashBTCShield1hMinimal.PolicyInfo memory info = shield.getPolicyInfo(policyId);
        IFlashBTCShield1hMinimal.BSSData memory bss = shield.getBSSData(policyId);

        console.log("--- Policy Details ---");
        console.log("Insured:        ", info.insuredAgent);
        console.log("Coverage:       ", info.coverageAmount);
        console.log("Max Payout:     ", info.maxPayout);
        console.log("Started:        ", info.startTimestamp);
        console.log("Expires:        ", info.expiresAt);
        console.log("CleanupAt:      ", info.cleanupAt);
        console.log("Status:         ", statusLabels[info.status]);
        console.log("");
        console.log("--- Trigger Data ---");
        console.log("Strike Price:   ", uint256(bss.strikePrice));
        console.log("Trigger Price:  ", uint256(bss.triggerPrice));
        console.log("");

        // Check timing
        uint256 safetyWindow = 24 hours;
        uint256 earliest = info.expiresAt + safetyWindow;

        if (block.timestamp < earliest) {
            uint256 wait = earliest - block.timestamp;
            console.log("WARNING: Safety window has NOT passed yet!");
            console.log("Earliest settlement: ", earliest);
            console.log("Current time:        ", block.timestamp);
            console.log("Wait remaining:       %s seconds (%s hours)", wait, wait / 3600);
            console.log("");
            console.log("The transaction WILL REVERT with SafetyWindowNotPassed.");
            console.log("To test locally, use --fork-url and vm.warp().");
            console.log("");
        }

        // Attempt settlement
        console.log("Attempting checkAndSettlePolicy...");

        vm.startBroadcast(privateKey);
        shield.checkAndSettlePolicy(policyId);
        vm.stopBroadcast();

        // Read post-settlement status
        uint8 newStatus = shield.getPolicyStatus(policyId);

        console.log("");
        console.log("========================================");
        console.log("  SETTLEMENT COMPLETE");
        console.log("  New Status: %s", statusLabels[newStatus]);
        if (newStatus == 4) {
            console.log("  >> TRIGGERED: Payout bonds minted!");
            console.log("  >> Check ClaimBond balance with 04_VerifyNFT.s.sol");
        } else {
            console.log("  >> EXPIRED: No trigger condition met.");
        }
        console.log("========================================");
    }
}
