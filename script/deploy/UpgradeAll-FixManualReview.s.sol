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
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {ShieldKeeper} from "../../src/automation/ShieldKeeper.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";

/// @title UpgradeAll-FixManualReview
/// @notice Sprint Fix 7.3 — Phase E scaffold. Deploys fresh implementations for
///         every UUPS contract touched by the Manual Review fixes and calls
///         `upgradeToAndCall` on each live proxy. Proxy addresses come from env.
///
/// ⚠️ NOT auto-broadcast in the audit environment. Standing rule: NO broadcast
///    until a 100%-clean production-profile dry-run. The Windows audit host OOMs
///    on the `via_ir`+`runs=200` build, so the dry-run + broadcast run from the
///    founder runbook with DEPLOYER_PRIVATE_KEY set.
///
/// Contracts upgraded here (UUPS): CapacityOracle (MR-H01), CoverRouterV2 (MR-M01),
///   PolicyManagerV2 (MR-L01/L03), BondVault (MR-M02/M03/L04/L10), BuybackEngine
///   (MR-M04/L11), CEXLiquidityReserve (MR-M03), TWAPBurner (MR-M07), SolvencyOracle
///   (MR-L06), MaintenanceReserve (INFO-1), ShieldKeeper (INFO-2), 6 FlashShieldAdapter
///   (INFO-3).
///
/// ⚠️ NON-upgradeable targets — handled SEPARATELY (redeploy + re-point), NOT here:
///   • LuminaOracleV2 (MR-L07 sequencer fix) — plain Ownable; redeploy + repoint refs.
///   • UniswapV3Adapter / AerodromeAdapter (MR-M06 minOut floor) — plain Ownable;
///     redeploy and update TWAPBurner's router registration.
///   • FounderVestingV2 (MR-M05) — not deployed on testnet; mainnet Fase 6 deploys fresh.
///
/// Post-upgrade wiring: none new. Optional: CapacityOracle.setFreshnessParams(maxAge,
///   minCardinality) — defaults (1h / 10) apply automatically on upgrade via the
///   DEFAULT_* fallback when the appended slots initialize to zero.
///
/// Required env (each the PROXY address of the live contract):
///   DEPLOYER_PRIVATE_KEY
///   CAPACITYORACLE_PROXY, COVERROUTER_PROXY, POLICYMANAGER_PROXY, BONDVAULT_PROXY,
///   BUYBACKENGINE_PROXY, CEXRESERVE_PROXY, TWAPBURNER_PROXY, SOLVENCYORACLE_PROXY,
///   MAINTENANCERESERVE_PROXY, SHIELDKEEPER_PROXY, ADAPTER_PROXIES (comma-separated, 6)
contract UpgradeAllFixManualReview is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);

        _upgrade(vm.envAddress("CAPACITYORACLE_PROXY"), address(new CapacityOracle()), "CapacityOracle");
        _upgrade(vm.envAddress("COVERROUTER_PROXY"), address(new CoverRouterV2()), "CoverRouterV2");
        _upgrade(vm.envAddress("POLICYMANAGER_PROXY"), address(new PolicyManagerV2()), "PolicyManagerV2");
        _upgrade(vm.envAddress("BONDVAULT_PROXY"), address(new BondVault()), "BondVault");
        _upgrade(vm.envAddress("BUYBACKENGINE_PROXY"), address(new BuybackEngine()), "BuybackEngine");
        _upgrade(vm.envAddress("CEXRESERVE_PROXY"), address(new CEXLiquidityReserve()), "CEXLiquidityReserve");
        _upgrade(vm.envAddress("TWAPBURNER_PROXY"), address(new TWAPBurner()), "TWAPBurner");
        _upgrade(vm.envAddress("SOLVENCYORACLE_PROXY"), address(new SolvencyOracle()), "SolvencyOracle");
        _upgrade(vm.envAddress("MAINTENANCERESERVE_PROXY"), address(new MaintenanceReserve()), "MaintenanceReserve");
        _upgrade(vm.envAddress("SHIELDKEEPER_PROXY"), address(new ShieldKeeper()), "ShieldKeeper");

        // 6 adapters share one implementation.
        address[] memory adapters = vm.envAddress("ADAPTER_PROXIES", ",");
        address adapterImpl = address(new FlashShieldAdapter());
        for (uint256 i = 0; i < adapters.length; i++) {
            _upgrade(adapters[i], adapterImpl, "FlashShieldAdapter");
        }

        vm.stopBroadcast();

        console.log("=== Fix-ManualReview UUPS upgrades complete ===");
        console.log("REMINDER: redeploy LuminaOracleV2 + 2 DEX adapters (non-upgradeable) per the runbook.");
    }

    function _upgrade(address proxy, address newImpl, string memory name) internal {
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        console.log("upgraded", name, "->", newImpl);
    }
}
