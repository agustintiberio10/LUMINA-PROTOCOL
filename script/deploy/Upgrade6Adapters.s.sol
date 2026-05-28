// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title Upgrade6Adapters
/// @notice Sprint Fix 7.4 C1 — UUPS upgrade for the 6 live `FlashShieldAdapter`
///         proxies on Base Sepolia. Adds the new permissionless
///         `checkAndSettlePolicy(uint256)` entry point that ShieldKeeper
///         expects, plus the `setPolicyManager(address)` setter so each
///         adapter can route settlements into PolicyManagerV2.
///
///         The 6 shield contracts themselves are NOT upgradeable (they're
///         deployed directly without a proxy). All the new logic lives in the
///         adapter and forwards into the shield's pre-existing
///         `verifyAndCalculate(uint256)` — the adapter catches the
///         `"WINDOW_EXPIRED"` revert from a stale-window policy and routes it
///         to `settlePolicy(_, _, false)`.
///
/// Required env:
///   PRIVATE_KEY — adapter owner (founder EOA).
contract Upgrade6Adapters is Script {
    address[6] public ADAPTERS = [
        0x5fC732D28c09DfcA2e7eF0AAd6C9491c8474eAdB, // FlashBTCShield1h
        0x844A5fDb3C910DC33Eb720fDB5387C3d55eC867d, // FlashBTCShield24h
        0x0840d638a3E79919afE3b1AB589E6D4b5E8C45Bb, // FlashBTCShield48h
        0xeC42c7169B4D80F4D8A113607367F75c2df02935, // FlashETHShield1h
        0xb0f143beF75F32BcAB569766e9159366f8fD69C4, // FlashETHShield24h
        0x26db224D3Ddc00F4bFcF8ab26A92B9f7c81A47E6 // FlashETHShield48h
    ];

    string[6] public NAMES = [
        "FlashBTC1hAdapter",
        "FlashBTC24hAdapter",
        "FlashBTC48hAdapter",
        "FlashETH1hAdapter",
        "FlashETH24hAdapter",
        "FlashETH48hAdapter"
    ];

    function run() external returns (address newImpl) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);

        FlashShieldAdapter impl = new FlashShieldAdapter();
        newImpl = address(impl);

        for (uint256 i = 0; i < 6; i++) {
            IUUPSUpgradeable(ADAPTERS[i]).upgradeToAndCall(newImpl, "");
            console2.log(NAMES[i], ADAPTERS[i], "->", newImpl);
        }

        vm.stopBroadcast();

        console2.log("=== Sprint Fix 7.4 C1: 6 FlashShieldAdapter proxies upgraded ===");
        console2.log("New impl:", newImpl);
    }
}
