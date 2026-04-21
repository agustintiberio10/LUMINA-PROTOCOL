// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

// ═══════ Token ═══════
import "../../src/token/LuminaTokenV2.sol";
import "../../src/token/FounderVesting.sol";
import "../../src/token/TreasuryVesting.sol";

// ═══════ Bonds ═══════
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";

// ═══════ Oracles ═══════
import {CapacityOracle} from "../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";

// ═══════ Core ═══════
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";

// ═══════ Treasury ═══════
import "../../src/treasury/CEXLiquidityReserve.sol";
import "../../src/treasury/MaintenanceReserve.sol";

// ═══════ Marketplace ═══════
import "../../src/marketplace/LuminaBondMarketplace.sol";
import "../../src/marketplace/BuybackEngine.sol";

// ═══════ Products (Shields) ═══════
import "../../src/products/FlashBTCShield1h.sol";
import "../../src/products/FlashBTCShield4h.sol";
import "../../src/products/FlashBTCShield24h.sol";
import "../../src/products/FlashBTCShield48h.sol";
import "../../src/products/FlashETHShield1h.sol";
import "../../src/products/FlashETHShield24h.sol";
import "../../src/products/FlashETHShield48h.sol";
import "../../src/products/MicroDepegShield.sol";
import "../../src/products/RateShockShield.sol";

/// @title DeployLuminaV5Complete
/// @notice Full deployment script for LUMINA Protocol V5.0.
/// @dev Load configuration from environment variables. Run with:
///      forge script script/deploy/DeployLuminaV5Complete.s.sol --rpc-url $RPC --broadcast
contract DeployLuminaV5Complete is Script {
    // ═══════ CONFIG ═══════

    struct DeploymentConfig {
        address usdc;
        address swapRouter;
        address multisig;
        address lbpDeposit;
        address opsWallet;
        address founderRecipient;
        address chainlinkOracle;
        address aavePool;
    }

    struct DeploymentResult {
        address luminaToken;
        address bondVault;
        address claimBond;
        address capacityOracle;
        address solvencyOracle;
        address adaptiveFeeDistributor;
        address twapBurner;
        address policyManager;
        address coverRouter;
        address cexLiquidityReserve;
        address maintenanceReserve;
        address founderVesting;
        address treasuryVesting;
        address marketplace;
        address buybackEngine;
        address flashBTCShield1h;
        address flashBTCShield4h;
        address flashBTCShield24h;
        address flashBTCShield48h;
        address flashETHShield1h;
        address flashETHShield24h;
        address flashETHShield48h;
        address microDepegShield;
        address rateShockShield;
    }

    function run() external {
        // ───── Load config from env ─────
        DeploymentConfig memory cfg = DeploymentConfig({
            usdc: vm.envAddress("USDC_ADDRESS"),
            swapRouter: vm.envAddress("SWAP_ROUTER"),
            multisig: vm.envAddress("MULTISIG"),
            lbpDeposit: vm.envAddress("LBP_DEPOSIT"),
            opsWallet: vm.envAddress("OPS_WALLET"),
            founderRecipient: vm.envAddress("FOUNDER_RECIPIENT"),
            chainlinkOracle: vm.envAddress("CHAINLINK_ORACLE"),
            aavePool: vm.envAddress("AAVE_POOL")
        });

        DeploymentResult memory res;

        vm.startBroadcast();

        address deployer = msg.sender;

        // ═══════════════════════════════════════════════════════
        // STEP 1: MaintenanceReserve (needs USDC only)
        // ═══════════════════════════════════════════════════════
        MaintenanceReserve maintenanceReserve = new MaintenanceReserve(cfg.usdc, cfg.multisig);
        res.maintenanceReserve = address(maintenanceReserve);
        console.log("1. MaintenanceReserve:", res.maintenanceReserve);

        // ═══════════════════════════════════════════════════════
        // STEP 2: ClaimBond (no deps)
        // ═══════════════════════════════════════════════════════
        ClaimBond claimBond = new ClaimBond();
        res.claimBond = address(claimBond);
        console.log("2. ClaimBond:", res.claimBond);

        // ═══════════════════════════════════════════════════════
        // STEP 3-7: Precompute LuminaTokenV2 address
        // Nonce: deployer has deployed 2 contracts so far (MaintenanceReserve, ClaimBond).
        // Next deploys: CapacityOracle(nonce+0), BondVault(nonce+1), CEXLiquidityReserve(nonce+2),
        //               FounderVesting(nonce+3), TreasuryVesting(nonce+4), LuminaTokenV2(nonce+5)
        // So LuminaTokenV2 is at currentNonce + 5 from here.
        // We need the nonce AFTER the broadcast started. The deployer nonce at this point
        // accounts for the 2 contracts already deployed in this script.
        // ═══════════════════════════════════════════════════════
        uint64 currentNonce = vm.getNonce(deployer);
        // LuminaTokenV2 will be deployed after 5 more contracts (steps 3-7)
        address precomputedLumina = vm.computeCreateAddress(deployer, currentNonce + 5);
        console.log("   Precomputed LUMINA address:", precomputedLumina);

        // ═══════════════════════════════════════════════════════
        // STEP 3: CapacityOracle (pool=address(0), emergencyPrice=0.036e18)
        // ═══════════════════════════════════════════════════════
        CapacityOracle capacityOracle = new CapacityOracle(address(0), precomputedLumina, cfg.usdc, 0.036e18);
        res.capacityOracle = address(capacityOracle);
        console.log("3. CapacityOracle:", res.capacityOracle);

        // ═══════════════════════════════════════════════════════
        // STEP 4: BondVault (policyManager=address(0) for 2-step init)
        // ═══════════════════════════════════════════════════════
        BondVault bondVault = new BondVault(
            precomputedLumina,
            res.claimBond,
            res.capacityOracle,
            address(0) // policyManager set later via setPolicyManager
        );
        res.bondVault = address(bondVault);
        console.log("4. BondVault:", res.bondVault);

        // ═══════════════════════════════════════════════════════
        // STEP 5: CEXLiquidityReserve
        // ═══════════════════════════════════════════════════════
        CEXLiquidityReserve cexReserve = new CEXLiquidityReserve(precomputedLumina, cfg.multisig);
        res.cexLiquidityReserve = address(cexReserve);
        console.log("5. CEXLiquidityReserve:", res.cexLiquidityReserve);

        // ═══════════════════════════════════════════════════════
        // STEP 6: FounderVesting
        // ═══════════════════════════════════════════════════════
        FounderVesting founderVesting =
            new FounderVesting(res.capacityOracle, cfg.aavePool, precomputedLumina, cfg.usdc, cfg.founderRecipient);
        res.founderVesting = address(founderVesting);
        console.log("6. FounderVesting:", res.founderVesting);

        // ═══════════════════════════════════════════════════════
        // STEP 7: TreasuryVesting
        // ═══════════════════════════════════════════════════════
        TreasuryVesting treasuryVesting = new TreasuryVesting(precomputedLumina);
        res.treasuryVesting = address(treasuryVesting);
        console.log("7. TreasuryVesting:", res.treasuryVesting);

        // ═══════════════════════════════════════════════════════
        // STEP 8: LuminaTokenV2 — NOW the LUMINA token exists
        // ═══════════════════════════════════════════════════════
        LuminaTokenV2 luminaToken = new LuminaTokenV2(
            res.bondVault, res.cexLiquidityReserve, res.founderVesting, cfg.lbpDeposit, res.treasuryVesting
        );
        res.luminaToken = address(luminaToken);
        require(res.luminaToken == precomputedLumina, "LUMINA address mismatch - nonce drift");
        console.log("8. LuminaTokenV2:", res.luminaToken);

        // ═══════════════════════════════════════════════════════
        // STEP 9: ClaimBond.setBondVault(bondVault)
        // ═══════════════════════════════════════════════════════
        claimBond.setBondVault(res.bondVault);
        console.log("9. ClaimBond.setBondVault done");

        // ═══════════════════════════════════════════════════════
        // STEP 10: SolvencyOracle
        // ═══════════════════════════════════════════════════════
        SolvencyOracle solvencyOracle = new SolvencyOracle(res.bondVault, res.capacityOracle, cfg.multisig);
        res.solvencyOracle = address(solvencyOracle);
        console.log("10. SolvencyOracle:", res.solvencyOracle);

        // ═══════════════════════════════════════════════════════
        // STEP 11: AdaptiveFeeDistributor
        // ═══════════════════════════════════════════════════════
        AdaptiveFeeDistributor adaptiveFeeDistributor = new AdaptiveFeeDistributor(res.solvencyOracle);
        res.adaptiveFeeDistributor = address(adaptiveFeeDistributor);
        console.log("11. AdaptiveFeeDistributor:", res.adaptiveFeeDistributor);

        // ═══════════════════════════════════════════════════════
        // STEP 12: TWAPBurner
        // ═══════════════════════════════════════════════════════
        TWAPBurner twapBurner = new TWAPBurner(cfg.usdc, res.luminaToken, cfg.swapRouter);
        res.twapBurner = address(twapBurner);
        console.log("12. TWAPBurner:", res.twapBurner);

        // ═══════════════════════════════════════════════════════
        // STEP 13: PolicyManagerV2
        // ═══════════════════════════════════════════════════════
        PolicyManagerV2 policyManager = new PolicyManagerV2(res.bondVault);
        res.policyManager = address(policyManager);
        console.log("13. PolicyManagerV2:", res.policyManager);

        // ═══════════════════════════════════════════════════════
        // STEP 14: BondVault.setPolicyManager(policyManagerV2)
        // ═══════════════════════════════════════════════════════
        bondVault.setPolicyManager(res.policyManager);
        console.log("14. BondVault.setPolicyManager done");

        // ═══════════════════════════════════════════════════════
        // STEP 15: CoverRouterV2
        // ═══════════════════════════════════════════════════════
        CoverRouterV2 coverRouter = new CoverRouterV2(cfg.usdc, res.policyManager, res.twapBurner);
        res.coverRouter = address(coverRouter);
        console.log("15. CoverRouterV2:", res.coverRouter);

        // ═══════════════════════════════════════════════════════
        // STEP 16: PolicyManagerV2.setRouter(coverRouter)
        // ═══════════════════════════════════════════════════════
        policyManager.setRouter(res.coverRouter);
        console.log("16. PolicyManagerV2.setRouter done");

        // ═══════════════════════════════════════════════════════
        // STEP 17: LuminaBondMarketplace
        // ═══════════════════════════════════════════════════════
        LuminaBondMarketplace marketplace =
            new LuminaBondMarketplace(res.claimBond, cfg.usdc, res.twapBurner, cfg.multisig);
        res.marketplace = address(marketplace);
        console.log("17. LuminaBondMarketplace:", res.marketplace);

        // ═══════════════════════════════════════════════════════
        // STEP 18: BuybackEngine
        // ═══════════════════════════════════════════════════════
        BuybackEngine buybackEngine = new BuybackEngine(
            res.claimBond,
            res.bondVault,
            res.solvencyOracle,
            res.capacityOracle,
            res.marketplace,
            cfg.usdc,
            cfg.multisig
        );
        res.buybackEngine = address(buybackEngine);
        console.log("18. BuybackEngine:", res.buybackEngine);

        // ═══════════════════════════════════════════════════════
        // STEP 19: Deploy 9 Shields
        // ═══════════════════════════════════════════════════════
        res.flashBTCShield1h = address(new FlashBTCShield1h(res.policyManager, cfg.chainlinkOracle));
        res.flashBTCShield4h = address(new FlashBTCShield4h(res.policyManager, cfg.chainlinkOracle));
        res.flashBTCShield24h = address(new FlashBTCShield24h(res.policyManager, cfg.chainlinkOracle));
        res.flashBTCShield48h = address(new FlashBTCShield48h(res.policyManager, cfg.chainlinkOracle));
        res.flashETHShield1h = address(new FlashETHShield1h(res.policyManager, cfg.chainlinkOracle));
        res.flashETHShield24h = address(new FlashETHShield24h(res.policyManager, cfg.chainlinkOracle));
        res.flashETHShield48h = address(new FlashETHShield48h(res.policyManager, cfg.chainlinkOracle));
        res.microDepegShield = address(new MicroDepegShield(res.policyManager, cfg.chainlinkOracle));
        res.rateShockShield =
            address(new RateShockShield(res.policyManager, cfg.chainlinkOracle, cfg.aavePool, cfg.usdc));
        console.log("19. Shields deployed (9)");

        // ═══════════════════════════════════════════════════════
        // WIRING: Cross-contract configuration
        // ═══════════════════════════════════════════════════════
        console.log("--- WIRING ---");

        // LuminaTokenV2.grantRole(BURNER_ROLE, twapBurner)
        luminaToken.grantRole(luminaToken.BURNER_ROLE(), res.twapBurner);
        console.log("  BURNER_ROLE granted to TWAPBurner");

        // TWAPBurner configuration
        twapBurner.setFeeDistributor(res.adaptiveFeeDistributor);
        twapBurner.setReserves(res.buybackEngine, cfg.opsWallet, res.maintenanceReserve);
        twapBurner.setCapacityOracle(res.capacityOracle);
        twapBurner.setAdaptiveMode(true);
        twapBurner.setAuthorizedSender(res.coverRouter, true);
        console.log("  TWAPBurner configured");

        // Authorize BuybackEngine in BondVault (deployer has AUTHORIZED_CALLER_ADMIN_ROLE)
        bondVault.setAuthorizedCaller(res.buybackEngine, true);
        console.log("  BuybackEngine authorized in BondVault");

        // PolicyManagerV2.registerProduct for each shield
        // IDs MUST match the PRODUCT_ID constant in each shield contract
        policyManager.registerProduct(keccak256("FLASHBTC1H-001"), res.flashBTCShield1h);
        policyManager.registerProduct(keccak256("FLASHBTC4H-001"), res.flashBTCShield4h);
        policyManager.registerProduct(keccak256("FLASHBTC24-001"), res.flashBTCShield24h);
        policyManager.registerProduct(keccak256("FLASHBTC48-001"), res.flashBTCShield48h);
        policyManager.registerProduct(keccak256("FLASHETH1H-001"), res.flashETHShield1h);
        policyManager.registerProduct(keccak256("FLASHETH24-001"), res.flashETHShield24h);
        policyManager.registerProduct(keccak256("FLASHETH48-001"), res.flashETHShield48h);
        policyManager.registerProduct(keccak256("MICRODEPEG-001"), res.microDepegShield);
        policyManager.registerProduct(keccak256("RATESHOCK-001"), res.rateShockShield);
        console.log("  PolicyManagerV2: 9 products registered");

        // CoverRouterV2.setCapacityOracle (auto-pause at MIN_PRICE_FOR_NEW_POLICIES)
        coverRouter.setCapacityOracle(res.capacityOracle);
        console.log("  CoverRouterV2.setCapacityOracle done");

        // CoverRouterV2.configureProduct for each shield
        // Default config: payoutRatio=8000bps(80%), triggerProb=200bps(2%), margin=2000bps(20%)
        _configureProducts(coverRouter, res);
        console.log("  CoverRouterV2: 9 products configured");

        // ═══════════════════════════════════════════════════════
        // OWNERSHIP TRANSFER to multisig
        // ═══════════════════════════════════════════════════════
        console.log("--- OWNERSHIP TRANSFER ---");

        twapBurner.transferOwnership(cfg.multisig);
        coverRouter.transferOwnership(cfg.multisig);
        policyManager.transferOwnership(cfg.multisig);
        capacityOracle.transferOwnership(cfg.multisig);
        founderVesting.transferOwnership(cfg.multisig);
        treasuryVesting.transferOwnership(cfg.multisig);
        claimBond.transferOwnership(cfg.multisig);

        // Transfer BondVault admin roles to multisig
        bondVault.grantRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), cfg.multisig);
        bondVault.grantRole(bondVault.DEFAULT_ADMIN_ROLE(), cfg.multisig);
        bondVault.revokeRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), msg.sender);
        bondVault.revokeRole(bondVault.DEFAULT_ADMIN_ROLE(), msg.sender);

        // Transfer LuminaTokenV2 admin to multisig
        luminaToken.grantRole(luminaToken.DEFAULT_ADMIN_ROLE(), cfg.multisig);
        luminaToken.revokeRole(luminaToken.DEFAULT_ADMIN_ROLE(), msg.sender);
        console.log("  Ownership transferred to multisig:", cfg.multisig);

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════
        // FINAL LOG: All deployed addresses
        // ═══════════════════════════════════════════════════════
        console.log("===== LUMINA V5.0 DEPLOYMENT COMPLETE =====");
        console.log("LuminaTokenV2:          ", res.luminaToken);
        console.log("BondVault:              ", res.bondVault);
        console.log("ClaimBond:              ", res.claimBond);
        console.log("CapacityOracle:         ", res.capacityOracle);
        console.log("SolvencyOracle:         ", res.solvencyOracle);
        console.log("AdaptiveFeeDistributor: ", res.adaptiveFeeDistributor);
        console.log("TWAPBurner:             ", res.twapBurner);
        console.log("PolicyManagerV2:        ", res.policyManager);
        console.log("CoverRouterV2:          ", res.coverRouter);
        console.log("CEXLiquidityReserve:    ", res.cexLiquidityReserve);
        console.log("MaintenanceReserve:     ", res.maintenanceReserve);
        console.log("FounderVesting:         ", res.founderVesting);
        console.log("TreasuryVesting:        ", res.treasuryVesting);
        console.log("LuminaBondMarketplace:  ", res.marketplace);
        console.log("BuybackEngine:          ", res.buybackEngine);
        console.log("FlashBTCShield1h:       ", res.flashBTCShield1h);
        console.log("FlashBTCShield4h:       ", res.flashBTCShield4h);
        console.log("FlashBTCShield24h:      ", res.flashBTCShield24h);
        console.log("FlashBTCShield48h:      ", res.flashBTCShield48h);
        console.log("FlashETHShield1h:       ", res.flashETHShield1h);
        console.log("FlashETHShield24h:      ", res.flashETHShield24h);
        console.log("FlashETHShield48h:      ", res.flashETHShield48h);
        console.log("MicroDepegShield:       ", res.microDepegShield);
        console.log("RateShockShield:        ", res.rateShockShield);
        console.log("===========================================");
    }

    /// @dev Configure all 9 products on CoverRouterV2 with default parameters.
    function _configureProducts(CoverRouterV2 router, DeploymentResult memory) internal {
        // Product configs: payoutRatioBps, triggerProbBps, marginBps, durationSeconds, active
        // IDs MUST match the PRODUCT_ID constant in each shield contract
        // payoutRatioBps = 8000 (80% payout)
        // BTC shields
        router.configureProduct(keccak256("FLASHBTC1H-001"), 8000, 20, 15000, 3600, true);
        router.configureProduct(keccak256("FLASHBTC4H-001"), 8000, 30, 15000, 14400, true);
        router.configureProduct(keccak256("FLASHBTC24-001"), 8000, 50, 15000, 86400, true);
        router.configureProduct(keccak256("FLASHBTC48-001"), 8000, 40, 15000, 172800, true);
        // ETH shields
        router.configureProduct(keccak256("FLASHETH1H-001"), 8000, 25, 15000, 3600, true);
        router.configureProduct(keccak256("FLASHETH24-001"), 8000, 60, 15000, 86400, true);
        router.configureProduct(keccak256("FLASHETH48-001"), 8000, 50, 15000, 172800, true);
        // Depeg / Rate (duration: 604800 = 7 days, matches shield MIN/MAX_DURATION)
        router.configureProduct(keccak256("MICRODEPEG-001"), 8000, 100, 15000, 604800, true);
        router.configureProduct(keccak256("RATESHOCK-001"), 8000, 80, 15000, 604800, true);
    }
}
