// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {MockClaimBondV5} from "../mocks/MockClaimBondV5.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MockUSDCM3 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] < a) revert("Insufficient allowance");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @title MinPricePerUnitTest
/// @notice Audit V5.1 fix M-3 — anti-spam / anti-price-manipulation floor on
///         `LuminaBondMarketplace.list()`. Covers the per-unit floor check,
///         the admin setter (cap + role gating), the reinitializer V2 path,
///         and regression that legitimate listings still work.
contract MinPricePerUnitTest is Test {
    using ProxyDeployer for *;

    // Events mirrored for vm.expectEmit
    event MinPricePerUnitUpdated(uint256 oldMin, uint256 newMin);

    LuminaBondMarketplace mp;
    MockClaimBondV5 bond;
    MockUSDCM3 usdc;

    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");
    address twapBurner = makeAddr("twapBurner");

    uint256 constant EPOCH = 202804;
    uint256 constant USDC_UNIT = 1e6; // 1 USDC = 1e6 raw
    uint256 constant ONE_DAY = 1 days;

    function setUp() public {
        bond = new MockClaimBondV5();
        usdc = new MockUSDCM3();
        mp = ProxyDeployer.deployLuminaBondMarketplace(address(bond), address(usdc), twapBurner, admin);

        bond.mint(seller, EPOCH, 10_000);
        bond.mint(attacker, EPOCH, 10_000);
        bond.setMaturityDate(EPOCH, block.timestamp + 730 days);

        usdc.mint(buyer, 1_000_000e6);
    }

    // ═══════ CRITICAL — the bug fix ═══════

    function test_DefaultMinPriceIs1USDC() public view {
        // [Fix M-3] initialize() seeds 1 USDC as the per-unit floor.
        assertEq(mp.minPricePerUnit(), USDC_UNIT, "default floor != 1 USDC");
        assertEq(mp.DEFAULT_MIN_PRICE_PER_UNIT(), USDC_UNIT);
    }

    function test_ListAt1WeiReverts() public {
        // The original bug: listing 100 bonds for 1 wei (= 0.000001 USDC TOTAL)
        // was accepted. Now reverts.
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        // pricePerUnit = 1 / 100 = 0 < 1e6 → revert with PriceBelowMinimum(0, 1e6)
        vm.expectRevert(abi.encodeWithSelector(LuminaBondMarketplace.PriceBelowMinimum.selector, 0, USDC_UNIT));
        mp.list(EPOCH, 100, 1);
        vm.stopPrank();
    }

    function test_ListAtMinPriceWorks() public {
        // pricePerUnit exactly == minPricePerUnit (1 USDC). 100 bonds * 1 USDC = 100 USDC total.
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 100, 100 * USDC_UNIT);
        vm.stopPrank();

        (,,, uint256 price, bool active) = mp.getListing(id);
        assertEq(price, 100 * USDC_UNIT);
        assertTrue(active);
    }

    function test_ListAboveMinPriceWorks() public {
        // pricePerUnit > floor. Plain happy path.
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 50, 75 * USDC_UNIT); // 1.5 USDC/unit
        vm.stopPrank();

        (,, uint256 amt, uint256 price,) = mp.getListing(id);
        assertEq(amt, 50);
        assertEq(price, 75 * USDC_UNIT);
    }

    function test_ListJustBelowMinReverts() public {
        // Edge: pricePerUnit = 0.99 USDC. Should revert.
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        // 100 bonds for 99 USDC → 0.99 USDC/unit
        vm.expectRevert(
            abi.encodeWithSelector(LuminaBondMarketplace.PriceBelowMinimum.selector, 990_000, USDC_UNIT)
        );
        mp.list(EPOCH, 100, 99 * USDC_UNIT);
        vm.stopPrank();
    }

    // ═══════ CRITICAL — admin setter ═══════

    function test_AdminCanUpdateMinPrice() public {
        vm.expectEmit(true, true, true, true);
        emit MinPricePerUnitUpdated(USDC_UNIT, 5 * USDC_UNIT);
        vm.prank(admin);
        mp.setMinPricePerUnit(5 * USDC_UNIT);
        assertEq(mp.minPricePerUnit(), 5 * USDC_UNIT);
    }

    function test_OnlyAdminCanUpdateMinPrice() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0))
        );
        vm.prank(attacker);
        mp.setMinPricePerUnit(2 * USDC_UNIT);
    }

    function test_AdminCannotSetMinAboveCap() public {
        // CAP = 100 USDC = 100e6
        uint256 over = mp.MIN_PRICE_PER_UNIT_CAP() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                LuminaBondMarketplace.MinPriceCapExceeded.selector, over, mp.MIN_PRICE_PER_UNIT_CAP()
            )
        );
        vm.prank(admin);
        mp.setMinPricePerUnit(over);
    }

    function test_AdminCannotSetMinToZero() public {
        vm.expectRevert(LuminaBondMarketplace.MinPriceZeroNotAllowed.selector);
        vm.prank(admin);
        mp.setMinPricePerUnit(0);
    }

    function test_AdminCanSetMinExactlyAtCap() public {
        // Boundary: cap itself is allowed.
        uint256 cap = mp.MIN_PRICE_PER_UNIT_CAP();
        vm.prank(admin);
        mp.setMinPricePerUnit(cap);
        assertEq(mp.minPricePerUnit(), cap);
    }

    // ═══════ PROTECTION ═══════

    function test_SpamAttackBlocked() public {
        // Attacker tries to flood the marketplace with 10 listings at 1 wei.
        // Every single one reverts under the new floor.
        vm.startPrank(attacker);
        bond.setApprovalForAll(address(mp), true);
        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(LuminaBondMarketplace.PriceBelowMinimum.selector, 0, USDC_UNIT)
            );
            mp.list(EPOCH, 100, 1);
        }
        vm.stopPrank();

        // Sanity check: no listings created.
        assertEq(mp.nextListingId(), 0, "spam created listings");
    }

    function test_PriceUpdateAffectsOnlyNewListings() public {
        // Existing listing at 1 USDC/unit (default floor).
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 50, 50 * USDC_UNIT); // 1 USDC/unit
        vm.stopPrank();

        // Admin raises floor to 10 USDC/unit.
        vm.prank(admin);
        mp.setMinPricePerUnit(10 * USDC_UNIT);

        // Existing listing remains active and buyable. No invalidation.
        (,,,, bool active) = mp.getListing(id);
        assertTrue(active, "existing listing invalidated");

        // New listings at 1 USDC/unit now revert.
        vm.startPrank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(LuminaBondMarketplace.PriceBelowMinimum.selector, USDC_UNIT, 10 * USDC_UNIT)
        );
        mp.list(EPOCH, 50, 50 * USDC_UNIT);
        vm.stopPrank();

        // New listing at 10 USDC/unit works.
        vm.startPrank(seller);
        uint256 id2 = mp.list(EPOCH, 50, 500 * USDC_UNIT);
        vm.stopPrank();
        (,,,, bool active2) = mp.getListing(id2);
        assertTrue(active2);
    }

    function test_InitializeV2SetsDefault() public {
        // Deploy a fresh proxy that did NOT seed minPricePerUnit (simulate
        // V1 deploy that needs initializeV2). We use the impl directly via
        // raw ERC1967Proxy without seeding, but practical V1 deploys called
        // initialize() before this fix existed. We exercise the reinitializer
        // path here against a fresh proxy by first calling initialize() and
        // then re-running initializeV2 to confirm the slot gets re-seeded.
        LuminaBondMarketplace fresh =
            ProxyDeployer.deployLuminaBondMarketplace(address(bond), address(usdc), twapBurner, admin);
        // initialize() already seeded 1e6 — confirm.
        assertEq(fresh.minPricePerUnit(), USDC_UNIT);

        // Now exercise initializeV2 with a custom value (5 USDC). Reinitializer(2)
        // is one-shot — calling it from our fresh proxy works because version=1
        // after initialize, version=2 after initializeV2.
        vm.expectEmit(true, true, true, true);
        emit MinPricePerUnitUpdated(USDC_UNIT, 5 * USDC_UNIT);
        vm.prank(admin);
        fresh.initializeV2(5 * USDC_UNIT);
        assertEq(fresh.minPricePerUnit(), 5 * USDC_UNIT);
    }

    function test_InitializeV2WithZeroUsesDefault() public {
        LuminaBondMarketplace fresh =
            ProxyDeployer.deployLuminaBondMarketplace(address(bond), address(usdc), twapBurner, admin);
        vm.prank(admin);
        fresh.initializeV2(0); // 0 → use DEFAULT_MIN_PRICE_PER_UNIT
        assertEq(fresh.minPricePerUnit(), USDC_UNIT);
    }

    function test_InitializeV2OnlyAdmin() public {
        LuminaBondMarketplace fresh =
            ProxyDeployer.deployLuminaBondMarketplace(address(bond), address(usdc), twapBurner, admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0))
        );
        vm.prank(attacker);
        fresh.initializeV2(2 * USDC_UNIT);
    }

    function test_InitializeV2RejectsAboveCap() public {
        LuminaBondMarketplace fresh =
            ProxyDeployer.deployLuminaBondMarketplace(address(bond), address(usdc), twapBurner, admin);
        uint256 over = fresh.MIN_PRICE_PER_UNIT_CAP() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                LuminaBondMarketplace.MinPriceCapExceeded.selector, over, fresh.MIN_PRICE_PER_UNIT_CAP()
            )
        );
        vm.prank(admin);
        fresh.initializeV2(over);
    }

    function test_InitializeV2OnlyOnce() public {
        LuminaBondMarketplace fresh =
            ProxyDeployer.deployLuminaBondMarketplace(address(bond), address(usdc), twapBurner, admin);
        vm.prank(admin);
        fresh.initializeV2(2 * USDC_UNIT);

        // Second call must revert (reinitializer(2) is one-shot at version 2).
        vm.expectRevert(); // OZ throws InvalidInitialization()
        vm.prank(admin);
        fresh.initializeV2(3 * USDC_UNIT);
    }

    // ═══════ REGRESSION (existing flows still work at >= 1 USDC/unit) ═══════

    function test_NormalListWorks() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 500, 750 * USDC_UNIT); // 1.5 USDC/unit, well above floor
        vm.stopPrank();

        (,, uint256 amt, uint256 price, bool active) = mp.getListing(id);
        assertEq(amt, 500);
        assertEq(price, 750 * USDC_UNIT);
        assertTrue(active);
    }

    function test_ExecuteBuyStillWorks() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 100, 200 * USDC_UNIT); // 2 USDC/unit
        vm.stopPrank();

        vm.startPrank(buyer);
        usdc.approve(address(mp), 1000 * USDC_UNIT);
        mp.executeBuy(id);
        vm.stopPrank();

        (,,,, bool active) = mp.getListing(id);
        assertFalse(active, "listing should be inactive after buy");
        assertEq(bond.balanceOf(buyer, EPOCH), 100, "buyer didn't receive bonds");
    }

    function test_CancelStillWorks() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 100, 200 * USDC_UNIT);
        mp.cancel(id);
        vm.stopPrank();

        (,,,, bool active) = mp.getListing(id);
        assertFalse(active, "cancel did not deactivate listing");
        assertEq(bond.balanceOf(seller, EPOCH), 10_000, "bonds not returned to seller");
    }
}
