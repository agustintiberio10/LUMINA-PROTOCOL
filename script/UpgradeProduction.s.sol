// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {CoverRouter} from "../src/core/CoverRouter.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {StableLongVault} from "../src/vaults/StableLongVault.sol";

/**
 * @title UpgradeProduction
 * @notice Deploy new implementations for UUPS upgrade.
 *
 * This script ONLY deploys new implementations. It does NOT execute upgrades.
 * Upgrades must be proposed via Gnosis Safe -> TimelockController (48h delay).
 *
 * Contracts to upgrade:
 *   1. CoverRouter - session approval, coverageAmount validation, cancelPayout fix, DRAIN-8.1
 *   2. VolatileShortVault - performance fee (3% on positive yield)
 *   3. VolatileLongVault - performance fee
 *   4. StableShortVault - performance fee
 *   5. StableLongVault - performance fee
 *
 * LuminaOracle is NOT upgradeable (no proxy) - requires new deploy + setOracle on Router.
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=0x... forge script script/UpgradeProduction.s.sol --rpc-url https://mainnet.base.org --broadcast
 */
contract UpgradeProduction is Script {

    // Production proxy addresses
    address constant COVER_ROUTER_PROXY = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025;
    address constant VOL_SHORT_PROXY    = 0xbd44547581b92805aAECc40EB2809352b9b2880d;
    address constant VOL_LONG_PROXY     = 0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904;
    address constant STABLE_SHORT_PROXY = 0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC;
    address constant STABLE_LONG_PROXY  = 0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c;

    // Governance
    address constant TIMELOCK = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // 1. Deploy new CoverRouter implementation
        CoverRouter newRouterImpl = new CoverRouter();
        console.log("New CoverRouter impl:", address(newRouterImpl));

        // 2. Deploy new vault implementations
        VolatileShortVault newVSImpl = new VolatileShortVault();
        console.log("New VolatileShort impl:", address(newVSImpl));

        VolatileLongVault newVLImpl = new VolatileLongVault();
        console.log("New VolatileLong impl:", address(newVLImpl));

        StableShortVault newSSImpl = new StableShortVault();
        console.log("New StableShort impl:", address(newSSImpl));

        StableLongVault newSLImpl = new StableLongVault();
        console.log("New StableLong impl:", address(newSLImpl));

        vm.stopBroadcast();

        // Log upgrade calldata for TimelockController
        console.log("");
        console.log("=== UPGRADE CALLDATA (for Gnosis Safe -> TimelockController) ===");
        console.log("");

        bytes memory routerUpgrade = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newRouterImpl), "");
        console.log("CoverRouter upgradeToAndCall data:");
        console.logBytes(routerUpgrade);

        bytes memory vsUpgrade = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newVSImpl), "");
        console.log("VolatileShort upgradeToAndCall data:");
        console.logBytes(vsUpgrade);

        bytes memory vlUpgrade = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newVLImpl), "");
        console.log("VolatileLong upgradeToAndCall data:");
        console.logBytes(vlUpgrade);

        bytes memory ssUpgrade = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newSSImpl), "");
        console.log("StableShort upgradeToAndCall data:");
        console.logBytes(ssUpgrade);

        bytes memory slUpgrade = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newSLImpl), "");
        console.log("StableLong upgradeToAndCall data:");
        console.logBytes(slUpgrade);

        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("1. Go to app.safe.global with Gnosis Safe:", 0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD);
        console.log("2. For each proxy, propose a TimelockController.schedule() tx");
        console.log("3. Target: proxy address, Data: upgradeToAndCall calldata above");
        console.log("4. Wait 48 hours");
        console.log("5. Execute via TimelockController.execute()");
        console.log("6. Verify with script/VerifyUpgrade.s.sol");
    }
}
