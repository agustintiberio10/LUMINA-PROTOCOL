// ==============================================================
// [DEPRECATED — 2026-05-07]
// This script targets V1 / intermediate contract addresses (pre-V5.1
// redeploy). Do NOT execute against the current Sepolia deployment;
// running it would broadcast transactions to contracts that no longer
// exist or are no longer in the canonical registry. Kept here for
// historical reference only.
//
// Live addresses: GET https://lumina-api-production-ac85.up.railway.app/health
// ==============================================================
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {FlashBTCShield1h}  from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h}  from "../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h}  from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";
import {MicroDepegShield}  from "../../src/products/MicroDepegShield.sol";
import {RateShockShield}   from "../../src/products/RateShockShield.sol";

interface IShieldUpgrade {
    function upgradeToAndCall(address newImpl, bytes calldata data) external payable;
    function setOracle(address newOracle) external;
    function oracle() external view returns (address);
    function owner() external view returns (address);
}

/// @notice Deploys a new implementation per shield, upgrades the proxy to it,
///         then rebinds each shield to the freshly-deployed LuminaOracleV2.
///
/// Shield proxy addresses are hardcoded from the V5.1 deploy log
/// (`deployments/sepolia/deploy-log-2026-04-27-1638.txt`) — NOT from
/// V5.1-2026-04-27.json (which omits shields) and NOT from base-sepolia.json
/// (V5.0 deprecated, flat non-UUPS contracts).
contract UpgradeShieldsAndRebind is Script {
    // V5.1 UUPS proxy addresses (Base Sepolia 84532, deployed 2026-04-27)
    address constant FLASH_BTC_1H  = 0x77c2A7cA53ED5cbDe66cE220647d2c213133f2a9;
    address constant FLASH_BTC_4H  = 0xb5b21f7c02C15B5D73e63538BC917825Ebcb8122;
    address constant FLASH_BTC_24H = 0xAc53Bf7Bb85Fcfb6d3c831F3AD9f6f79ebeeF99f;
    address constant FLASH_BTC_48H = 0xf2D3Fe86Ad8BB96600bB5fdF21159bb6255e95f2;
    address constant FLASH_ETH_1H  = 0xa63237a0fd57443D73F9ED36CBE15E2792D4a170;
    address constant FLASH_ETH_24H = 0x6D6E250bc936D92F64d70262d14D6b020107Ee26;
    address constant FLASH_ETH_48H = 0xcCbE9CCCD887D67f4bfD833c2431DD2B4e1f864D;
    address constant MICRODEPEG    = 0x06DF0608c7256c8Df0723538574Babad1a7fd53d;
    address constant RATESHOCK     = 0x7287E55380ee877279ef2e390e2528F772e7Da2f;

    function run() external {
        require(block.chainid == 84532, "wrong chain");

        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        address newOracle = vm.envAddress("LUMINA_ORACLE_V2_ADDRESS");
        address ownerAddr = vm.addr(ownerKey);

        console.log("=== Upgrade 9 shields + rebind to LuminaOracleV2 ===");
        console.log("Owner (deployer):", ownerAddr);
        console.log("New oracle:", newOracle);
        require(newOracle.code.length > 0, "oracle has no code");

        vm.startBroadcast(ownerKey);

        _upgradeOne("FlashBTC1h",  FLASH_BTC_1H,  address(new FlashBTCShield1h()),  newOracle, ownerAddr);
        _upgradeOne("FlashBTC4h",  FLASH_BTC_4H,  address(new FlashBTCShield4h()),  newOracle, ownerAddr);
        _upgradeOne("FlashBTC24h", FLASH_BTC_24H, address(new FlashBTCShield24h()), newOracle, ownerAddr);
        _upgradeOne("FlashBTC48h", FLASH_BTC_48H, address(new FlashBTCShield48h()), newOracle, ownerAddr);
        _upgradeOne("FlashETH1h",  FLASH_ETH_1H,  address(new FlashETHShield1h()),  newOracle, ownerAddr);
        _upgradeOne("FlashETH24h", FLASH_ETH_24H, address(new FlashETHShield24h()), newOracle, ownerAddr);
        _upgradeOne("FlashETH48h", FLASH_ETH_48H, address(new FlashETHShield48h()), newOracle, ownerAddr);
        _upgradeOne("MicroDepeg",  MICRODEPEG,    address(new MicroDepegShield()),  newOracle, ownerAddr);
        _upgradeOne("RateShock",   RATESHOCK,     address(new RateShockShield()),   newOracle, ownerAddr);

        vm.stopBroadcast();

        console.log("=== ALL 9 SHIELDS UPGRADED + REBOUND ===");
    }

    function _upgradeOne(
        string memory label,
        address proxy,
        address newImpl,
        address newOracle,
        address expectedOwner
    ) internal {
        IShieldUpgrade s = IShieldUpgrade(proxy);

        require(s.owner() == expectedOwner, "owner mismatch");

        console.log(label, "proxy:", proxy);
        console.log(label, "newImpl:", newImpl);

        s.upgradeToAndCall(newImpl, "");
        s.setOracle(newOracle);

        address current = s.oracle();
        require(current == newOracle, "oracle mismatch after setOracle");
        console.log(label, "oracle now:", current);
    }
}
