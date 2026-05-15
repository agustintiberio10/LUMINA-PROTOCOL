// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../../src/products/FlashBTCShield48h.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract FlashBTCShield48hTest is Test {
    FlashBTCShield48h shield;

    function setUp() public {
        vm.chainId(8453);
        shield = ProxyDeployer.deployFlashBTCShield48h(makeAddr("r"), makeAddr("o"));
    }

    function test_productId() public view {
        assertEq(shield.productId(), keccak256("FLASHBTC48-001"));
    }

    function test_durationRange() public view {
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, 172800);
        assertEq(mx, 172800);
    }

    function test_triggerDropBps() public view {
        assertEq(shield.TRIGGER_DROP_BPS(), 1500);
    }

    function test_deductibleBps() public view {
        assertEq(shield.DEDUCTIBLE_BPS(), 2000);
    }
}
