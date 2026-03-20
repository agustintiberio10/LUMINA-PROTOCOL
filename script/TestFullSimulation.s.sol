// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoverRouter} from "../src/interfaces/ICoverRouter.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IShield} from "../src/interfaces/IShield.sol";

/**
 * @title TestFullSimulation
 * @notice Comprehensive Foundry script that simulates multiple Lumina operations
 *         on Base Mainnet: 5 BSS purchases, 1 of each other product, withdrawal
 *         request, BSS claim, and final summary.
 *
 * Usage:
 *   forge script script/TestFullSimulation.s.sol:TestFullSimulation \
 *     --rpc-url $BASE_RPC_URL --broadcast -vvvv
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY — private key of the deployer (also the oracle signer)
 */
contract TestFullSimulation is Script {

    // ═══════════════════════════════════════════════════════════════
    //  DEPLOYED ADDRESSES (test deployment on Base Mainnet)
    // ═══════════════════════════════════════════════════════════════

    address constant COVER_ROUTER     = 0x5755af9cd293b9A0a798B7e2e816eAbE659750C0;
    address constant MOCK_USDC        = 0x8a342233cFC95F4AeB11c2855BFF1f441241E8d1;
    address constant VOLATILE_SHORT   = 0xe74d19551cbB809AaDcAb568c0E150B6BF0e3354;
    address constant POLICY_MANAGER   = 0x5B337325b854a68Cd262aa2b6fE48EBe18073902;
    address constant BSS_SHIELD       = 0x149e1d0474a7c212a5eAA78432863B01b98479d8;
    address constant DEPEG_SHIELD     = 0xaD1EB669b4a9DC6C9432B904F65B360962E1d381;
    address constant IL_INDEX_SHIELD  = 0xc2262311eD02E9c937cBC33F34426D5D9134F6CF;
    address constant EXPLOIT_SHIELD   = 0x931427cED326eB49a3E5268b9b3e713Eb2EC5440;

    // ═══════════════════════════════════════════════════════════════
    //  PRODUCT IDs (must match on-chain registrations)
    // ═══════════════════════════════════════════════════════════════

    bytes32 constant BSS_PRODUCT_ID     = keccak256("BLACKSWAN-001");
    bytes32 constant DEPEG_PRODUCT_ID   = keccak256("DEPEG-STABLE-001");
    bytes32 constant IL_PRODUCT_ID      = keccak256("ILPROT-001");
    bytes32 constant EXPLOIT_PRODUCT_ID = keccak256("EXPLOIT-001");

    // ═══════════════════════════════════════════════════════════════
    //  EIP-712 TYPE HASHES (must match CoverRouter exactly)
    // ═══════════════════════════════════════════════════════════════

    bytes32 constant QUOTE_TYPEHASH = keccak256(
        "SignedQuote("
        "bytes32 productId,"
        "uint256 coverageAmount,"
        "uint256 premiumAmount,"
        "uint32 durationSeconds,"
        "bytes32 asset,"
        "bytes32 stablecoin,"
        "address protocol,"
        "address buyer,"
        "uint256 deadline,"
        "uint256 nonce"
        ")"
    );

    bytes32 constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // ═══════════════════════════════════════════════════════════════
    //  PREMIUM MATH CONSTANTS (mirror PremiumMath.sol)
    // ═══════════════════════════════════════════════════════════════

    uint256 constant WAD              = 1e18;
    uint256 constant SECONDS_PER_YEAR = 31_536_000;
    uint256 constant U_KINK           = 8000;
    uint256 constant R_SLOPE1_WAD     = 5e17;
    uint256 constant R_SLOPE2_WAD     = 3e18;
    uint256 constant U_MAX            = 9500;
    uint256 constant BPS              = 10_000;

    // BSS pricing params
    uint256 constant BSS_P_BASE_BPS            = 2200;
    uint256 constant BSS_RISK_MULT_BPS         = 10_000;
    uint256 constant BSS_DURATION_DISCOUNT_BPS = 10_000;

    // ═══════════════════════════════════════════════════════════════
    //  BSS DATA STRUCT (for reading from BlackSwanShield)
    // ═══════════════════════════════════════════════════════════════

    struct BSSData {
        bytes32 asset;
        int256  strikePrice;
        int256  triggerPrice;
    }

    // ═══════════════════════════════════════════════════════════════
    //  STATE — nonce counter
    // ═══════════════════════════════════════════════════════════════

    uint256 private _nonceCounter;

    // ═══════════════════════════════════════════════════════════════
    //  MAIN ENTRY POINT
    // ═══════════════════════════════════════════════════════════════

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("========================================");
        console.log("  LUMINA FULL SIMULATION");
        console.log("========================================");
        console.log("Deployer / Oracle signer:", deployer);
        console.log("Block timestamp:", block.timestamp);

        // Initialize nonce counter from block.timestamp to guarantee uniqueness
        _nonceCounter = block.timestamp * 100;

        // Ensure USDC allowance to CoverRouter (max approve once)
        vm.startBroadcast(deployerKey);
        uint256 currentAllowance = IERC20(MOCK_USDC).allowance(deployer, COVER_ROUTER);
        if (currentAllowance < type(uint128).max) {
            IERC20(MOCK_USDC).approve(COVER_ROUTER, type(uint256).max);
            console.log("Approved USDC (max) to CoverRouter");
        }
        vm.stopBroadcast();

        // ══════════════════════════════════════════════════════════
        //  PART 1: Buy 5 BSS policies ($1,000 each, 14 days)
        // ══════════════════════════════════════════════════════════
        console.log("");
        console.log("========================================");
        console.log("  PART 1: Buy 5 BSS Policies");
        console.log("========================================");

        uint256 totalBSSPremium = 0;
        uint256[] memory bssPolicyIds = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            console.log("");
            console.log("--- BSS Policy", i + 1, "of 5 ---");

            // Read vault state before purchase
            IVault.VaultState memory vsBefore = IVault(VOLATILE_SHORT).getVaultState();
            console.log("  [Before] totalAssets:    ", vsBefore.totalAssets);
            console.log("  [Before] allocatedAssets:", vsBefore.allocatedAssets);
            console.log("  [Before] utilizationBps: ", vsBefore.utilizationBps);

            // Calculate premium using current utilization
            uint256 coverageAmount = 1_000_000_000; // $1,000 in 6 decimals
            uint32 duration = 1_209_600; // 14 days
            uint256 premium = _calculatePremium(
                coverageAmount,
                BSS_P_BASE_BPS,
                BSS_RISK_MULT_BPS,
                BSS_DURATION_DISCOUNT_BPS,
                vsBefore.utilizationBps,
                duration
            );
            console.log("  Calculated premium:", premium);

            // Sign and purchase
            uint256 nonce = _nextNonce();
            ICoverRouter.SignedQuote memory quote = ICoverRouter.SignedQuote({
                productId:       BSS_PRODUCT_ID,
                coverageAmount:  coverageAmount,
                premiumAmount:   premium,
                durationSeconds: duration,
                asset:           bytes32("ETH"),
                stablecoin:      bytes32("USDC"),
                protocol:        address(0),
                buyer:           deployer,
                deadline:        block.timestamp + 300,
                nonce:           nonce
            });

            bytes memory sig = _signQuote(quote, deployerKey);

            vm.startBroadcast(deployerKey);
            ICoverRouter.PurchaseResult memory result = ICoverRouter(COVER_ROUTER).purchasePolicy(quote, sig);
            vm.stopBroadcast();

            bssPolicyIds[i] = result.policyId;
            totalBSSPremium += result.premiumPaid;

            console.log("  Policy ID:      ", result.policyId);
            console.log("  Premium Paid:   ", result.premiumPaid);

            // Read vault state after purchase
            IVault.VaultState memory vsAfter = IVault(VOLATILE_SHORT).getVaultState();
            console.log("  [After] utilizationBps:", vsAfter.utilizationBps);
        }

        // Part 1 summary
        console.log("");
        console.log("--- Part 1 Summary ---");
        console.log("Total BSS Premiums Collected:", totalBSSPremium);
        IVault.VaultState memory vsP1 = IVault(VOLATILE_SHORT).getVaultState();
        console.log("Final Vault totalAssets:     ", vsP1.totalAssets);
        console.log("Final Vault allocatedAssets: ", vsP1.allocatedAssets);
        console.log("Final Vault utilizationBps:  ", vsP1.utilizationBps);

        // ══════════════════════════════════════════════════════════
        //  PART 2: Buy 1 of each other product
        // ══════════════════════════════════════════════════════════
        console.log("");
        console.log("========================================");
        console.log("  PART 2: Buy 1 of Each Other Product");
        console.log("========================================");

        // --- DEPEG: $500, 30 days, stablecoin=USDT ---
        console.log("");
        console.log("--- DEPEG Policy ---");
        {
            uint256 depegCoverage = 500_000_000; // $500
            uint32 depegDuration = 2_592_000;    // 30 days
            uint256 depegPremium = _calculatePremium(
                depegCoverage,
                2200, // P_base (placeholder — same kink model)
                10_000,
                10_000,
                0,    // Use 0 utilization as approximation
                depegDuration
            );
            // Ensure premium passes minimum check (>= coverage/1000)
            uint256 minPremium = depegCoverage / 1000;
            if (depegPremium < minPremium) depegPremium = minPremium;

            ICoverRouter.SignedQuote memory depegQuote = ICoverRouter.SignedQuote({
                productId:       DEPEG_PRODUCT_ID,
                coverageAmount:  depegCoverage,
                premiumAmount:   depegPremium,
                durationSeconds: depegDuration,
                asset:           bytes32("USDT"),       // asset = USDT for Depeg
                stablecoin:      bytes32("USDT"),       // stablecoin = USDT
                protocol:        address(0),
                buyer:           deployer,
                deadline:        block.timestamp + 300,
                nonce:           _nextNonce()
            });

            bytes memory depegSig = _signQuote(depegQuote, deployerKey);

            vm.startBroadcast(deployerKey);
            try ICoverRouter(COVER_ROUTER).purchasePolicy(depegQuote, depegSig) returns (
                ICoverRouter.PurchaseResult memory depegResult
            ) {
                console.log("  DEPEG Policy ID:    ", depegResult.policyId);
                console.log("  DEPEG Premium Paid: ", depegResult.premiumPaid);
                console.log("  DEPEG Vault:        ", depegResult.vault);
                console.log("  DEPEG Expires At:   ", depegResult.expiresAt);
            } catch (bytes memory reason) {
                console.log("  DEPEG REVERTED (may need oracle feed or vault)");
                console.logBytes(reason);
            }
            vm.stopBroadcast();
        }

        // --- IL INDEX: $1,000, 30 days, asset=ETH ---
        console.log("");
        console.log("--- IL INDEX Policy ---");
        {
            uint256 ilCoverage = 1_000_000_000; // $1,000
            uint32 ilDuration = 2_592_000;      // 30 days
            uint256 ilPremium = _calculatePremium(
                ilCoverage, 2200, 10_000, 10_000, 0, ilDuration
            );
            uint256 minPremium = ilCoverage / 1000;
            if (ilPremium < minPremium) ilPremium = minPremium;

            ICoverRouter.SignedQuote memory ilQuote = ICoverRouter.SignedQuote({
                productId:       IL_PRODUCT_ID,
                coverageAmount:  ilCoverage,
                premiumAmount:   ilPremium,
                durationSeconds: ilDuration,
                asset:           bytes32("ETH"),
                stablecoin:      bytes32("USDC"),
                protocol:        address(0),
                buyer:           deployer,
                deadline:        block.timestamp + 300,
                nonce:           _nextNonce()
            });

            bytes memory ilSig = _signQuote(ilQuote, deployerKey);

            vm.startBroadcast(deployerKey);
            try ICoverRouter(COVER_ROUTER).purchasePolicy(ilQuote, ilSig) returns (
                ICoverRouter.PurchaseResult memory ilResult
            ) {
                console.log("  IL Policy ID:    ", ilResult.policyId);
                console.log("  IL Premium Paid: ", ilResult.premiumPaid);
                console.log("  IL Vault:        ", ilResult.vault);
                console.log("  IL Expires At:   ", ilResult.expiresAt);
            } catch (bytes memory reason) {
                console.log("  IL INDEX REVERTED (may need oracle feed)");
                console.logBytes(reason);
            }
            vm.stopBroadcast();
        }

        // --- EXPLOIT: $2,000, 90 days, protocol=address(1), asset=ETH ---
        console.log("");
        console.log("--- EXPLOIT Policy ---");
        {
            uint256 exploitCoverage = 2_000_000_000; // $2,000
            uint32 exploitDuration = 7_776_000;      // 90 days
            uint256 exploitPremium = _calculatePremium(
                exploitCoverage, 2200, 10_000, 10_000, 0, exploitDuration
            );
            uint256 minPremium = exploitCoverage / 1000;
            if (exploitPremium < minPremium) exploitPremium = minPremium;

            ICoverRouter.SignedQuote memory exploitQuote = ICoverRouter.SignedQuote({
                productId:       EXPLOIT_PRODUCT_ID,
                coverageAmount:  exploitCoverage,
                premiumAmount:   exploitPremium,
                durationSeconds: exploitDuration,
                asset:           bytes32("ETH"),        // repurposed as protocolId
                stablecoin:      bytes32("USDC"),
                protocol:        address(1),            // dummy non-Aave address
                buyer:           deployer,
                deadline:        block.timestamp + 300,
                nonce:           _nextNonce()
            });

            bytes memory exploitSig = _signQuote(exploitQuote, deployerKey);

            vm.startBroadcast(deployerKey);
            try ICoverRouter(COVER_ROUTER).purchasePolicy(exploitQuote, exploitSig) returns (
                ICoverRouter.PurchaseResult memory exploitResult
            ) {
                console.log("  EXPLOIT Policy ID:    ", exploitResult.policyId);
                console.log("  EXPLOIT Premium Paid: ", exploitResult.premiumPaid);
                console.log("  EXPLOIT Vault:        ", exploitResult.vault);
                console.log("  EXPLOIT Expires At:   ", exploitResult.expiresAt);
            } catch (bytes memory reason) {
                console.log("  EXPLOIT REVERTED (may need oracle feed or Phala verifier)");
                console.logBytes(reason);
            }
            vm.stopBroadcast();
        }

        // ══════════════════════════════════════════════════════════
        //  PART 3: Request Withdrawal (no time warp)
        // ══════════════════════════════════════════════════════════
        console.log("");
        console.log("========================================");
        console.log("  PART 3: Request Withdrawal");
        console.log("========================================");

        {
            IVault vault = IVault(VOLATILE_SHORT);
            uint256 deployerShares = IERC20(VOLATILE_SHORT).balanceOf(deployer);
            console.log("Deployer shares in VolatileShort:", deployerShares);

            if (deployerShares > 0) {
                // Request withdrawal of 10% of shares (or all if very small)
                uint256 sharesToWithdraw = deployerShares / 10;
                if (sharesToWithdraw == 0) sharesToWithdraw = deployerShares;

                console.log("Requesting withdrawal of shares:", sharesToWithdraw);

                vm.startBroadcast(deployerKey);
                try vault.requestWithdrawal(sharesToWithdraw) {
                    console.log("Withdrawal request submitted successfully");
                } catch (bytes memory reason) {
                    console.log("Withdrawal request REVERTED (may already have pending request)");
                    console.logBytes(reason);
                }
                vm.stopBroadcast();

                // Read the withdrawal request to show cooldown end
                IVault.WithdrawalRequest memory wr = vault.getWithdrawalRequest(deployer);
                console.log("Withdrawal shares:    ", wr.shares);
                console.log("Cooldown ends at:     ", wr.cooldownEnd);
                console.log("Current timestamp:    ", block.timestamp);
                if (wr.cooldownEnd > block.timestamp) {
                    console.log("Seconds remaining:    ", wr.cooldownEnd - block.timestamp);
                }
                console.log("NOTE: Cannot complete -- need to wait 30 days for cooldown");
            } else {
                console.log("No shares to withdraw. Skipping.");
            }
        }

        // ══════════════════════════════════════════════════════════
        //  PART 4: Trigger BSS Claim on Policy #2
        // ══════════════════════════════════════════════════════════
        console.log("");
        console.log("========================================");
        console.log("  PART 4: Trigger BSS Claim (Policy #2)");
        console.log("========================================");

        {
            // Use the second BSS policy from Part 1
            uint256 claimPolicyId = bssPolicyIds[1];
            console.log("Claiming on Policy ID:", claimPolicyId);

            // Read policy info
            IShield.PolicyInfo memory pInfo = IShield(BSS_SHIELD).getPolicyInfo(claimPolicyId);
            console.log("Insured Agent:   ", pInfo.insuredAgent);
            console.log("Coverage Amount: ", pInfo.coverageAmount);
            console.log("Max Payout:      ", pInfo.maxPayout);
            console.log("Status (enum):   ", uint256(pInfo.status));

            // Read BSS data (strikePrice, triggerPrice)
            (bool ok, bytes memory ret) = BSS_SHIELD.staticcall(
                abi.encodeWithSignature("getBSSData(uint256)", claimPolicyId)
            );
            require(ok, "getBSSData call failed");
            BSSData memory bss = abi.decode(ret, (BSSData));

            console.log("Asset:");
            console.logBytes32(bss.asset);
            console.logInt(bss.strikePrice);
            console.log("  ^ strikePrice (8 decimals)");
            console.logInt(bss.triggerPrice);
            console.log("  ^ triggerPrice (70% of strike)");

            // Create fake price at 60% of strike (below the 70% trigger)
            int256 verifiedPrice = (bss.strikePrice * 60) / 100;
            bytes32 proofAsset = bss.asset;
            uint256 verifiedAt = block.timestamp;

            console.log("=== Oracle Proof ===");
            console.logInt(verifiedPrice);
            console.log("  ^ verifiedPrice (60% of strike)");

            // Sign the proof data
            bytes32 dataHash = keccak256(abi.encode(verifiedPrice, proofAsset, verifiedAt));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, dataHash);
            bytes memory proofSig = abi.encodePacked(r, s, v);

            // Encode full oracle proof
            bytes memory oracleProof = abi.encode(verifiedPrice, proofAsset, verifiedAt, proofSig);

            // Record balances before
            uint256 balBefore = IERC20(MOCK_USDC).balanceOf(pInfo.insuredAgent);
            console.log("Recipient USDC before:", balBefore);

            // Trigger payout
            vm.startBroadcast(deployerKey);
            try ICoverRouter(COVER_ROUTER).triggerPayout(BSS_PRODUCT_ID, claimPolicyId, oracleProof) {
                console.log("Payout triggered successfully!");
            } catch (bytes memory reason) {
                console.log("triggerPayout REVERTED");
                console.logBytes(reason);
            }
            vm.stopBroadcast();

            // Record balances after
            uint256 balAfter = IERC20(MOCK_USDC).balanceOf(pInfo.insuredAgent);
            console.log("Recipient USDC after: ", balAfter);

            if (balAfter > balBefore) {
                uint256 actualPayout = balAfter - balBefore;
                uint256 grossPayout = pInfo.maxPayout;
                uint256 fee = (grossPayout * 300) / 10_000;
                uint256 expectedNet = grossPayout - fee;

                console.log("=== Payout Breakdown ===");
                console.log("Gross Payout (maxPayout):", grossPayout);
                console.log("Protocol Fee (3%):       ", fee);
                console.log("Expected Net Payout:     ", expectedNet);
                console.log("Actual Net Received:     ", actualPayout);
            }
        }

        // ══════════════════════════════════════════════════════════
        //  PART 5: Final Summary
        // ══════════════════════════════════════════════════════════
        console.log("");
        console.log("========================================");
        console.log("  PART 5: Final Summary");
        console.log("========================================");

        // Log VolatileShort vault state
        {
            IVault.VaultState memory vs = IVault(VOLATILE_SHORT).getVaultState();
            console.log("VolatileShort totalAssets:    ", vs.totalAssets);
            console.log("VolatileShort allocatedAssets:", vs.allocatedAssets);
            console.log("VolatileShort freeAssets:     ", vs.freeAssets);
            console.log("VolatileShort utilizationBps: ", vs.utilizationBps);
        }

        // Log deployer USDC balance
        uint256 deployerUSDC = IERC20(MOCK_USDC).balanceOf(deployer);
        console.log("");
        console.log("Deployer USDC Balance:", deployerUSDC);
        console.log("");
        console.log("========================================");
        console.log("  SIMULATION COMPLETE");
        console.log("========================================");
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPER: EIP-712 Signing
    // ═══════════════════════════════════════════════════════════════

    function _signQuote(
        ICoverRouter.SignedQuote memory quote,
        uint256 signerKey
    ) internal view returns (bytes memory signature) {
        // Struct hash
        bytes32 structHash = keccak256(abi.encode(
            QUOTE_TYPEHASH,
            quote.productId,
            quote.coverageAmount,
            quote.premiumAmount,
            quote.durationSeconds,
            quote.asset,
            quote.stablecoin,
            quote.protocol,
            quote.buyer,
            quote.deadline,
            quote.nonce
        ));

        // Domain separator
        bytes32 domainSep = keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256("LuminaProtocol"),
            keccak256("1"),
            block.chainid,
            COVER_ROUTER
        ));

        // EIP-712 digest
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            domainSep,
            structHash
        ));

        // Sign
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPER: Unique Nonce Generator
    // ═══════════════════════════════════════════════════════════════

    function _nextNonce() internal returns (uint256 nonce) {
        _nonceCounter++;
        nonce = _nonceCounter;
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPER: Kink-model Premium Calculation (mirrors PremiumMath.sol)
    // ═══════════════════════════════════════════════════════════════

    function _calculatePremium(
        uint256 coverageAmount,
        uint256 pBaseBps,
        uint256 riskMultBps,
        uint256 durationDiscountBps,
        uint256 utilizationBps,
        uint256 durationSeconds
    ) internal pure returns (uint256 premiumAmount) {
        uint256 mWad = _calculateMultiplier(utilizationBps);

        uint256 step1 = coverageAmount * pBaseBps;
        uint256 step2 = (step1 * riskMultBps) / BPS;
        uint256 step3 = (step2 * durationDiscountBps) / BPS;
        uint256 step4 = (step3 * mWad) / WAD;
        uint256 step5 = (step4 * durationSeconds) / SECONDS_PER_YEAR;

        // Ceiling division
        premiumAmount = (step5 + BPS - 1) / BPS;
    }

    function _calculateMultiplier(uint256 utilizationBps) internal pure returns (uint256 multiplierWad) {
        if (utilizationBps > U_MAX) utilizationBps = U_MAX;

        multiplierWad = WAD;

        if (utilizationBps == 0) {
            return multiplierWad;
        }

        if (utilizationBps <= U_KINK) {
            uint256 ratio = (utilizationBps * WAD) / U_KINK;
            uint256 slopeContribution = (ratio * R_SLOPE1_WAD) / WAD;
            multiplierWad = WAD + slopeContribution;
        } else {
            uint256 excessBps = utilizationBps - U_KINK;
            uint256 remainingBps = BPS - U_KINK;
            uint256 excessRatio = (excessBps * WAD) / remainingBps;
            uint256 steepContribution = (excessRatio * R_SLOPE2_WAD) / WAD;
            multiplierWad = WAD + R_SLOPE1_WAD + steepContribution;
        }
    }
}
