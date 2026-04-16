// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/v2/products/MicroDepegShield.sol";

contract MicroDepegShieldTest is Test {
    MicroDepegShield shield;

    address router = makeAddr("router");
    address oracle = makeAddr("oracle");

    function setUp() public {
        shield = new MicroDepegShield(router, oracle);
    }

    function test_productId() public view {
        assertEq(shield.productId(), keccak256("MICRODEPEG-001"));
    }

    function test_triggerPrice_is_0995_8decimals() public view {
        // $0.995 in Chainlink 8 decimals = 99_500_000
        assertEq(shield.TRIGGER_PRICE(), 99_500_000);
    }

    function test_durationRange_is_7_days() public view {
        (uint32 min, uint32 max) = shield.durationRange();
        assertEq(min, 604800);
        assertEq(max, 604800);
    }

    function test_deductibleBps() public view {
        assertEq(shield.DEDUCTIBLE_BPS(), 2000);
    }

    function test_waitingPeriod_zero() public view {
        assertEq(shield.waitingPeriod(), 0);
    }
}
