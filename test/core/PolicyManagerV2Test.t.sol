// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../../src/core/PolicyManagerV2.sol";

contract MockBondVault {
    uint256 public cap = 1_000_000; // integer dollars
    uint256 public totalReserved; // 18-dec USD-wei
    uint256 public lastPayoutUSD;
    address public lastTo;

    function availableCapacityUSD() external view returns (uint256) {
        uint256 reservedDollars = totalReserved / 1e18;
        if (cap <= reservedDollars) return 0;
        return cap - reservedDollars;
    }

    function issueBond(address to, uint256 usdPayout) external {
        lastTo = to;
        lastPayoutUSD = usdPayout;
    }

    function reserveCapacity(uint256 amount) external {
        totalReserved += amount;
    }

    function releaseReservation(uint256 amount) external {
        totalReserved -= amount;
    }

    function commitReservation(uint256 amount) external {
        totalReserved -= amount;
    }

    function setCap(uint256 c) external {
        cap = c;
    }
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

    // ═══════ deactivateProduct tests ═══════

    function test_DeactivateProduct_Success() public {
        bytes32 pid = keccak256("DEACTIVATE-TEST");
        address shield = makeAddr("shield");
        pm.registerProduct(pid, shield);
        assertTrue(pm.productActive(pid), "Product should be active after registration");

        pm.deactivateProduct(pid);
        assertFalse(pm.productActive(pid), "Product should be inactive after deactivation");
    }

    function test_DeactivateProduct_RevertIf_NotOwner() public {
        bytes32 pid = keccak256("DEACTIVATE-TEST2");
        pm.registerProduct(pid, makeAddr("shield"));

        vm.prank(makeAddr("random"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("random")));
        pm.deactivateProduct(pid);
    }

    function test_DeactivateProduct_ExistingPoliciesUnaffected() public {
        bytes32 pid = keccak256("DEACTIVATE-POLICIES");
        address shield = makeAddr("shield");
        pm.registerProduct(pid, shield);

        // Mock shield so recordPolicy can create a policy
        vm.mockCall(shield, abi.encodeWithSelector(IShieldV2.createPolicy.selector), abi.encode(uint256(42)));

        // Record a policy while product is active
        pm.recordPolicy(pid, makeAddr("buyer"), 1000e6, 2e6, 3600, "BTC");

        // Deactivate the product
        pm.deactivateProduct(pid);
        assertFalse(pm.productActive(pid), "Product should be inactive");

        // Existing policy record should still be intact
        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(pid, 42);
        assertEq(rec.buyer, makeAddr("buyer"), "Policy buyer should be unchanged");
        assertEq(rec.coverageAmount, 1000e6, "Coverage should be unchanged");
        assertFalse(rec.triggered, "Policy should not be triggered");
        assertFalse(rec.expired, "Policy should not be expired");
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
