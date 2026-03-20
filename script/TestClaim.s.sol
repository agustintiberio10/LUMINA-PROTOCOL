// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoverRouter} from "../src/interfaces/ICoverRouter.sol";
import {IShield} from "../src/interfaces/IShield.sol";

/**
 * @title TestClaim
 * @notice Foundry script that triggers a payout for BSS policy #1.
 *
 *         It reads the policy's strikePrice/triggerPrice from BlackSwanShield,
 *         constructs a fake oracle proof with a price below the trigger,
 *         signs it with the deployer key (= oracleKey on testnet), and calls
 *         CoverRouter.triggerPayout().
 *
 * Usage:
 *   forge script script/TestClaim.s.sol:TestClaim \
 *     --rpc-url $BASE_RPC_URL --broadcast -vvvv
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY — private key of the deployer (also the oracle signer)
 */
contract TestClaim is Script {

    // ── Deployed addresses ──────────────────────────────────────
    address constant COVER_ROUTER = 0x5755af9cd293b9A0a798B7e2e816eAbE659750C0;
    address constant BSS_SHIELD   = 0x149e1d0474a7c212a5eAA78432863B01b98479d8;
    address constant MOCK_USDC    = 0x8a342233cFC95F4AeB11c2855BFF1f441241E8d1;

    // ── BSS product ID ──────────────────────────────────────────
    bytes32 constant BSS_PRODUCT_ID = keccak256("BLACKSWAN-001");

    // ── Policy to claim ─────────────────────────────────────────
    uint256 constant POLICY_ID = 1;

    // ── BSS-specific interface for getBSSData ───────────────────
    // Mirrors BlackSwanShield.BSSData
    struct BSSData {
        bytes32 asset;
        int256  strikePrice;
        int256  triggerPrice;
    }

    function run() external {
        // ────────────────────────────────────────────────────────
        // 1. Load deployer key (deployer = oracleKey in test)
        // ────────────────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer / Oracle signer:", deployer);

        // ────────────────────────────────────────────────────────
        // 2. Read policy #1 info from BSShield
        // ────────────────────────────────────────────────────────
        IShield.PolicyInfo memory info = IShield(BSS_SHIELD).getPolicyInfo(POLICY_ID);
        console.log("=== Policy #1 Info ===");
        console.log("Insured Agent:   ", info.insuredAgent);
        console.log("Coverage Amount: ", info.coverageAmount);
        console.log("Max Payout:      ", info.maxPayout);
        console.log("Start Timestamp: ", info.startTimestamp);
        console.log("Expires At:      ", info.expiresAt);
        console.log("Status (enum):   ", uint256(info.status));

        // ────────────────────────────────────────────────────────
        // 3. Read BSS-specific data (strikePrice, triggerPrice)
        // ────────────────────────────────────────────────────────
        // Call getBSSData(uint256) on BSS_SHIELD
        (bool ok, bytes memory ret) = BSS_SHIELD.staticcall(
            abi.encodeWithSignature("getBSSData(uint256)", POLICY_ID)
        );
        require(ok, "getBSSData call failed");
        BSSData memory bss = abi.decode(ret, (BSSData));

        console.log("=== BSS Data ===");
        console.log("Asset:        ");
        console.logBytes32(bss.asset);
        console.logInt(bss.strikePrice);
        console.log("  ^ strikePrice (8 decimals)");
        console.logInt(bss.triggerPrice);
        console.log("  ^ triggerPrice (70% of strike)");

        // ────────────────────────────────────────────────────────
        // 4. Construct the oracle proof
        // ────────────────────────────────────────────────────────
        // verifiedPrice must be BELOW triggerPrice to trigger payout
        int256 verifiedPrice = (bss.strikePrice * 60) / 100; // 60% of strike (well below 70% trigger)
        bytes32 proofAsset   = bss.asset;                     // Must match policy asset
        uint256 verifiedAt   = block.timestamp;               // Must be within coverage period & fresh

        console.log("=== Oracle Proof ===");
        console.logInt(verifiedPrice);
        console.log("  ^ verifiedPrice (60% of strike)");
        console.log("verifiedAt:   ", verifiedAt);

        // ────────────────────────────────────────────────────────
        // 5. Sign the proof data
        //    Signature is over: keccak256(abi.encode(verifiedPrice, proofAsset, verifiedAt))
        //    The oracle's verifySignature does raw ECDSA.recover(digest, sig)
        // ────────────────────────────────────────────────────────
        bytes32 dataHash = keccak256(abi.encode(verifiedPrice, proofAsset, verifiedAt));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, dataHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("Proof signed. v:", v);

        // ────────────────────────────────────────────────────────
        // 6. Encode the full oracle proof
        //    Format: abi.encode(int256, bytes32, uint256, bytes)
        // ────────────────────────────────────────────────────────
        bytes memory oracleProof = abi.encode(verifiedPrice, proofAsset, verifiedAt, signature);

        // ────────────────────────────────────────────────────────
        // 7. Log balances BEFORE
        // ────────────────────────────────────────────────────────
        address recipient = info.insuredAgent;
        uint256 balBefore = IERC20(MOCK_USDC).balanceOf(recipient);
        console.log("=== Balances BEFORE ===");
        console.log("Recipient USDC:  ", balBefore);

        // ────────────────────────────────────────────────────────
        // 8. Call CoverRouter.triggerPayout(productId, policyId, oracleProof)
        // ────────────────────────────────────────────────────────
        console.log("=== Triggering Payout ===");
        console.log("ProductId:");
        console.logBytes32(BSS_PRODUCT_ID);
        console.log("PolicyId:        ", POLICY_ID);

        vm.startBroadcast(deployerKey);
        ICoverRouter(COVER_ROUTER).triggerPayout(BSS_PRODUCT_ID, POLICY_ID, oracleProof);
        vm.stopBroadcast();

        // ────────────────────────────────────────────────────────
        // 9. Log balances AFTER
        // ────────────────────────────────────────────────────────
        uint256 balAfter = IERC20(MOCK_USDC).balanceOf(recipient);
        console.log("=== Balances AFTER ===");
        console.log("Recipient USDC:  ", balAfter);

        // ────────────────────────────────────────────────────────
        // 10. Calculate and log payout breakdown
        // ────────────────────────────────────────────────────────
        uint256 grossPayout = info.maxPayout; // BSS pays 80% of coverage (binary)
        uint256 fee         = (grossPayout * 300) / 10_000; // 3% protocol fee
        uint256 netPayout   = grossPayout - fee;
        uint256 actualNet   = balAfter - balBefore;

        console.log("=== Payout Breakdown ===");
        console.log("Gross Payout (maxPayout): ", grossPayout);
        console.log("Protocol Fee (3%):        ", fee);
        console.log("Expected Net Payout:      ", netPayout);
        console.log("Actual Net Received:      ", actualNet);
        console.log("=== Claim Complete ===");
    }
}
