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
import {LuminaOracleV2} from "../../src/oracles/LuminaOracleV2.sol";

// ═══════ Core ═══════
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";

// ═══════ Automation ═══════
import {ShieldKeeper} from "../../src/automation/ShieldKeeper.sol";

// ═══════ DEX Adapters ═══════
import {AerodromeAdapter} from "../../src/dex/AerodromeAdapter.sol";
import {UniswapV3Adapter} from "../../src/dex/UniswapV3Adapter.sol";

// ═══════ Treasury ═══════
import "../../src/treasury/CEXLiquidityReserve.sol";
import "../../src/treasury/MaintenanceReserve.sol";

// ═══════ Marketplace ═══════
import "../../src/marketplace/LuminaBondMarketplace.sol";
import "../../src/marketplace/BuybackEngine.sol";

// ═══════ Products (Shields) ═══════
// [Sprint T-30a Phase B] V5.2 shield set (FlashBTC/FlashETH 1h/24h/48h + RateShock)
// removed. New shields land in Phase C with the drop-from-purchase mechanic.
// RateShock not replaced (founder decision: removed permanently).

/// @title DeployLuminaV5Complete
/// @notice Full deployment script for LUMINA Protocol V5.0 — 26 contracts.
///         (Sprint EE Phase H 2026-05-17: removed FlashBTCShield4h to mirror the
///         FlashETH set (1h/24h/48h, no 4h). Per ADR-026, the BTC set is
///         collapsed from 1h/4h/24h/48h to 1h/24h/48h; 7 shields total now.)
///         (Sprint EE Phase A 2026-05-17: removed MicroDepegShield — no reliable
///         Sepolia USDT Chainlink feed.)
///         (Sprint B 2026-05-07: + LuminaOracleV2, ShieldKeeper, AerodromeAdapter,
///         UniswapV3Adapter. Shields now bind to LuminaOracleV2 directly,
///         replacing the prior `chainlinkOracle` config that was the wrong type.)
/// @dev Load configuration from environment variables. Run with:
///      forge script script/deploy/DeployLuminaV5Complete.s.sol --rpc-url $RPC --broadcast
contract DeployLuminaV5Complete is Script {
    // ═══════ CONFIG ═══════

    struct DeploymentConfig {
        address usdc;
        address multisig;
        address lbpDeposit;
        address opsWallet;
        address founderRecipient;
        address aavePool;
        // ─── Sprint B additions ───
        address oracleKey; // EOA signer key for LuminaOracleV2 EIP-712 proofs
        address sequencerUptimeFeed; // Chainlink L2 sequencer feed; address(0) on Sepolia
        address aerodromeRouter;
        address aerodromeFactory;
        address uniswapV3Router;
        address uniswapV3Quoter;
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
        // [Sprint T-30a Phase B] shield struct fields removed; re-added in Phase C
        // with new shield names.
        // ─── Sprint B additions ───
        address luminaOracleV2;
        address shieldKeeper;
        address aerodromeAdapter;
        address uniswapV3Adapter;
    }

    /// @dev `external virtual` so subclasses (e.g. `DeployLuminaV5Mainnet`) can
    ///      override `run()` and chain into this base via `super.run()`. The
    ///      pre-fix wrapper used `new Complete() + completeRunner.run()` which
    ///      made `msg.sender` inside `Complete.run()` equal the wrapper instance
    ///      (not the broadcaster EOA), breaking the nonce-based LUMINA proxy
    ///      precompute at STEP 8. Fork dry-run 2026-05-28 surfaced this. The
    ///      inheritance pattern fixes it because `super.run()` is an internal
    ///      dispatch — `msg.sender` propagates unchanged from the caller.
    function run() public virtual {
        // ───── Load config from env ─────
        DeploymentConfig memory cfg = DeploymentConfig({
            usdc: vm.envAddress("USDC_ADDRESS"),
            multisig: vm.envAddress("MULTISIG"),
            lbpDeposit: vm.envAddress("LBP_DEPOSIT"),
            opsWallet: vm.envAddress("OPS_WALLET"),
            founderRecipient: vm.envAddress("FOUNDER_RECIPIENT"),
            aavePool: vm.envAddress("AAVE_POOL"),
            // ─── Sprint B additions ───
            oracleKey: vm.envAddress("ORACLE_KEY"),
            sequencerUptimeFeed: vm.envAddress("SEQUENCER_UPTIME_FEED"),
            aerodromeRouter: vm.envAddress("AERODROME_ROUTER"),
            aerodromeFactory: vm.envAddress("AERODROME_FACTORY"),
            uniswapV3Router: vm.envAddress("UNISWAP_V3_ROUTER"),
            uniswapV3Quoter: vm.envAddress("UNISWAP_V3_QUOTER")
        });

        DeploymentResult memory res;

        vm.startBroadcast();

        address deployer = msg.sender;

        // ═══════════════════════════════════════════════════════
        // STEP 0a: LuminaOracleV2 (no Lumina deps; needs oracleKey + L2 sequencer feed)
        // ═══════════════════════════════════════════════════════
        LuminaOracleV2 luminaOracleV2 = new LuminaOracleV2(deployer, cfg.oracleKey, cfg.sequencerUptimeFeed);
        res.luminaOracleV2 = address(luminaOracleV2);
        console.log("0a. LuminaOracleV2:", res.luminaOracleV2);

        // ═══════════════════════════════════════════════════════
        // STEP 0b: AerodromeAdapter (testnet-only path: skip when AERODROME_ROUTER==0).
        //          Aerodrome doesn't have a Sepolia deployment; on testnet we
        //          run with UniswapV3Adapter only.
        // ═══════════════════════════════════════════════════════
        AerodromeAdapter aerodromeAdapter;
        if (cfg.aerodromeRouter != address(0)) {
            aerodromeAdapter = new AerodromeAdapter(cfg.aerodromeRouter, cfg.aerodromeFactory, false);
            res.aerodromeAdapter = address(aerodromeAdapter);
            console.log("0b. AerodromeAdapter:", res.aerodromeAdapter);
        } else {
            res.aerodromeAdapter = address(0);
            console.log("0b. [SKIP] AerodromeAdapter (testnet path: Aerodrome not on Sepolia)");
        }

        // ═══════════════════════════════════════════════════════
        // STEP 0c: UniswapV3Adapter (no Lumina deps; pool fee 0.3%)
        // ═══════════════════════════════════════════════════════
        UniswapV3Adapter uniswapV3Adapter = new UniswapV3Adapter(cfg.uniswapV3Router, cfg.uniswapV3Quoter, 3000);
        res.uniswapV3Adapter = address(uniswapV3Adapter);
        console.log("0c. UniswapV3Adapter:", res.uniswapV3Adapter);

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
        // [Sprint B] STEP 0a/0b/0c added BEFORE this line. They consume nonces but
        // are read AFTER `vm.getNonce`, so the +10 offset is unchanged.
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
        // [Sprint FV, ADR-025] Oracle wiring fix: FV needs LuminaOracleV2 (EIP-712 price oracle
        //   with getLatestPrice(bytes32)), NOT CapacityOracle (different ABI). On Sepolia this
        //   resolves to LuminaOracleV2 SET A 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194 via the
        //   deploy-time `res.luminaOracleV2` variable populated at STEP 0a.
        FounderVesting founderVesting =
            new FounderVesting(res.luminaOracleV2, cfg.aavePool, precomputedLumina, cfg.usdc, cfg.founderRecipient);
        res.founderVesting = address(founderVesting);
        console.log("6. FounderVesting:", res.founderVesting);
        console.log("   oracle (LuminaOracleV2):", res.luminaOracleV2);

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
            abi.encodeWithSelector(TWAPBurner.initialize.selector, cfg.usdc, res.luminaToken, res.uniswapV3Adapter)
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
        // STEP 14b: ShieldKeeper via UUPS proxy (Chainlink Automation interface).
        // Reads from PolicyManagerV2 to enumerate active policies for keeper-driven settlement.
        // ═══════════════════════════════════════════════════════
        ShieldKeeper shieldKeeperImpl = new ShieldKeeper();
        ERC1967Proxy shieldKeeperProxy = new ERC1967Proxy(
            address(shieldKeeperImpl), abi.encodeWithSelector(ShieldKeeper.initialize.selector, res.policyManager)
        );
        ShieldKeeper shieldKeeper = ShieldKeeper(address(shieldKeeperProxy));
        res.shieldKeeper = address(shieldKeeper);
        console.log("14b. ShieldKeeper (proxy):", res.shieldKeeper);

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
        // STEP 19: Deploy Shields
        // [Sprint T-30a Phase B] Shield deploy block removed. New shield set
        // (drop-from-purchase mechanic) lands in Phase C with the new
        // BaseFlashShield base contract + Chainlink direct-read constructor
        // signatures. Until then, the script deploys core protocol only.
        // RateShockShield NOT replaced (founder decision: removed permanently).
        // TODO Phase C: re-introduce shield impls + proxies + res.* assignments.
        // ═══════════════════════════════════════════════════════

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

        // [Sprint B+C] Configure TWAPBurner DEX routers. Mainnet: aerodrome+uniswap.
        // Testnet (Sepolia): uniswap-only (Aerodrome doesn't deploy to Sepolia).
        address[] memory dexRouters;
        if (res.aerodromeAdapter != address(0)) {
            dexRouters = new address[](2);
            dexRouters[0] = res.aerodromeAdapter;
            dexRouters[1] = res.uniswapV3Adapter;
        } else {
            dexRouters = new address[](1);
            dexRouters[0] = res.uniswapV3Adapter;
        }
        twapBurner.setDexRouters(dexRouters);
        console.log("  TWAPBurner configured (dex routers count):", dexRouters.length);

        // Authorize BuybackEngine in BondVault (deployer has AUTHORIZED_CALLER_ADMIN_ROLE)
        bondVault.setAuthorizedCaller(res.buybackEngine, true);
        console.log("  BuybackEngine authorized in BondVault");

        // [Fix audit #31 CRITICAL] Authorize Marketplace + BuybackEngine as ClaimBond operators.
        // Without these, Fix #18's transfer whitelist makes the Marketplace 100% non-functional
        // (sellers cannot list bonds, buybacks cannot complete). MUST run pre-launch.
        claimBond.setAuthorizedOperator(res.marketplace, true);
        claimBond.setAuthorizedOperator(res.buybackEngine, true);
        console.log("  Marketplace + BuybackEngine authorized as ClaimBond operators");

        // PolicyManagerV2.registerProduct
        // [Sprint T-30a Phase B] product registration removed (old shields deleted).
        // Phase C re-adds registerProduct() calls keyed to the new PRODUCT_IDs.
        // TODO Phase C: policyManager.registerProduct(<NEW_PRODUCT_ID>, <newShield>) per shield.

        // CoverRouterV2.setCapacityOracle (auto-pause at MIN_PRICE_FOR_NEW_POLICIES)
        coverRouter.setCapacityOracle(res.capacityOracle);
        console.log("  CoverRouterV2.setCapacityOracle done");

        // CoverRouterV2.configureProduct
        // [Sprint T-30a Phase B] product configuration removed (old shields deleted).
        // TODO Phase C: re-introduce _configureProducts(coverRouter, res) for the new set.
        // _configureProducts(coverRouter, res);

        // ═══════════════════════════════════════════════════════
        // OWNERSHIP TRANSFER to multisig
        // ═══════════════════════════════════════════════════════
        // [Post-dryrun 2026-05-28, ADR-027] PolicyManagerV2 + CoverRouterV2
        //   transfers can be DEFERRED via the `DEFER_PM_CR_OWNERSHIP` env flag,
        //   so the deployer remains owner long enough to register Phase C
        //   shields/products (which require onlyOwner). The mainnet wrapper
        //   `DeployLuminaV5Mainnet` sets the flag, runs Phase C, then performs
        //   the deferred transfer itself. Default behavior unchanged (flag
        //   defaults to false) → existing tests continue to assert
        //   `policyManager.owner() == multisig` post-deploy.
        bool deferPmCr = vm.envOr("DEFER_PM_CR_OWNERSHIP", false);
        console.log("--- OWNERSHIP TRANSFER --- (deferPmCr =", deferPmCr ? "true)" : "false)");

        twapBurner.transferOwnership(cfg.multisig);
        if (!deferPmCr) {
            coverRouter.transferOwnership(cfg.multisig);
            policyManager.transferOwnership(cfg.multisig);
        } else {
            console.log("  [DEFERRED] CoverRouter + PolicyManager ownership stays with deployer for Phase C");
        }
        capacityOracle.transferOwnership(cfg.multisig);
        founderVesting.transferOwnership(cfg.multisig);
        treasuryVesting.transferOwnership(cfg.multisig);
        claimBond.transferOwnership(cfg.multisig);

        // [Sprint B+C] Transfer ownership of new contracts to multisig.
        // AerodromeAdapter: skip if not deployed (testnet path).
        luminaOracleV2.transferOwnership(cfg.multisig);
        if (res.aerodromeAdapter != address(0)) aerodromeAdapter.transferOwnership(cfg.multisig);
        uniswapV3Adapter.transferOwnership(cfg.multisig);
        shieldKeeper.transferOwnership(cfg.multisig);

        // [Sprint T, ADR-012] DEPLOYER MAINTAINS ADMIN ROLE — multisig
        //   transfer is now a SEPARATE flow (mainnet only). The previous
        //   in-script revoke caused BondVault SET B (Sepolia,
        //   0x9EfdD63B...3726c) to lock at 0 admin holders ~3min after deploy
        //   when `cfg.multisig` was misconfigured to the deployer address —
        //   `revokeRole(role, msg.sender)` then dropped the only holder.
        //
        //   The lines below were previously:
        //     bondVault.grantRole(AUTHORIZED_CALLER_ADMIN_ROLE, cfg.multisig);
        //     bondVault.grantRole(DEFAULT_ADMIN_ROLE,           cfg.multisig);
        //     bondVault.revokeRole(AUTHORIZED_CALLER_ADMIN_ROLE, msg.sender);
        //     bondVault.revokeRole(DEFAULT_ADMIN_ROLE,           msg.sender);
        //     luminaToken.grantRole(DEFAULT_ADMIN_ROLE, cfg.multisig);
        //     luminaToken.revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        //
        //   For mainnet, run a SEPARATE post-deploy script that:
        //     1. Verifies cfg.multisig responds (multisig sends a noop tx).
        //     2. grantRole(...) to multisig.
        //     3. ONLY THEN revokeRole(...) from deployer.
        //     4. Verifies multisig has the role post-revoke.
        console.log("  DEPLOYER MAINTAINS ADMIN ROLE on BondVault + LuminaTokenV2");
        console.log("  (transfer to multisig is a separate mainnet flow -- see ADR-012)");

        // [Sprint T, ADR-012] Post-deploy invariant: deployer must end up with
        //   both BondVault admin roles + LuminaToken admin role. Catches any
        //   regression that re-introduces the self-revoke.
        require(
            bondVault.hasRole(bondVault.DEFAULT_ADMIN_ROLE(), msg.sender),
            "Deployer must keep BondVault DEFAULT_ADMIN_ROLE"
        );
        require(
            bondVault.hasRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), msg.sender),
            "Deployer must keep BondVault AUTHORIZED_CALLER_ADMIN_ROLE"
        );
        require(
            luminaToken.hasRole(luminaToken.DEFAULT_ADMIN_ROLE(), msg.sender),
            "Deployer must keep LuminaToken DEFAULT_ADMIN_ROLE"
        );

        vm.stopBroadcast();

        // [Post-dryrun 2026-05-28, ADR-027] Export the addresses subclass scripts
        //   (e.g. `DeployLuminaV5Mainnet`) need to chain into Phase C + the
        //   deferred PM/CR ownership handoff. Keys are prefixed `DEPLOY_OUT_*`
        //   to make their downstream-only role obvious in shell history.
        vm.setEnv("DEPLOY_OUT_LUMINA_TOKEN",    vm.toString(res.luminaToken));
        vm.setEnv("DEPLOY_OUT_BOND_VAULT",      vm.toString(res.bondVault));
        vm.setEnv("DEPLOY_OUT_CLAIM_BOND",      vm.toString(res.claimBond));
        vm.setEnv("DEPLOY_OUT_CAPACITY_ORACLE", vm.toString(res.capacityOracle));
        vm.setEnv("DEPLOY_OUT_POLICY_MANAGER",  vm.toString(res.policyManager));
        vm.setEnv("DEPLOY_OUT_COVER_ROUTER",    vm.toString(res.coverRouter));
        vm.setEnv("DEPLOY_OUT_TWAP_BURNER",     vm.toString(res.twapBurner));
        vm.setEnv("DEPLOY_OUT_SOLVENCY_ORACLE", vm.toString(res.solvencyOracle));
        vm.setEnv("DEPLOY_OUT_LUMINA_ORACLE_V2",vm.toString(res.luminaOracleV2));
        vm.setEnv("DEPLOY_OUT_SHIELD_KEEPER",   vm.toString(res.shieldKeeper));

        // ═══════════════════════════════════════════════════════
        // FINAL LOG: All deployed addresses
        // ═══════════════════════════════════════════════════════
        console.log("===== LUMINA V5.0 DEPLOYMENT COMPLETE (core only; shields pending Phase C) =====");
        console.log("LuminaTokenV2:          ", res.luminaToken);
        console.log("BondVault:              ", res.bondVault);
        console.log("ClaimBond:              ", res.claimBond);
        console.log("CapacityOracle:         ", res.capacityOracle);
        console.log("SolvencyOracle:         ", res.solvencyOracle);
        console.log("LuminaOracleV2:         ", res.luminaOracleV2);
        console.log("AdaptiveFeeDistributor: ", res.adaptiveFeeDistributor);
        console.log("TWAPBurner:             ", res.twapBurner);
        console.log("PolicyManagerV2:        ", res.policyManager);
        console.log("CoverRouterV2:          ", res.coverRouter);
        console.log("ShieldKeeper:           ", res.shieldKeeper);
        console.log("CEXLiquidityReserve:    ", res.cexLiquidityReserve);
        console.log("MaintenanceReserve:     ", res.maintenanceReserve);
        console.log("FounderVesting:         ", res.founderVesting);
        console.log("TreasuryVesting:        ", res.treasuryVesting);
        console.log("LuminaBondMarketplace:  ", res.marketplace);
        console.log("BuybackEngine:          ", res.buybackEngine);
        if (res.aerodromeAdapter != address(0)) {
            console.log("AerodromeAdapter:       ", res.aerodromeAdapter);
        } else {
            console.log("AerodromeAdapter:        SKIPPED (testnet)");
        }
        console.log("UniswapV3Adapter:       ", res.uniswapV3Adapter);
        // [Sprint T-30a Phase B] Shield address logs removed; re-added in Phase C
        // with the new shield names.
        console.log("===========================================");
    }

    // [Sprint T-30a Phase B] _configureProducts() removed; new shields land in Phase C
    // with their own configureProduct() parameters.
}
