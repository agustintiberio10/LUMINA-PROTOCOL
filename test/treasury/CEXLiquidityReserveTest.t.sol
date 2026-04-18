// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";

contract MockLUMINA {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }
}

contract CEXLiquidityReserveTest is Test {
    CEXLiquidityReserve reserve;
    MockLUMINA lumina;
    address multisig = makeAddr("multisig");
    address recipient = makeAddr("recipient");

    function setUp() public {
        lumina = new MockLUMINA();
        reserve = new CEXLiquidityReserve(address(lumina), multisig);
        // Fund the reserve with 14M
        lumina.mint(address(reserve), 14_000_000 * 1e18);
    }

    function test_Constructor_CorrectInit() public view {
        assertEq(address(reserve.lumina()), address(lumina));
        assertEq(reserve.TOTAL_AMOUNT(), 14_000_000 * 1e18);
    }

    function test_RevertIf_ConstructorZeroAddresses() public {
        vm.expectRevert("Lumina zero address");
        new CEXLiquidityReserve(address(0), multisig);
        vm.expectRevert("Multisig zero address");
        new CEXLiquidityReserve(address(lumina), address(0));
    }

    function test_Allocate_FromImmediateUse_Success() public {
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            1_000_000 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Tier 3 listing"
        );
        assertEq(lumina.balanceOf(recipient), 1_000_000 * 1e18);
        assertEq(reserve.allocatedFromImmediate(), 1_000_000 * 1e18);
    }

    function test_RevertIf_AllocateFromStrategicBeforeUnlock() public {
        vm.prank(multisig);
        vm.expectRevert("Insufficient in sub-bucket");
        reserve.allocate(
            recipient,
            1e18,
            CEXLiquidityReserve.SubBucket.StrategicReserve,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1,
            "Too early"
        );
    }

    function test_Allocate_FromStrategicAfterUnlock() public {
        vm.warp(block.timestamp + 548 days); // After 547d lock
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            1_000_000 * 1e18,
            CEXLiquidityReserve.SubBucket.StrategicReserve,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1,
            "Tier 1"
        );
        assertEq(reserve.allocatedFromStrategic(), 1_000_000 * 1e18);
    }

    function test_RevertIf_AllocateExceedsMonthlyCap() public {
        vm.startPrank(multisig);
        reserve.allocate(
            recipient,
            1_000_000 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Max"
        );
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(
            recipient,
            1,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Over"
        );
        vm.stopPrank();
    }

    function test_RevertIf_AllocateZeroAmount() public {
        vm.prank(multisig);
        vm.expectRevert("Amount zero");
        reserve.allocate(
            recipient,
            0,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Zero"
        );
    }

    function test_RevertIf_AllocateUnauthorized() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        reserve.allocate(
            recipient,
            1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Unauth"
        );
    }

    function test_GetVestedAmount_LinearOverTime() public {
        assertEq(reserve.getVestedAmount(), 0);
        vm.warp(block.timestamp + 365 days); // ~50% vested
        uint256 vested = reserve.getVestedAmount();
        assertGt(vested, 4_000_000 * 1e18);
        assertLt(vested, 4_500_000 * 1e18);
    }

    function test_GetVestedAmount_FullAfter24Months() public {
        vm.warp(block.timestamp + 731 days);
        assertEq(reserve.getVestedAmount(), 8_400_000 * 1e18);
    }

    function test_AllocationHistory_RecordsAll() public {
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            100 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "First"
        );
        assertEq(reserve.getAllocationHistoryLength(), 1);
    }
}
