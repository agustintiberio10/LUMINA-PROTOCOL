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

/// @notice Core suite for `CEXLiquidityReserve`. Post-Tier-1-redesign:
///         the V1 sub-bucket model (Immediate/Vesting/Strategic) is gone,
///         so every test that gated on per-bucket availability, the
///         linear vesting curve, or the 547d strategic lock has been
///         removed or rewritten against the new flat-reserve semantics.
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
        assertEq(reserve.monthlyCap(), 1_000_000 * 1e18, "default cap");
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

    function test_Allocate_Success() public {
        vm.prank(multisig);
        reserve.allocate(recipient, 1_000_000 * 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "Tier 3 listing");
        assertEq(lumina.balanceOf(recipient), 1_000_000 * 1e18);
        assertEq(reserve.totalAllocated(), 1_000_000 * 1e18);
    }

    function test_RevertIf_AllocateExceedsMonthlyCap() public {
        vm.startPrank(multisig);
        reserve.allocate(recipient, 1_000_000 * 1e18, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Max");
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(recipient, 1, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Over");
        vm.stopPrank();
    }

    function test_RevertIf_AllocateZeroAmount() public {
        vm.prank(multisig);
        vm.expectRevert("Zero amount");
        reserve.allocate(recipient, 0, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Zero");
    }

    function test_RevertIf_AllocateZeroRecipient() public {
        vm.prank(multisig);
        vm.expectRevert("Zero recipient");
        reserve.allocate(address(0), 1e18, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Zero recipient");
    }

    function test_RevertIf_AllocateUnauthorized() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        reserve.allocate(recipient, 1e18, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Unauth");
    }

    function test_AllocationHistory_RecordsAll() public {
        vm.prank(multisig);
        reserve.allocate(recipient, 100 * 1e18, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "First");
        assertEq(reserve.getAllocationHistoryLength(), 1);
    }

    function test_GetTotalAllocated_Correct() public {
        vm.startPrank(multisig);
        reserve.allocate(recipient, 500_000 * 1e18, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Alloc 1");
        vm.warp(block.timestamp + 31 days); // cross monthly bucket
        reserve.allocate(recipient, 200_000 * 1e18, CEXLiquidityReserve.Purpose.MARKET_MAKER_LOAN, "Alloc 2");
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
        reserve.allocate(recipient, 500_000 * 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "Half cap");
        assertEq(reserve.getMonthlyCapRemaining(), 500_000 * 1e18, "Remaining = 500K");
    }

    function test_GetMonthlyCapRemaining_ResetsNextMonth() public {
        vm.prank(multisig);
        reserve.allocate(recipient, 500_000 * 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "Month 0 alloc");
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
        reserve.allocate(recipient, 1e18, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, string(longDesc));
    }

    function test_DescriptionEmpty_Reverts() public {
        vm.prank(multisig);
        vm.expectRevert("Description required");
        reserve.allocate(recipient, 1e18, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "");
    }

    function test_AllocateExactlyAtCap_Success() public {
        vm.prank(multisig);
        reserve.allocate(recipient, 1_000_000 * 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2, "Exactly at cap");
        assertEq(reserve.getMonthlyCapRemaining(), 0, "Cap fully used");
        assertEq(lumina.balanceOf(recipient), 1_000_000 * 1e18);
    }

    function test_MultipleAllocationsTrackSeparately() public {
        vm.startPrank(multisig);
        reserve.allocate(recipient, 300_000 * 1e18, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Alloc 1");
        vm.warp(block.timestamp + 31 days);
        reserve.allocate(recipient, 200_000 * 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1, "Alloc 2");
        vm.stopPrank();

        assertEq(reserve.totalAllocated(), 500_000 * 1e18, "Cumulative tracked");
        assertEq(reserve.getAllocationHistoryLength(), 2);
    }

    function test_AllocateAtTOTAL_AMOUNTCeiling() public {
        // Lift cap so the cumulative ceiling, not the monthly cap, becomes
        // the binding constraint for this drain pattern.
        vm.prank(multisig);
        reserve.setMonthlyCap(14_000_000 * 1e18);

        vm.prank(multisig);
        reserve.allocate(recipient, 14_000_000 * 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1, "Drain reserve");
        assertEq(reserve.totalAllocated(), 14_000_000 * 1e18);

        // One wei more — must revert "Exceeds total reserve".
        vm.warp(block.timestamp + 31 days);
        vm.prank(multisig);
        vm.expectRevert("Exceeds total reserve");
        reserve.allocate(recipient, 1, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1, "Over total");
    }
}
