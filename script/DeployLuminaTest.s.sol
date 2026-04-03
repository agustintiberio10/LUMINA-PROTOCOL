// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mocks
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

// Oracle + Verifier
import {LuminaOracle} from "../src/oracles/LuminaOracle.sol";
import {LuminaPhalaVerifier} from "../src/oracles/LuminaPhalaVerifier.sol";

// Core (UUPS)
import {CoverRouter} from "../src/core/CoverRouter.sol";
import {PolicyManager} from "../src/core/PolicyManager.sol";

// Vaults (UUPS)
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {StableLongVault} from "../src/vaults/StableLongVault.sol";

// Products (non-upgradeable)
import {BlackSwanShield} from "../src/products/BlackSwanShield.sol";
import {DepegShield} from "../src/products/DepegShield.sol";
import {ILIndexCover} from "../src/products/ILIndexCover.sol";
import {ExploitShield} from "../src/products/ExploitShield.sol";

/**
 * @title DeployLuminaTest
 * @notice Complete testnet deployment of the entire Lumina Protocol stack.
 *
 *   Deploys mocks (USDC, aToken, AavePool), oracle, Phala verifier,
 *   PolicyManager, CoverRouter, 4 vaults, 4 shields, and wires everything up.
 *
 * Usage:
 *   forge script script/DeployLuminaTest.s.sol:DeployLuminaTest \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast -vvvv
 */
contract DeployLuminaTest is Script {

    // Fee config
    address constant FEE_RECEIVER = 0x2b4D825417f568231e809E31B9332ED146760337;
    uint16  constant FEE_BPS      = 300; // 3%

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("=== Lumina Protocol Full Testnet Deploy ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════════════════════
        //  1. DEPLOY MOCKS
        // ═══════════════════════════════════════════════════════════

        // 1a. MockERC20 — USDC (6 decimals)
        MockERC20 usdc = new MockERC20("USD Coin Mock", "USDC", 6);
        console.log("MockUSDC:", address(usdc));

        // 1b. MockERC20 — aToken (Aave Base USDC, 6 decimals)
        MockERC20 aToken = new MockERC20("Aave Base USDC Mock", "aBasUSDC", 6);
        console.log("MockAToken:", address(aToken));

        // 1c. MockAavePool
        MockAavePool aavePool = new MockAavePool(address(aToken));
        console.log("MockAavePool:", address(aavePool));

        // 1d. Fund MockAavePool with USDC so it can honour withdrawals
        //     Mint 10M USDC to the pool
        usdc.mint(address(aavePool), 10_000_000e6);
        console.log("MockAavePool funded with 10M USDC");

        // ═══════════════════════════════════════════════════════════
        //  2. DEPLOY ORACLE
        //     constructor(owner_, oracleKey_, sequencerUptimeFeed_)
        //     sequencerUptimeFeed_ = address(0) for testnet (skips check)
        // ═══════════════════════════════════════════════════════════

        LuminaOracle oracle = new LuminaOracle(
            deployer,           // owner
            deployer,           // oracleKey (deployer signs quotes on testnet)
            address(0)          // no sequencer feed on testnet
        );
        console.log("LuminaOracle:", address(oracle));

        // ═══════════════════════════════════════════════════════════
        //  3. DEPLOY PHALA VERIFIER
        //     constructor(owner_, initialWorker_)
        // ═══════════════════════════════════════════════════════════

        LuminaPhalaVerifier phala = new LuminaPhalaVerifier(
            deployer,           // owner
            deployer            // initialWorker (deployer acts as TEE on testnet)
        );
        console.log("LuminaPhalaVerifier:", address(phala));

        // ═══════════════════════════════════════════════════════════
        //  4. DEPLOY POLICYMANAGER (UUPS proxy)
        //     Circular dependency resolution:
        //       PM needs router, Router needs PM.
        //       Solution: deploy PM with deployer as temporary router,
        //       then deploy Router, then update PM router.
        //     initialize(owner_, router_)
        // ═══════════════════════════════════════════════════════════

        PolicyManager pmImpl = new PolicyManager();
        bytes memory pmData = abi.encodeCall(
            PolicyManager.initialize,
            (deployer, deployer) // owner, router = deployer (temporary)
        );
        ERC1967Proxy pmProxy = new ERC1967Proxy(address(pmImpl), pmData);
        address policyManagerAddr = address(pmProxy);
        console.log("PolicyManager impl:", address(pmImpl));
        console.log("PolicyManager proxy:", policyManagerAddr);

        // ═══════════════════════════════════════════════════════════
        //  5. DEPLOY COVERROUTER (UUPS proxy)
        //     initialize(owner_, oracle_, phalaVerifier_, policyManager_,
        //                usdcToken_, isTestnet_, feeReceiver_, feeBps_)
        // ═══════════════════════════════════════════════════════════

        CoverRouter routerImpl = new CoverRouter();
        bytes memory routerData = abi.encodeCall(
            CoverRouter.initialize,
            (
                deployer,                   // owner
                address(oracle),            // oracle
                address(phala),             // phalaVerifier
                policyManagerAddr,          // policyManager
                address(usdc),              // usdcToken
                true,                       // isTestnet
                FEE_RECEIVER,               // feeReceiver
                FEE_BPS                     // feeBps (300 = 3%)
            )
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerData);
        address coverRouterAddr = address(routerProxy);
        console.log("CoverRouter impl:", address(routerImpl));
        console.log("CoverRouter proxy:", coverRouterAddr);

        // ═══════════════════════════════════════════════════════════
        //  6. UPDATE POLICYMANAGER ROUTER to real CoverRouter
        // ═══════════════════════════════════════════════════════════

        PolicyManager(policyManagerAddr).setRouter(coverRouterAddr);
        console.log("PolicyManager router -> CoverRouter (updated)");

        // ═══════════════════════════════════════════════════════════
        //  7. DEPLOY 4 VAULTS (UUPS proxies)
        //     initialize(owner_, asset_, router_, policyManager_, aavePool_, aToken_)
        // ═══════════════════════════════════════════════════════════

        // 7a. VolatileShort — 30d cooldown
        VolatileShortVault vsImpl = new VolatileShortVault();
        bytes memory vsData = abi.encodeCall(
            VolatileShortVault.initialize,
            (deployer, address(usdc), coverRouterAddr, policyManagerAddr, address(aavePool), address(aToken))
        );
        ERC1967Proxy vsProxy = new ERC1967Proxy(address(vsImpl), vsData);
        address volatileShortAddr = address(vsProxy);
        console.log("VolatileShort impl:", address(vsImpl));
        console.log("VolatileShort proxy:", volatileShortAddr);

        // 7b. VolatileLong — 90d cooldown
        VolatileLongVault vlImpl = new VolatileLongVault();
        bytes memory vlData = abi.encodeCall(
            VolatileLongVault.initialize,
            (deployer, address(usdc), coverRouterAddr, policyManagerAddr, address(aavePool), address(aToken))
        );
        ERC1967Proxy vlProxy = new ERC1967Proxy(address(vlImpl), vlData);
        address volatileLongAddr = address(vlProxy);
        console.log("VolatileLong impl:", address(vlImpl));
        console.log("VolatileLong proxy:", volatileLongAddr);

        // 7c. StableShort — 90d cooldown
        StableShortVault ssImpl = new StableShortVault();
        bytes memory ssData = abi.encodeCall(
            StableShortVault.initialize,
            (deployer, address(usdc), coverRouterAddr, policyManagerAddr, address(aavePool), address(aToken))
        );
        ERC1967Proxy ssProxy = new ERC1967Proxy(address(ssImpl), ssData);
        address stableShortAddr = address(ssProxy);
        console.log("StableShort impl:", address(ssImpl));
        console.log("StableShort proxy:", stableShortAddr);

        // 7d. StableLong — 365d cooldown
        StableLongVault slImpl = new StableLongVault();
        bytes memory slData = abi.encodeCall(
            StableLongVault.initialize,
            (deployer, address(usdc), coverRouterAddr, policyManagerAddr, address(aavePool), address(aToken))
        );
        ERC1967Proxy slProxy = new ERC1967Proxy(address(slImpl), slData);
        address stableLongAddr = address(slProxy);
        console.log("StableLong impl:", address(slImpl));
        console.log("StableLong proxy:", stableLongAddr);

        // ═══════════════════════════════════════════════════════════
        //  8. DEPLOY 4 SHIELDS (non-upgradeable, immutable router + oracle)
        // ═══════════════════════════════════════════════════════════

        // 8a. BlackSwanShield — constructor(router_, oracle_)
        BlackSwanShield bss = new BlackSwanShield(coverRouterAddr, address(oracle));
        console.log("BlackSwanShield:", address(bss));

        // 8b. DepegShield — constructor(router_, oracle_)
        DepegShield depeg = new DepegShield(coverRouterAddr, address(oracle));
        console.log("DepegShield:", address(depeg));

        // 8c. ILIndexCover — constructor(router_, oracle_)
        ILIndexCover il = new ILIndexCover(coverRouterAddr, address(oracle));
        console.log("ILIndexCover:", address(il));

        // 8d. ExploitShield — constructor(router_, oracle_, phalaVerifier_)
        ExploitShield exploit = new ExploitShield(coverRouterAddr, address(oracle), address(phala));
        console.log("ExploitShield:", address(exploit));

        // ═══════════════════════════════════════════════════════════
        //  9. REGISTER PRODUCTS in CoverRouter
        //     registerProduct(productId, shield, riskType, maxAllocationBps)
        //     CoverRouter.registerProduct also calls PM.registerProduct atomically
        // ═══════════════════════════════════════════════════════════

        CoverRouter router = CoverRouter(coverRouterAddr);

        router.registerProduct(
            keccak256("BLACKSWAN-001"),
            address(bss),
            keccak256("VOLATILE"),
            2000 // 20% max allocation
        );
        console.log("Registered: BlackSwanShield (VOLATILE)");

        router.registerProduct(
            keccak256("DEPEG-STABLE-001"),
            address(depeg),
            keccak256("STABLE"),
            2000 // 20% max allocation
        );
        console.log("Registered: DepegShield (STABLE)");

        router.registerProduct(
            keccak256("ILPROT-001"),
            address(il),
            keccak256("VOLATILE"),
            2000 // 20% max allocation
        );
        console.log("Registered: ILIndexCover (VOLATILE)");

        router.registerProduct(
            keccak256("EXPLOIT-001"),
            address(exploit),
            keccak256("STABLE"),
            1000 // 10% max allocation (as per contract constant)
        );
        console.log("Registered: ExploitShield (STABLE)");

        // ═══════════════════════════════════════════════════════════
        //  10. REGISTER VAULTS in PolicyManager
        //      registerVault(vault, riskType, cooldownDuration, priority)
        //      Lower priority = tried first in waterfall
        // ═══════════════════════════════════════════════════════════

        PolicyManager pm = PolicyManager(policyManagerAddr);

        pm.registerVault(volatileShortAddr, keccak256("VOLATILE"), 30 days,  1);
        console.log("Registered vault: VolatileShort (VOLATILE, 30d, priority 1)");

        pm.registerVault(volatileLongAddr,  keccak256("VOLATILE"), 90 days,  2);
        console.log("Registered vault: VolatileLong (VOLATILE, 90d, priority 2)");

        pm.registerVault(stableShortAddr,   keccak256("STABLE"),   90 days,  1);
        console.log("Registered vault: StableShort (STABLE, 90d, priority 1)");

        pm.registerVault(stableLongAddr,    keccak256("STABLE"),   365 days, 2);
        console.log("Registered vault: StableLong (STABLE, 365d, priority 2)");

        // ═══════════════════════════════════════════════════════════
        //  11. CORRELATION GROUPS — Actuarial risk mitigation
        //      BSS + IL share VolatileShort and are correlated (ETH crash
        //      triggers both). Combined cap of 70% limits worst-case LP loss
        //      from ~66% to ~45%.
        // ═══════════════════════════════════════════════════════════

        bytes32 groupEthCrash = keccak256("GROUP_ETH_CRASH");
        pm.createCorrelationGroup(groupEthCrash, 7000); // 70% combined cap
        console.log("Created correlation group: GROUP_ETH_CRASH (70% cap)");

        pm.addProductToGroup(keccak256("BLACKSWAN-001"), groupEthCrash);
        console.log("Added BSS to GROUP_ETH_CRASH");

        pm.addProductToGroup(keccak256("ILPROT-001"), groupEthCrash);
        console.log("Added IL to GROUP_ETH_CRASH");

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════
        //  11. LOG ALL DEPLOYED ADDRESSES
        // ═══════════════════════════════════════════════════════════

        console.log("");
        console.log("=============================================");
        console.log("  LUMINA PROTOCOL - FULL DEPLOYMENT SUMMARY");
        console.log("=============================================");
        console.log("");
        console.log("--- Mocks ---");
        console.log("MockUSDC:            ", address(usdc));
        console.log("MockAToken:          ", address(aToken));
        console.log("MockAavePool:        ", address(aavePool));
        console.log("");
        console.log("--- Oracle & Verifier ---");
        console.log("LuminaOracle:        ", address(oracle));
        console.log("LuminaPhalaVerifier: ", address(phala));
        console.log("");
        console.log("--- Core (UUPS proxies) ---");
        console.log("PolicyManager proxy: ", policyManagerAddr);
        console.log("PolicyManager impl:  ", address(pmImpl));
        console.log("CoverRouter proxy:   ", coverRouterAddr);
        console.log("CoverRouter impl:    ", address(routerImpl));
        console.log("");
        console.log("--- Vaults (UUPS proxies) ---");
        console.log("VolatileShort proxy: ", volatileShortAddr);
        console.log("VolatileLong proxy:  ", volatileLongAddr);
        console.log("StableShort proxy:   ", stableShortAddr);
        console.log("StableLong proxy:    ", stableLongAddr);
        console.log("");
        console.log("--- Shields ---");
        console.log("BlackSwanShield:     ", address(bss));
        console.log("DepegShield:         ", address(depeg));
        console.log("ILIndexCover:        ", address(il));
        console.log("ExploitShield:       ", address(exploit));
        console.log("");
        console.log("--- Config ---");
        console.log("Fee receiver:        ", FEE_RECEIVER);
        console.log("Fee BPS:              300 (3%)");
        console.log("Testnet mode:         true");
        console.log("=============================================");
    }
}
