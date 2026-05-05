// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
        MaintenanceReserve maintenanceReserveImpl = new MaintenanceReserve();
        ERC1967Proxy maintenanceReserveProxy = new ERC1967Proxy(
            address(maintenanceReserveImpl),
            abi.encodeWithSelector(MaintenanceReserve.initialize.selector, cfg.usdc, cfg.multisig)
        );
        MaintenanceReserve maintenanceReserve = MaintenanceReserve(address(maintenanceReserveProxy));
        res.maintenanceReserve = address(maintenanceReserve);
        console.log("1. MaintenanceReserve (proxy):", res.maintenanceReserve);

        // ═══════════════════════════════════════════════════════
        // STEP 2: ClaimBond via UUPS proxy (no deps)
        // ═══════════════════════════════════════════════════════
        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        ClaimBond claimBond = ClaimBond(address(claimBondProxy));
        res.claimBond = address(claimBond);
        console.log("2. ClaimBond (proxy):", res.claimBond);

        // ═══════════════════════════════════════════════════════
        // STEP 3-7: Precompute LuminaTokenV2 PROXY address
        // [V5.2] All contracts before LuminaTokenV2 now use UUPS proxy (2 nonces each),
        // except FounderVesting which remains non-proxied (1 nonce).
        // Nonce count: CapacityOracleImpl(+1), CapacityOracleProxy(+1),
        //              BondVaultImpl(+1), BondVaultProxy(+1),
        //              CEXReserveImpl(+1), CEXReserveProxy(+1),
        //              FounderVesting(+1),
        //              TreasuryVestingImpl(+1), TreasuryVestingProxy(+1),
        //              LuminaImpl(+1), LuminaProxy(+1) = +11 total, proxy at +10
        // ═══════════════════════════════════════════════════════
        uint64 currentNonce = vm.getNonce(deployer);
        address precomputedLumina = vm.computeCreateAddress(deployer, currentNonce + 10);
        console.log("   Precomputed LUMINA proxy address:", precomputedLumina);

        // ═══════════════════════════════════════════════════════
        // STEP 3: CapacityOracle (pool=address(0), emergencyPrice=0.036e18)
        // ═══════════════════════════════════════════════════════
        CapacityOracle capacityOracleImpl = new CapacityOracle();
        ERC1967Proxy capacityOracleProxy = new ERC1967Proxy(
            address(capacityOracleImpl),
            abi.encodeWithSelector(
                CapacityOracle.initialize.selector, address(0), precomputedLumina, cfg.usdc, 0.036e18
            )
        );
        CapacityOracle capacityOracle = CapacityOracle(address(capacityOracleProxy));
        res.capacityOracle = address(capacityOracle);
        console.log("3. CapacityOracle (proxy):", res.capacityOracle);

        // ═══════════════════════════════════════════════════════
        // STEP 4: BondVault via UUPS proxy (policyManager=address(0) for 2-step init)
        // ═══════════════════════════════════════════════════════
        BondVault bondVaultImpl = new BondVault();
        ERC1967Proxy bondVaultProxy = new ERC1967Proxy(
            address(bondVaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, precomputedLumina, res.claimBond, res.capacityOracle, address(0)
            )
        );
        BondVault bondVault = BondVault(address(bondVaultProxy));
        res.bondVault = address(bondVault);
        console.log("4. BondVault (proxy):", res.bondVault);

        // ═══════════════════════════════════════════════════════
        // STEP 5: CEXLiquidityReserve
        // ═══════════════════════════════════════════════════════
        CEXLiquidityReserve cexReserveImpl = new CEXLiquidityReserve();
        ERC1967Proxy cexReserveProxy = new ERC1967Proxy(
            address(cexReserveImpl),
            abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, precomputedLumina, cfg.multisig)
        );
        CEXLiquidityReserve cexReserve = CEXLiquidityReserve(address(cexReserveProxy));
        res.cexLiquidityReserve = address(cexReserve);
        console.log("5. CEXLiquidityReserve (proxy):", res.cexLiquidityReserve);

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
        TreasuryVesting treasuryVestingImpl = new TreasuryVesting();
        ERC1967Proxy treasuryVestingProxy = new ERC1967Proxy(
            address(treasuryVestingImpl), abi.encodeWithSelector(TreasuryVesting.initialize.selector, precomputedLumina)
        );
        TreasuryVesting treasuryVesting = TreasuryVesting(address(treasuryVestingProxy));
        res.treasuryVesting = address(treasuryVesting);
        console.log("7. TreasuryVesting (proxy):", res.treasuryVesting);

        // ═══════════════════════════════════════════════════════
        // STEP 8: LuminaTokenV2 via UUPS proxy — NOW the LUMINA token exists
        // ═══════════════════════════════════════════════════════
        LuminaTokenV2 luminaImpl = new LuminaTokenV2();
        ERC1967Proxy luminaProxy = new ERC1967Proxy(
            address(luminaImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector,
                res.bondVault,
                res.cexLiquidityReserve,
                res.founderVesting,
                cfg.lbpDeposit,
                res.treasuryVesting
            )
        );
        LuminaTokenV2 luminaToken = LuminaTokenV2(address(luminaProxy));
        res.luminaToken = address(luminaToken);
        require(res.luminaToken == precomputedLumina, "LUMINA proxy address mismatch - nonce drift");
        console.log("8. LuminaTokenV2 (proxy):", res.luminaToken);

        // ═══════════════════════════════════════════════════════
        // STEP 9: ClaimBond.setBondVault(bondVault)
        // ═══════════════════════════════════════════════════════
        claimBond.setBondVault(res.bondVault);
        console.log("9. ClaimBond.setBondVault done");

        // ═══════════════════════════════════════════════════════
        // STEP 10: SolvencyOracle
        // ═══════════════════════════════════════════════════════
        SolvencyOracle solvencyOracleImpl = new SolvencyOracle();
        ERC1967Proxy solvencyOracleProxy = new ERC1967Proxy(
            address(solvencyOracleImpl),
            abi.encodeWithSelector(SolvencyOracle.initialize.selector, res.bondVault, res.capacityOracle, cfg.multisig)
        );
        SolvencyOracle solvencyOracle = SolvencyOracle(address(solvencyOracleProxy));
        res.solvencyOracle = address(solvencyOracle);
        console.log("10. SolvencyOracle (proxy):", res.solvencyOracle);

        // ═══════════════════════════════════════════════════════
        // STEP 11: AdaptiveFeeDistributor
        // ═══════════════════════════════════════════════════════
        AdaptiveFeeDistributor adaptiveFeeDistributorImpl = new AdaptiveFeeDistributor();
        ERC1967Proxy adaptiveFeeDistributorProxy = new ERC1967Proxy(
            address(adaptiveFeeDistributorImpl),
            abi.encodeWithSelector(AdaptiveFeeDistributor.initialize.selector, res.solvencyOracle)
        );
        AdaptiveFeeDistributor adaptiveFeeDistributor = AdaptiveFeeDistributor(address(adaptiveFeeDistributorProxy));
        res.adaptiveFeeDistributor = address(adaptiveFeeDistributor);
        console.log("11. AdaptiveFeeDistributor (proxy):", res.adaptiveFeeDistributor);

        // ═══════════════════════════════════════════════════════
        // STEP 12: TWAPBurner via UUPS proxy
        // ═══════════════════════════════════════════════════════
        TWAPBurner twapBurnerImpl = new TWAPBurner();
        ERC1967Proxy twapBurnerProxy = new ERC1967Proxy(
            address(twapBurnerImpl),
            abi.encodeWithSelector(TWAPBurner.initialize.selector, cfg.usdc, res.luminaToken, cfg.swapRouter)
        );
        TWAPBurner twapBurner = TWAPBurner(payable(address(twapBurnerProxy)));
        res.twapBurner = address(twapBurner);
        console.log("12. TWAPBurner (proxy):", res.twapBurner);

        // ═══════════════════════════════════════════════════════
        // STEP 13: PolicyManagerV2 via UUPS proxy
        // ═══════════════════════════════════════════════════════
        PolicyManagerV2 pmImpl = new PolicyManagerV2();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl), abi.encodeWithSelector(PolicyManagerV2.initialize.selector, res.bondVault)
        );
        PolicyManagerV2 policyManager = PolicyManagerV2(address(pmProxy));
        res.policyManager = address(policyManager);
        console.log("13. PolicyManagerV2 (proxy):", res.policyManager);

        // ═══════════════════════════════════════════════════════
        // STEP 14: BondVault.setPolicyManager(policyManagerV2)
        // ═══════════════════════════════════════════════════════
        bondVault.setPolicyManager(res.policyManager);
        console.log("14. BondVault.setPolicyManager done");

        // ═══════════════════════════════════════════════════════
        // STEP 15: CoverRouterV2 via UUPS proxy
        // ═══════════════════════════════════════════════════════
        CoverRouterV2 crImpl = new CoverRouterV2();
        ERC1967Proxy crProxy = new ERC1967Proxy(
            address(crImpl),
            abi.encodeWithSelector(CoverRouterV2.initialize.selector, cfg.usdc, res.policyManager, res.twapBurner)
        );
        CoverRouterV2 coverRouter = CoverRouterV2(address(crProxy));
        res.coverRouter = address(coverRouter);
        console.log("15. CoverRouterV2 (proxy):", res.coverRouter);

        // ═══════════════════════════════════════════════════════
        // STEP 16: PolicyManagerV2.setRouter(coverRouter)
        // ═══════════════════════════════════════════════════════
        policyManager.setRouter(res.coverRouter);
        console.log("16. PolicyManagerV2.setRouter done");

        // ═══════════════════════════════════════════════════════
        // STEP 17: LuminaBondMarketplace via UUPS proxy
        // ═══════════════════════════════════════════════════════
        LuminaBondMarketplace mktImpl = new LuminaBondMarketplace();
        ERC1967Proxy mktProxy = new ERC1967Proxy(
            address(mktImpl),
            abi.encodeWithSelector(
                LuminaBondMarketplace.initialize.selector, res.claimBond, cfg.usdc, res.twapBurner, cfg.multisig
            )
        );
        LuminaBondMarketplace marketplace = LuminaBondMarketplace(address(mktProxy));
        res.marketplace = address(marketplace);
        console.log("17. LuminaBondMarketplace (proxy):", res.marketplace);

        // ═══════════════════════════════════════════════════════
        // STEP 18: BuybackEngine via UUPS proxy
        // ═══════════════════════════════════════════════════════
        BuybackEngine bbImpl = new BuybackEngine();
        ERC1967Proxy bbProxy = new ERC1967Proxy(
            address(bbImpl),
            abi.encodeWithSelector(
                BuybackEngine.initialize.selector,
                res.claimBond,
                res.bondVault,
                res.solvencyOracle,
                res.capacityOracle,
                res.marketplace,
                cfg.usdc,
                cfg.multisig
            )
        );
        BuybackEngine buybackEngine = BuybackEngine(address(bbProxy));
        res.buybackEngine = address(buybackEngine);
        console.log("18. BuybackEngine (proxy):", res.buybackEngine);

        // ═══════════════════════════════════════════════════════
        // STEP 19: Deploy 9 Shields
        // ═══════════════════════════════════════════════════════
        FlashBTCShield1h flashBtc1hImpl = new FlashBTCShield1h();
        ERC1967Proxy flashBtc1hProxy = new ERC1967Proxy(
            address(flashBtc1hImpl),
            abi.encodeWithSelector(FlashBTCShield1h.initialize.selector, res.policyManager, cfg.chainlinkOracle)
        );
        res.flashBTCShield1h = address(flashBtc1hProxy);

        FlashBTCShield4h flashBtc4hImpl = new FlashBTCShield4h();
        ERC1967Proxy flashBtc4hProxy = new ERC1967Proxy(
            address(flashBtc4hImpl),
            abi.encodeWithSelector(FlashBTCShield4h.initialize.selector, res.policyManager, cfg.chainlinkOracle)
        );
        res.flashBTCShield4h = address(flashBtc4hProxy);

        FlashBTCShield24h flashBtc24hImpl = new FlashBTCShield24h();
        ERC1967Proxy flashBtc24hProxy = new ERC1967Proxy(
            address(flashBtc24hImpl),
            abi.encodeWithSelector(FlashBTCShield24h.initialize.selector, res.policyManager, cfg.chainlinkOracle)
        );
        res.flashBTCShield24h = address(flashBtc24hProxy);

        FlashBTCShield48h flashBtc48hImpl = new FlashBTCShield48h();
        ERC1967Proxy flashBtc48hProxy = new ERC1967Proxy(
            address(flashBtc48hImpl),
            abi.encodeWithSelector(FlashBTCShield48h.initialize.selector, res.policyManager, cfg.chainlinkOracle)
        );
        res.flashBTCShield48h = address(flashBtc48hProxy);

        FlashETHShield1h flashEth1hImpl = new FlashETHShield1h();
        ERC1967Proxy flashEth1hProxy = new ERC1967Proxy(
            address(flashEth1hImpl),
            abi.encodeWithSelector(FlashETHShield1h.initialize.selector, res.policyManager, cfg.chainlinkOracle)
        );
        res.flashETHShield1h = address(flashEth1hProxy);

        FlashETHShield24h flashEth24hImpl = new FlashETHShield24h();
        ERC1967Proxy flashEth24hProxy = new ERC1967Proxy(
            address(flashEth24hImpl),
            abi.encodeWithSelector(FlashETHShield24h.initialize.selector, res.policyManager, cfg.chainlinkOracle)
        );
        res.flashETHShield24h = address(flashEth24hProxy);

        FlashETHShield48h flashEth48hImpl = new FlashETHShield48h();
        ERC1967Proxy flashEth48hProxy = new ERC1967Proxy(
            address(flashEth48hImpl),
            abi.encodeWithSelector(FlashETHShield48h.initialize.selector, res.policyManager, cfg.chainlinkOracle)
        );
        res.flashETHShield48h = address(flashEth48hProxy);

        MicroDepegShield microDepegImpl = new MicroDepegShield();
        ERC1967Proxy microDepegProxy = new ERC1967Proxy(
            address(microDepegImpl),
            abi.encodeWithSelector(MicroDepegShield.initialize.selector, res.policyManager, cfg.chainlinkOracle)
        );
        res.microDepegShield = address(microDepegProxy);

        RateShockShield rateShockImpl = new RateShockShield();
        ERC1967Proxy rateShockProxy = new ERC1967Proxy(
            address(rateShockImpl),
            abi.encodeWithSelector(
                RateShockShield.initialize.selector, res.policyManager, cfg.chainlinkOracle, cfg.aavePool, cfg.usdc
            )
        );
        res.rateShockShield = address(rateShockProxy);
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

        // [Fix audit #31 CRITICAL] Authorize Marketplace + BuybackEngine as ClaimBond operators.
        // Without these, Fix #18's transfer whitelist makes the Marketplace 100% non-functional
        // (sellers cannot list bonds, buybacks cannot complete). MUST run pre-launch.
        claimBond.setAuthorizedOperator(res.marketplace, true);
        claimBond.setAuthorizedOperator(res.buybackEngine, true);
        console.log("  Marketplace + BuybackEngine authorized as ClaimBond operators");

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
    function _configureProducts(
        CoverRouterV2 router,
        DeploymentResult memory /* res */
    )
        internal
    {
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
