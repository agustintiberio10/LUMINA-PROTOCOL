// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../../src/products/FlashETHShield48h.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract FlashETHShield48hTest is Test {
    FlashETHShield48h shield;

    function setUp() public {
        vm.chainId(8453);
        shield = ProxyDeployer.deployFlashETHShield48h(makeAddr("r"), makeAddr("o"));
    }

    function test_productId() public view {
        assertEq(shield.productId(), keccak256("FLASHETH48-001"));
    }

    function test_durationRange() public view {
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, 172800);
        assertEq(mx, 172800);
    }

    function test_triggerDropBps() public view {
        assertEq(shield.TRIGGER_DROP_BPS(), 1800);
    }

    function test_deductibleBps() public view {
        assertEq(shield.DEDUCTIBLE_BPS(), 2000);
    }
}
