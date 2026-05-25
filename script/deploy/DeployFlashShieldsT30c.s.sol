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
import {AtomicShieldPairDeployer} from "./AtomicShieldPairDeployer.sol";

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

        // F-05 fix: the final owner is the broadcaster (founder Safe/EOA). Each
        // pair is built atomically by the helper so the proxy is never left
        // uninitialized across a tx boundary (no init front-run window).
        address finalOwner = vm.addr(pk);

        vm.startBroadcast(pk);

        AtomicShieldPairDeployer deployer = new AtomicShieldPairDeployer();

        // The shield CREATION CODE is passed to the helper (which appends ctor
        // args + CREATE-s it), so the helper never embeds shield bytecode and
        // stays under EIP-170. This Script is size-exempt, so embedding the
        // creation code here is fine.
        records[0] = _deployPair(deployer, "FlashBTCShield1h", keccak256("FLASHBTC1H-001"), type(FlashBTCShield1h).creationCode, btcFeed, sequencerFeed, finalOwner);
        records[1] = _deployPair(deployer, "FlashBTCShield24h", keccak256("FLASHBTC24-001"), type(FlashBTCShield24h).creationCode, btcFeed, sequencerFeed, finalOwner);
        records[2] = _deployPair(deployer, "FlashBTCShield48h", keccak256("FLASHBTC48-001"), type(FlashBTCShield48h).creationCode, btcFeed, sequencerFeed, finalOwner);
        records[3] = _deployPair(deployer, "FlashETHShield1h", keccak256("FLASHETH1H-001"), type(FlashETHShield1h).creationCode, ethFeed, sequencerFeed, finalOwner);
        records[4] = _deployPair(deployer, "FlashETHShield24h", keccak256("FLASHETH24-001"), type(FlashETHShield24h).creationCode, ethFeed, sequencerFeed, finalOwner);
        records[5] = _deployPair(deployer, "FlashETHShield48h", keccak256("FLASHETH48-001"), type(FlashETHShield48h).creationCode, ethFeed, sequencerFeed, finalOwner);

        vm.stopBroadcast();

        console.log("=== Sprint T-30c flash shields deployed on Base Sepolia ===");
        for (uint256 i = 0; i < records.length; i++) {
            console.log(records[i].name);
            console.log("  shield :", records[i].shield);
            console.log("  adapter:", records[i].adapter);
        }
    }

    function _deployPair(
        AtomicShieldPairDeployer deployer,
        string memory name,
        bytes32 productId,
        bytes memory shieldCreationCode,
        address priceFeed,
        address sequencer,
        address finalOwner
    ) internal returns (ShieldRecord memory rec) {
        // F-05 fix: a single atomic call builds proxy + shield + init + owner
        // transfer. No uninitialized-proxy window exists across transactions.
        (address shieldAddr, address adapterAddr) =
            deployer.deployPair(shieldCreationCode, priceFeed, sequencer, productId, finalOwner);

        rec = ShieldRecord({name: name, shield: shieldAddr, adapter: adapterAddr});
    }
}
