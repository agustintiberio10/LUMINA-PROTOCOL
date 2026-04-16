// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaPriceOracle} from "../../src/token/LuminaPriceOracle.sol";

contract LuminaPriceOracleTest is Test {
    LuminaPriceOracle public oracle;
    address owner;
    address notOwner = makeAddr("notOwner");

    function setUp() public {
        owner = address(this);
        oracle = new LuminaPriceOracle(40000); // $0.04
    }

    function test_manual_price_set() public {
        assertEq(oracle.getPrice(), 40000);
    }

    function test_usdToLumina_conversion() public {
        // $100 USDC = 100_000_000 (6 dec) at $0.04 per LUMINA = 2500 LUMINA
        uint256 result = oracle.usdToLumina(100_000_000);
        assertEq(result, 2500 * 1e18);
    }

    function test_luminaToUsd_conversion() public {
        // 2500 LUMINA at $0.04 = $100 = 100_000_000 (6 dec)
        uint256 result = oracle.luminaToUsd(2500 * 1e18);
        assertEq(result, 100_000_000);
    }

    function test_manual_price_update() public {
        oracle.setManualPrice(80000);
        assertEq(oracle.getPrice(), 80000);
    }

    function test_enable_twap_disables_manual() public {
        address fakePool = makeAddr("pool");
        oracle.enableTwap(fakePool, true);
        assertFalse(oracle.useManualPrice());
    }

    function test_set_manual_in_twap_mode_reverts() public {
        oracle.enableTwap(makeAddr("pool"), true);
        vm.expectRevert("TWAP mode active, cannot set manual");
        oracle.setManualPrice(50000);
    }

    function test_revert_to_manual() public {
        oracle.enableTwap(makeAddr("pool"), true);
        oracle.revertToManual(40000);
        assertTrue(oracle.useManualPrice());
        assertEq(oracle.getPrice(), 40000);
    }

    function test_only_owner_can_set_price() public {
        vm.prank(notOwner);
        vm.expectRevert();
        oracle.setManualPrice(50000);
    }

    function test_only_owner_can_enable_twap() public {
        vm.prank(notOwner);
        vm.expectRevert();
        oracle.enableTwap(makeAddr("pool"), true);
    }

    function test_set_manual_price_too_high_reverts() public {
        vm.expectRevert("Price too high");
        oracle.setManualPrice(1_000_000_001); // > $1000
    }

    function test_revert_to_manual_too_high_reverts() public {
        oracle.enableTwap(makeAddr("pool"), true);
        vm.expectRevert("Price too high");
        oracle.revertToManual(1_000_000_001);
    }

    function test_twap_interval_bounds() public {
        vm.expectRevert("5min to 2h");
        oracle.setTwapInterval(200);

        vm.expectRevert("5min to 2h");
        oracle.setTwapInterval(8000);

        oracle.setTwapInterval(1800);
        assertEq(oracle.twapInterval(), 1800);
    }
}
