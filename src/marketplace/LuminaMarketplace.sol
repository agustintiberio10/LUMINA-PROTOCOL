// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILuminaToken is IERC20 {
    function burnByRole(address account, uint256 amount) external;
    function BURNER_ROLE() external view returns (bytes32);
}

/**
 * @title LuminaMarketplace
 * @notice P2P marketplace for trading whitelisted NFTs priced in LUMINA tokens.
 *         A configurable fee (default 2%) is burned on every sale.
 */
contract LuminaMarketplace is Ownable, ReentrancyGuard, Pausable {
    // ──────────────────────────── Types ────────────────────────────
    struct Listing {
        uint256 id;
        address nftContract;
        uint256 tokenId;
        address seller;
        uint256 priceInLumina;
        uint256 createdAt;
        bool active;
    }

    // ──────────────────────────── State ────────────────────────────
    uint256 public nextListingId;
    mapping(uint256 => Listing) public listings;

    uint256 public feeBps = 200; // 2 %
    uint256 public constant MAX_FEE_BPS = 500; // 5 % cap

    ILuminaToken public immutable luminaToken;

    mapping(address => bool) public approvedNFTs;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ──────────────────────────── Events ───────────────────────────
    event Listed(
        uint256 indexed listingId, address indexed seller, address nftContract, uint256 tokenId, uint256 priceInLumina
    );
    event Sold(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 priceInLumina,
        uint256 feeBurned
    );
    event Cancelled(uint256 indexed listingId);
    event PriceUpdated(uint256 indexed listingId, uint256 oldPrice, uint256 newPrice);
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    // ──────────────────────────── Errors ───────────────────────────
    error NotSeller();
    error ListingNotActive();
    error NFTNotAllowed();
    error PriceZero();
    error FeeExceedsCap();

    // ──────────────────────────── Constructor ──────────────────────
    constructor(address _luminaToken) Ownable(msg.sender) {
        require(_luminaToken != address(0), "Zero token address");
        luminaToken = ILuminaToken(_luminaToken);
    }

    // ──────────────────────────── Seller ───────────────────────────

    /**
     * @notice List an NFT for sale. The NFT is transferred into escrow.
     * @param nftContract Address of the whitelisted NFT contract.
     * @param tokenId     Token ID to list.
     * @param priceInLumina Sale price denominated in LUMINA (wei units).
     */
    function list(address nftContract, uint256 tokenId, uint256 priceInLumina) external whenNotPaused {
        if (!approvedNFTs[nftContract]) revert NFTNotAllowed();
        if (priceInLumina == 0) revert PriceZero();

        // Transfer NFT into escrow
        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

        uint256 listingId = nextListingId++;
        listings[listingId] = Listing({
            id: listingId,
            nftContract: nftContract,
            tokenId: tokenId,
            seller: msg.sender,
            priceInLumina: priceInLumina,
            createdAt: block.timestamp,
            active: true
        });

        emit Listed(listingId, msg.sender, nftContract, tokenId, priceInLumina);
    }

    /**
     * @notice Update the price of an existing listing.
     */
    function updatePrice(uint256 listingId, uint256 newPrice) external whenNotPaused {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingNotActive();
        if (l.seller != msg.sender) revert NotSeller();
        if (newPrice == 0) revert PriceZero();

        uint256 oldPrice = l.priceInLumina;
        l.priceInLumina = newPrice;

        emit PriceUpdated(listingId, oldPrice, newPrice);
    }

    /**
     * @notice Cancel a listing and return the NFT to the seller.
     */
    function cancelListing(uint256 listingId) external {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingNotActive();
        if (l.seller != msg.sender) revert NotSeller();

        l.active = false;

        IERC721(l.nftContract).transferFrom(address(this), l.seller, l.tokenId);

        emit Cancelled(listingId);
    }

    // ──────────────────────────── Buyer ────────────────────────────

    /**
     * @notice Buy a listed NFT. Caller must have approved LUMINA for the price.
     *         The fee portion is burned; the remainder goes to the seller.
     */
    function buy(uint256 listingId) external nonReentrant whenNotPaused {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingNotActive();

        l.active = false;

        uint256 price = l.priceInLumina;
        uint256 fee = (price * feeBps) / 10_000;
        uint256 sellerProceeds = price - fee;

        // Pay seller
        require(luminaToken.transferFrom(msg.sender, l.seller, sellerProceeds), "Transfer to seller failed");

        // Burn fee
        if (fee > 0) {
            _burnFee(msg.sender, fee);
        }

        // Transfer NFT to buyer
        IERC721(l.nftContract).transferFrom(address(this), msg.sender, l.tokenId);

        emit Sold(listingId, msg.sender, l.seller, price, fee);
    }

    /**
     * @dev Try burnByRole first (marketplace holds fee briefly); fall back to dead address.
     */
    function _burnFee(address buyer, uint256 amount) internal {
        // Transfer fee from buyer to this contract, then burn via burnByRole
        require(luminaToken.transferFrom(buyer, address(this), amount), "Fee transfer failed");

        try luminaToken.burnByRole(address(this), amount) {
        // Successfully burned
        }
        catch {
            // Fallback: send to dead address
            require(luminaToken.transfer(DEAD, amount), "Dead transfer failed");
        }
    }

    // ──────────────────────────── Admin ────────────────────────────

    function setFeeBps(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE_BPS) revert FeeExceedsCap();
        uint256 oldFee = feeBps;
        feeBps = newFee;
        emit FeeUpdated(oldFee, newFee);
    }

    function setApprovedNFT(address nft, bool allowed) external onlyOwner {
        approvedNFTs[nft] = allowed;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ──────────────────────────── Views ────────────────────────────

    function getListing(uint256 id) external view returns (Listing memory) {
        return listings[id];
    }

    /**
     * @notice Return all active listings. Use off-chain indexing for large datasets.
     */
    function getActiveListings() external view returns (Listing[] memory) {
        uint256 total = nextListingId;

        // First pass: count active
        uint256 count;
        for (uint256 i; i < total; ++i) {
            if (listings[i].active) ++count;
        }

        // Second pass: populate
        Listing[] memory result = new Listing[](count);
        uint256 idx;
        for (uint256 i; i < total; ++i) {
            if (listings[i].active) {
                result[idx++] = listings[i];
            }
        }
        return result;
    }
}
