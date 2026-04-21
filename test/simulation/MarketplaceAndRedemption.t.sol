// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ MOCKS ═══════

contract MockUSDC6 {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPriceOracle {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

// ═══════ SIMULATION TEST ═══════

contract MarketplaceAndRedemptionTest is Test {
    // Contracts
    LuminaTokenV2 lumina;
    ClaimBond claimBond;
    BondVault bondVault;
    MockPriceOracle oracle;
    MockUSDC6 usdc;
    LuminaBondMarketplace marketplace;

    // Actors
    address admin = makeAddr("admin");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address buyer2 = makeAddr("buyer2");
    address twapBurner = makeAddr("twapBurner");
    address policyManager = makeAddr("policyManager");

    // Placeholder addresses for LuminaTokenV2 constructor
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");

    // Constants
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC
    uint256 constant INITIAL_PRICE = 0.1e18; // $0.10 per LUMINA

    // Epoch used for tests (will be set by BondVault.issueBond based on timestamp)
    uint256 epochId;

    function setUp() public {
        // Warp to base + 60 days
        vm.warp(BASE_TS + 60 days);

        // Deploy oracle at $0.10
        oracle = new MockPriceOracle(INITIAL_PRICE);

        // Deploy ClaimBond (owner = address(this))
        claimBond = ProxyDeployer.deployClaimBond();

        // Deploy LuminaTokenV2 — BondVault address not yet known, use a temp then transfer
        // We need to predict the BondVault address or deploy token with bondVault as one of recipients
        // Strategy: deploy BondVault first address prediction via CREATE
        // Simpler: deploy token with admin as bondVault placeholder, then transfer to real vault
        // Actually, let's compute BondVault address from deployer nonce

        // Get current nonce for this test contract
        uint64 nonce = vm.getNonce(address(this));
        // LuminaTokenV2 via proxy at nonce+0,+1; BondVault via proxy at nonce+2 (impl), +3 (proxy)
        address predictedBondVault = vm.computeCreateAddress(address(this), nonce + 3);

        // Deploy token with predicted BondVault address
        lumina = ProxyDeployer.deployLuminaTokenV2(
            predictedBondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting
        );

        // Deploy BondVault (should match predicted address)
        bondVault = ProxyDeployer.deployBondVault(address(lumina), address(claimBond), address(oracle), policyManager);
        require(address(bondVault) == predictedBondVault, "BondVault address mismatch");

        // Wire ClaimBond -> BondVault (owner is address(this))
        claimBond.setBondVault(address(bondVault));

        // Deploy USDC mock
        usdc = new MockUSDC6();

        // Deploy Marketplace
        marketplace = new LuminaBondMarketplace(address(claimBond), address(usdc), twapBurner, admin);

        // Issue bonds to seller (1000 bonds) and buyer2 (500 bonds) via policyManager
        // issueBond issues bonds with 730-day maturity from current time
        vm.startPrank(policyManager);
        bondVault.issueBond(seller, 1000); // $1000 = 1000 bond tokens
        bondVault.issueBond(buyer2, 500); // $500 = 500 bond tokens
        vm.stopPrank();

        // Calculate the epoch that was assigned (current time + 730 days)
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        epochId = year * 100 + month;

        // Fund buyers with USDC
        usdc.mint(buyer, 1_000_000e6);
        usdc.mint(buyer2, 1_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // MARKETPLACE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Marketplace_PartialListing() public {
        // Seller has 1000 bonds, lists 300 at $0.40 each
        uint256 priceUSDC = 300 * 0.4e6; // total price for 300 bonds = $120 USDC

        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 300, priceUSDC);
        vm.stopPrank();

        // Verify seller has 700 remaining (300 transferred to marketplace)
        assertEq(claimBond.balanceOf(seller, epochId), 700);

        // Buyer buys
        uint256 sellerFee = (priceUSDC * 150) / 10000; // 1.5%
        uint256 buyerFee = (priceUSDC * 150) / 10000; // 1.5%
        uint256 totalBuyerPays = priceUSDC + buyerFee;
        uint256 sellerReceives = priceUSDC - sellerFee;

        uint256 sellerUsdcBefore = usdc.balanceOf(seller);
        uint256 twapBefore = usdc.balanceOf(twapBurner);

        vm.startPrank(buyer);
        usdc.approve(address(marketplace), totalBuyerPays);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        // Buyer has 300 bonds
        assertEq(claimBond.balanceOf(buyer, epochId), 300);
        // Seller still has 700
        assertEq(claimBond.balanceOf(seller, epochId), 700);
        // Seller received price - 1.5%
        assertEq(usdc.balanceOf(seller) - sellerUsdcBefore, sellerReceives);
        // twapBurner receives total 3% (sellerFee + buyerFee)
        assertEq(usdc.balanceOf(twapBurner) - twapBefore, sellerFee + buyerFee);
        // Buyer paid price + 1.5%
        assertEq(1_000_000e6 - usdc.balanceOf(buyer), totalBuyerPays);
    }

    function test_Marketplace_FullListing() public {
        // buyer2 has 500 bonds, lists ALL at $0.50 each = $250 total
        uint256 priceUSDC = 500 * 0.5e6; // $250

        vm.startPrank(buyer2);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 500, priceUSDC);
        vm.stopPrank();

        // buyer2 should have 0 bonds now (transferred to marketplace)
        assertEq(claimBond.balanceOf(buyer2, epochId), 0);

        // buyer buys all
        uint256 totalBuyerPays = priceUSDC + (priceUSDC * 150) / 10000;
        vm.startPrank(buyer);
        usdc.approve(address(marketplace), totalBuyerPays);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        // Buyer has all 500 bonds
        assertEq(claimBond.balanceOf(buyer, epochId), 500);
        // Listing is no longer active
        (,,,, bool active) = marketplace.getListing(listingId);
        assertFalse(active);
    }

    function test_Marketplace_CancelListing() public {
        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 200, 100e6);
        vm.stopPrank();

        // Seller has 800 after listing
        assertEq(claimBond.balanceOf(seller, epochId), 800);

        // Cancel
        vm.prank(seller);
        marketplace.cancel(listingId);

        // Bonds returned
        assertEq(claimBond.balanceOf(seller, epochId), 1000);
        // Listing inactive
        (,,,, bool active) = marketplace.getListing(listingId);
        assertFalse(active);
    }

    function test_Marketplace_MultipleListings() public {
        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 id0 = marketplace.list(epochId, 100, 50e6);
        uint256 id1 = marketplace.list(epochId, 200, 80e6);
        uint256 id2 = marketplace.list(epochId, 300, 120e6);
        vm.stopPrank();

        // Seller has 1000 - 100 - 200 - 300 = 400
        assertEq(claimBond.balanceOf(seller, epochId), 400);

        // Buyer buys the middle listing (id1)
        uint256 totalPay = 80e6 + (80e6 * 150) / 10000;
        vm.startPrank(buyer);
        usdc.approve(address(marketplace), totalPay);
        marketplace.executeBuy(id1);
        vm.stopPrank();

        // Buyer has 200 bonds from id1
        assertEq(claimBond.balanceOf(buyer, epochId), 200);

        // Other listings remain active
        (,,,, bool active0) = marketplace.getListing(id0);
        assertTrue(active0);
        (,,,, bool active2) = marketplace.getListing(id2);
        assertTrue(active2);
        // id1 is inactive
        (,,,, bool active1) = marketplace.getListing(id1);
        assertFalse(active1);
    }

    function test_Marketplace_SecondaryBuyerRedeemsAtMaturity() public {
        // Seller lists 200 bonds
        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 200, 80e6);
        vm.stopPrank();

        // buyer2 buys them
        uint256 totalPay = 80e6 + (80e6 * 150) / 10000;
        vm.startPrank(buyer2);
        usdc.approve(address(marketplace), totalPay);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        assertEq(claimBond.balanceOf(buyer2, epochId), 700); // 500 original + 200 bought

        // Warp to maturity
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        // Set oracle price for redemption
        oracle.setPrice(0.1e18); // $0.10

        // buyer2 redeems 200 bonds
        uint256 expectedLumina = (200 * 1e36) / 0.1e18; // 200 / 0.10 = 2000 LUMINA = 2000e18
        uint256 balBefore = lumina.balanceOf(buyer2);

        vm.prank(buyer2);
        bondVault.redeemBond(epochId, 200);

        uint256 balAfter = lumina.balanceOf(buyer2);
        assertEq(balAfter - balBefore, expectedLumina);
        // Remaining bonds
        assertEq(claimBond.balanceOf(buyer2, epochId), 500);
    }

    function test_Marketplace_CannotListMaturedBond() public {
        // Warp past maturity
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.expectRevert("Bond matured");
        marketplace.list(epochId, 100, 50e6);
        vm.stopPrank();
    }

    function test_Marketplace_CannotBuyCancelledListing() public {
        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 100, 50e6);
        marketplace.cancel(listingId);
        vm.stopPrank();

        uint256 totalPay = 50e6 + (50e6 * 150) / 10000;
        vm.startPrank(buyer);
        usdc.approve(address(marketplace), totalPay);
        vm.expectRevert("Not active");
        marketplace.executeBuy(listingId);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    // REDEMPTION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Redemption_SamePrice() public {
        // Issue at $0.10, redeem at $0.10
        // Warp to maturity
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        oracle.setPrice(0.1e18); // same as issuance

        // Seller redeems 100 bonds ($100 USD value)
        // luminaAmount = (100 * 1e36) / 0.10e18 = 1000e18 LUMINA
        uint256 expectedLumina = (100 * 1e36) / 0.1e18;
        assertEq(expectedLumina, 1000e18);

        uint256 balBefore = lumina.balanceOf(seller);
        vm.prank(seller);
        bondVault.redeemBond(epochId, 100);
        uint256 balAfter = lumina.balanceOf(seller);

        assertEq(balAfter - balBefore, expectedLumina);
    }

    function test_Redemption_PriceUp10x() public {
        // Issue at $0.10, redeem at $1.00
        // Should get LESS LUMINA but same USD value
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        oracle.setPrice(1.0e18); // $1.00 — 10x up

        // Seller redeems 100 bonds ($100 USD)
        // luminaAmount = (100 * 1e36) / 1.0e18 = 100e18 LUMINA
        uint256 expectedLumina = (100 * 1e36) / 1.0e18;
        assertEq(expectedLumina, 100e18); // only 100 LUMINA vs 1000 at $0.10

        uint256 balBefore = lumina.balanceOf(seller);
        vm.prank(seller);
        bondVault.redeemBond(epochId, 100);
        uint256 balAfter = lumina.balanceOf(seller);

        assertEq(balAfter - balBefore, expectedLumina);
        // Verify: less LUMINA than at original price
        uint256 luminaAtOriginalPrice = (100 * 1e36) / 0.1e18;
        assertTrue(expectedLumina < luminaAtOriginalPrice);
        // But same USD value: 100 LUMINA * $1.00 = $100
        assertEq((expectedLumina * 1.0e18) / 1e18, 100e18);
    }

    function test_Redemption_PriceDown10x() public {
        // Issue at $0.10, redeem at $0.01
        // Should get MORE LUMINA to honor face value
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        oracle.setPrice(0.01e18); // $0.01 — 10x down

        // Seller redeems 100 bonds ($100 USD)
        // luminaAmount = (100 * 1e36) / 0.01e18 = 10000e18 LUMINA
        uint256 expectedLumina = (100 * 1e36) / 0.01e18;
        assertEq(expectedLumina, 10_000e18); // 10000 LUMINA vs 1000 at $0.10

        uint256 balBefore = lumina.balanceOf(seller);
        vm.prank(seller);
        bondVault.redeemBond(epochId, 100);
        uint256 balAfter = lumina.balanceOf(seller);

        assertEq(balAfter - balBefore, expectedLumina);
        // Verify: more LUMINA than at original price
        uint256 luminaAtOriginalPrice = (100 * 1e36) / 0.1e18;
        assertTrue(expectedLumina > luminaAtOriginalPrice);
    }

    function test_Redemption_Partial() public {
        // 1000 bonds, redeem 400, verify 600 remaining, then redeem 600
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        oracle.setPrice(0.1e18);

        // Redeem 400
        vm.prank(seller);
        bondVault.redeemBond(epochId, 400);
        assertEq(claimBond.balanceOf(seller, epochId), 600);

        // Redeem remaining 600
        vm.prank(seller);
        bondVault.redeemBond(epochId, 600);
        assertEq(claimBond.balanceOf(seller, epochId), 0);

        // Total LUMINA received: (1000 * 1e36) / 0.10e18 = 10000e18
        assertEq(lumina.balanceOf(seller), 10_000e18);
    }

    function test_Redemption_BeforeMaturity_Reverts() public {
        // Current time is before maturity — should revert
        vm.prank(seller);
        vm.expectRevert("Not matured");
        bondVault.redeemBond(epochId, 100);
    }
}
