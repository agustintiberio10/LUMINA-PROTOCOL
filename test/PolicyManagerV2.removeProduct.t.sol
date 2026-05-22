// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../src/core/PolicyManagerV2.sol";

/// @title PolicyManagerV2 removeProduct + removeProductBatch unit tests
/// @notice Sprint Cleanup — exercises the new swap-and-pop array cleanup that
///         strips duplicate or stale `productId` entries from `productIds[]`
///         without touching the `productShield` / `productActive` mappings.

contract MockBondVault {
    uint256 public cap = 1_000_000;

    function availableCapacityUSD() external view returns (uint256) {
        return cap;
    }

    function issueBond(address, uint256) external {}
    function reserveCapacity(uint256) external {}
    function releaseReservation(uint256) external {}
    function commitReservation(uint256) external {}
}

contract PolicyManagerV2RemoveProductTest is Test {
    PolicyManagerV2 pm;
    MockBondVault vault;

    address owner = address(this);
    address attacker = makeAddr("attacker");
    address shieldA = makeAddr("shieldA");
    address shieldB = makeAddr("shieldB");
    address shieldC = makeAddr("shieldC");

    bytes32 constant PID_A = keccak256("PRODUCT-A");
    bytes32 constant PID_B = keccak256("PRODUCT-B");
    bytes32 constant PID_C = keccak256("PRODUCT-C");
    bytes32 constant PID_GHOST = keccak256("PRODUCT-DOES-NOT-EXIST");

    // Mirror the contract event so vm.expectEmit can match by topic.
    event ProductRemoved(bytes32 indexed productId);

    function setUp() public {
        vault = new MockBondVault();
        PolicyManagerV2 impl = new PolicyManagerV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(PolicyManagerV2.initialize.selector, address(vault))
        );
        pm = PolicyManagerV2(address(proxy));
    }

    // ── 1. Single entry: registered once, removed once ──────────────────────
    function testRemoveProduct_SingleEntry() public {
        pm.registerProduct(PID_A, shieldA);
        assertEq(pm.getProductCount(), 1);

        pm.removeProduct(PID_A);
        assertEq(pm.getProductCount(), 0, "array empty after removal");
        // Mapping untouched by design — caller is expected to deactivate first.
        assertEq(pm.productShield(PID_A), shieldA, "productShield mapping preserved");
        assertTrue(pm.productActive(PID_A), "productActive mapping preserved");
    }

    // ── 2. Real duplicates case: 2 entries of same pid stripped in one call ──
    function testRemoveProduct_AllDuplicates() public {
        pm.registerProduct(PID_A, shieldA);
        pm.registerProduct(PID_B, shieldB);
        pm.registerProduct(PID_A, shieldA); // duplicate
        pm.registerProduct(PID_C, shieldC);
        pm.registerProduct(PID_A, shieldA); // 3rd dupe
        assertEq(pm.getProductCount(), 5, "5 entries with 3 dupes of PID_A");

        pm.removeProduct(PID_A);
        assertEq(pm.getProductCount(), 2, "all 3 PID_A entries gone");

        // The 2 survivors must be PID_B and PID_C, in some order.
        bytes32 e0 = pm.productIds(0);
        bytes32 e1 = pm.productIds(1);
        bool hasB = (e0 == PID_B) || (e1 == PID_B);
        bool hasC = (e0 == PID_C) || (e1 == PID_C);
        assertTrue(hasB, "PID_B survives");
        assertTrue(hasC, "PID_C survives");
    }

    // ── 3. Reverts if productId not in array ────────────────────────────────
    function testRemoveProduct_RevertIfNotInArray() public {
        pm.registerProduct(PID_A, shieldA);
        vm.expectRevert(bytes("PM: productId not in array"));
        pm.removeProduct(PID_GHOST);
    }

    // ── 4. Only owner can call ──────────────────────────────────────────────
    function testRemoveProduct_OnlyOwner() public {
        pm.registerProduct(PID_A, shieldA);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        pm.removeProduct(PID_A);
    }

    // ── 5. productShield mapping is preserved across removal ────────────────
    function testRemoveProduct_PreservesProductShieldMapping() public {
        pm.registerProduct(PID_A, shieldA);
        pm.registerProduct(PID_A, shieldA); // duplicate
        pm.removeProduct(PID_A);

        assertEq(pm.productShield(PID_A), shieldA, "productShield(PID_A) intact");
        assertTrue(pm.productActive(PID_A), "productActive(PID_A) intact");
        assertEq(pm.getProductCount(), 0);
    }

    // ── 6. Batch: multiple pids removed in one call ─────────────────────────
    function testRemoveProductBatch_MultiplePids() public {
        pm.registerProduct(PID_A, shieldA);
        pm.registerProduct(PID_B, shieldB);
        pm.registerProduct(PID_C, shieldC);
        pm.registerProduct(PID_A, shieldA); // dupe
        assertEq(pm.getProductCount(), 4);

        bytes32[] memory pids = new bytes32[](2);
        pids[0] = PID_A;
        pids[1] = PID_B;
        pm.removeProductBatch(pids);

        assertEq(pm.getProductCount(), 1, "only PID_C survives");
        assertEq(pm.productIds(0), PID_C, "PID_C is the sole entry");
    }

    // ── 7. Batch: partial failure reverts whole call (all-or-nothing) ───────
    function testRemoveProductBatch_PartialFailureRevertsAll() public {
        pm.registerProduct(PID_A, shieldA);

        bytes32[] memory pids = new bytes32[](2);
        pids[0] = PID_A; // would succeed
        pids[1] = PID_GHOST; // does not exist
        vm.expectRevert(bytes("PM: productId not in array"));
        pm.removeProductBatch(pids);

        // State change from the first removal SHOULD be rolled back by the revert.
        assertEq(pm.getProductCount(), 1, "rollback: PID_A still present");
    }

    // ── 8. Event is emitted once per removeProduct call ─────────────────────
    function testRemoveProduct_EmitsEvent() public {
        pm.registerProduct(PID_A, shieldA);
        pm.registerProduct(PID_A, shieldA); // dupe — still ONE event on removal

        vm.expectEmit(true, false, false, true);
        emit ProductRemoved(PID_A);
        pm.removeProduct(PID_A);
    }

    // ── 9. Swap-and-pop leaves no gap, order may be permuted but is contiguous
    function testRemoveProduct_ArraySwapAndPop_NoGap() public {
        // Register A, B, C, D, E.
        bytes32 PID_D = keccak256("PRODUCT-D");
        bytes32 PID_E = keccak256("PRODUCT-E");
        pm.registerProduct(PID_A, shieldA);
        pm.registerProduct(PID_B, shieldB);
        pm.registerProduct(PID_C, shieldC);
        pm.registerProduct(PID_D, makeAddr("shieldD"));
        pm.registerProduct(PID_E, makeAddr("shieldE"));
        assertEq(pm.getProductCount(), 5);

        // Remove the middle one (C).
        pm.removeProduct(PID_C);
        assertEq(pm.getProductCount(), 4, "length decremented by 1");

        // Iterate the 4 surviving entries — must be {A, B, D, E} as a set, no gap.
        bool seenA;
        bool seenB;
        bool seenD;
        bool seenE;
        bool seenC;
        for (uint256 i = 0; i < 4; i++) {
            bytes32 v = pm.productIds(i);
            if (v == PID_A) seenA = true;
            else if (v == PID_B) seenB = true;
            else if (v == PID_C) seenC = true;
            else if (v == PID_D) seenD = true;
            else if (v == PID_E) seenE = true;
        }
        assertTrue(seenA && seenB && seenD && seenE, "all survivors present");
        assertFalse(seenC, "removed entry absent");
    }

    // ── 10. Removing the last element does not touch the rest ───────────────
    function testRemoveProduct_LastElementOnly() public {
        pm.registerProduct(PID_A, shieldA);
        pm.registerProduct(PID_B, shieldB);
        pm.registerProduct(PID_C, shieldC);

        pm.removeProduct(PID_C);
        assertEq(pm.getProductCount(), 2);
        assertEq(pm.productIds(0), PID_A, "PID_A undisturbed");
        assertEq(pm.productIds(1), PID_B, "PID_B undisturbed");
    }

    // ── 11. Removing the only element leaves an empty array ─────────────────
    function testRemoveProduct_OnlyEntryEmptiesArray() public {
        pm.registerProduct(PID_A, shieldA);
        pm.removeProduct(PID_A);
        assertEq(pm.getProductCount(), 0);
        vm.expectRevert(); // index OOB
        pm.productIds(0);
    }
}
