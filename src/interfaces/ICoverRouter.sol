// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "./IShield.sol";

/**
 * @title ICoverRouter
 * @author Lumina Protocol
 * @notice Single entry point for ALL agent interactions.
 *         UUPS upgradable — address NEVER changes.
 * 
 * POST-PIVOT CHANGES:
 *   - Purchase flow: vault selected by PolicyManager via waterfall (not from Shield)
 *   - Router tracks policyId → vault mapping (needed for payout/cleanup)
 *   - SignedQuote unchanged (agents don't need to know about vault internals)
 * 
 * DUAL ORACLE:
 *   - oracle (IOracle): Chainlink — prices, TWAPs, EIP-712 quote signatures
 *   - phalaVerifier (IPhalaVerifier): Phala TEE — agent attestations
 */
interface ICoverRouter {

    struct SignedQuote {
        bytes32 productId;
        uint256 coverageAmount;     // USD, 6 decimals
        uint256 premiumAmount;      // USD, 6 decimals
        uint32 durationSeconds;
        bytes32 asset;              // "ETH", "BTC"
        bytes32 stablecoin;         // "USDC", "USDT", "DAI"
        address protocol;           // Protocol address (Exploit)
        address buyer;              // Must match msg.sender
        uint256 deadline;           // Quote expiry (~5 min)
        uint256 nonce;              // Anti-replay
    }

    struct PurchaseResult {
        uint256 policyId;
        bytes32 productId;
        address vault;              // NEW: which vault backs this policy
        uint256 coverageAmount;
        uint256 premiumPaid;
        uint256 startsAt;
        uint256 expiresAt;
    }

    event PolicyPurchased(uint256 indexed policyId, bytes32 indexed productId, address indexed buyer, address vault, uint256 coverageAmount, uint256 premiumPaid, uint32 durationSeconds);
    event PayoutTriggered(uint256 indexed policyId, bytes32 indexed productId, address indexed recipient, uint256 payoutAmount);
    event PolicyCleanedUp(uint256 indexed policyId, bytes32 indexed productId);
    event ProductUpdated(bytes32 indexed productId, address shield, bool active);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event PhalaVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);
    event ProtocolPausedChanged(bool paused);

    error ProtocolIsPaused();
    error QuoteExpired(uint256 deadline, uint256 currentTime);
    error InvalidQuoteSignature();
    error NonceAlreadyUsed(uint256 nonce);
    error ProductNotAvailable(bytes32 productId);
    error BuyerMismatch(address expected, address actual);
    error InvalidPolicyForPayout(uint256 policyId);
    error TriggerNotMet(uint256 policyId);
    error PolicyAlreadyResolved(bytes32 productId, uint256 policyId);
    error RecipientMismatch(address expected, address actual);
    error OnlyAdmin();

    // ── Agent Operations ──
    function purchasePolicy(SignedQuote calldata quote, bytes calldata signature) external returns (PurchaseResult memory result);
    function triggerPayout(bytes32 productId, uint256 policyId, bytes calldata oracleProof) external;
    function cleanupExpiredPolicy(bytes32 productId, uint256 policyId) external;

    // ── Admin Operations ──
    function registerProduct(bytes32 productId, address shield, bytes32 riskType, uint16 maxAllocationBps) external;
    function setOracle(address newOracle) external;
    function setPhalaVerifier(address newVerifier) external;
    function setPaused(bool paused) external;

    // ── Views ──
    function oracle() external view returns (address);
    function phalaVerifier() external view returns (address);
    function policyManager() external view returns (address);
    function isProductAvailable(bytes32 productId) external view returns (bool);
    function getProductShield(bytes32 productId) external view returns (address);
    function getPolicyVault(bytes32 productId, uint256 policyId) external view returns (address);
    function isNonceUsed(uint256 nonce) external view returns (bool);
    function isPaused() external view returns (bool);
    function domainSeparator() external view returns (bytes32);
}
