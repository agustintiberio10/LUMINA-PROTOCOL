// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {IVault} from "../interfaces/IVault.sol";

/// @notice Minimal interface for ERC-4626 view used by getValue()
interface IERC4626View {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/**
 * @title VaultShareNFT
 * @author Lumina Protocol
 * @notice Claim-rights NFT for soulbound vault share positions.
 *
 * @dev Vault shares in Lumina are SOULBOUND (BaseVault._update blocks transfers).
 *      This NFT does NOT hold actual vault shares. Instead it records a claim right:
 *
 *      1. LP calls wrap() — their current share balance is recorded, NFT is minted.
 *         No share transfer occurs (impossible — soulbound).
 *      2. The NFT represents the RIGHT to the LP's vault position.
 *      3. The NFT itself IS transferable (ERC-721), enabling secondary markets.
 *      4. On unwrap(), the NFT is burned and the claim right is released back
 *         to the original depositor (who must still complete withdrawal via the vault).
 */
contract VaultShareNFT is ERC721, Ownable {
    using Strings for uint256;
    using Strings for address;

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    struct Position {
        address vault;
        uint256 shares;
        address originalDepositor;
        uint256 wrapTimestamp;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextTokenId;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event PositionWrapped(uint256 indexed tokenId, address indexed vault, address indexed depositor, uint256 shares);

    event PositionUnwrapped(uint256 indexed tokenId, address indexed vault, address indexed depositor, uint256 shares);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroShares();
    error InsufficientShareBalance(uint256 requested, uint256 available);
    error NotTokenOwner(uint256 tokenId, address caller);
    error TokenDoesNotExist(uint256 tokenId);

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor() ERC721("Lumina Vault Share NFT", "lvNFT") Ownable(msg.sender) {}

    // ═══════════════════════════════════════════════════════════
    //  CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Wrap a vault share position into a transferable NFT.
     * @dev Does NOT transfer shares (they are soulbound). Records the caller's
     *      share balance claim at wrap time. The caller must actually hold at least
     *      `shareAmount` shares in the vault.
     * @param vault Address of the BaseVault
     * @param shareAmount Number of shares to wrap as a claim
     * @return tokenId The minted NFT token ID
     */
    function wrap(address vault, uint256 shareAmount) external returns (uint256 tokenId) {
        if (vault == address(0)) revert ZeroAddress();
        if (shareAmount == 0) revert ZeroShares();

        // Verify the caller actually holds enough shares in the vault
        uint256 balance = IERC20(vault).balanceOf(msg.sender);
        if (balance < shareAmount) {
            revert InsufficientShareBalance(shareAmount, balance);
        }

        tokenId = nextTokenId++;

        positions[tokenId] = Position({
            vault: vault, shares: shareAmount, originalDepositor: msg.sender, wrapTimestamp: block.timestamp
        });

        _mint(msg.sender, tokenId);

        emit PositionWrapped(tokenId, vault, msg.sender, shareAmount);
    }

    /**
     * @notice Unwrap an NFT, releasing the claim right back to the original depositor.
     * @dev Only the current NFT holder can unwrap. Burns the NFT.
     *      The original depositor retains their soulbound shares and must
     *      use the vault's withdrawal flow to exit.
     * @param tokenId The NFT to unwrap
     */
    function unwrap(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) {
            revert NotTokenOwner(tokenId, msg.sender);
        }

        Position memory pos = positions[tokenId];

        delete positions[tokenId];
        _burn(tokenId);

        emit PositionUnwrapped(tokenId, pos.vault, pos.originalDepositor, pos.shares);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get the current USDC value of the wrapped position.
     * @dev Calls the vault's ERC-4626 convertToAssets() to compute real-time value.
     * @param tokenId The NFT to query
     * @return value The current USDC value of the shares
     */
    function getValue(uint256 tokenId) external view returns (uint256 value) {
        _requirePosition(tokenId);
        Position memory pos = positions[tokenId];
        value = IERC4626View(pos.vault).convertToAssets(pos.shares);
    }

    /**
     * @notice Check cooldown status for the original depositor's withdrawal request.
     * @dev Reads the vault's withdrawal request for the original depositor.
     *      Returns whether a cooldown is active and when it ends.
     * @param tokenId The NFT to query
     * @return active Whether a withdrawal cooldown is currently active
     * @return endsAt Timestamp when the cooldown expires (0 if no active request)
     */
    function getCooldownStatus(uint256 tokenId) external view returns (bool active, uint256 endsAt) {
        _requirePosition(tokenId);
        Position memory pos = positions[tokenId];

        IVault.WithdrawalRequest memory req = IVault(pos.vault).getWithdrawalRequest(pos.originalDepositor);

        endsAt = req.cooldownEnd;
        active = endsAt > 0 && block.timestamp < endsAt;
    }

    /**
     * @notice Get full position data for an NFT.
     * @param tokenId The NFT to query
     * @return vault The vault address
     * @return shares The number of shares wrapped
     * @return originalDepositor The LP who created the position
     * @return wrapTimestamp When the position was wrapped
     */
    function getPositionData(uint256 tokenId)
        external
        view
        returns (address vault, uint256 shares, address originalDepositor, uint256 wrapTimestamp)
    {
        _requirePosition(tokenId);
        Position memory pos = positions[tokenId];
        vault = pos.vault;
        shares = pos.shares;
        originalDepositor = pos.originalDepositor;
        wrapTimestamp = pos.wrapTimestamp;
    }

    /// @dev Kept with original typo from spec for backwards compatibility
    function getPosistionData(uint256 tokenId)
        external
        view
        returns (address vault, uint256 shares, address originalDepositor, uint256 wrapTimestamp)
    {
        _requirePosition(tokenId);
        Position memory pos = positions[tokenId];
        vault = pos.vault;
        shares = pos.shares;
        originalDepositor = pos.originalDepositor;
        wrapTimestamp = pos.wrapTimestamp;
    }

    // ═══════════════════════════════════════════════════════════
    //  METADATA
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice On-chain JSON metadata for the NFT.
     * @param tokenId The NFT to query
     * @return URI data:application/json;base64 encoded metadata
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requirePosition(tokenId);
        Position memory pos = positions[tokenId];

        uint256 usdcValue = IERC4626View(pos.vault).convertToAssets(pos.shares);

        string memory json = string(
            abi.encodePacked(
                '{"name":"Lumina Vault Position #',
                tokenId.toString(),
                '","description":"Claim rights to a soulbound vault share position in Lumina Protocol.",'
                '"attributes":[' '{"trait_type":"Vault","value":"',
                Strings.toHexString(pos.vault),
                '"},' '{"trait_type":"Shares","value":"',
                pos.shares.toString(),
                '"},' '{"trait_type":"Original Depositor","value":"',
                Strings.toHexString(pos.originalDepositor),
                '"},' '{"trait_type":"Wrap Timestamp","display_type":"date","value":',
                pos.wrapTimestamp.toString(),
                "}," '{"trait_type":"USDC Value","value":"',
                usdcValue.toString(),
                '"}' "]}"
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════

    function _requirePosition(uint256 tokenId) internal view {
        if (positions[tokenId].vault == address(0)) {
            revert TokenDoesNotExist(tokenId);
        }
    }
}
