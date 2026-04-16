// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PolicyManagerV2
/// @notice Simplified brain of Lumina V2 — no vaults, no waterfall.
/// @dev Registers products (shields), tracks active policies,
///      and coordinates with BondVault for bond issuance on trigger.
///      Owner = Gnosis Safe (TimelockController in prod).

interface IBondVault {
    function issueBond(address to, uint256 usdPayout) external;
    function availableCapacityUSD() external view returns (uint256);
}

interface IShieldV2 {
    function productId() external view returns (bytes32);
    function createPolicy(IShieldV2.CreatePolicyParams calldata params) external returns (uint256);
    function verifyAndCalculate(uint256 policyId, bytes calldata oracleProof)
        external returns (IShieldV2.PayoutResult memory);
    function getPolicyInfo(uint256 policyId) external view returns (
        address insuredAgent, uint256 coverageAmount, uint256 premiumPaid,
        uint256 maxPayout, uint256 expiresAt, uint8 status
    );

    struct CreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        uint256 deadline;
        uint256 nonce;
    }

    struct PayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }
}

contract PolicyManagerV2 is Ownable {
    // ═══════ STATE ═══════
    IBondVault public bondVault;
    address public router; // only CoverRouterV2 can call

    // Product registry
    mapping(bytes32 => address) public productShield;  // productId → shield address
    mapping(bytes32 => bool) public productActive;
    bytes32[] public productIds;

    // Policy tracking
    uint256 public totalPolicies;
    uint256 public activePolicies;
    uint256 public totalTriggers;
    uint256 public totalBondsIssuedUSD;

    // Policy → product mapping (for trigger routing)
    struct PolicyRecord {
        bytes32 productId;
        address shield;
        address buyer;
        uint256 coverageAmount;
        uint256 payoutAmount; // coverage × 80%
        uint256 premiumPaid;
        uint256 createdAt;
        uint256 expiresAt;
        bool triggered;
        bool expired;
    }
    mapping(bytes32 => mapping(uint256 => PolicyRecord)) public policies; // productId → policyId → record

    // ═══════ EVENTS ═══════
    event ProductRegistered(bytes32 indexed productId, address shield);
    event ProductDeactivated(bytes32 indexed productId);
    event PolicyCreated(
        bytes32 indexed productId, uint256 indexed policyId,
        address buyer, uint256 coverage, uint256 premium, uint256 payout
    );
    event PolicyTriggered(
        bytes32 indexed productId, uint256 indexed policyId,
        address buyer, uint256 bondAmount, bytes32 reason
    );
    event PolicyExpired(bytes32 indexed productId, uint256 indexed policyId);

    // ═══════ ERRORS ═══════
    error OnlyRouter();
    error ProductNotFound(bytes32 productId);
    error ProductNotActive(bytes32 productId);
    error InsufficientCapacity(uint256 required, uint256 available);

    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    constructor(address _bondVault) Ownable(msg.sender) {
        require(_bondVault != address(0), "Zero bondVault");
        bondVault = IBondVault(_bondVault);
    }

    // ═══════ ADMIN ═══════

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero router");
        router = _router;
    }

    function registerProduct(bytes32 _productId, address _shield) external onlyOwner {
        require(_shield != address(0), "Zero shield");
        productShield[_productId] = _shield;
        productActive[_productId] = true;
        productIds.push(_productId);
        emit ProductRegistered(_productId, _shield);
    }

    function deactivateProduct(bytes32 _productId) external onlyOwner {
        productActive[_productId] = false;
        emit ProductDeactivated(_productId);
    }

    // ═══════ CORE: recordPolicy (called by CoverRouter) ═══════

    /// @notice Record a new policy. Called by CoverRouterV2 after receiving premium.
    /// @return policyId The ID of the newly created policy within the shield
    function recordPolicy(
        bytes32 productId,
        address buyer,
        uint256 coverageAmount,
        uint256 premiumAmount,
        uint32 durationSeconds,
        bytes32 asset
    ) external onlyRouter returns (uint256 policyId) {
        if (productShield[productId] == address(0)) revert ProductNotFound(productId);
        if (!productActive[productId]) revert ProductNotActive(productId);

        // Check BondVault capacity (can we back this policy if it triggers?)
        uint256 payoutAmount = (coverageAmount * 8000) / 10000; // 80% payout
        uint256 available = bondVault.availableCapacityUSD();
        if (available < payoutAmount) revert InsufficientCapacity(payoutAmount, available);

        // Create policy in the shield
        address shield = productShield[productId];
        policyId = IShieldV2(shield).createPolicy(
            IShieldV2.CreatePolicyParams({
                buyer: buyer,
                coverageAmount: coverageAmount,
                premiumAmount: premiumAmount,
                durationSeconds: durationSeconds,
                asset: asset,
                stablecoin: "USDC",
                protocol: address(0),
                deadline: block.timestamp + 300, // 5 min
                nonce: totalPolicies + 1
            })
        );

        // Record locally
        uint256 expiresAt = block.timestamp + durationSeconds;
        policies[productId][policyId] = PolicyRecord({
            productId: productId,
            shield: shield,
            buyer: buyer,
            coverageAmount: coverageAmount,
            payoutAmount: payoutAmount,
            premiumPaid: premiumAmount,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            triggered: false,
            expired: false
        });

        totalPolicies++;
        activePolicies++;

        emit PolicyCreated(productId, policyId, buyer, coverageAmount, premiumAmount, payoutAmount);
    }

    // ═══════ CORE: triggerPayout (called by CoverRouter) ═══════

    /// @notice Process a trigger. Verifies with shield, issues bond via BondVault.
    /// @param productId The product
    /// @param policyId The policy within that product's shield
    /// @param oracleProof Oracle-signed proof of the trigger event
    function triggerPayout(
        bytes32 productId,
        uint256 policyId,
        bytes calldata oracleProof
    ) external onlyRouter {
        PolicyRecord storage pr = policies[productId][policyId];
        require(pr.buyer != address(0), "Policy not found");
        require(!pr.triggered, "Already triggered");
        require(!pr.expired, "Already expired");

        // Verify trigger with the shield
        address shield = pr.shield;
        IShieldV2.PayoutResult memory result = IShieldV2(shield).verifyAndCalculate(policyId, oracleProof);

        require(result.triggered, "Trigger not met");

        // Mark as triggered
        pr.triggered = true;
        activePolicies--;
        totalTriggers++;

        // Issue bond via BondVault (payout is in USD)
        // Convert from USDC 6 decimals to whole USD for BondVault
        uint256 payoutUSD = pr.payoutAmount / 1e6;
        bondVault.issueBond(pr.buyer, payoutUSD);
        totalBondsIssuedUSD += payoutUSD;

        emit PolicyTriggered(productId, policyId, pr.buyer, payoutUSD, result.reason);
    }

    // ═══════ CORE: markExpired ═══════

    /// @notice Mark a policy as expired (no trigger within window).
    function markExpired(bytes32 productId, uint256 policyId) external {
        PolicyRecord storage pr = policies[productId][policyId];
        require(pr.buyer != address(0), "Policy not found");
        require(!pr.triggered, "Already triggered");
        require(!pr.expired, "Already expired");
        require(block.timestamp > pr.expiresAt, "Not expired yet");

        pr.expired = true;
        activePolicies--;
        emit PolicyExpired(productId, policyId);
    }

    // ═══════ VIEW ═══════

    function getProductCount() external view returns (uint256) {
        return productIds.length;
    }

    function getPolicy(bytes32 productId, uint256 policyId) external view returns (PolicyRecord memory) {
        return policies[productId][policyId];
    }

    function getStats() external view returns (
        uint256 _totalPolicies,
        uint256 _activePolicies,
        uint256 _totalTriggers,
        uint256 _totalBondsIssuedUSD,
        uint256 _availableCapacity
    ) {
        _totalPolicies = totalPolicies;
        _activePolicies = activePolicies;
        _totalTriggers = totalTriggers;
        _totalBondsIssuedUSD = totalBondsIssuedUSD;
        _availableCapacity = bondVault.availableCapacityUSD();
    }
}
