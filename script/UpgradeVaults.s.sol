// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {StableLongVault} from "../src/vaults/StableLongVault.sol";
import {MockUSDY} from "../src/mocks/MockUSDY.sol";

contract UpgradeVaults is Script {

    // Proxy addresses from DeployUUPS
    address constant VS_PROXY = 0x2D7D735f71638730cbe9A143227A00Fa64E94E88;
    address constant VL_PROXY = 0xDf30548d46e77015A4dDA82D3c263e81a60B075c;
    address constant SS_PROXY = 0x8F6e6a4Ee6aeD70757c16382eA7156AD4b33c078;
    address constant SL_PROXY = 0x3e8dF8746c42Aa4B0CDb089174aBbBaf2C3aD46c;

    // MockUSDY address from Deploy
    address constant USDY = 0x12cc5bd1ab02A50285834eaF6eBdc2d95FB42cC9;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════════
        // 1. Deploy new implementations (with fixed MIN_DEPOSIT = 100e6)
        // ═══════════════════════════════════════════
        VolatileShortVault vsImpl = new VolatileShortVault();
        console.log("New VolatileShort impl:", address(vsImpl));

        VolatileLongVault vlImpl = new VolatileLongVault();
        console.log("New VolatileLong impl:", address(vlImpl));

        StableShortVault ssImpl = new StableShortVault();
        console.log("New StableShort impl:", address(ssImpl));

        StableLongVault slImpl = new StableLongVault();
        console.log("New StableLong impl:", address(slImpl));

        // ═══════════════════════════════════════════
        // 2. Upgrade proxies to new implementations
        // ═══════════════════════════════════════════
        UUPSUpgradeable(VS_PROXY).upgradeToAndCall(address(vsImpl), "");
        console.log("VolatileShort upgraded");

        UUPSUpgradeable(VL_PROXY).upgradeToAndCall(address(vlImpl), "");
        console.log("VolatileLong upgraded");

        UUPSUpgradeable(SS_PROXY).upgradeToAndCall(address(ssImpl), "");
        console.log("StableShort upgraded");

        UUPSUpgradeable(SL_PROXY).upgradeToAndCall(address(slImpl), "");
        console.log("StableLong upgraded");

        // ═══════════════════════════════════════════
        // 3. Seed liquidity - $2,500 USDY per vault = $10K total
        // ═══════════════════════════════════════════
        MockUSDY usdy = MockUSDY(USDY);
        usdy.mint(deployer, 10_000e6);
        console.log("Minted 10K MockUSDY");

        usdy.approve(VS_PROXY, 2_500e6);
        VolatileShortVault(VS_PROXY).deposit(2_500e6, deployer);
        console.log("Seeded VolatileShort: 2500 USDY");

        usdy.approve(VL_PROXY, 2_500e6);
        VolatileLongVault(VL_PROXY).deposit(2_500e6, deployer);
        console.log("Seeded VolatileLong: 2500 USDY");

        usdy.approve(SS_PROXY, 2_500e6);
        StableShortVault(SS_PROXY).deposit(2_500e6, deployer);
        console.log("Seeded StableShort: 2500 USDY");

        usdy.approve(SL_PROXY, 2_500e6);
        StableLongVault(SL_PROXY).deposit(2_500e6, deployer);
        console.log("Seeded StableLong: 2500 USDY");

        console.log("--- UPGRADE + SEED COMPLETE ---");

        vm.stopBroadcast();
    }
}
