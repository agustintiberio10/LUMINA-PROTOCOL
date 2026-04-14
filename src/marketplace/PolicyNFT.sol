// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title PolicyNFT
 * @author Lumina Protocol
 * @notice ERC-721 representing insurance policies — AUTO-MINT pattern.
 *
 * @dev CoverRouter mints an NFT automatically when a policy is purchased.
 *      tokenId == policyId (1:1 mapping). No PolicyManager dependency.
 *      Simple mint/burn/transfer with minter access control.
 */
contract PolicyNFT is ERC721, Ownable {
    using Strings for uint256;
    using Strings for address;

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    /// @notice Addresses authorized to mint/burn (CoverRouter)
    mapping(address => bool) public minters;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error NotMinter(address caller);
    error NotHolderOrMinter(address caller, uint256 tokenId);

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event MinterUpdated(address indexed minter, bool authorized);

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

    constructor() ERC721("Lumina Policy NFT", "LPNFT") Ownable(msg.sender) {}

    // ═══════════════════════════════════════════════════════════
    //  ADMIN
    // ═══════════════════════════════════════════════════════════

    /// @notice Authorize or revoke a minter address (e.g. CoverRouter)
    function setMinter(address minter, bool authorized) external onlyOwner {
        minters[minter] = authorized;
        emit MinterUpdated(minter, authorized);
    }

    // ═══════════════════════════════════════════════════════════
    //  MINT / BURN
    // ═══════════════════════════════════════════════════════════

    /// @notice Mint a policy NFT. tokenId = policyId. Only callable by minters.
    /// @param to The policy holder receiving the NFT
    /// @param policyId The policy ID (becomes the tokenId)
    function mint(address to, uint256 policyId) external onlyMinter {
        _mint(to, policyId);
    }

    /// @notice Burn a policy NFT. Only the holder or a minter can burn.
    /// @param tokenId The token to burn
    function burn(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender && !minters[msg.sender]) {
            revert NotHolderOrMinter(msg.sender, tokenId);
        }
        _burn(tokenId);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Check if a policy NFT is valid (exists). Policy expiry checked off-chain.
    /// @param tokenId The token to check
    /// @return True if the token exists
    function isValid(uint256 tokenId) external view returns (bool) {
        try this.ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  METADATA
    // ═══════════════════════════════════════════════════════════

    /// @notice On-chain JSON metadata with policy attributes
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address holder = ownerOf(tokenId);

        string memory json = string(
            abi.encodePacked(
                '{"name":"Lumina Policy #',
                tokenId.toString(),
                '","description":"Lumina Protocol insurance policy NFT.",' '"attributes":['
                '{"trait_type":"Policy ID","value":"',
                tokenId.toString(),
                '"},{"trait_type":"Holder","value":"',
                Strings.toHexString(holder),
                '"}]}'
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }
}
