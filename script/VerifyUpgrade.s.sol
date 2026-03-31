// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {CoverRouter} from "../src/core/CoverRouter.sol";

interface IProxy {
    function owner() external view returns (address);
}

interface IVaultCheck {
    function performanceFeeBps() external view returns (uint16);
    function feeReceiver() external view returns (address);
    function totalAssets() external view returns (uint256);
}

/**
 * @title VerifyUpgrade
 * @notice Verify that UUPS upgrades were successful and storage is intact.
 *
 * Usage:
 *   forge script script/VerifyUpgrade.s.sol --rpc-url https://mainnet.base.org
 */
contract VerifyUpgrade is Script {

    address constant TIMELOCK = 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a;

    address constant COVER_ROUTER = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025;
    address constant VOL_SHORT    = 0xbd44547581b92805aAECc40EB2809352b9b2880d;
    address constant VOL_LONG     = 0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904;
    address constant STABLE_SHORT = 0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC;
    address constant STABLE_LONG  = 0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c;

    function run() external view {
        console.log("=== POST-UPGRADE VERIFICATION ===");
        console.log("");

        // 1. Check ownership (should still be TimelockController)
        _checkOwner("CoverRouter", COVER_ROUTER);
        _checkOwner("VolatileShort", VOL_SHORT);
        _checkOwner("VolatileLong", VOL_LONG);
        _checkOwner("StableShort", STABLE_SHORT);
        _checkOwner("StableLong", STABLE_LONG);

        // 2. Check vault performance fee exists (new feature)
        _checkVaultFee("VolatileShort", VOL_SHORT);
        _checkVaultFee("VolatileLong", VOL_LONG);
        _checkVaultFee("StableShort", STABLE_SHORT);
        _checkVaultFee("StableLong", STABLE_LONG);

        // 3. Check CoverRouter new features
        CoverRouter router = CoverRouter(COVER_ROUTER);
        console.log("CoverRouter oracle:", router.oracle());
        console.log("CoverRouter policyManager:", router.policyManager());

        // 4. Check totalAssets (should be unchanged)
        _checkTotalAssets("VolatileShort", VOL_SHORT);
        _checkTotalAssets("VolatileLong", VOL_LONG);
        _checkTotalAssets("StableShort", STABLE_SHORT);
        _checkTotalAssets("StableLong", STABLE_LONG);

        console.log("");
        console.log("=== VERIFICATION COMPLETE ===");
    }

    function _checkOwner(string memory name, address proxy) internal view {
        address owner = IProxy(proxy).owner();
        bool ok = owner == TIMELOCK;
        console.log(name, "owner:", owner);
        console.log(ok ? "  -> OK" : "  -> WRONG!");
        require(ok, string.concat(name, " owner is not TimelockController"));
    }

    function _checkVaultFee(string memory name, address vault) internal view {
        uint16 fee = IVaultCheck(vault).performanceFeeBps();
        address receiver = IVaultCheck(vault).feeReceiver();
        console.log(name, "performanceFeeBps:");
        console.log(fee);
        console.log("feeReceiver:", receiver);
        require(fee == 300, string.concat(name, " fee should be 300"));
    }

    function _checkTotalAssets(string memory name, address vault) internal view {
        uint256 assets = IVaultCheck(vault).totalAssets();
        console.log(name, "totalAssets:", assets);
    }
}
