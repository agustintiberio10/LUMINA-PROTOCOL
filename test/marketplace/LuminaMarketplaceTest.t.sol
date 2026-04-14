// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LuminaMarketplace} from "../../src/marketplace/LuminaMarketplace.sol";
import {LuminaToken} from "../../src/token/LuminaToken.sol";
import {VaultShareNFT} from "../../src/marketplace/VaultShareNFT.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// ═══════════════════════════════════════════════════════════
//  MOCKS
// ═══════════════════════════════════════════════════════════

/// @dev Simple mock vault so VaultShareNFT.wrap() can check balanceOf
contract MarketMockVault is ERC20 {
    constructor() ERC20("Mock Vault", "mVLT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares * 1e6 / 1e18;
    }
}

/// @dev A simple non-whitelisted ERC721 for testing rejection
contract RandomNFT is ERC721 {
    uint256 public nextId;

    constructor() ERC721("Random", "RND") {}

    function mint(address to) external returns (uint256 id) {
        id = nextId++;
        _mint(to, id);
    }
}

// ═══════════════════════════════════════════════════════════
//  TEST
// ═══════════════════════════════════════════════════════════

contract LuminaMarketplaceTest is Test {
    LuminaMarketplace public marketplace;
    LuminaToken public lumina;
    VaultShareNFT public vaultNFT;
    MarketMockVault public vault;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public exitReserve = makeAddr("exitReserve");
    address public exchangeReserve = makeAddr("exchangeReserve");
    address public vestingReserve = makeAddr("vestingReserve");

    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");

    uint256 public constant PRICE = 1000e18; // 1000 LUMINA

    function setUp() public {
        // Deploy LuminaToken (real)
        vm.prank(admin);
        lumina = new LuminaToken(treasury, exitReserve, exchangeReserve, vestingReserve);

        // Deploy marketplace
        vm.prank(admin);
        marketplace = new LuminaMarketplace(address(lumina));

        // Deploy VaultShareNFT and mock vault
        vaultNFT = new VaultShareNFT();
        vault = new MarketMockVault();

        // Whitelist the VaultShareNFT
        vm.prank(admin);
        marketplace.setAllowedNFT(address(vaultNFT), true);

        // Give seller vault shares and wrap into NFT
        vault.mint(seller, 500e18);

        // Give buyer LUMINA tokens (from treasury)
        vm.prank(treasury);
        lumina.transfer(buyer, 10_000e18);
    }

    function _mintAndListNFT() internal returns (uint256 listingId, uint256 tokenId) {
        vm.prank(seller);
        tokenId = vaultNFT.wrap(address(vault), 100e18);

        vm.prank(seller);
        vaultNFT.approve(address(marketplace), tokenId);

        vm.prank(seller);
        marketplace.list(address(vaultNFT), tokenId, PRICE);

        listingId = 0; // first listing
    }

    function test_list() public {
        (uint256 listingId, uint256 tokenId) = _mintAndListNFT();

        LuminaMarketplace.Listing memory l = marketplace.getListing(listingId);
        assertEq(l.seller, seller);
        assertEq(l.nftContract, address(vaultNFT));
        assertEq(l.tokenId, tokenId);
        assertEq(l.priceInLumina, PRICE);
        assertTrue(l.active);
        // NFT should be in escrow
        assertEq(vaultNFT.ownerOf(tokenId), address(marketplace));
    }

    function test_list_not_allowed_nft_reverts() public {
        RandomNFT rnd = new RandomNFT();
        uint256 tokenId = rnd.mint(seller);

        vm.prank(seller);
        rnd.approve(address(marketplace), tokenId);

        vm.prank(seller);
        vm.expectRevert(LuminaMarketplace.NFTNotAllowed.selector);
        marketplace.list(address(rnd), tokenId, PRICE);
    }

    function test_buy() public {
        (uint256 listingId, uint256 tokenId) = _mintAndListNFT();

        uint256 sellerBalBefore = lumina.balanceOf(seller);

        vm.prank(buyer);
        lumina.approve(address(marketplace), PRICE);

        vm.prank(buyer);
        marketplace.buy(listingId);

        // Buyer gets NFT
        assertEq(vaultNFT.ownerOf(tokenId), buyer);

        // Seller gets 98% (fee = 2%)
        uint256 fee = (PRICE * 200) / 10_000; // 20 LUMINA
        uint256 sellerProceeds = PRICE - fee;
        assertEq(lumina.balanceOf(seller), sellerBalBefore + sellerProceeds);

        // Listing no longer active
        LuminaMarketplace.Listing memory l = marketplace.getListing(listingId);
        assertFalse(l.active);
    }

    function test_buy_fee_burned() public {
        // Grant BURNER_ROLE to marketplace so burnByRole works
        bytes32 burnerRole = lumina.BURNER_ROLE();
        vm.prank(admin);
        lumina.grantRole(burnerRole, address(marketplace));

        _mintAndListNFT();

        uint256 totalBefore = lumina.totalSupply();

        vm.prank(buyer);
        lumina.approve(address(marketplace), PRICE);

        vm.prank(buyer);
        marketplace.buy(0);

        uint256 fee = (PRICE * 200) / 10_000;
        // Fee should be burned (total supply decreased)
        assertEq(lumina.totalSupply(), totalBefore - fee);
    }

    function test_cancel() public {
        (uint256 listingId, uint256 tokenId) = _mintAndListNFT();

        vm.prank(seller);
        marketplace.cancelListing(listingId);

        // NFT returned to seller
        assertEq(vaultNFT.ownerOf(tokenId), seller);

        // Listing inactive
        LuminaMarketplace.Listing memory l = marketplace.getListing(listingId);
        assertFalse(l.active);
    }

    function test_update_price() public {
        (uint256 listingId,) = _mintAndListNFT();

        uint256 newPrice = 2000e18;
        vm.prank(seller);
        marketplace.updatePrice(listingId, newPrice);

        LuminaMarketplace.Listing memory l = marketplace.getListing(listingId);
        assertEq(l.priceInLumina, newPrice);
    }

    function test_buy_insufficient_lumina_reverts() public {
        _mintAndListNFT();

        address poorBuyer = makeAddr("poorBuyer");
        // poorBuyer has 0 LUMINA

        vm.prank(poorBuyer);
        lumina.approve(address(marketplace), PRICE);

        vm.prank(poorBuyer);
        vm.expectRevert(); // ERC20 insufficient balance
        marketplace.buy(0);
    }

    function test_set_fee() public {
        vm.prank(admin);
        marketplace.setFeeBps(300); // 3%
        assertEq(marketplace.feeBps(), 300);
    }

    function test_max_fee() public {
        vm.prank(admin);
        vm.expectRevert(LuminaMarketplace.FeeExceedsCap.selector);
        marketplace.setFeeBps(501); // > 5%
    }

    function test_pause() public {
        _mintAndListNFT();

        vm.prank(admin);
        marketplace.pause();

        vm.prank(buyer);
        lumina.approve(address(marketplace), PRICE);

        vm.prank(buyer);
        vm.expectRevert(); // EnforcedPause
        marketplace.buy(0);
    }

    function test_cancel_not_seller_reverts() public {
        (uint256 listingId,) = _mintAndListNFT();

        vm.prank(buyer);
        vm.expectRevert(LuminaMarketplace.NotSeller.selector);
        marketplace.cancelListing(listingId);
    }
}
