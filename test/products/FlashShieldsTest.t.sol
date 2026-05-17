// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/products/FlashBTCShield1h.sol";
import "../../src/products/FlashETHShield1h.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract FlashShieldsTest is Test {
    FlashBTCShield1h btc1h;
    FlashETHShield1h eth1h;

    address router = makeAddr("router");
    address oracle = makeAddr("oracle");

    function setUp() public {
        vm.chainId(8453);
        btc1h = ProxyDeployer.deployFlashBTCShield1h(router, oracle);
        eth1h = ProxyDeployer.deployFlashETHShield1h(router, oracle);
    }

    // ═══════ FlashBTCShield1h ═══════
    function test_btc1h_productId() public view {
        assertEq(btc1h.productId(), keccak256("FLASHBTC1H-001"));
    }

    function test_btc1h_durationRange() public view {
        (uint32 min, uint32 max) = btc1h.durationRange();
        assertEq(min, 3600);
        assertEq(max, 3600);
    }

    function test_btc1h_triggerDropBps() public view {
        assertEq(btc1h.TRIGGER_DROP_BPS(), 500);
    }

    function test_btc1h_deductibleBps() public view {
        assertEq(btc1h.DEDUCTIBLE_BPS(), 2000);
    }

    // ═══════ FlashETHShield1h ═══════
    function test_eth1h_productId() public view {
        assertEq(eth1h.productId(), keccak256("FLASHETH1H-001"));
    }

    function test_eth1h_durationRange() public view {
        (uint32 min, uint32 max) = eth1h.durationRange();
        assertEq(min, 3600);
        assertEq(max, 3600);
    }

    function test_eth1h_triggerDropBps() public view {
        assertEq(eth1h.TRIGGER_DROP_BPS(), 700);
    }

    function test_eth1h_deductibleBps() public view {
        assertEq(eth1h.DEDUCTIBLE_BPS(), 2000);
    }
}
