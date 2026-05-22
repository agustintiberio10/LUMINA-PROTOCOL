// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";

/// @title DeployFlashShieldsT30c
/// @notice Sprint T-30c Phase E: fresh deploy of the 6 flash-shield products
///         (BTC/ETH × 1h/24h/48h) + 6 FlashShieldAdapter UUPS proxies on Base
///         Sepolia. Each adapter wraps a single underlying slim shield so the
///         legacy IShieldV2 surface PolicyManagerV2 still expects keeps working.
///
/// Required env vars (Base Sepolia):
///   DEPLOYER_PRIVATE_KEY  — broadcaster pk
///   CHAINLINK_BTC_USD     — BTC/USD Chainlink aggregator (Base Sepolia)
///   CHAINLINK_ETH_USD     — ETH/USD Chainlink aggregator (Base Sepolia)
///   CHAINLINK_SEQUENCER   — L2 sequencer uptime feed (Base Sepolia: 0xBCF8...)
///
/// Adapter wiring requires a chicken-and-egg dance:
///   1. Deploy adapter proxy (uninitialized) — gets a stable address.
///   2. Deploy slim shield with adapter proxy address as its `router`.
///   3. Initialize adapter with the freshly-deployed shield address.
contract DeployFlashShieldsT30c is Script {
    struct ShieldRecord {
        string name;
        address shield;
        address adapter;
    }

    function run() external returns (ShieldRecord[6] memory records) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address btcFeed = vm.envAddress("CHAINLINK_BTC_USD");
        address ethFeed = vm.envAddress("CHAINLINK_ETH_USD");
        address sequencerFeed = vm.envAddress("CHAINLINK_SEQUENCER");

        vm.startBroadcast(pk);

        records[0] = _deployPair("FlashBTCShield1h", keccak256("FLASHBTC1H-001"), btcFeed, sequencerFeed, 1);
        records[1] = _deployPair("FlashBTCShield24h", keccak256("FLASHBTC24-001"), btcFeed, sequencerFeed, 24);
        records[2] = _deployPair("FlashBTCShield48h", keccak256("FLASHBTC48-001"), btcFeed, sequencerFeed, 48);
        records[3] = _deployPair("FlashETHShield1h", keccak256("FLASHETH1H-001"), ethFeed, sequencerFeed, 101);
        records[4] = _deployPair("FlashETHShield24h", keccak256("FLASHETH24-001"), ethFeed, sequencerFeed, 124);
        records[5] = _deployPair("FlashETHShield48h", keccak256("FLASHETH48-001"), ethFeed, sequencerFeed, 148);

        vm.stopBroadcast();

        console.log("=== Sprint T-30c flash shields deployed on Base Sepolia ===");
        for (uint256 i = 0; i < records.length; i++) {
            console.log(records[i].name);
            console.log("  shield :", records[i].shield);
            console.log("  adapter:", records[i].adapter);
        }
    }

    function _deployPair(string memory name, bytes32 productId, address priceFeed, address sequencer, uint256 variant)
        internal
        returns (ShieldRecord memory rec)
    {
        // 1. Deploy adapter impl + proxy (uninitialized).
        FlashShieldAdapter adapterImpl = new FlashShieldAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(adapterImpl), "");
        address adapterAddr = address(proxy);

        // 2. Deploy slim shield with adapter as router.
        address shieldAddr;
        if (variant == 1) {
            shieldAddr = address(new FlashBTCShield1h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 24) {
            shieldAddr = address(new FlashBTCShield24h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 48) {
            shieldAddr = address(new FlashBTCShield48h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 101) {
            shieldAddr = address(new FlashETHShield1h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 124) {
            shieldAddr = address(new FlashETHShield24h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 148) {
            shieldAddr = address(new FlashETHShield48h(adapterAddr, priceFeed, sequencer));
        } else {
            revert("Unknown variant");
        }

        // 3. Initialize adapter with the new shield.
        FlashShieldAdapter(adapterAddr).initialize(shieldAddr, productId);

        rec = ShieldRecord({name: name, shield: shieldAddr, adapter: adapterAddr});
    }
}
