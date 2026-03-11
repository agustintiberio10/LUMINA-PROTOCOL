// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IShield
 * @author Lumina Protocol
 * @notice Interface ALL insurance products must implement.
 *         CoverRouter ONLY knows this — zero knowledge of internal logic.
 * 
 * 🔴 INMUTABLE — Changing this requires redeploying all products.
 * 
 * POST-PIVOT CHANGE: vault() REMOVED.
 *   A product no longer has a fixed vault. The PolicyManager decides
 *   which vault backs each policy via waterfall (Short → Long).
 *   Example: DepegShield 30d policy → PM tries StableShort, if full → StableLong.
 * 
 * GAS: All reason fields are bytes32 (not string). M2M target.
 */
interface IShield {

    enum PolicyStatus {
        NONEXISTENT,
        WAITING,        // Within waiting period — NOT covered
        ACTIVE,         // Coverage active
        EXPIRED,        // Expired without claim
        SETTLEMENT,     // Settlement window (IL Index: 48h post-expiry)
        PAID_OUT,
        CANCELLED
    }

    struct PolicyInfo {
        uint256 policyId;
        address insuredAgent;
        uint256 coverageAmount;     // USD, 6 decimals
        uint256 premiumPaid;
        uint256 maxPayout;
        uint256 startTimestamp;
        uint256 waitingEndsAt;
        uint256 expiresAt;
        uint256 cleanupAt;          // expiresAt for most products. expiresAt + 48h for IL Index.
        PolicyStatus status;
    }

    struct CreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;              // BSS, IL: "ETH", "BTC"
        bytes32 stablecoin;         // Depeg: "USDC", "USDT", "DAI"
        address protocol;           // Exploit: Aave, Compound address
        bytes extraData;            // Future-proof
    }

    struct PayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;             // bytes32 for gas optimization
    }

    event PolicyCreated(
        uint256 indexed policyId, address indexed buyer, uint256 coverageAmount,
        uint256 premiumPaid, uint32 durationSeconds, uint256 waitingEndsAt, uint256 expiresAt
    );
    event PolicyPaidOut(uint256 indexed policyId, address indexed recipient, uint256 payoutAmount, bytes32 reason);
    event PolicyExpired(uint256 indexed policyId);

    error PolicyNotFound(uint256 policyId);
    error InvalidPolicyStatus(uint256 policyId, PolicyStatus current, PolicyStatus required);
    error DurationOutOfRange(uint32 requested, uint32 min, uint32 max);
    error CoverageOutOfRange(uint256 requested, uint256 min, uint256 max);
    error TriggerNotMet(uint256 policyId, bytes32 reason);
    error OnlyRouter();

    // ── Product Metadata ──
    function productId() external view returns (bytes32 id);
    function riskType() external view returns (bytes32);     // "VOLATILE" or "STABLE"
    function maxAllocationBps() external view returns (uint16 bps);
    function durationRange() external view returns (uint32 minSeconds, uint32 maxSeconds);
    function waitingPeriod() external view returns (uint32);

    // NOTE: vault() REMOVED — PolicyManager handles vault selection via waterfall

    // ── Policy Lifecycle (only CoverRouter) ──
    function createPolicy(CreatePolicyParams calldata params) external returns (uint256 policyId);
    function verifyAndCalculate(uint256 policyId, bytes calldata oracleProof) external returns (PayoutResult memory result);
    function markPaidOut(uint256 policyId) external;
    function markExpired(uint256 policyId) external;

    // ── Queries ──
    function getPolicyInfo(uint256 policyId) external view returns (PolicyInfo memory info);
    function getPolicyStatus(uint256 policyId) external view returns (PolicyStatus status);
    function totalPolicies() external view returns (uint256 count);
    function activePolicies() external view returns (uint256 count);
    function totalActiveCoverage() external view returns (uint256 amount);
}
