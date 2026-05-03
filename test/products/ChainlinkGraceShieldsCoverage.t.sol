// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";
import {MicroDepegShield} from "../../src/products/MicroDepegShield.sol";
import {RateShockShield} from "../../src/products/RateShockShield.sol";

/// @title ChainlinkGraceShieldsCoverageTest
/// @notice Audit V5.1 fix H-13 follow-up — pins the per-shield
///         `_chainlinkGraceAsset()` override on every concrete shield
///         that consumes a Chainlink price feed. The public getter
///         `chainlinkGraceAsset()` (added on BaseShield in this sprint)
///         is `view` not `pure`, so a deploy of the implementation is
///         enough — we do NOT need to drive a proxy + initialize. That
///         keeps the test fast and self-contained.
contract ChainlinkGraceShieldsCoverageTest is Test {
    function test_FlashBTC1h_HasGraceForBTC() public {
        FlashBTCShield1h s = new FlashBTCShield1h();
        assertEq(s.chainlinkGraceAsset(), bytes32("BTC"));
    }

    function test_FlashBTC4h_HasGraceForBTC() public {
        FlashBTCShield4h s = new FlashBTCShield4h();
        assertEq(s.chainlinkGraceAsset(), bytes32("BTC"));
    }

    function test_FlashBTC24h_HasGraceForBTC() public {
        FlashBTCShield24h s = new FlashBTCShield24h();
        assertEq(s.chainlinkGraceAsset(), bytes32("BTC"));
    }

    function test_FlashBTC48h_HasGraceForBTC() public {
        FlashBTCShield48h s = new FlashBTCShield48h();
        assertEq(s.chainlinkGraceAsset(), bytes32("BTC"));
    }

    function test_FlashETH1h_HasGraceForETH() public {
        FlashETHShield1h s = new FlashETHShield1h();
        assertEq(s.chainlinkGraceAsset(), bytes32("ETH"));
    }

    function test_FlashETH24h_HasGraceForETH() public {
        FlashETHShield24h s = new FlashETHShield24h();
        assertEq(s.chainlinkGraceAsset(), bytes32("ETH"));
    }

    function test_FlashETH48h_HasGraceForETH() public {
        FlashETHShield48h s = new FlashETHShield48h();
        assertEq(s.chainlinkGraceAsset(), bytes32("ETH"));
    }

    function test_MicroDepeg_HasGraceForUSDC() public {
        MicroDepegShield s = new MicroDepegShield();
        assertEq(s.chainlinkGraceAsset(), bytes32("USDC"));
    }

    function test_RateShock_HasGraceForUSDC() public {
        RateShockShield s = new RateShockShield();
        assertEq(s.chainlinkGraceAsset(), bytes32("USDC"));
    }
}
