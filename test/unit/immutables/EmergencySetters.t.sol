// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title EmergencySetters
/// @notice Sprint Z.1 Phase 4 — verify TWAPBurner can replace immutable AerodromeAdapter
///         and UniswapV3Adapter at runtime (kill-switch capability post-mainnet).
///         If a setter is missing, that contract becomes a vulnerability since the
///         adapter itself is immutable.
contract EmergencySettersTest is Test {
    TWAPBurner burner;
    address usdc = makeAddr("usdc");
    address lumina = makeAddr("lumina");
    address initialRouter = makeAddr("initialRouter");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.chainId(8453);
        burner = ProxyDeployer.deployTWAPBurner(usdc, lumina, initialRouter);
    }

    // ─────────────── setDexRouters ───────────────

    function test_SetDexRouters_OwnerCanReplaceAdapter() public {
        address newAerodrome = makeAddr("newAerodrome");
        address newUniswap = makeAddr("newUniswap");
        address[] memory routers = new address[](2);
        routers[0] = newAerodrome;
        routers[1] = newUniswap;
        burner.setDexRouters(routers);
        assertEq(address(burner.dexRouters(0)), newAerodrome);
        assertEq(address(burner.dexRouters(1)), newUniswap);
    }

    function test_SetDexRouters_NonOwner_Reverts() public {
        address[] memory routers = new address[](1);
        routers[0] = makeAddr("router");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        burner.setDexRouters(routers);
    }

    // ─────────────── addDexRouter ───────────────

    function test_AddDexRouter_Owner_Success() public {
        address newRouter = makeAddr("anotherRouter");
        burner.addDexRouter(newRouter);
        // initialRouter is at index 0; newRouter at 1.
        assertEq(address(burner.dexRouters(1)), newRouter);
    }

    function test_AddDexRouter_NonOwner_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        burner.addDexRouter(makeAddr("router"));
    }

    // ─────────────── setReserves ───────────────

    function test_SetReserves_OwnerCanReplaceAll3() public {
        address newBuyback = makeAddr("nb");
        address newOps = makeAddr("no");
        address newMaint = makeAddr("nm");
        burner.setReserves(newBuyback, newOps, newMaint);
        assertEq(burner.buybackReserve(), newBuyback);
        assertEq(burner.opsReserve(), newOps);
        assertEq(burner.maintenanceReserve(), newMaint);
    }

    function test_SetReserves_NonOwner_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        burner.setReserves(makeAddr("a"), makeAddr("b"), makeAddr("c"));
    }

    // ─────────────── setAdaptiveMode ───────────────

    function test_SetAdaptiveMode_OwnerCanFlip() public {
        // Pre-condition: feeDistributor + reserves must be set OR enabled = false works always.
        burner.setAdaptiveMode(false); // disable always works regardless of dist+reserves.
        assertFalse(burner.adaptiveModeEnabled());
    }

    function test_SetAdaptiveMode_NonOwner_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        burner.setAdaptiveMode(false);
    }

    // ─────────────── State preservation across adapter swap ───────────────

    function test_AdapterReplacement_PreservesTotalUSDCBurned() public {
        // Pre-state.
        uint256 burnedBefore = burner.totalUSDCBurned();
        address newRouter = makeAddr("newRouter");
        burner.addDexRouter(newRouter);
        // Replacing dexRouters should NOT clear historical counters.
        assertEq(burner.totalUSDCBurned(), burnedBefore);
        assertEq(burner.totalLUMINABurned(), 0);
    }

    function test_AdapterReplacement_PreservesLastBurnTimestamp() public {
        uint256 lbtBefore = burner.lastBurnTimestamp();
        burner.addDexRouter(makeAddr("router"));
        assertEq(burner.lastBurnTimestamp(), lbtBefore);
    }
}
