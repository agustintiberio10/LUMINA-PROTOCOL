// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {BondVault} from "../../src/bonds/BondVault.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";
import {CapacityOracle} from "../../src/oracles/CapacityOracle.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";

/// @title UpgradeAll-FixRedTeam
/// @notice Sprint Fix 7.2 — Phase F scaffold. Deploys fresh implementations for
///         every UUPS-upgradeable contract touched by the red-team fixes and
///         calls `upgradeToAndCall` on each live proxy. Proxy addresses are read
///         from env so the same script works across deployments.
///
/// ⚠️ NOT auto-broadcast in the audit environment (no DEPLOYER_PRIVATE_KEY). Run
///    from the founder runbook with the key set.
///
/// ⚠️ This script covers ONLY the upgradeable contracts. Two parts of Phase F
///    are SEPARATE because the targets are NOT upgradeable:
///      1. The 6 flash shields (F-01/F-06 changed `BaseFlashShield`) must be
///         REDEPLOYED via the F-05-fixed `DeployFlashShieldsT30c`, re-registered
///         in PolicyManagerV2, and the adapters re-pointed.
///      2. `FounderVestingV2` must be deployed and migrated (storage + refs +
///         ADR) — see audit-pack/audits/2026-05-24-red-team-audit-v53-v2.md.
///
/// Required env (Base Sepolia), each the PROXY address of the live contract:
///   DEPLOYER_PRIVATE_KEY
///   BONDVAULT_PROXY, COVERROUTER_PROXY, POLICYMANAGER_PROXY, TWAPBURNER_PROXY,
///   BUYBACKENGINE_PROXY, CAPACITYORACLE_PROXY, MAINTENANCERESERVE_PROXY,
///   MARKETPLACE_PROXY, ADAPTER_PROXY_1..6 (comma-separated in ADAPTER_PROXIES)
///
/// Post-upgrade wiring (also founder-side, see runbook):
///   BondVault.setAuthorizedCaller(ClaimBond, true)   // F-18 obligation sync
///   FlashShieldAdapter.setKeeper(ShieldKeeper)        // F-01 settlement
///   MaintenanceReserve.setMonthlyCap(DEFAULT)         // F-15 if live cap == 0
contract UpgradeAllFixRedTeam is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);

        _upgrade(vm.envAddress("BONDVAULT_PROXY"), address(new BondVault()), "BondVault");
        _upgrade(vm.envAddress("COVERROUTER_PROXY"), address(new CoverRouterV2()), "CoverRouterV2");
        _upgrade(vm.envAddress("POLICYMANAGER_PROXY"), address(new PolicyManagerV2()), "PolicyManagerV2");
        _upgrade(vm.envAddress("TWAPBURNER_PROXY"), address(new TWAPBurner()), "TWAPBurner");
        _upgrade(vm.envAddress("BUYBACKENGINE_PROXY"), address(new BuybackEngine()), "BuybackEngine");
        _upgrade(vm.envAddress("CAPACITYORACLE_PROXY"), address(new CapacityOracle()), "CapacityOracle");
        _upgrade(vm.envAddress("MAINTENANCERESERVE_PROXY"), address(new MaintenanceReserve()), "MaintenanceReserve");
        _upgrade(vm.envAddress("MARKETPLACE_PROXY"), address(new LuminaBondMarketplace()), "LuminaBondMarketplace");

        // 6 adapters share one implementation contract.
        address[] memory adapters = vm.envAddress("ADAPTER_PROXIES", ",");
        address adapterImpl = address(new FlashShieldAdapter());
        for (uint256 i = 0; i < adapters.length; i++) {
            _upgrade(adapters[i], adapterImpl, "FlashShieldAdapter");
        }

        vm.stopBroadcast();

        console.log("=== Fix-RedTeam UUPS upgrades complete ===");
        console.log("REMINDER: redeploy the 6 shields + FounderVestingV2 (non-upgradeable) per the runbook.");
    }

    function _upgrade(address proxy, address newImpl, string memory name) internal {
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        console.log("upgraded", name, "->", newImpl);
    }
}
