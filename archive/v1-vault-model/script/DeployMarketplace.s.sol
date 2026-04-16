// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PolicyNFT} from "../src/marketplace/PolicyNFT.sol";
import {VaultShareNFT} from "../src/marketplace/VaultShareNFT.sol";
import {LuminaMarketplace} from "../src/marketplace/LuminaMarketplace.sol";
import {InstantLiquidity} from "../src/marketplace/InstantLiquidity.sol";

contract DeployMarketplace is Script {
    address constant LUMINA_TOKEN = 0xd764f293B1B90e36d8a045caAD1aA491ED2EC4e8;
    address constant PRICE_ORACLE = 0x2AfFdA00746b90D6FC92Aae3ff182801bf546C88;
    address constant COVER_ROUTER = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025;
    address constant TIMELOCK = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;

    // All 5 vault proxies — will be set as minters on VaultShareNFT
    address constant VOL_SHORT = 0xbd44547581b92805aAECc40EB2809352b9b2880d;
    address constant VOL_LONG = 0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904;
    address constant STABLE_SHORT = 0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC;
    address constant STABLE_LONG = 0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c;
    address constant FLASH_VAULT = 0x65D22E9BfE79306433Bf93Da9B0e5b626b8D021b;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // ═══ 1. Deploy PolicyNFT ═══
        PolicyNFT policyNFT = new PolicyNFT();
        // CoverRouter is the minter (auto-mint on purchasePolicy)
        policyNFT.setMinter(COVER_ROUTER, true);

        // ═══ 2. Deploy VaultShareNFT ═══
        VaultShareNFT vaultShareNFT = new VaultShareNFT();
        // All 5 vaults are minters (auto-mint on deposit)
        vaultShareNFT.setMinter(VOL_SHORT, true);
        vaultShareNFT.setMinter(VOL_LONG, true);
        vaultShareNFT.setMinter(STABLE_SHORT, true);
        vaultShareNFT.setMinter(STABLE_LONG, true);
        vaultShareNFT.setMinter(FLASH_VAULT, true);

        // ═══ 3. Deploy LuminaMarketplace ═══
        LuminaMarketplace marketplace = new LuminaMarketplace(LUMINA_TOKEN);
        marketplace.setApprovedNFT(address(policyNFT), true);
        marketplace.setApprovedNFT(address(vaultShareNFT), true);
        marketplace.setPolicyNFT(address(policyNFT));

        // ═══ 4. Deploy InstantLiquidity ═══
        InstantLiquidity instantLiq =
            new InstantLiquidity(LUMINA_TOKEN, PRICE_ORACLE, address(vaultShareNFT), address(policyNFT));

        // ═══ 5. Transfer ownership to TimelockController ═══
        policyNFT.transferOwnership(TIMELOCK);
        vaultShareNFT.transferOwnership(TIMELOCK);
        marketplace.transferOwnership(TIMELOCK);
        instantLiq.transferOwnership(TIMELOCK);

        vm.stopBroadcast();

        // ═══ Log ═══
        console.log("=== MARKETPLACE DEPLOYMENT ===");
        console.log("PolicyNFT:       ", address(policyNFT));
        console.log("VaultShareNFT:   ", address(vaultShareNFT));
        console.log("Marketplace:     ", address(marketplace));
        console.log("InstantLiquidity:", address(instantLiq));
        console.log("Owner:           ", TIMELOCK);
        console.log("");
        console.log("=== NEXT: SAFE BATCH FOR UPGRADES ===");
        console.log("Vault/Router proxies owned by TimelockController.");
        console.log("Upgrade via Safe batch to enable auto-mint:");
        console.log("1. upgradeToAndCall on each vault proxy (new BaseVault impl)");
        console.log("2. upgradeToAndCall on CoverRouter proxy (new CoverRouter impl)");
        console.log("3. setVaultShareNFT on each vault");
        console.log("4. setPolicyNFT on CoverRouter");
    }
}
