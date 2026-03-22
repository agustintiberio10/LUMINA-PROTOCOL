// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoverRouter} from "../src/interfaces/ICoverRouter.sol";
import {IVault} from "../src/interfaces/IVault.sol";

/**
 * @title TestBuyBatch
 * @notice Foundry script that purchases 7 BSS (Black Swan Shield) policies
 *         of $2,000 each in sequence, logging premium and utilization changes.
 *
 * Usage:
 *   forge script script/TestBuyBatch.s.sol:TestBuyBatch \
 *     --rpc-url $BASE_RPC_URL --broadcast -vvvv
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY — private key of the deployer (also the oracle signer)
 */
contract TestBuyBatch is Script {

    // ── Deployed addresses (Base Mainnet) ──────────────────────────
    address constant COVER_ROUTER   = 0x5755af9cd293b9A0a798B7e2e816eAbE659750C0;
    address constant MOCK_USDC      = 0x8a342233cFC95F4AeB11c2855BFF1f441241E8d1;
    address constant VOLATILE_SHORT = 0xe74d19551cbB809AaDcAb568c0E150B6BF0e3354;

    // ── BSS product ID (must match keccak256("BLACKSWAN-001") used at registration) ──
    bytes32 constant BSS_PRODUCT_ID = keccak256("BLACKSWAN-001");

    // ── EIP-712 type hashes (must match CoverRouter exactly) ──────
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

    // ── Policy parameters ─────────────────────────────────────────
    uint256 constant COVERAGE_AMOUNT  = 2_000_000_000; // $2,000 in 6 decimals
    uint32  constant DURATION_SECONDS = 1_209_600;     // 14 days
    uint256 constant BATCH_SIZE       = 7;

    // ── PremiumMath constants (mirrored from src/libraries/PremiumMath.sol) ──
    uint256 constant WAD              = 1e18;
    uint256 constant SECONDS_PER_YEAR = 31_536_000;
    uint256 constant U_KINK           = 8000;
    uint256 constant R_SLOPE1_WAD     = 5e17;
    uint256 constant R_SLOPE2_WAD     = 3e18;
    uint256 constant U_MAX            = 9500;
    uint256 constant BPS              = 10_000;

    // BSS pricing params (from actuarial spec: P_base=22%, riskMult=1.0x, durationDiscount=1.0x)
    uint256 constant P_BASE_BPS            = 2200;
    uint256 constant RISK_MULT_BPS         = 10_000;
    uint256 constant DURATION_DISCOUNT_BPS = 10_000;

    function run() external {
        // ── 1. Load deployer key (deployer = oracleKey in test deployment) ──
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer / Oracle signer:", deployer);

        // ── 2. Read initial vault state ───────────────────────────────
        IVault vault = IVault(VOLATILE_SHORT);
        IVault.VaultState memory vsInitial = vault.getVaultState();
        uint256 initialUtil = vsInitial.utilizationBps;
        console.log("=== Initial Vault State ===");
        console.log("  totalAssets:    ", vsInitial.totalAssets);
        console.log("  allocatedAssets:", vsInitial.allocatedAssets);
        console.log("  utilizationBps: ", initialUtil);

        // ── 3. Pre-compute domain separator (constant across iterations) ──
        bytes32 domainSep = keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256("LuminaProtocol"),
            keccak256("1"),
            block.chainid,
            COVER_ROUTER
        ));

        // ── 4. Max-approve USDC to CoverRouter once ──────────────────
        vm.startBroadcast(deployerKey);
        IERC20(MOCK_USDC).approve(COVER_ROUTER, type(uint256).max);
        console.log("Approved USDC (max) to CoverRouter");

        ICoverRouter router = ICoverRouter(COVER_ROUTER);

        uint256 totalPremiums = 0;
        uint256 firstPremium = 0;
        uint256 lastPremium = 0;

        // ── 5. Loop: purchase 7 policies ──────────────────────────────
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            console.log("");
            console.log("--- Iteration", i + 1, "of 7 ---");

            // 5a. Read current vault state
            IVault.VaultState memory vs = vault.getVaultState();
            console.log("  totalAssets:    ", vs.totalAssets);
            console.log("  allocatedAssets:", vs.allocatedAssets);
            console.log("  utilizationBps: ", vs.utilizationBps);

            // 5b. Calculate premium via kink model with current utilization
            uint256 premiumAmount = _calculatePremium(
                COVERAGE_AMOUNT,
                P_BASE_BPS,
                RISK_MULT_BPS,
                DURATION_DISCOUNT_BPS,
                vs.utilizationBps,
                DURATION_SECONDS
            );
            console.log("  Calculated premium (6 dec):", premiumAmount);

            // 5c. Build SignedQuote with unique nonce
            uint256 nonce = block.timestamp * 1000 + i;
            ICoverRouter.SignedQuote memory quote = ICoverRouter.SignedQuote({
                productId:       BSS_PRODUCT_ID,
                coverageAmount:  COVERAGE_AMOUNT,
                premiumAmount:   premiumAmount,
                durationSeconds: DURATION_SECONDS,
                asset:           bytes32("ETH"),
                stablecoin:      bytes32("USDC"),
                protocol:        address(0),
                buyer:           deployer,
                deadline:        block.timestamp + 300,
                nonce:           nonce
            });

            // 5d. Sign via EIP-712
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

            bytes32 digest = keccak256(abi.encodePacked(
                "\x19\x01",
                domainSep,
                structHash
            ));

            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);
            bytes memory signature = abi.encodePacked(r, s, v);

            // 5e. Purchase policy
            ICoverRouter.PurchaseResult memory result = router.purchasePolicy(quote, signature);

            // 5f. Log iteration results
            console.log("  Policy ID:     ", result.policyId);
            console.log("  Premium Paid:  ", result.premiumPaid);

            // Read updated utilization
            IVault.VaultState memory vsAfter = vault.getVaultState();
            console.log("  New utilization:", vsAfter.utilizationBps);

            // Track premiums
            totalPremiums += result.premiumPaid;
            if (i == 0) firstPremium = result.premiumPaid;
            if (i == BATCH_SIZE - 1) lastPremium = result.premiumPaid;
        }

        vm.stopBroadcast();

        // ── 6. Summary ───────────────────────────────────────────────
        IVault.VaultState memory vsFinal = vault.getVaultState();
        uint256 finalUtil = vsFinal.utilizationBps;

        console.log("");
        console.log("========== BATCH SUMMARY ==========");
        console.log("Policies purchased:  7");
        console.log("Initial utilization: ", initialUtil);
        console.log("Final utilization:   ", finalUtil);
        console.log("First premium:       ", firstPremium);
        console.log("Last premium:        ", lastPremium);
        console.log("Total premiums paid: ", totalPremiums);
        console.log("====================================");
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTERNAL: Kink-model premium calculation (mirrors PremiumMath)
    // ═══════════════════════════════════════════════════════════════

    function _calculatePremium(
        uint256 coverageAmount,
        uint256 pBaseBps,
        uint256 riskMultBps,
        uint256 durationDiscountBps,
        uint256 utilizationBps,
        uint256 durationSeconds
    ) internal pure returns (uint256 premiumAmount) {
        // M(U) — kink multiplier
        uint256 mWad = _calculateMultiplier(utilizationBps);

        // Premium = Coverage * P_base * riskMult * durDiscount * M(U) * duration / SECONDS_PER_YEAR
        // Computed step-by-step exactly as in PremiumMath.sol
        uint256 step1 = coverageAmount * pBaseBps;
        uint256 step2 = (step1 * riskMultBps) / BPS;
        uint256 step3 = (step2 * durationDiscountBps) / BPS;
        uint256 step4 = (step3 * mWad) / WAD;
        uint256 step5 = (step4 * durationSeconds) / SECONDS_PER_YEAR;

        // Ceiling division (protocol always rounds up)
        premiumAmount = (step5 + BPS - 1) / BPS;
    }

    function _calculateMultiplier(uint256 utilizationBps) internal pure returns (uint256 multiplierWad) {
        require(utilizationBps <= U_MAX, "Utilization above 95%");

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
