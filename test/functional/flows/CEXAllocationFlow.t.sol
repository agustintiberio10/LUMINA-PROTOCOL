// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../../src/treasury/CEXLiquidityReserve.sol";

// Minimal ERC20 mock for LUMINA in allocation tests
contract MockLuminaToken is ERC20 {
    constructor() ERC20("Lumina Protocol", "LUMINA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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
        reserve = new CEXLiquidityReserve(address(lumina), multisig);

        // Fund reserve with TOTAL_AMOUNT of LUMINA
        lumina.mint(address(reserve), reserve.TOTAL_AMOUNT());
    }

    // ─── Test 1: Allocate from ImmediateUse bucket transfers LUMINA ───

    function test_Flow_CEX_AllocateFromImmediate() public {
        uint256 amount = 500_000 * 1e18;
        uint256 available = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.ImmediateUse);
        assertEq(available, reserve.IMMEDIATE_AMOUNT(), "Full immediate bucket available");

        uint256 recipientBalBefore = lumina.balanceOf(recipient);

        vm.prank(multisig);
        reserve.allocate(
            recipient,
            amount,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Initial DEX liquidity provision"
        );

        uint256 recipientBalAfter = lumina.balanceOf(recipient);
        assertEq(recipientBalAfter - recipientBalBefore, amount, "LUMINA not transferred");
        assertEq(reserve.allocatedFromImmediate(), amount, "allocatedFromImmediate not updated");

        uint256 remainingAvailable = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.ImmediateUse);
        assertEq(remainingAvailable, reserve.IMMEDIATE_AMOUNT() - amount, "Available not decreased");
    }

    // ─── Test 2: Monthly cap enforced ───

    function test_Flow_CEX_MonthlyCap_Enforced() public {
        uint256 cap = reserve.MONTHLY_CAP();
        assertEq(cap, 1_000_000 * 1e18, "MONTHLY_CAP should be 1M LUMINA");

        // Allocate exactly at cap
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            cap,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Fill monthly cap"
        );

        // Next allocation should revert
        vm.prank(multisig);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(
            recipient,
            1e18, // even 1 LUMINA should fail
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Over cap allocation"
        );
    }

    // ─── Test 3: Monthly cap resets after 30 days ───

    function test_Flow_CEX_MonthlyCap_ResetsNextMonth() public {
        uint256 cap = reserve.MONTHLY_CAP();

        // Use up the monthly cap
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            cap,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2,
            "Max out month"
        );

        // Verify cap is fully used
        vm.prank(multisig);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(
            recipient,
            1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2,
            "Should fail"
        );

        // Warp 30 days forward (enters new month bucket)
        vm.warp(block.timestamp + 30 days);

        // Now allocation should succeed in the new month
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            500_000 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2,
            "New month allocation"
        );

        assertEq(lumina.balanceOf(recipient), cap + 500_000 * 1e18, "Total received mismatch");
    }

    // ─── Test 4: Strategic bucket locked before STRATEGIC_LOCK days ───

    function test_Flow_CEX_StrategicLocked() public {
        uint256 lockDuration = reserve.STRATEGIC_LOCK();
        assertEq(lockDuration, 547 days, "STRATEGIC_LOCK should be 547 days");

        // Immediately after deploy, strategic should have 0 available
        uint256 available = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.StrategicReserve);
        assertEq(available, 0, "Strategic should be locked");

        vm.prank(multisig);
        vm.expectRevert("Insufficient in sub-bucket");
        reserve.allocate(
            recipient,
            100_000 * 1e18,
            CEXLiquidityReserve.SubBucket.StrategicReserve,
            CEXLiquidityReserve.Purpose.MARKET_MAKER_LOAN,
            "Early strategic attempt"
        );
    }

    // ─── Test 5: Strategic bucket unlocked after STRATEGIC_LOCK ───

    function test_Flow_CEX_StrategicUnlocked() public {
        uint256 lockDuration = reserve.STRATEGIC_LOCK();

        // Warp past lock period
        vm.warp(block.timestamp + lockDuration + 1);

        uint256 available = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.StrategicReserve);
        assertEq(available, reserve.STRATEGIC_AMOUNT(), "Full strategic bucket should be available");

        uint256 amount = 500_000 * 1e18;

        vm.prank(multisig);
        reserve.allocate(
            recipient,
            amount,
            CEXLiquidityReserve.SubBucket.StrategicReserve,
            CEXLiquidityReserve.Purpose.MARKET_MAKER_LOAN,
            "Post-lock strategic allocation"
        );

        assertEq(lumina.balanceOf(recipient), amount, "LUMINA not received");
        assertEq(reserve.allocatedFromStrategic(), amount, "Strategic tracking mismatch");
    }
}
