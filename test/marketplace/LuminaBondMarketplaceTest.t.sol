// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {MockClaimBondV5} from "../mocks/MockClaimBondV5.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockUSDCMP {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
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

contract LuminaBondMarketplaceTest is Test {
    using ProxyDeployer for *;

    // Mirror events for vm.expectEmit
    event TwapBurnerUpdated(address indexed newTwapBurner);
    event MinPricePerUnitUpdated(uint256 oldValue, uint256 newValue);
    LuminaBondMarketplace mp;
    MockClaimBondV5 bond;
    MockUSDCMP usdc;
    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address twapBurner = makeAddr("twapBurner");

    uint256 constant EPOCH = 202804;

    function setUp() public {
        vm.chainId(8453);
        bond = new MockClaimBondV5();
        usdc = new MockUSDCMP();
        mp = ProxyDeployer.deployLuminaBondMarketplace(address(bond), address(usdc), twapBurner, admin);

        // Setup: mint bonds to seller, set maturity in future
        bond.mint(seller, EPOCH, 1000);
        bond.setMaturityDate(EPOCH, block.timestamp + 730 days);

        // Fund buyer with USDC
        usdc.mint(buyer, 100_000e6);
    }

    function test_Constructor_CorrectInit() public view {
        assertEq(address(mp.claimBond()), address(bond));
        assertEq(address(mp.usdc()), address(usdc));
        assertEq(mp.twapBurner(), twapBurner);
    }

    function test_List_Success() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 500, 400e6);
        vm.stopPrank();

        (address s, uint256 e, uint256 a, uint256 p, bool active) = mp.getListing(id);
        assertEq(s, seller);
        assertEq(e, EPOCH);
        assertEq(a, 500);
        assertEq(p, 400e6);
        assertTrue(active);
    }

    function test_RevertIf_ListInsufficientBalance() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        vm.expectRevert("Insufficient balance");
        mp.list(EPOCH, 2000, 400e6); // Only has 1000
        vm.stopPrank();
    }

    function test_RevertIf_ListMaturedBond() public {
        vm.warp(block.timestamp + 731 days);
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        vm.expectRevert("Bond matured");
        mp.list(EPOCH, 500, 400e6);
        vm.stopPrank();
    }

    function test_Cancel_Success() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 500, 400e6);
        mp.cancel(id);
        vm.stopPrank();
        (,,,, bool active) = mp.getListing(id);
        assertFalse(active);
        assertEq(bond.balanceOf(seller, EPOCH), 1000); // All returned
    }

    function test_RevertIf_CancelByNonSeller() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 500, 400e6);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert("Not seller");
        mp.cancel(id);
    }

    function test_ExecuteBuy_Success_FeesDistributed() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 500, 400e6);
        vm.stopPrank();

        // Buyer approves and buys
        uint256 buyerFee = (400e6 * 150) / 10000; // 1.5% = 6e6
        uint256 totalPays = 400e6 + buyerFee; // 406e6
        vm.startPrank(buyer);
        usdc.approve(address(mp), totalPays);
        mp.executeBuy(id);
        vm.stopPrank();

        // Verify bond transferred to buyer
        assertEq(bond.balanceOf(buyer, EPOCH), 500);
        // Verify fees to TWAPBurner
        uint256 sellerFee = (400e6 * 150) / 10000;
        assertEq(usdc.balanceOf(twapBurner), sellerFee + buyerFee); // 12e6 total (3%)
    }

    function test_CalculateFees_Correct() public view {
        (uint256 sf, uint256 bf, uint256 total) = mp.calculateFees(1000e6);
        assertEq(sf, 15e6); // 1.5%
        assertEq(bf, 15e6); // 1.5%
        assertEq(total, 30e6); // 3%
    }

    function test_SetTwapBurner_OnlyAdmin() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        mp.setTwapBurner(makeAddr("new"));
    }

    function test_RevertIf_ConstructorZeroAddresses() public {
        LuminaBondMarketplace impl = new LuminaBondMarketplace();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaBondMarketplace.initialize.selector, address(0), address(usdc), twapBurner, admin
            )
        );
    }

    function test_RevertIf_CancelInactiveListing() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 500, 400e6);
        mp.cancel(id);
        vm.expectRevert("Not active");
        mp.cancel(id);
        vm.stopPrank();
    }

    function test_RevertIf_ExecuteBuyInactiveListing() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 500, 400e6);
        mp.cancel(id);
        vm.stopPrank();

        vm.startPrank(buyer);
        usdc.approve(address(mp), 500e6);
        vm.expectRevert("Not active");
        mp.executeBuy(id);
        vm.stopPrank();
    }

    function test_RevertIf_ListZeroPrice() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        vm.expectRevert("Price zero");
        mp.list(EPOCH, 500, 0);
        vm.stopPrank();
    }

    function test_CalculateFees_LargeNumbers() public view {
        uint256 price = 1_000_000_000e6; // 1B USDC
        (uint256 sf, uint256 bf, uint256 total) = mp.calculateFees(price);
        assertEq(sf, (price * 150) / 10000);
        assertEq(bf, (price * 150) / 10000);
        assertEq(total, sf + bf);
    }

    function test_FullLifecycle_MultipleListings() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id1 = mp.list(EPOCH, 300, 200e6);
        uint256 id2 = mp.list(EPOCH, 400, 300e6);
        vm.stopPrank();

        // Buy listing 1
        uint256 buyerFee1 = (200e6 * 150) / 10000;
        vm.startPrank(buyer);
        usdc.approve(address(mp), 200e6 + buyerFee1);
        mp.executeBuy(id1);
        vm.stopPrank();

        // Cancel listing 2
        vm.prank(seller);
        mp.cancel(id2);

        // Verify states
        (,,,, bool active1) = mp.getListing(id1);
        (,,,, bool active2) = mp.getListing(id2);
        assertFalse(active1);
        assertFalse(active2);
        assertEq(bond.balanceOf(buyer, EPOCH), 300);
        // Seller gets back 400 from cancelled + keeps remaining 300
        assertEq(bond.balanceOf(seller, EPOCH), 700);
    }

    function test_GetListing_ReturnsCorrectData() public {
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(EPOCH, 250, 175e6);
        vm.stopPrank();

        (address s, uint256 e, uint256 a, uint256 p, bool active) = mp.getListing(id);
        assertEq(s, seller);
        assertEq(e, EPOCH);
        assertEq(a, 250);
        assertEq(p, 175e6);
        assertTrue(active);
    }

    function test_SetTwapBurner_EmitsEvent() public {
        address newBurner = makeAddr("newBurner");
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit TwapBurnerUpdated(newBurner);
        mp.setTwapBurner(newBurner);
        assertEq(mp.twapBurner(), newBurner);
    }

    function test_RevertIf_SetTwapBurnerZero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Zero"));
        mp.setTwapBurner(address(0));
    }

    // ═══════ M-3 anti-spam minimum price floor ═══════

    function test_minPricePerUnit_initialValue_is_1e6() public view {
        assertEq(mp.minPricePerUnit(), 1_000_000, "initial floor must be $1 USDC (1e6)");
    }

    function test_setMinPricePerUnit_onlyOwner_reverts_for_non_owner() public {
        vm.prank(makeAddr("randomUser"));
        vm.expectRevert(); // AccessControl reverts when caller lacks FEE_MANAGER_ROLE
        mp.setMinPricePerUnit(2_000_000);
    }

    function test_setMinPricePerUnit_emits_event_with_old_and_new() public {
        uint256 oldFloor = mp.minPricePerUnit();
        uint256 newFloor = 5_000_000;

        vm.expectEmit(false, false, false, true);
        emit MinPricePerUnitUpdated(oldFloor, newFloor);

        vm.prank(admin);
        mp.setMinPricePerUnit(newFloor);

        assertEq(mp.minPricePerUnit(), newFloor, "floor must be updated");
    }

    function test_list_reverts_below_minimum_floor() public {
        // Default floor is 1e6 ($1 USDC). Listing total at 1e6 - 1 must revert.
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        vm.expectRevert(bytes("below minimum"));
        mp.list(EPOCH, 500, 1_000_000 - 1);
        vm.stopPrank();
    }

    function test_list_succeeds_at_or_above_minimum_floor() public {
        // Exact boundary: priceUSDC == minPricePerUnit must succeed.
        vm.startPrank(seller);
        bond.setApprovalForAll(address(mp), true);
        uint256 idAt = mp.list(EPOCH, 100, 1_000_000); // exactly at floor
        uint256 idAbove = mp.list(EPOCH, 100, 50_000_000); // well above floor
        vm.stopPrank();

        (,,, uint256 pAt, bool activeAt) = mp.getListing(idAt);
        (,,, uint256 pAbove, bool activeAbove) = mp.getListing(idAbove);

        assertTrue(activeAt);
        assertEq(pAt, 1_000_000);
        assertTrue(activeAbove);
        assertEq(pAbove, 50_000_000);
    }
}
