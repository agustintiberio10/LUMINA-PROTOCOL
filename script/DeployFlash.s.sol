// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashVault} from "../src/vaults/FlashVault.sol";
import {FlashBTCShield24h} from "../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../src/products/FlashBTCShield48h.sol";
import {FlashETHShield24h} from "../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../src/products/FlashETHShield48h.sol";

contract DeployFlash is Script {
    // Base mainnet addresses
    address constant COVER_ROUTER = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025;
    address constant POLICY_MANAGER = 0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a;
    address constant ORACLE_V2 = 0x87B576f688bE0E1d7d23A299f55b475658215105;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant TIMELOCK = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        // ═══ 1. Deploy FlashVault (UUPS proxy) ═══
        FlashVault vaultImpl = new FlashVault();
        bytes memory vaultData = abi.encodeCall(
            FlashVault.initialize, (deployer, USDC, COVER_ROUTER, POLICY_MANAGER, AAVE_POOL, AAVE_AUSDC)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultData);
        FlashVault vault = FlashVault(address(vaultProxy));

        // ═══ 2. Deploy 4 Flash Shields ═══
        FlashBTCShield24h btc24 = new FlashBTCShield24h(COVER_ROUTER, ORACLE_V2);
        FlashBTCShield48h btc48 = new FlashBTCShield48h(COVER_ROUTER, ORACLE_V2);
        FlashETHShield24h eth24 = new FlashETHShield24h(COVER_ROUTER, ORACLE_V2);
        FlashETHShield48h eth48 = new FlashETHShield48h(COVER_ROUTER, ORACLE_V2);

        // ═══ 3. Transfer vault ownership to TimelockController ═══
        vault.transferOwnership(TIMELOCK);

        vm.stopBroadcast();

        // ═══ Verification ═══
        require(vault.cooldownDuration() == 604800, "Vault cooldown wrong");
        require(vault.owner() == TIMELOCK, "Vault owner not timelock");
        require(btc24.TRIGGER_DROP_BPS() == 1800, "BTC24 trigger wrong");
        require(btc48.TRIGGER_DROP_BPS() == 2200, "BTC48 trigger wrong");
        require(eth24.TRIGGER_DROP_BPS() == 2000, "ETH24 trigger wrong");
        require(eth48.TRIGGER_DROP_BPS() == 2800, "ETH48 trigger wrong");

        // ═══ Log addresses ═══
        console.log("=== FLASH INSURANCE DEPLOYMENT ===");
        console.log("FlashVault (proxy):", address(vault));
        console.log("FlashVault (impl): ", address(vaultImpl));
        console.log("FlashBTCShield24h: ", address(btc24));
        console.log("FlashBTCShield48h: ", address(btc48));
        console.log("FlashETHShield24h: ", address(eth24));
        console.log("FlashETHShield48h: ", address(eth48));
        console.log("");
        console.log("=== RAILWAY ENV VARS ===");
        console.log("FLASH_VAULT=", address(vault));
        console.log("FLASH_BTC_24H_SHIELD=", address(btc24));
        console.log("FLASH_BTC_48H_SHIELD=", address(btc48));
        console.log("FLASH_ETH_24H_SHIELD=", address(eth24));
        console.log("FLASH_ETH_48H_SHIELD=", address(eth48));
        console.log("");
        console.log("=== NEXT STEPS (via Safe multisig) ===");
        console.log("1. Register 4 shields in CoverRouter");
        console.log("2. Create correlation group FLASH_CRASH cap 60%");
        console.log("3. Seed USDC deposit in FlashVault");
    }
}
