// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../../src/products/FlashETHShield24h.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract FlashETHShield24hTest is Test {
    FlashETHShield24h shield;

    function setUp() public {
        shield = ProxyDeployer.deployFlashETHShield24h(makeAddr("r"), makeAddr("o"));
    }

    function test_productId() public view {
        assertEq(shield.productId(), keccak256("FLASHETH24-001"));
    }

    function test_durationRange() public view {
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, 86400);
        assertEq(mx, 86400);
    }

    function test_triggerDropBps() public view {
        assertEq(shield.TRIGGER_DROP_BPS(), 1200);
    }

    function test_deductibleBps() public view {
        assertEq(shield.DEDUCTIBLE_BPS(), 2000);
    }
}
