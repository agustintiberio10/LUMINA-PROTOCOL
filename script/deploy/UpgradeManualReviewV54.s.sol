// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {CapacityOracle} from "../../src/oracles/CapacityOracle.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";

/// @title UpgradeManualReviewV54
/// @notice Sprint UUPS Upgrade — applies the Manual-Review (Sprint Fix 7.3 / PR #158)
///         fixes on-chain to the 8 UUPS proxies. Addresses are the CANONICAL LIVE
///         V5.4 values DERIVED ON-CHAIN (PR #160 manifest) and HARDCODED here — NOT
///         the stale V5.0 values in the repo deployment manifests (which caused the
///         earlier dry-run to revert at CapacityOracle 0xAf99).
///
/// Scope (exactly 8): CapacityOracle (MR-H01), CoverRouterV2 (MR-M01),
///   PolicyManagerV2 (MR-M01/L01/L03), BondVault (MR-M02/M03/L04/L10),
///   BuybackEngine (MR-M04/L11), TWAPBurner (MR-M07), ClaimBond, AdaptiveFeeDistributor.
///   NOTE: ClaimBond + AdaptiveFeeDistributor have NO Manual-Review code changes
///   (MR-L10 lives in BondVault) — included per sprint scope; their upgrade is a
///   same-source refresh (no behavior change).
///
/// DESCOPED: ShieldKeeper (gap — adapter.keeper()==0x0), CEXLiquidityReserve (gap —
///   cexReserve()==0x0; MR-M03 reserve-side cannot deploy), the 2 DEX adapters
///   (MR-M06, non-upgradeable → redeploy), MR-H02 (lumina-api off-chain).
///
/// upgradeToAndCall(newImpl, "") only swaps the ERC1967 impl pointer (no re-init,
/// no storage writes) — storage compatibility is guaranteed by the append-only
/// layout verification (only CapacityOracle added storage: maxObservationAge,
/// minCardinality + __gap 48→46; the other 7 are logic-only).
contract UpgradeManualReviewV54 is Script {
    // Canonical LIVE V5.4 proxies (derived on-chain, PR #160).
    address constant CAPACITY_ORACLE = 0xd52aef11ff411E9e54F7a1bB680065F158cF6545;
    address constant COVER_ROUTER = 0xcdB70B40e6a3DEac3189185d947A0e458518F566;
    address constant POLICY_MANAGER = 0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8;
    address constant BOND_VAULT = 0x193acBc1EdC5E565a4aBE96941C7E7AeF637B6EC;
    address constant BUYBACK_ENGINE = 0x56B5a1115B0d9781E7358521204d927d2F80d8B4;
    address constant TWAP_BURNER = 0x242d76082856901b4ba1E7c50C022D46a6941bC0;
    address constant CLAIM_BOND = 0xaa57Ab52Eb00f296Ad4CFA9E9c201f3737271FB4;
    address constant ADAPTIVE_FEE_DISTRIBUTOR = 0xeC7841A4a9ecfb8cA58391E233A645B021c59D54;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        _upgrade(CAPACITY_ORACLE, address(new CapacityOracle()), "CapacityOracle");
        _upgrade(COVER_ROUTER, address(new CoverRouterV2()), "CoverRouterV2");
        _upgrade(POLICY_MANAGER, address(new PolicyManagerV2()), "PolicyManagerV2");
        _upgrade(BOND_VAULT, address(new BondVault()), "BondVault");
        _upgrade(BUYBACK_ENGINE, address(new BuybackEngine()), "BuybackEngine");
        _upgrade(TWAP_BURNER, address(new TWAPBurner()), "TWAPBurner");
        _upgrade(CLAIM_BOND, address(new ClaimBond()), "ClaimBond");
        _upgrade(ADAPTIVE_FEE_DISTRIBUTOR, address(new AdaptiveFeeDistributor()), "AdaptiveFeeDistributor");

        vm.stopBroadcast();
        console.log("=== 8 Manual-Review UUPS upgrades complete ===");
    }

    function _upgrade(address proxy, address newImpl, string memory name) internal {
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        console.log("upgraded", name);
        console.log("   newImpl:", newImpl);
    }
}
