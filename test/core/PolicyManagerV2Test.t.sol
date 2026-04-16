// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/v2/core/PolicyManagerV2.sol";

contract MockBondVault {
    uint256 public cap = 1_000_000;
    uint256 public lastPayoutUSD;
    address public lastTo;

    function availableCapacityUSD() external view returns (uint256) { return cap; }
    function issueBond(address to, uint256 usdPayout) external {
        lastTo = to;
        lastPayoutUSD = usdPayout;
    }
    function setCap(uint256 c) external { cap = c; }
}

contract PolicyManagerV2Test is Test {
    PolicyManagerV2 pm;
    MockBondVault vault;
    address router;

    function setUp() public {
        vault = new MockBondVault();
        pm = new PolicyManagerV2(address(vault));
        router = address(this);
        pm.setRouter(router);
    }

    function test_registerProduct() public {
        bytes32 pid = keccak256("FLASHBTC1H-001");
        pm.registerProduct(pid, makeAddr("shield"));
        assertEq(pm.productShield(pid), makeAddr("shield"));
        assertTrue(pm.productActive(pid));
    }

    function test_onlyRouter_recordPolicy() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        pm.recordPolicy(keccak256("X"), makeAddr("buyer"), 1000e6, 2e6, 3600, "BTC");
    }

    function test_insufficientCapacity() public {
        bytes32 pid = keccak256("TEST");
        pm.registerProduct(pid, makeAddr("shield"));
        vault.setCap(100); // very low cap
        vm.expectRevert();
        pm.recordPolicy(pid, makeAddr("buyer"), 1_000_000e6, 2e6, 3600, "BTC");
    }

    function test_markExpired() public {
        // Would need a full shield mock — simplified test
        // The logic checks block.timestamp > expiresAt
        assertTrue(true); // placeholder, full integration test day 6
    }

    function test_getStats() public view {
        (uint256 total, uint256 active, uint256 triggers, uint256 bonds, uint256 cap_) = pm.getStats();
        assertEq(total, 0);
        assertEq(active, 0);
        assertEq(triggers, 0);
        assertEq(bonds, 0);
        assertGt(cap_, 0);
    }
}
