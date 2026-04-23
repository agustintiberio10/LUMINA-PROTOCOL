// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract MarketMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal mock BondVault that only mints/burns ClaimBond (for wiring setBondVault).
contract MarketMockBondVault {
    ClaimBond public claimBond;

    constructor(address _claimBond) {
        claimBond = ClaimBond(_claimBond);
    }

    /// @notice Mint bonds directly (test helper, acts as BondVault).
    function mintBonds(address to, uint256 epochId, uint256 amount) external {
        claimBond.mint(to, epochId, amount);
    }
}

// ═══════ TEST CONTRACT ═══════

contract MarketplaceStress is Test {
    uint256 constant BASE_TS = 1767225600;
    uint256 constant EPOCH_ID = 202804; // April 2028

    ClaimBond claimBond;
    MarketMockUSDC usdc;
    MarketMockBondVault mockVault;
    LuminaBondMarketplace marketplace;

    address admin = address(0xAD);
    address twapBurner = address(0xBBBB);

    function setUp() public {
        vm.warp(BASE_TS + 60 days);

        claimBond = ProxyDeployer.deployClaimBond();
        usdc = new MarketMockUSDC();

        // Deploy mock BondVault and wire ClaimBond
        mockVault = new MarketMockBondVault(address(claimBond));
        claimBond.setBondVault(address(mockVault));

        // Deploy marketplace
        marketplace = ProxyDeployer.deployLuminaBondMarketplace(address(claimBond), address(usdc), twapBurner, admin);
        // [FIX-#18] Whitelist marketplace so ClaimBond allows its transfers.
        claimBond.setAuthorizedOperator(address(marketplace), true);
    }

    /// @notice Create 100 marketplace listings. Verify nextListingId = 100.
    function test_Stress_100ActiveListings() public {
        uint256 listingCount = 100;

        for (uint256 i = 0; i < listingCount; i++) {
            address seller = address(uint160(0x100000 + i));

            // Mint bonds to seller
            mockVault.mintBonds(seller, EPOCH_ID, 10);

            // Seller approves marketplace, then lists
            vm.startPrank(seller);
            claimBond.setApprovalForAll(address(marketplace), true);
            marketplace.list(EPOCH_ID, 10, 8e6); // 10 bonds at $8 USDC
            vm.stopPrank();
        }

        assertEq(marketplace.nextListingId(), listingCount, "nextListingId should be 100");
    }

    /// @notice Create 20 listings, buy all 20. Verify fees flow correctly.
    function test_Stress_BuyAllListings() public {
        uint256 listingCount = 20;
        uint256 priceUSDC = 10e6; // $10 per listing
        uint256 bondAmount = 5; // 5 bond tokens per listing

        address buyer = address(0xBEEF);

        // Calculate expected fees per trade
        uint256 sellerFeePer = (priceUSDC * 150) / 10000; // 1.5%
        uint256 buyerFeePer = (priceUSDC * 150) / 10000; // 1.5%
        uint256 totalBuyerPaysPer = priceUSDC + buyerFeePer;

        // Fund buyer with enough USDC for all purchases
        usdc.mint(buyer, totalBuyerPaysPer * listingCount);

        // Create listings from different sellers
        for (uint256 i = 0; i < listingCount; i++) {
            address seller = address(uint160(0x200000 + i));

            // Mint bonds and list
            mockVault.mintBonds(seller, EPOCH_ID, bondAmount);
            vm.startPrank(seller);
            claimBond.setApprovalForAll(address(marketplace), true);
            marketplace.list(EPOCH_ID, bondAmount, priceUSDC);
            vm.stopPrank();
        }

        // Buyer approves marketplace for USDC
        vm.startPrank(buyer);
        usdc.approve(address(marketplace), type(uint256).max);

        uint256 burnerBalBefore = usdc.balanceOf(twapBurner);

        // Buy all listings
        for (uint256 i = 0; i < listingCount; i++) {
            marketplace.executeBuy(i);
        }
        vm.stopPrank();

        // Verify buyer got all bonds
        uint256 totalBonds = bondAmount * listingCount;
        assertEq(claimBond.balanceOf(buyer, EPOCH_ID), totalBonds, "Buyer should hold all bonds");

        // Verify fees flowed to twapBurner
        uint256 totalFees = (sellerFeePer + buyerFeePer) * listingCount;
        uint256 burnerBalAfter = usdc.balanceOf(twapBurner);
        assertEq(burnerBalAfter - burnerBalBefore, totalFees, "TwapBurner should receive all fees");

        // Verify buyer's USDC balance is 0 (spent everything)
        assertEq(usdc.balanceOf(buyer), 0, "Buyer should have spent all USDC");
    }
}
