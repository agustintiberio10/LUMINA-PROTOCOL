// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @notice Minimal ERC-4626 view interface for convertToAssets
interface IERC4626View {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/**
 * @title VaultShareNFT
 * @author Lumina Protocol
 * @notice ERC-721 representing vault share positions — AUTO-MINT pattern.
 *
 * @dev Vaults mint an NFT automatically when a deposit is made.
 *      Each NFT tracks the vault address, share amount, and deposit timestamp.
 *      getValue() queries the vault's convertToAssets() for real-time valuation.
 */
contract VaultShareNFT is ERC721, Ownable {
    using Strings for uint256;
    using Strings for address;

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    struct Position {
        address vault;
        uint256 shares;
        uint256 depositedAt;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    /// @notice Token ID => position data
    mapping(uint256 => Position) public positions;

    /// @notice Next token ID to mint
    uint256 public nextTokenId;

    /// @notice Addresses authorized to mint/burn (vault contracts)
    mapping(address => bool) public minters;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error NotMinter(address caller);
    error NotHolderOrMinter(address caller, uint256 tokenId);
    error TokenDoesNotExist(uint256 tokenId);

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event MinterUpdated(address indexed minter, bool authorized);
    event PositionMinted(uint256 indexed tokenId, address indexed to, address indexed vault, uint256 shares);
    event PositionBurned(uint256 indexed tokenId);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert NotMinter(msg.sender);
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor() ERC721("Lumina Vault Share", "LVSNFT") Ownable(msg.sender) {}

    // ═══════════════════════════════════════════════════════════
    //  ADMIN
    // ═══════════════════════════════════════════════════════════

    /// @notice Authorize or revoke a minter address (e.g. a vault contract)
    function setMinter(address minter, bool authorized) external onlyOwner {
        minters[minter] = authorized;
        emit MinterUpdated(minter, authorized);
    }

    // ═══════════════════════════════════════════════════════════
    //  MINT / BURN
    // ═══════════════════════════════════════════════════════════

    /// @notice Mint a vault share NFT. Only callable by minters (vault contracts).
    /// @param to The depositor receiving the NFT
    /// @param vault The vault address where shares are held
    /// @param shares The number of vault shares represented
    /// @return tokenId The minted token ID
    function mint(address to, address vault, uint256 shares) external onlyMinter returns (uint256 tokenId) {
        tokenId = nextTokenId++;

        positions[tokenId] = Position({vault: vault, shares: shares, depositedAt: block.timestamp});

        _mint(to, tokenId);

        emit PositionMinted(tokenId, to, vault, shares);
    }

    /// @notice Burn a vault share NFT. Only the holder or a minter can burn.
    /// @param tokenId The token to burn
    function burn(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender && !minters[msg.sender]) {
            revert NotHolderOrMinter(msg.sender, tokenId);
        }

        delete positions[tokenId];
        _burn(tokenId);

        emit PositionBurned(tokenId);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Get the current asset value of the position via vault's convertToAssets
    /// @param tokenId The token to query
    /// @return The current value in underlying assets
    function getValue(uint256 tokenId) external view returns (uint256) {
        Position memory pos = positions[tokenId];
        if (pos.vault == address(0)) revert TokenDoesNotExist(tokenId);
        return IERC4626View(pos.vault).convertToAssets(pos.shares);
    }

    /// @notice Get full position data for a token
    /// @param tokenId The token to query
    /// @return The Position struct
    function getPosition(uint256 tokenId) external view returns (Position memory) {
        Position memory pos = positions[tokenId];
        if (pos.vault == address(0)) revert TokenDoesNotExist(tokenId);
        return pos;
    }

    // ═══════════════════════════════════════════════════════════
    //  METADATA
    // ═══════════════════════════════════════════════════════════

    /// @notice On-chain JSON metadata with vault position attributes
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        ownerOf(tokenId); // reverts if token does not exist

        Position memory pos = positions[tokenId];

        // Get current value (may revert if vault is broken, but that's acceptable for metadata)
        uint256 value = IERC4626View(pos.vault).convertToAssets(pos.shares);

        string memory json = string(
            abi.encodePacked(
                '{"name":"Lumina Vault Share #',
                tokenId.toString(),
                '","description":"Lumina Protocol vault share position NFT.",' '"attributes":['
                '{"trait_type":"Vault","value":"',
                Strings.toHexString(pos.vault),
                '"},{"trait_type":"Shares","value":"',
                pos.shares.toString(),
                '"},{"trait_type":"Value","value":"',
                value.toString(),
                '"}]}'
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }
}
