// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LuminaOracle} from "../src/oracles/LuminaOracle.sol";
import {LuminaPhalaVerifier} from "../src/oracles/LuminaPhalaVerifier.sol";
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

/**
 * @title DeployProduction
 * @notice Production deployment of Lumina Protocol on Base L2 with real USDC + Aave V3.
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=0x... \
 *   forge script script/DeployProduction.s.sol:DeployProduction \
 *     --rpc-url https://mainnet.base.org --broadcast
 */
contract DeployProduction is Script {

    // ═══ External addresses (Base Mainnet) ═══
    address constant USDC           = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_POOL      = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_AUSDC     = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant SEQ_UPTIME     = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // ═══ Keys (rotated) ═══
    address constant ORACLE_KEY     = 0x933b15dd4F42bd2EE2794C1D188882aBCCDa977E;
    address constant RELAYER        = 0xEdA7774A071a8DDa0c8c98037Cb542A1ee6aC7Eb;

    // ═══ Governance ═══
    address constant FEE_RECEIVER   = 0x2b4D825417f568231e809E31B9332ED146760337;
    address constant TIMELOCK       = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;
    uint16  constant FEE_BPS        = 300; // 3%

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== LUMINA PROTOCOL - PRODUCTION DEPLOY ===");
        console.log("Deployer:", deployer);
        console.log("USDC:", USDC);
        console.log("Aave V3 Pool:", AAVE_POOL);

        vm.startBroadcast(deployerKey);

        // ═══ 1. ORACLE (with sequencer uptime feed) ═══
        LuminaOracle oracle = new LuminaOracle(deployer, ORACLE_KEY, SEQ_UPTIME);
        console.log("LuminaOracle:", address(oracle));

        // ═══ 2. PHALA VERIFIER ═══
        LuminaPhalaVerifier phala = new LuminaPhalaVerifier(deployer, deployer);
        console.log("LuminaPhalaVerifier:", address(phala));

        // ═══ 3. POLICY MANAGER (UUPS) ═══
        PolicyManager pmImpl = new PolicyManager();
        bytes memory pmData = abi.encodeCall(PolicyManager.initialize, (deployer, deployer));
        ERC1967Proxy pmProxy = new ERC1967Proxy(address(pmImpl), pmData);
        address pmAddr = address(pmProxy);
        console.log("PolicyManager proxy:", pmAddr);

        // ═══ 4. COVER ROUTER (UUPS) ═══
        CoverRouter routerImpl = new CoverRouter();
        bytes memory routerData = abi.encodeCall(
            CoverRouter.initialize,
            (deployer, address(oracle), address(phala), pmAddr, USDC, false, FEE_RECEIVER, FEE_BPS)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerData);
        address routerAddr = address(routerProxy);
        console.log("CoverRouter proxy:", routerAddr);

        // ═══ 5. UPDATE PM ROUTER ═══
        PolicyManager(pmAddr).setRouter(routerAddr);

        // ═══ 6. VAULTS (UUPS) ═══
        address vsAddr = _deployVault(address(new VolatileShortVault()), deployer, routerAddr, pmAddr);
        console.log("VolatileShort:", vsAddr);

        address vlAddr = _deployVault(address(new VolatileLongVault()), deployer, routerAddr, pmAddr);
        console.log("VolatileLong:", vlAddr);

        address ssAddr = _deployVault(address(new StableShortVault()), deployer, routerAddr, pmAddr);
        console.log("StableShort:", ssAddr);

        address slAddr = _deployVault(address(new StableLongVault()), deployer, routerAddr, pmAddr);
        console.log("StableLong:", slAddr);

        // ═══ 7. SHIELDS ═══
        BlackSwanShield bss = new BlackSwanShield(routerAddr, address(oracle));
        console.log("BlackSwanShield:", address(bss));

        DepegShield depeg = new DepegShield(routerAddr, address(oracle));
        console.log("DepegShield:", address(depeg));

        ILIndexCover il = new ILIndexCover(routerAddr, address(oracle));
        console.log("ILIndexCover:", address(il));

        ExploitShield exploit = new ExploitShield(routerAddr, address(oracle), address(phala));
        console.log("ExploitShield:", address(exploit));

        // ═══ 8. REGISTER PRODUCTS ═══
        CoverRouter router = CoverRouter(routerAddr);

        router.registerProduct(keccak256("BLACKSWAN-001"), address(bss), keccak256("VOLATILE"), 2000);
        router.registerProduct(keccak256("DEPEG-STABLE-001"), address(depeg), keccak256("STABLE"), 2000);
        router.registerProduct(keccak256("ILPROT-001"), address(il), keccak256("VOLATILE"), 2000);
        router.registerProduct(keccak256("EXPLOIT-001"), address(exploit), keccak256("STABLE"), 1000);
        console.log("Products registered");

        // ═══ 9. REGISTER VAULTS ═══
        PolicyManager pm = PolicyManager(pmAddr);

        pm.registerVault(vsAddr, keccak256("VOLATILE"), 30 days, 1);
        pm.registerVault(vlAddr, keccak256("VOLATILE"), 90 days, 2);
        pm.registerVault(ssAddr, keccak256("STABLE"), 90 days, 1);
        pm.registerVault(slAddr, keccak256("STABLE"), 365 days, 2);
        console.log("Vaults registered");

        // ═══ 10. AUTHORIZE RELAYER ═══
        router.setRelayer(RELAYER, true);
        console.log("Relayer authorized:", RELAYER);

        // ═══ 11. REGISTER CHAINLINK FEEDS ═══
        oracle.registerFeed(keccak256("ETH"), 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70, 1200);
        oracle.registerFeed(keccak256("BTC"), 0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E, 1200);
        oracle.registerFeed(keccak256("USDC"), 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B, 86400);
        oracle.registerFeed(keccak256("USDT"), 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9, 86400);
        oracle.registerFeed(keccak256("DAI"), 0x591e79239a7d679378eC8c847e5038150364C78F, 86400);
        console.log("Chainlink feeds registered");

        // ═══ 12. TRANSFER OWNERSHIP TO TIMELOCK ═══
        oracle.transferOwnership(TIMELOCK);
        phala.transferOwnership(TIMELOCK);
        PolicyManager(pmAddr).transferOwnership(TIMELOCK);
        router.transferOwnership(TIMELOCK);
        VolatileShortVault(vsAddr).transferOwnership(TIMELOCK);
        VolatileLongVault(vlAddr).transferOwnership(TIMELOCK);
        StableShortVault(ssAddr).transferOwnership(TIMELOCK);
        StableLongVault(slAddr).transferOwnership(TIMELOCK);
        console.log("Ownership transferred to TimelockController");

        vm.stopBroadcast();

        // ═══ SUMMARY ═══
        console.log("");
        console.log("=============================================");
        console.log("  LUMINA PROTOCOL - PRODUCTION DEPLOYMENT");
        console.log("=============================================");
        console.log("LuminaOracle:        ", address(oracle));
        console.log("LuminaPhalaVerifier: ", address(phala));
        console.log("PolicyManager:       ", pmAddr);
        console.log("CoverRouter:         ", routerAddr);
        console.log("VolatileShort:       ", vsAddr);
        console.log("VolatileLong:        ", vlAddr);
        console.log("StableShort:         ", ssAddr);
        console.log("StableLong:          ", slAddr);
        console.log("BlackSwanShield:     ", address(bss));
        console.log("DepegShield:         ", address(depeg));
        console.log("ILIndexCover:        ", address(il));
        console.log("ExploitShield:       ", address(exploit));
        console.log("TimelockController:  ", TIMELOCK);
        console.log("USDC:                ", USDC);
        console.log("Aave V3 Pool:        ", AAVE_POOL);
        console.log("=============================================");
    }

    function _deployVault(
        address impl,
        address owner,
        address router,
        address pm
    ) internal returns (address) {
        bytes memory data = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, USDC, router, pm, AAVE_POOL, AAVE_AUSDC)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(impl, data);
        return address(proxy);
    }
}
