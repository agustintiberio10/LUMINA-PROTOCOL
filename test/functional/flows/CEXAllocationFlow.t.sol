// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../../src/treasury/CEXLiquidityReserve.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// Minimal ERC20 mock for LUMINA in allocation tests
contract MockLuminaToken is ERC20 {
    constructor() ERC20("Lumina Protocol", "LUMINA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Functional flow tests for `CEXLiquidityReserve.allocate()`.
///         Post Tier-1 redesign — sub-buckets and the strategic-lock
///         have been retired. The only remaining gates are:
///         (a) cumulative `totalAllocated <= TOTAL_AMOUNT` and
///         (b) per-30d-bucket `monthlyAllocations[m] <= monthlyCap`.
contract CEXAllocationFlowTest is Test {
    CEXLiquidityReserve reserve;
    MockLuminaToken lumina;

    address multisig = makeAddr("multisig");
    address recipient = makeAddr("recipient");

    function setUp() public {
        // Warp to a sane base time
        vm.warp(1767225600 + 30 days);

        lumina = new MockLuminaToken();

        vm.prank(multisig);
        reserve = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), multisig);

        // Fund reserve with TOTAL_AMOUNT of LUMINA
        lumina.mint(address(reserve), reserve.TOTAL_AMOUNT());
    }

    // ─── Test 1: A simple allocate transfers LUMINA and bumps totalAllocated ───

    function test_Flow_CEX_Allocate() public {
        uint256 amount = 500_000 * 1e18;

        uint256 recipientBalBefore = lumina.balanceOf(recipient);

        vm.prank(multisig);
        reserve.allocate(
            recipient, amount, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Initial DEX liquidity provision"
        );

        uint256 recipientBalAfter = lumina.balanceOf(recipient);
        assertEq(recipientBalAfter - recipientBalBefore, amount, "LUMINA not transferred");
        assertEq(reserve.totalAllocated(), amount, "totalAllocated not updated");
    }

    // ─── Test 2: Monthly cap enforced ───

    function test_Flow_CEX_MonthlyCap_Enforced() public {
        uint256 cap = reserve.monthlyCap();
        assertEq(cap, 1_000_000 * 1e18, "monthlyCap default should be 1M LUMINA");

        // Allocate exactly at cap
        vm.prank(multisig);
        reserve.allocate(recipient, cap, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "Fill monthly cap");

        // Next allocation should revert
        vm.prank(multisig);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(recipient, 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "Over cap allocation");
    }

    // ─── Test 3: Monthly cap resets after 30 days ───

    function test_Flow_CEX_MonthlyCap_ResetsNextMonth() public {
        uint256 cap = reserve.monthlyCap();

        // Use up the monthly cap
        vm.prank(multisig);
        reserve.allocate(recipient, cap, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2, "Max out month");

        // Verify cap is fully used
        vm.prank(multisig);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(recipient, 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2, "Should fail");

        // Warp 30 days forward (enters new month bucket)
        vm.warp(block.timestamp + 30 days);

        // Now allocation should succeed in the new month
        vm.prank(multisig);
        reserve.allocate(
            recipient, 500_000 * 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2, "New month allocation"
        );

        assertEq(lumina.balanceOf(recipient), cap + 500_000 * 1e18, "Total received mismatch");
    }

    // ─── Test 4: With cap raised to TOTAL_AMOUNT, all 14M can clear day-1 ───

    function test_Flow_CEX_FullDrainSingleMonth() public {
        // Tier-1 use case: admin lifts cap to MAX, single allocate clears
        // the entire reserve in one shot. No vesting curve, no strategic lock.
        uint256 total = reserve.TOTAL_AMOUNT();

        vm.prank(multisig);
        reserve.setMonthlyCap(total);

        vm.prank(multisig);
        reserve.allocate(recipient, total, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1, "Full Tier-1 day-1 drop");

        assertEq(lumina.balanceOf(recipient), total, "Recipient holds full reserve");
        assertEq(reserve.totalAllocated(), total, "Reserve fully consumed");
    }

    // ─── Test 5: Cumulative ceiling at TOTAL_AMOUNT cannot be exceeded ───

    function test_Flow_CEX_TotalReserveCeiling() public {
        uint256 total = reserve.TOTAL_AMOUNT();

        vm.prank(multisig);
        reserve.setMonthlyCap(total);

        vm.prank(multisig);
        reserve.allocate(recipient, total, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1, "Drain");

        // Cross to next month so monthlyCap doesn't gate the over-ceiling probe.
        vm.warp(block.timestamp + 31 days);

        vm.prank(multisig);
        vm.expectRevert("Exceeds total reserve");
        reserve.allocate(recipient, 1, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1, "Over total");
    }
}
