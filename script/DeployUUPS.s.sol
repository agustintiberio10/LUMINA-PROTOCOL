// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Implementations
import {CoverRouter} from "../src/core/CoverRouter.sol";
import {PolicyManager} from "../src/core/PolicyManager.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {StableLongVault} from "../src/vaults/StableLongVault.sol";
import {BlackSwanShield} from "../src/products/BlackSwanShield.sol";
import {DepegShield} from "../src/products/DepegShield.sol";
import {ILIndexCover} from "../src/products/ILIndexCover.sol";
import {ExploitShield} from "../src/products/ExploitShield.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployUUPS is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Addresses from first deploy (Deploy.s.sol)
        address usdc = vm.envAddress("USDC_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address phala = vm.envAddress("PHALA_ADDRESS");

        // Fee config
        address feeReceiver = 0x2b4D825417f568231e809E31B9332ED146760337;
        uint16 feeBps = 300; // 3%

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════════════════════
        // DEPLOY ORDER (circular dependency resolution):
        //   1. PolicyManager with deployer as temporary router
        //   2. CoverRouter with real PM address
        //   3. Update PM router to real CoverRouter via setRouter()
        // ═══════════════════════════════════════════════════════════

        // ═══════════════════════════════════════════
        // 1. Deploy PolicyManager (UUPS proxy) — temporary router = deployer
        // ═══════════════════════════════════════════
        PolicyManager pmImpl = new PolicyManager();
        bytes memory pmData = abi.encodeCall(
            PolicyManager.initialize,
            (deployer, deployer) // owner, router (deployer as temp router)
        );
        ERC1967Proxy pmProxy = new ERC1967Proxy(address(pmImpl), pmData);
        console.log("PolicyManager proxy:", address(pmProxy));

        // ═══════════════════════════════════════════
        // 2. Deploy CoverRouter (UUPS proxy) — with real PM address
        // ═══════════════════════════════════════════
        CoverRouter routerImpl = new CoverRouter();
        bytes memory routerData = abi.encodeCall(
            CoverRouter.initialize,
            (deployer, oracle, phala, address(pmProxy), usdc, true, feeReceiver, feeBps)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerData);
        console.log("CoverRouter proxy:", address(routerProxy));

        // ═══════════════════════════════════════════
        // 3. Update PolicyManager router to real CoverRouter
        // ═══════════════════════════════════════════
        PolicyManager(address(pmProxy)).setRouter(address(routerProxy));
        console.log("PM router updated to CoverRouter");

        // ═══════════════════════════════════════════
        // 4. Deploy Vaults (UUPS proxies)
        //    initialize(owner_, asset_, router_, policyManager_)
        // ═══════════════════════════════════════════

        // Volatile Short (30d cooldown)
        VolatileShortVault vsImpl = new VolatileShortVault();
        bytes memory vsData = abi.encodeCall(
            VolatileShortVault.initialize,
            (deployer, usdc, address(routerProxy), address(pmProxy))
        );
        ERC1967Proxy vsProxy = new ERC1967Proxy(address(vsImpl), vsData);
        console.log("VolatileShort proxy:", address(vsProxy));

        // Volatile Long (90d cooldown)
        VolatileLongVault vlImpl = new VolatileLongVault();
        bytes memory vlData = abi.encodeCall(
            VolatileLongVault.initialize,
            (deployer, usdc, address(routerProxy), address(pmProxy))
        );
        ERC1967Proxy vlProxy = new ERC1967Proxy(address(vlImpl), vlData);
        console.log("VolatileLong proxy:", address(vlProxy));

        // Stable Short (90d cooldown)
        StableShortVault ssImpl = new StableShortVault();
        bytes memory ssData = abi.encodeCall(
            StableShortVault.initialize,
            (deployer, usdc, address(routerProxy), address(pmProxy))
        );
        ERC1967Proxy ssProxy = new ERC1967Proxy(address(ssImpl), ssData);
        console.log("StableShort proxy:", address(ssProxy));

        // Stable Long (365d cooldown)
        StableLongVault slImpl = new StableLongVault();
        bytes memory slData = abi.encodeCall(
            StableLongVault.initialize,
            (deployer, usdc, address(routerProxy), address(pmProxy))
        );
        ERC1967Proxy slProxy = new ERC1967Proxy(address(slImpl), slData);
        console.log("StableLong proxy:", address(slProxy));

        // ═══════════════════════════════════════════
        // 5. Deploy Shields (non-UUPS, immutable router/oracle)
        // ═══════════════════════════════════════════
        BlackSwanShield bss = new BlackSwanShield(address(routerProxy), oracle);
        console.log("BlackSwanShield:", address(bss));

        DepegShield depeg = new DepegShield(address(routerProxy), oracle);
        console.log("DepegShield:", address(depeg));

        ILIndexCover il = new ILIndexCover(address(routerProxy), oracle);
        console.log("ILIndexCover:", address(il));

        ExploitShield exploit = new ExploitShield(address(routerProxy), oracle, phala);
        console.log("ExploitShield:", address(exploit));

        // ═══════════════════════════════════════════
        // 6. Register products in CoverRouter
        //    registerProduct(productId, shield, riskType, maxAllocationBps)
        //    Product IDs from contract constants:
        //      BlackSwanShield.PRODUCT_ID  = keccak256("BLACKSWAN-001")
        //      DepegShield.PRODUCT_ID      = keccak256("DEPEG-STABLE-001")
        //      ILIndexCover.PRODUCT_ID     = keccak256("ILPROT-001")
        //      ExploitShield.PRODUCT_ID    = keccak256("EXPLOIT-001")
        // ═══════════════════════════════════════════
        CoverRouter router = CoverRouter(address(routerProxy));

        router.registerProduct(keccak256("BLACKSWAN-001"), address(bss), keccak256("VOLATILE"), 5000);
        router.registerProduct(keccak256("DEPEG-STABLE-001"), address(depeg), keccak256("STABLE"), 5000);
        router.registerProduct(keccak256("ILPROT-001"), address(il), keccak256("VOLATILE"), 5000);
        router.registerProduct(keccak256("EXPLOIT-001"), address(exploit), keccak256("VOLATILE"), 5000);
        console.log("4 products registered in CoverRouter");

        // ═══════════════════════════════════════════
        // 7. Register vaults in PolicyManager
        //    registerVault(vault, riskType, cooldownDuration, priority)
        // ═══════════════════════════════════════════
        PolicyManager pm = PolicyManager(address(pmProxy));

        pm.registerVault(address(vsProxy), keccak256("VOLATILE"), 30 days, 1);
        pm.registerVault(address(vlProxy), keccak256("VOLATILE"), 90 days, 2);
        pm.registerVault(address(ssProxy), keccak256("STABLE"), 90 days, 1);
        pm.registerVault(address(slProxy), keccak256("STABLE"), 365 days, 2);
        console.log("4 vaults registered in PolicyManager");

        // ═══════════════════════════════════════════
        // 8. Seed liquidity — SKIPPED
        //    BaseVault.MIN_DEPOSIT = 1e15 is too high for 6-decimal USDC
        //    Will fix MIN_DEPOSIT and seed separately
        // ═══════════════════════════════════════════

        // ═══════════════════════════════════════════
        // 9. Log all addresses
        // ═══════════════════════════════════════════
        console.log("--- FULL DEPLOYMENT COMPLETE ---");
        console.log("CoverRouter:", address(routerProxy));
        console.log("PolicyManager:", address(pmProxy));
        console.log("VolatileShort:", address(vsProxy));
        console.log("VolatileLong:", address(vlProxy));
        console.log("StableShort:", address(ssProxy));
        console.log("StableLong:", address(slProxy));
        console.log("BlackSwanShield:", address(bss));
        console.log("DepegShield:", address(depeg));
        console.log("ILIndexCover:", address(il));
        console.log("ExploitShield:", address(exploit));
        console.log("NOTE: Seed liquidity skipped - MIN_DEPOSIT too high for 6-decimal USDC");

        vm.stopBroadcast();
    }
}
