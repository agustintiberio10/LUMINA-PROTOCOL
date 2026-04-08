// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPolicyManager
 * @author Lumina Protocol
 * @notice Allocation controller — bridge between products and vaults.
 *         Now handles WATERFALL vault selection and ALM (Asset-Liability Matching).
 * 
 * 🔴 INMUTABLE — Interface cannot change without redeploying.
 * 🟡 UPGRADABLE — Implementation is UUPS, logic can be improved.
 * 
 * POST-PIVOT CHANGES:
 *   - Products no longer have a fixed vault. PM selects vault via waterfall.
 *   - recordAllocation() returns the chosen vault address (Router needs it for premium).
 *   - ALM check: policy duration must fit within vault's cooldown capacity.
 *   - 4 vaults: VolatileShort(30d), VolatileLong(90d), StableShort(90d), StableLong(365d)
 * 
 * WATERFALL:
 *   Policy of 14 days, riskType "STABLE":
 *     1. Try StableShort (90d cooldown, 90d ≥ 14d ✓) — if capacity, use it
 *     2. If full → Try StableLong (365d cooldown, 365d ≥ 14d ✓)
 *     3. If all full → reject
 * 
 * CORRELATION GROUPS (unchanged):
 *   GROUP_ETH_CRASH: BSS + IL combined cap
 *   GROUP_STABLECOIN: Depeg cap
 *   GROUP_SMART_CONTRACT: Exploit cap
 */
interface IPolicyManager {

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    struct ProductRegistration {
        bytes32 productId;
        address shield;
        bytes32 riskType;           // "VOLATILE" or "STABLE"
        uint16 maxAllocationBps;
        bytes32[] correlationGroups;
        bool active;
    }

    /// @notice A vault registered in the waterfall
    struct VaultRegistration {
        address vault;              // Vault contract address
        bytes32 riskType;           // "VOLATILE" or "STABLE"
        uint32 cooldownDuration;    // Vault's cooldown in seconds (30d, 90d, 365d)
        uint8 priority;             // Waterfall order: 0 = try first (shortest), 1 = next, etc.
        bool active;
    }

    struct AllocationState {
        bytes32 productId;
        uint256 allocated;
        uint256 maxAllowed;
        uint256 available;
        uint16 utilizationBps;
    }

    struct CorrelationGroup {
        bytes32 groupId;
        uint16 maxAllocationBps;
        uint256 currentAllocated;
        bytes32[] productIds;
    }

    /// @notice Result of waterfall allocation — tells Router which vault was chosen
    struct AllocationResult {
        address vault;              // Vault that will back this policy
        uint256 policyId;           // Not used in PM, passed through for reference
        uint256 amount;             // Amount allocated
    }

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event ProductRegistered(bytes32 indexed productId, address indexed shield, bytes32 riskType, uint16 maxAllocationBps);
    event ProductShieldUpdated(bytes32 indexed productId, address indexed oldShield, address indexed newShield);
    event VaultRegistered(address indexed vault, bytes32 riskType, uint32 cooldownDuration, uint8 priority);
    event ProductStatusChanged(bytes32 indexed productId, bool active);
    event CorrelationGroupCreated(bytes32 indexed groupId, uint16 maxAllocationBps);
    event ProductAddedToGroup(bytes32 indexed productId, bytes32 indexed groupId);
    event AllocationRecorded(bytes32 indexed productId, uint256 indexed policyId, address indexed vault, uint256 amount);
    event AllocationReleased(bytes32 indexed productId, uint256 indexed policyId, address indexed vault, uint256 amount);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error ProductNotRegistered(bytes32 productId);
    error ProductNotActive(bytes32 productId);
    error MaxAllocationExceeded(bytes32 productId, uint256 requested, uint256 available);
    error CorrelationGroupCapExceeded(bytes32 groupId, uint256 requested, uint256 available);
    error NoVaultCapacity(bytes32 riskType, uint32 policyDuration);
    error VaultUtilizationTooHigh(address vault, uint256 currentBps, uint256 maxBps);
    error GroupNotFound(bytes32 groupId);
    error OnlyRouter();
    error OnlyAdmin();

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT + VAULT REGISTRY (admin only)
    // ═══════════════════════════════════════════════════════════

    function registerProduct(bytes32 productId, address shield, bytes32 riskType, uint16 maxAllocationBps) external;
    function setProductActive(bytes32 productId, bool active) external;
    function updateMaxAllocation(bytes32 productId, uint16 newMaxAllocationBps) external;

    /// @notice Replace the shield contract address for an already-registered product.
    /// @dev Used when a shield is redeployed (e.g. V1 → V2) and we want to keep
    ///      the existing productId so API integrations remain stable. Only mutates
    ///      the `shield` field; riskType, maxAllocationBps, correlationGroups, and
    ///      `active` are preserved. Caller MUST be either the admin (owner) or
    ///      the CoverRouter (so CoverRouter.updateProductShield can propagate
    ///      atomically).
    function updateProductShield(bytes32 productId, address newShield) external;

    /// @notice Register a vault in the waterfall
    function registerVault(address vault, bytes32 riskType, uint32 cooldownDuration, uint8 priority) external;

    // ── Correlation Groups (admin only) ──
    function createCorrelationGroup(bytes32 groupId, uint16 maxAllocationBps) external;
    function addProductToGroup(bytes32 productId, bytes32 groupId) external;
    function updateGroupCap(bytes32 groupId, uint16 newMaxAllocationBps) external;

    // ═══════════════════════════════════════════════════════════
    //  ALLOCATION MANAGEMENT (only CoverRouter)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Check if a policy can be allocated via waterfall
     * @dev Checks: product active, product cap, correlation group cap,
     *      finds a vault with capacity via waterfall (shortest cooldown first).
     * @param productId Product ID
     * @param amount Coverage amount
     * @param policyDurationSeconds Policy duration (for ALM check: duration ≤ vault cooldown)
     * @return allowed True if a vault with capacity was found
     * @return vault Address of the vault that would back this policy
     * @return reason bytes32 reason if not allowed
     */
    function canAllocate(
        bytes32 productId,
        uint256 amount,
        uint32 policyDurationSeconds
    ) external view returns (bool allowed, address vault, bytes32 reason);

    /**
     * @notice Record allocation via waterfall — locks collateral in the chosen vault
     * @dev MUST re-verify caps internally (TOCTOU defense).
     *      Returns the vault address so Router knows where to send the premium.
     * @param productId Product ID
     * @param policyId Policy ID (from Shield)
     * @param amount Coverage amount
     * @param policyDurationSeconds Policy duration (for ALM)
     * @return vault Address of the vault that backs this policy
     */
    function recordAllocation(
        bytes32 productId,
        uint256 policyId,
        uint256 amount,
        uint32 policyDurationSeconds
    ) external returns (address vault);

    /**
     * @notice Release allocation — unlocks collateral in the specific vault
     * @param productId Product ID
     * @param policyId Policy ID
     * @param amount Coverage amount to release
     * @param vault Address of the vault to unlock from
     */
    function releaseAllocation(
        bytes32 productId,
        uint256 policyId,
        uint256 amount,
        address vault
    ) external;

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    function getProduct(bytes32 productId) external view returns (ProductRegistration memory);
    function getAllocationState(bytes32 productId) external view returns (AllocationState memory);
    function getAllProducts() external view returns (bytes32[] memory ids);
    function getVaultsByRiskType(bytes32 riskType) external view returns (address[] memory vaults);
    function getCorrelationGroup(bytes32 groupId) external view returns (CorrelationGroup memory);
    function getProductGroups(bytes32 productId) external view returns (bytes32[] memory groupIds);
    function getAllCorrelationGroups() external view returns (bytes32[] memory groupIds);
}
