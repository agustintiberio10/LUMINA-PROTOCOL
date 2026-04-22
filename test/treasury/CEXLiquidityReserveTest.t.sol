// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
    using ProxyDeployer for *;

    CEXLiquidityReserve reserve;
    MockLUMINA lumina;
    address multisig = makeAddr("multisig");
    address recipient = makeAddr("recipient");

    function setUp() public {
        lumina = new MockLUMINA();
        reserve = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), multisig);
        // Fund the reserve with 14M
        lumina.mint(address(reserve), 14_000_000 * 1e18);
    }

    function test_Constructor_CorrectInit() public view {
        assertEq(address(reserve.lumina()), address(lumina));
        assertEq(reserve.TOTAL_AMOUNT(), 14_000_000 * 1e18);
    }

    function test_RevertIf_ConstructorZeroAddresses() public {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, address(0), multisig)
        );
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, address(lumina), address(0))
        );
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

    // ---- New tests ----

    function test_GetAvailableInBucket_Immediate() public view {
        uint256 avail = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.ImmediateUse);
        assertEq(avail, 2_800_000 * 1e18, "Full immediate amount available at start");
    }

    function test_GetAvailableInBucket_Vesting_AtMidpoint() public {
        vm.warp(block.timestamp + 365 days);
        uint256 avail = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.VestingLinear);
        // 365/730 = 50% of 8.4M = 4.2M
        assertGt(avail, 4_100_000 * 1e18, "Should be ~50% vested");
        assertLt(avail, 4_300_000 * 1e18, "Should be ~50% vested");
    }

    function test_GetAvailableInBucket_Strategic_BeforeAndAfter() public {
        uint256 before_ = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.StrategicReserve);
        assertEq(before_, 0, "Strategic locked before 547d");

        vm.warp(block.timestamp + 548 days);
        uint256 after_ = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.StrategicReserve);
        assertEq(after_, 2_800_000 * 1e18, "Full strategic after unlock");
    }

    function test_GetTotalAllocated_Correct() public {
        vm.startPrank(multisig);
        reserve.allocate(
            recipient,
            500_000 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Alloc 1"
        );
        vm.warp(block.timestamp + 365 days);
        reserve.allocate(
            recipient,
            200_000 * 1e18,
            CEXLiquidityReserve.SubBucket.VestingLinear,
            CEXLiquidityReserve.Purpose.MARKET_MAKER_LOAN,
            "Alloc 2"
        );
        vm.stopPrank();
        assertEq(reserve.getTotalAllocated(), 700_000 * 1e18, "Sum of both allocations");
    }

    function test_GetCurrentMonth_AdvancesOverTime() public {
        assertEq(reserve.getCurrentMonth(), 0, "Month 0 at deploy");
        vm.warp(block.timestamp + 30 days);
        assertEq(reserve.getCurrentMonth(), 1, "Month 1 after 30d");
    }

    function test_GetMonthlyCapRemaining_DecreasesWithAllocations() public {
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            500_000 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Half cap"
        );
        assertEq(reserve.getMonthlyCapRemaining(), 500_000 * 1e18, "Remaining = 500K");
    }

    function test_GetMonthlyCapRemaining_ResetsNextMonth() public {
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            500_000 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Month 0 alloc"
        );
        vm.warp(block.timestamp + 30 days);
        assertEq(reserve.getMonthlyCapRemaining(), 1_000_000 * 1e18, "Full cap in new month");
    }

    function test_DescriptionTooLong_Reverts() public {
        // 201 characters
        bytes memory longDesc = new bytes(201);
        for (uint256 i = 0; i < 201; i++) {
            longDesc[i] = "A";
        }
        vm.prank(multisig);
        vm.expectRevert("Description too long");
        reserve.allocate(
            recipient,
            1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            string(longDesc)
        );
    }

    function test_AllocateExactlyAtCap_Success() public {
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            1_000_000 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2,
            "Exactly at cap"
        );
        assertEq(reserve.getMonthlyCapRemaining(), 0, "Cap fully used");
        assertEq(lumina.balanceOf(recipient), 1_000_000 * 1e18);
    }

    function test_MultipleAllocationsTrackSeparately() public {
        vm.startPrank(multisig);
        reserve.allocate(
            recipient,
            300_000 * 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Immediate alloc"
        );
        vm.warp(block.timestamp + 548 days);
        reserve.allocate(
            recipient,
            200_000 * 1e18,
            CEXLiquidityReserve.SubBucket.StrategicReserve,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1,
            "Strategic alloc"
        );
        vm.stopPrank();

        assertEq(reserve.allocatedFromImmediate(), 300_000 * 1e18, "Immediate tracked");
        assertEq(reserve.allocatedFromStrategic(), 200_000 * 1e18, "Strategic tracked");
        assertEq(reserve.allocatedFromVesting(), 0, "Vesting untouched");
    }

    function test_AllocateFromVesting_RespectSchedule() public {
        // At time 0, no vesting available
        vm.prank(multisig);
        vm.expectRevert("Insufficient in sub-bucket");
        reserve.allocate(
            recipient,
            1e18,
            CEXLiquidityReserve.SubBucket.VestingLinear,
            CEXLiquidityReserve.Purpose.MARKET_MAKER_LOAN,
            "Too early vesting"
        );

        // Warp 365 days => ~4.2M vested, allocate up to monthly cap (1M)
        vm.warp(block.timestamp + 365 days);
        uint256 avail = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.VestingLinear);
        assertGt(avail, 1_000_000 * 1e18, "Should have >1M vested");
        uint256 allocAmount = 1_000_000 * 1e18; // monthly cap
        vm.prank(multisig);
        reserve.allocate(
            recipient,
            allocAmount,
            CEXLiquidityReserve.SubBucket.VestingLinear,
            CEXLiquidityReserve.Purpose.MARKET_MAKER_LOAN,
            "Allocate within cap"
        );
        assertEq(reserve.allocatedFromVesting(), allocAmount);
    }
}
