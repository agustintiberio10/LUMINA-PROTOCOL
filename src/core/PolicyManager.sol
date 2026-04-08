// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IPolicyManager} from "../interfaces/IPolicyManager.sol";
import {IVault} from "../interfaces/IVault.sol";

/**
 * @title PolicyManager
 * @author Lumina Protocol
 * @notice The brain of Lumina — connects products to vaults via waterfall.
 *         Enforces MaxAllocation per product, correlation group caps, and ALM.
 * 
 * 🟡 UPGRADABLE via UUPS.
 * 
 * KEY RESPONSIBILITIES:
 *   1. Product registry: which products exist and their risk type
 *   2. Vault registry: which vaults exist, their cooldown, and waterfall priority
 *   3. Waterfall: for each policy, find the cheapest vault that can back it
 *   4. ALM: policy duration must fit within vault cooldown
 *   5. Allocation caps: per-product MaxAllocation + correlation group caps
 *   6. recordAllocation: RE-VERIFIES all caps internally (TOCTOU defense)
 *   7. Tracks which vault backs each allocation (for release)
 * 
 * WATERFALL LOGIC:
 *   Agent wants Depeg 30d policy → PM tries StableShort (90d, priority 0)
 *   If StableShort full → tries StableLong (365d, priority 1)
 *   If all full → rejects
 *   
 *   Always tries shortest-cooldown vault first (cheapest for the protocol).
 *   Overflow into longer vaults is a feature: long LPs earn extra premia.
 */
contract PolicyManager is
    IPolicyManager,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    // ═══════════════════════════════════════════════════════════
    //  STORAGE — 🔴 NEVER reorder. Only APPEND.
    // ═══════════════════════════════════════════════════════════

    /// @notice CoverRouter address — only it can call allocation functions
    address private _router;

    /// @notice Product registry: productId → ProductRegistration
    mapping(bytes32 => ProductRegistration) private _products;

    /// @notice All registered product IDs
    bytes32[] private _productIds;

    /// @notice Vault registry: vault address → VaultRegistration
    mapping(address => VaultRegistration) private _vaults;

    /// @notice Vaults by risk type: riskType → vault addresses (sorted by priority)
    mapping(bytes32 => address[]) private _vaultsByRiskType;

    /// @notice Correlation groups: groupId → CorrelationGroup
    mapping(bytes32 => CorrelationGroup) private _correlationGroups;

    /// @notice All correlation group IDs
    bytes32[] private _correlationGroupIds;

    /// @notice Per-product allocation tracking: productId → total allocated across all vaults
    mapping(bytes32 => uint256) private _productAllocated;

    /// @notice Per-product-per-vault allocation: productId → vault → allocated
    mapping(bytes32 => mapping(address => uint256)) private _productVaultAllocated;

    /// @notice Per-policy allocation record: productId → policyId → (vault, amount)
    mapping(bytes32 => mapping(uint256 => AllocationRecord)) private _policyAllocations;

    /// @notice Internal struct for tracking individual policy allocations
    struct AllocationRecord {
        address vault;
        uint256 amount;
    }

    /// @notice Per-product freeze flag — emergency halt for individual products
    /// @dev APPENDED to storage layout (safe for UUPS upgrade)
    mapping(bytes32 => bool) public productFrozen;

    /// @dev Storage gap for future UUPS upgrades
    uint256[49] private __gap;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_UTILIZATION_BPS = 9_500;

    // ═══════════════════════════════════════════════════════════
    //  ADDITIONAL ERRORS
    // ═══════════════════════════════════════════════════════════

    error ZeroAddress(string param);
    error VaultAlreadyRegistered(address vault);
    error VaultNotRegistered(address vault);
    error ProductAlreadyExists(bytes32 productId);
    error PolicyAlreadyAllocated(bytes32 productId, uint256 policyId);
    error ProductFrozen(bytes32 productId);

    event AllocationUnderflow(bytes32 indexed productId, uint256 expected, uint256 actual);
    event MaxAllocationUpdated(bytes32 indexed productId, uint16 oldBps, uint16 newBps);

    // ═══════════════════════════════════════════════════════════
    //  INITIALIZER
    // ═══════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address owner_, address router_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress("owner");
        if (router_ == address(0)) revert ZeroAddress("router");

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        _router = router_;
    }

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyRouter() {
        if (msg.sender != _router) revert OnlyRouter();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != owner()) revert OnlyAdmin();
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT REGISTRY (admin only)
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IPolicyManager
    /// @dev [FIX] Allows both owner (admin) AND router to register products.
    ///      Router calls this atomically during CoverRouter.registerProduct().
    function registerProduct(
        bytes32 productId,
        address shield,
        bytes32 riskType,
        uint16 maxAllocationBps
    ) external {
        if (msg.sender != owner() && msg.sender != _router) revert OnlyAdmin();
        if (_products[productId].shield != address(0)) revert ProductAlreadyExists(productId);
        if (shield == address(0)) revert ZeroAddress("shield");

        _products[productId] = ProductRegistration({
            productId: productId,
            shield: shield,
            riskType: riskType,
            maxAllocationBps: maxAllocationBps,
            correlationGroups: new bytes32[](0),
            active: true
        });

        _productIds.push(productId);

        emit ProductRegistered(productId, shield, riskType, maxAllocationBps);
    }

    /// @inheritdoc IPolicyManager
    /// @dev Allows owner AND router (Router calls this from setProductActive)
    function setProductActive(bytes32 productId, bool active) external {
        if (msg.sender != owner() && msg.sender != _router) revert OnlyAdmin();
        if (_products[productId].shield == address(0)) revert ProductNotRegistered(productId);
        _products[productId].active = active;
        emit ProductStatusChanged(productId, active);
    }

    /// @inheritdoc IPolicyManager
    function updateMaxAllocation(bytes32 productId, uint16 newMaxAllocationBps) external onlyAdmin {
        if (_products[productId].shield == address(0)) revert ProductNotRegistered(productId);
        uint16 oldBps = _products[productId].maxAllocationBps;
        _products[productId].maxAllocationBps = newMaxAllocationBps;
        emit MaxAllocationUpdated(productId, oldBps, newMaxAllocationBps);
    }

    /// @inheritdoc IPolicyManager
    /// @dev Mutates ONLY the shield field. Allows owner OR router so that
    ///      CoverRouter.updateProductShield can keep both registries in sync
    ///      atomically.
    function updateProductShield(bytes32 productId, address newShield) external {
        if (msg.sender != owner() && msg.sender != _router) revert OnlyAdmin();
        if (newShield == address(0)) revert ZeroAddress("shield");
        if (_products[productId].shield == address(0)) revert ProductNotRegistered(productId);
        address oldShield = _products[productId].shield;
        _products[productId].shield = newShield;
        emit ProductShieldUpdated(productId, oldShield, newShield);
    }

    // ═══════════════════════════════════════════════════════════
    //  VAULT REGISTRY (admin only)
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IPolicyManager
    function registerVault(
        address vault,
        bytes32 riskType,
        uint32 cooldownDuration,
        uint8 priority
    ) external onlyAdmin {
        if (vault == address(0)) revert ZeroAddress("vault");
        if (_vaults[vault].vault != address(0)) revert VaultAlreadyRegistered(vault);

        _vaults[vault] = VaultRegistration({
            vault: vault,
            riskType: riskType,
            cooldownDuration: cooldownDuration,
            priority: priority,
            active: true
        });

        // Insert into sorted array by priority (ascending: 0 = first tried)
        address[] storage vaultList = _vaultsByRiskType[riskType];
        uint256 insertIdx = vaultList.length;
        for (uint256 i = 0; i < vaultList.length; i++) {
            if (_vaults[vaultList[i]].priority > priority) {
                insertIdx = i;
                break;
            }
        }

        // Shift and insert
        vaultList.push(address(0)); // extend array
        for (uint256 i = vaultList.length - 1; i > insertIdx; i--) {
            vaultList[i] = vaultList[i - 1];
        }
        vaultList[insertIdx] = vault;

        emit VaultRegistered(vault, riskType, cooldownDuration, priority);
    }

    /// @notice Activate or deactivate a vault in the waterfall
    /// @dev Deactivated vaults are skipped by _findVault — no new policies assigned.
    ///      Existing policies in the vault remain backed and can still be released/paid.
    function setVaultActive(address vault, bool active) external onlyAdmin {
        if (_vaults[vault].vault == address(0)) revert VaultNotRegistered(vault);
        _vaults[vault].active = active;
    }

    // ═══════════════════════════════════════════════════════════
    //  CORRELATION GROUPS (admin only)
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IPolicyManager
    /// @dev [FIX] Prevents overwriting existing group (would reset currentAllocated to 0)
    function createCorrelationGroup(bytes32 groupId, uint16 maxAllocationBps) external onlyAdmin {
        if (_correlationGroups[groupId].maxAllocationBps != 0) revert GroupNotFound(groupId); // reuse error: group already exists
        _correlationGroups[groupId] = CorrelationGroup({
            groupId: groupId,
            maxAllocationBps: maxAllocationBps,
            currentAllocated: 0,
            productIds: new bytes32[](0)
        });
        _correlationGroupIds.push(groupId);
        emit CorrelationGroupCreated(groupId, maxAllocationBps);
    }

    /// @inheritdoc IPolicyManager
    /// @dev [FIX] Prevents duplicate: adding same product twice would double-increment group allocation
    function addProductToGroup(bytes32 productId, bytes32 groupId) external onlyAdmin {
        if (_products[productId].shield == address(0)) revert ProductNotRegistered(productId);
        if (_correlationGroups[groupId].maxAllocationBps == 0) revert GroupNotFound(groupId);

        // Check product not already in this group
        bytes32[] storage existingGroups = _products[productId].correlationGroups;
        for (uint256 i = 0; i < existingGroups.length; i++) {
            if (existingGroups[i] == groupId) revert ProductNotRegistered(productId); // reuse error: already in group
        }

        _correlationGroups[groupId].productIds.push(productId);
        _products[productId].correlationGroups.push(groupId);

        emit ProductAddedToGroup(productId, groupId);
    }

    /// @inheritdoc IPolicyManager
    function updateGroupCap(bytes32 groupId, uint16 newMaxAllocationBps) external onlyAdmin {
        if (_correlationGroups[groupId].maxAllocationBps == 0) revert GroupNotFound(groupId);
        _correlationGroups[groupId].maxAllocationBps = newMaxAllocationBps;
    }

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT FREEZE (admin only — emergency halt)
    // ═══════════════════════════════════════════════════════════

    event ProductFreezeChanged(bytes32 indexed productId, bool frozen);

    /// @notice Freeze a product — blocks new allocations without deactivating
    /// @dev Unlike setProductActive(false), freeze is designed for temporary emergency halt.
    ///      Existing policies remain backed and can still be claimed/cleaned up.
    function freezeProduct(bytes32 productId) external onlyAdmin {
        if (_products[productId].shield == address(0)) revert ProductNotRegistered(productId);
        productFrozen[productId] = true;
        emit ProductFreezeChanged(productId, true);
    }

    /// @notice Unfreeze a product — re-enables new allocations
    function unfreezeProduct(bytes32 productId) external onlyAdmin {
        if (_products[productId].shield == address(0)) revert ProductNotRegistered(productId);
        productFrozen[productId] = false;
        emit ProductFreezeChanged(productId, false);
    }

    // ═══════════════════════════════════════════════════════════
    //  ALLOCATION — WATERFALL (only CoverRouter)
    // ═══════════════════════════════════════════════════════════

    /**
     * @inheritdoc IPolicyManager
     * @dev View function for pre-checking. The Router calls this before purchase.
     *      Does NOT lock anything — just checks if allocation would succeed.
     */
    function canAllocate(
        bytes32 productId,
        uint256 amount,
        uint32 policyDurationSeconds
    ) external view returns (bool allowed, address vault, bytes32 reason) {
        ProductRegistration storage prod = _products[productId];
        if (prod.shield == address(0)) return (false, address(0), "PRODUCT_NOT_FOUND");
        if (!prod.active) return (false, address(0), "PRODUCT_NOT_ACTIVE");
        if (productFrozen[productId]) return (false, address(0), "PRODUCT_FROZEN");

        // Check per-product cap
        uint256 productMaxAllowed = _getProductMaxAllowed(productId);
        if (_productAllocated[productId] + amount > productMaxAllowed) {
            return (false, address(0), "PRODUCT_CAP_EXCEEDED");
        }

        // Check correlation group caps
        bytes32[] storage groups = prod.correlationGroups;
        for (uint256 i = 0; i < groups.length; i++) {
            CorrelationGroup storage group = _correlationGroups[groups[i]];
            uint256 groupMax = _getGroupMaxAllowed(groups[i]);
            if (group.currentAllocated + amount > groupMax) {
                return (false, address(0), "GROUP_CAP_EXCEEDED");
            }
        }

        // Waterfall: find vault with capacity
        vault = _findVault(prod.riskType, amount, policyDurationSeconds);
        if (vault == address(0)) {
            return (false, address(0), "NO_VAULT_CAPACITY");
        }

        return (true, vault, "");
    }

    /**
     * @inheritdoc IPolicyManager
     * @dev MUST re-verify all caps internally (TOCTOU defense).
     *      This is the ONLY function that actually locks collateral.
     */
    function recordAllocation(
        bytes32 productId,
        uint256 policyId,
        uint256 amount,
        uint32 policyDurationSeconds
    ) external onlyRouter returns (address vault) {
        // Prevent double allocation for same policy
        if (_policyAllocations[productId][policyId].vault != address(0)) {
            revert PolicyAlreadyAllocated(productId, policyId);
        }

        ProductRegistration storage prod = _products[productId];
        if (prod.shield == address(0)) revert ProductNotRegistered(productId);
        if (!prod.active) revert ProductNotActive(productId);
        if (productFrozen[productId]) revert ProductFrozen(productId);

        // RE-VERIFY per-product cap (TOCTOU defense)
        uint256 productMaxAllowed = _getProductMaxAllowed(productId);
        if (_productAllocated[productId] + amount > productMaxAllowed) {
            uint256 available = productMaxAllowed > _productAllocated[productId]
                ? productMaxAllowed - _productAllocated[productId]
                : 0;
            revert MaxAllocationExceeded(productId, amount, available);
        }

        // RE-VERIFY correlation group caps (TOCTOU defense)
        bytes32[] storage groups = prod.correlationGroups;
        for (uint256 i = 0; i < groups.length; i++) {
            CorrelationGroup storage group = _correlationGroups[groups[i]];
            uint256 groupMax = _getGroupMaxAllowed(groups[i]);
            if (group.currentAllocated + amount > groupMax) {
                uint256 groupAvailable = groupMax > group.currentAllocated
                    ? groupMax - group.currentAllocated
                    : 0;
                revert CorrelationGroupCapExceeded(groups[i], amount, groupAvailable);
            }
        }

        // Waterfall: find vault (re-verified, not cached from canAllocate)
        vault = _findVault(prod.riskType, amount, policyDurationSeconds);
        if (vault == address(0)) revert NoVaultCapacity(prod.riskType, policyDurationSeconds);

        // ── EFFECTS ──

        // Update product allocation tracking
        _productAllocated[productId] += amount;
        _productVaultAllocated[productId][vault] += amount;

        // Update correlation group tracking
        for (uint256 i = 0; i < groups.length; i++) {
            _correlationGroups[groups[i]].currentAllocated += amount;
        }

        // Store allocation record (needed for releaseAllocation)
        _policyAllocations[productId][policyId] = AllocationRecord({
            vault: vault,
            amount: amount
        });

        // ── INTERACTION ──

        // Lock collateral in the chosen vault
        IVault(vault).lockCollateral(amount, productId, policyId);

        emit AllocationRecorded(productId, policyId, vault, amount);
    }

    /**
     * @inheritdoc IPolicyManager
     * @dev Called by Router when policy expires or pays out.
     *      Unlocks collateral in the specific vault that backed the policy.
     */
    function releaseAllocation(
        bytes32 productId,
        uint256 policyId,
        uint256 amount,
        address vault
    ) external onlyRouter {
        AllocationRecord storage record = _policyAllocations[productId][policyId];

        // Use stored vault if caller passes address(0) or wrong vault
        address actualVault = record.vault != address(0) ? record.vault : vault;

        // Cap amount to what was actually allocated
        uint256 actualAmount = amount > record.amount ? record.amount : amount;

        // ── EFFECTS ──

        // Update product tracking
        if (actualAmount > _productAllocated[productId]) {
            emit AllocationUnderflow(productId, actualAmount, _productAllocated[productId]);
            _productAllocated[productId] = 0;
        } else {
            _productAllocated[productId] -= actualAmount;
        }

        if (actualAmount > _productVaultAllocated[productId][actualVault]) {
            emit AllocationUnderflow(productId, actualAmount, _productVaultAllocated[productId][actualVault]);
            _productVaultAllocated[productId][actualVault] = 0;
        } else {
            _productVaultAllocated[productId][actualVault] -= actualAmount;
        }

        // Update correlation groups
        ProductRegistration storage prod = _products[productId];
        bytes32[] storage groups = prod.correlationGroups;
        for (uint256 i = 0; i < groups.length; i++) {
            CorrelationGroup storage group = _correlationGroups[groups[i]];
            if (actualAmount > group.currentAllocated) {
                emit AllocationUnderflow(productId, actualAmount, group.currentAllocated);
                group.currentAllocated = 0;
            } else {
                group.currentAllocated -= actualAmount;
            }
        }

        // Clear allocation record
        delete _policyAllocations[productId][policyId];

        // ── INTERACTION ──

        // Unlock collateral in vault
        IVault(actualVault).unlockCollateral(actualAmount, productId, policyId);

        emit AllocationReleased(productId, policyId, actualVault, actualAmount);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IPolicyManager
    function getProduct(bytes32 productId) external view returns (ProductRegistration memory) {
        return _products[productId];
    }

    /// @inheritdoc IPolicyManager
    function getAllocationState(bytes32 productId) external view returns (AllocationState memory) {
        uint256 maxAllowed = _getProductMaxAllowed(productId);
        uint256 allocated = _productAllocated[productId];
        return AllocationState({
            productId: productId,
            allocated: allocated,
            maxAllowed: maxAllowed,
            available: maxAllowed > allocated ? maxAllowed - allocated : 0,
            utilizationBps: maxAllowed > 0 ? uint16((allocated * BPS) / maxAllowed) : 0
        });
    }

    /// @inheritdoc IPolicyManager
    function getAllProducts() external view returns (bytes32[] memory) {
        return _productIds;
    }

    /// @inheritdoc IPolicyManager
    function getVaultsByRiskType(bytes32 riskType) external view returns (address[] memory) {
        return _vaultsByRiskType[riskType];
    }

    /// @inheritdoc IPolicyManager
    function getCorrelationGroup(bytes32 groupId) external view returns (CorrelationGroup memory) {
        return _correlationGroups[groupId];
    }

    /// @inheritdoc IPolicyManager
    function getProductGroups(bytes32 productId) external view returns (bytes32[] memory) {
        return _products[productId].correlationGroups;
    }

    /// @inheritdoc IPolicyManager
    function getAllCorrelationGroups() external view returns (bytes32[] memory) {
        return _correlationGroupIds;
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN
    // ═══════════════════════════════════════════════════════════

    function setRouter(address newRouter) external onlyAdmin {
        if (newRouter == address(0)) revert ZeroAddress("router");
        _router = newRouter;
    }

    /// @notice Remove inactive products from _productIds array (gas optimization)
    function cleanProductIds() external onlyAdmin {
        uint256 writeIdx = 0;
        for (uint256 i = 0; i < _productIds.length; i++) {
            if (_products[_productIds[i]].active) {
                _productIds[writeIdx] = _productIds[i];
                writeIdx++;
            }
        }
        while (_productIds.length > writeIdx) {
            _productIds.pop();
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — WATERFALL
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Find the best vault for a policy via waterfall
     * @dev Iterates vaults of matching riskType in priority order (shortest first).
     *      For each vault, checks:
     *        1. Vault is active
     *        2. Vault cooldown ≥ policy duration (ALM check)
     *        3. Vault has enough free liquidity
     *        4. Vault utilization won't exceed 95%
     * @param riskType "VOLATILE" or "STABLE"
     * @param amount Coverage amount to allocate
     * @param policyDurationSeconds Policy duration (for ALM)
     * @return vault Address of chosen vault, or address(0) if none found
     */
    function _findVault(
        bytes32 riskType,
        uint256 amount,
        uint32 policyDurationSeconds
    ) internal view returns (address vault) {
        address[] storage candidates = _vaultsByRiskType[riskType];

        for (uint256 i = 0; i < candidates.length; i++) {
            address candidate = candidates[i];
            VaultRegistration storage reg = _vaults[candidate];

            // Skip inactive vaults
            if (!reg.active) continue;

            // ALM check: vault cooldown must cover policy duration
            if (reg.cooldownDuration < policyDurationSeconds) continue;

            // Check vault has physical capacity
            IVault v = IVault(candidate);
            uint256 capacity = v.availableCapacity(policyDurationSeconds);
            if (capacity < amount) continue;

            // [FIX] Pre-check 95% utilization BEFORE calling lockCollateral.
            // Without this, _findVault would pick a vault with enough free USDC
            // but lockCollateral would revert because util > 95%.
            // The revert kills the whole TX instead of spilling to the next vault.
            IVault.VaultState memory state = v.getVaultState();
            if (state.totalAssets > 0) {
                uint256 newUtilBps = ((state.allocatedAssets + amount) * BPS) / state.totalAssets;
                if (newUtilBps > MAX_UTILIZATION_BPS) continue; // Spillover to next vault
            }

            // This vault works
            return candidate;
        }

        // No vault found
        return address(0);
    }

    /**
     * @notice Calculate max allowed allocation for a product across all its vaults
     * @dev maxAllowed = product.maxAllocationBps × sum(totalAssets of matching vaults) / BPS
     */
    function _getProductMaxAllowed(bytes32 productId) internal view returns (uint256) {
        ProductRegistration storage prod = _products[productId];
        address[] storage vaultList = _vaultsByRiskType[prod.riskType];

        uint256 totalTVL = 0;
        for (uint256 i = 0; i < vaultList.length; i++) {
            totalTVL += IVault(vaultList[i]).getVaultState().totalAssets;
        }

        return (totalTVL * prod.maxAllocationBps) / BPS;
    }

    /**
     * @notice Calculate max allowed allocation for a correlation group across all vaults
     * @dev Uses the TVL of ALL vaults that serve the products in the group.
     *      [FIX] Uses set-based dedup for riskTypes instead of lastRiskType,
     *      which failed when products weren't sorted by riskType (double-counted TVL).
     */
    function _getGroupMaxAllowed(bytes32 groupId) internal view returns (uint256) {
        CorrelationGroup storage group = _correlationGroups[groupId];

        uint256 totalTVL = 0;
        bytes32[] memory seenRiskTypes = new bytes32[](group.productIds.length);
        uint256 seenCount = 0;

        for (uint256 i = 0; i < group.productIds.length; i++) {
            bytes32 rt = _products[group.productIds[i]].riskType;

            // Check if already counted this riskType
            bool alreadyCounted = false;
            for (uint256 k = 0; k < seenCount; k++) {
                if (seenRiskTypes[k] == rt) { alreadyCounted = true; break; }
            }
            if (alreadyCounted) continue;

            // Mark as seen and sum TVL
            seenRiskTypes[seenCount++] = rt;
            address[] storage vaultList = _vaultsByRiskType[rt];
            for (uint256 j = 0; j < vaultList.length; j++) {
                totalTVL += IVault(vaultList[j]).getVaultState().totalAssets;
            }
        }

        return (totalTVL * group.maxAllocationBps) / BPS;
    }

    // ═══════════════════════════════════════════════════════════
    //  UUPS
    // ═══════════════════════════════════════════════════════════

    function _authorizeUpgrade(address /* newImplementation */) internal override onlyOwner {}
}
