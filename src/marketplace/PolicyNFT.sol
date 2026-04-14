// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {IPolicyManager} from "../interfaces/IPolicyManager.sol";
import {IShield} from "../interfaces/IShield.sol";

/**
 * @title PolicyNFT
 * @author Lumina Protocol
 * @notice ERC-721 wrapper for active insurance policies — CLAIM RIGHTS token.
 *
 * DESIGN RATIONALE:
 *   PolicyManager has NO setBeneficiary function. The on-chain beneficiary
 *   (insuredAgent) is immutable once a policy is created. PolicyNFT therefore
 *   acts as a PROXY: the NFT holder owns the RIGHT to claim payout, not the
 *   on-chain beneficiary status. The actual payout routing would require
 *   integration with CoverRouter (future upgrade).
 *
 *   Flow:
 *     1. Policy buyer calls wrap() → NFT minted to buyer
 *     2. Buyer transfers NFT on secondary market
 *     3. New holder has claim rights (enforced off-chain or via future CoverRouter upgrade)
 *     4. Holder can unwrap() to burn the NFT
 *
 * SECURITY:
 *   - Only the original policy buyer (insuredAgent) can wrap a policy
 *   - Double-wrapping is prevented via isWrapped mapping
 *   - Only the current NFT holder can unwrap (burn)
 */
contract PolicyNFT is ERC721, Ownable {
    using Strings for uint256;
    using Strings for address;

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    struct PolicyData {
        bytes32 productId;
        uint256 policyId;
        address originalBuyer;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    /// @notice PolicyManager contract — used to read policy data
    IPolicyManager public immutable policyManager;

    /// @notice Next token ID to mint
    uint256 public nextTokenId;

    /// @notice Token ID → wrapped policy data
    mapping(uint256 => PolicyData) public wrappedPolicies;

    /// @notice productId → policyId → whether already wrapped (prevents double wrap)
    mapping(bytes32 => mapping(uint256 => bool)) public isWrapped;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error NotPolicyBuyer(address caller, address insuredAgent);
    error PolicyNotActive(bytes32 productId, uint256 policyId);
    error AlreadyWrapped(bytes32 productId, uint256 policyId);
    error NotTokenHolder(address caller, uint256 tokenId);
    error ZeroAddress(string param);
    error ShieldNotFound(bytes32 productId);

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event PolicyWrapped(
        uint256 indexed tokenId, bytes32 indexed productId, uint256 indexed policyId, address originalBuyer
    );
    event PolicyUnwrapped(uint256 indexed tokenId, bytes32 indexed productId, uint256 indexed policyId);

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor(address policyManager_) ERC721("Lumina Policy NFT", "LPNFT") Ownable(msg.sender) {
        if (policyManager_ == address(0)) revert ZeroAddress("policyManager");
        policyManager = IPolicyManager(policyManager_);
    }

    // ═══════════════════════════════════════════════════════════
    //  WRAP / UNWRAP
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Wrap an active policy into an NFT — only the policy buyer can call
     * @dev Reads the Shield contract from PolicyManager to verify the caller is
     *      the insuredAgent. Mints an NFT representing claim rights.
     * @param productId The product ID the policy belongs to
     * @param policyId The policy ID within the Shield contract
     * @return tokenId The minted NFT token ID
     */
    function wrap(bytes32 productId, uint256 policyId) external returns (uint256 tokenId) {
        // Prevent double wrapping
        if (isWrapped[productId][policyId]) revert AlreadyWrapped(productId, policyId);

        // Get product registration to find Shield address
        IPolicyManager.ProductRegistration memory product = policyManager.getProduct(productId);
        if (product.shield == address(0)) revert ShieldNotFound(productId);

        // Read policy from Shield to verify caller is the insuredAgent
        IShield shield = IShield(product.shield);
        IShield.PolicyInfo memory policy = shield.getPolicyInfo(policyId);

        // Only the insured agent (policy buyer) can wrap
        if (msg.sender != policy.insuredAgent) {
            revert NotPolicyBuyer(msg.sender, policy.insuredAgent);
        }

        // Policy must be active or in waiting period (still valid coverage)
        if (policy.status != IShield.PolicyStatus.ACTIVE && policy.status != IShield.PolicyStatus.WAITING) {
            revert PolicyNotActive(productId, policyId);
        }

        // Mint NFT
        tokenId = nextTokenId++;
        wrappedPolicies[tokenId] = PolicyData({productId: productId, policyId: policyId, originalBuyer: msg.sender});
        isWrapped[productId][policyId] = true;

        _mint(msg.sender, tokenId);

        emit PolicyWrapped(tokenId, productId, policyId, msg.sender);
    }

    /**
     * @notice Unwrap — burns the NFT and releases the wrapper. Only NFT holder can call.
     * @param tokenId The NFT token ID to unwrap
     */
    function unwrap(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenHolder(msg.sender, tokenId);

        PolicyData memory data = wrappedPolicies[tokenId];

        // Clear wrapped state
        isWrapped[data.productId][data.policyId] = false;
        delete wrappedPolicies[tokenId];

        _burn(tokenId);

        emit PolicyUnwrapped(tokenId, data.productId, data.policyId);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Get the policy data associated with a wrapped NFT
     * @param tokenId The NFT token ID
     * @return productId The product ID
     * @return policyId The policy ID
     * @return originalBuyer The address that originally wrapped the policy
     */
    function getPolicyData(uint256 tokenId)
        external
        view
        returns (bytes32 productId, uint256 policyId, address originalBuyer)
    {
        // Verify token exists by calling ownerOf (reverts for nonexistent tokens)
        ownerOf(tokenId);

        PolicyData memory data = wrappedPolicies[tokenId];
        return (data.productId, data.policyId, data.originalBuyer);
    }

    /**
     * @notice On-chain JSON metadata with policy info
     * @dev Returns a base64-encoded data URI containing JSON metadata.
     *      Includes product ID, policy ID, original buyer, and current holder.
     * @param tokenId The NFT token ID
     * @return URI string with base64-encoded JSON metadata
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // Verify token exists
        address holder = ownerOf(tokenId);

        PolicyData memory data = wrappedPolicies[tokenId];

        // Build JSON metadata
        string memory json = string(
            abi.encodePacked(
                '{"name":"Lumina Policy #',
                tokenId.toString(),
                '","description":"Claim rights token for a Lumina Protocol insurance policy.","attributes":[',
                '{"trait_type":"Policy ID","value":"',
                data.policyId.toString(),
                '"},{"trait_type":"Product ID","value":"',
                _bytes32ToHexString(data.productId),
                '"},{"trait_type":"Original Buyer","value":"',
                Strings.toHexString(data.originalBuyer),
                '"},{"trait_type":"Current Holder","value":"',
                Strings.toHexString(holder),
                '"}]}'
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Convert a bytes32 value to a "0x..." hex string
     */
    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66); // "0x" + 64 hex chars
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
