// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title PolicyManagerV2
/// @notice Simplified brain of Lumina V2 — no vaults, no waterfall.
/// @dev Registers products (shields), tracks active policies,
///      and coordinates with BondVault for bond issuance on trigger.
///      Owner = Gnosis Safe (TimelockController in prod).
///
///      [V5.1] UUPS upgradeable proxy pattern.

interface IBondVault {
    function issueBond(address to, uint256 usdPayout) external;
    function availableCapacityUSD() external view returns (uint256);
    function reserveCapacity(uint256 amount) external;
    function releaseReservation(uint256 amount) external;
    function commitReservation(uint256 amount) external;
}

interface IShieldV2 {
    function productId() external view returns (bytes32);
    function createPolicy(IShieldV2.CreatePolicyParams calldata params) external returns (uint256);
    function verifyAndCalculate(uint256 policyId, bytes calldata oracleProof)
        external
        returns (IShieldV2.PayoutResult memory);
    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (
            address insuredAgent,
            uint256 coverageAmount,
            uint256 premiumPaid,
            uint256 maxPayout,
            uint256 expiresAt,
            uint8 status
        );

    struct CreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        bytes extraData; // [C-1] aligned with IShield.CreatePolicyParams
    }

    struct PayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }
}

contract PolicyManagerV2 is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // ═══════ STATE ═══════
    IBondVault public bondVault;
    address public router; // only CoverRouterV2 can call

    // Product registry
    mapping(bytes32 => address) public productShield; // productId → shield address
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

    // [V5/M-RACE] Track reserved capacity per policy for release on expiry / commit on trigger
    mapping(bytes32 => mapping(uint256 => uint256)) public policyReservedUSD; // productId → policyId → reserved 18-dec USD-wei

    // ═══════ EVENTS ═══════
    event ProductRegistered(bytes32 indexed productId, address shield);
    event ProductDeactivated(bytes32 indexed productId);
    event PolicyCreated(
        bytes32 indexed productId,
        uint256 indexed policyId,
        address buyer,
        uint256 coverage,
        uint256 premium,
        uint256 payout
    );
    event PolicyTriggered(
        bytes32 indexed productId, uint256 indexed policyId, address buyer, uint256 bondAmount, bytes32 reason
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _bondVault) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

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
        uint256 payoutAmount = (coverageAmount * 8000) / 10000; // 6-dec USDC
        uint256 payoutUSD = payoutAmount / 1e6; // integer dollars
        uint256 available = bondVault.availableCapacityUSD(); // integer dollars
        if (available < payoutUSD) revert InsufficientCapacity(payoutUSD, available);

        // [V5/M-RACE] Reserve capacity IMMEDIATELY
        uint256 reservedAmount = payoutUSD * 1e18; // 18-dec USD-wei (matches BondVault units)
        bondVault.reserveCapacity(reservedAmount);

        // [M-1] CEI: increment counters BEFORE external call
        totalPolicies++;
        activePolicies++;

        // Create policy in the shield
        address shield = productShield[productId];
        policyId = IShieldV2(shield)
            .createPolicy(
                IShieldV2.CreatePolicyParams({
                    buyer: buyer,
                    coverageAmount: coverageAmount,
                    premiumAmount: premiumAmount,
                    durationSeconds: durationSeconds,
                    asset: asset,
                    stablecoin: "USDC",
                    protocol: address(0),
                    extraData: ""
                })
            );

        // Record locally (must happen after external call to obtain policyId)
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

        // [V5/M-RACE] Store reservation for release on expiry or commit on trigger
        policyReservedUSD[productId][policyId] = reservedAmount;

        emit PolicyCreated(productId, policyId, buyer, coverageAmount, premiumAmount, payoutAmount);
    }

    // ═══════ CORE: triggerPayout (called by CoverRouter) ═══════

    /// @notice Process a trigger. Verifies with shield, issues bond via BondVault.
    function triggerPayout(bytes32 productId, uint256 policyId, bytes calldata oracleProof) external onlyRouter {
        PolicyRecord storage pr = policies[productId][policyId];
        require(pr.buyer != address(0), "Policy not found");
        require(!pr.triggered, "Already triggered");
        require(!pr.expired, "Already expired");

        // [M-1] CEI: effects BEFORE interactions.
        pr.triggered = true;
        activePolicies--;
        totalTriggers++;

        // [M-6] Enforce non-zero USD payout before external call
        uint256 payoutUSD = pr.payoutAmount / 1e6;
        require(payoutUSD > 0, "Payout too small for bond issuance");
        totalBondsIssuedUSD += payoutUSD;

        // [V5/M-RACE] Commit the reservation before issuing the bond.
        uint256 reserved = policyReservedUSD[productId][policyId];
        if (reserved > 0) {
            policyReservedUSD[productId][policyId] = 0;
            bondVault.commitReservation(reserved);
        }

        // External interactions (last)
        address shield = pr.shield;
        IShieldV2.PayoutResult memory result = IShieldV2(shield).verifyAndCalculate(policyId, oracleProof);
        require(result.triggered, "Trigger not met");

        bondVault.issueBond(pr.buyer, payoutUSD);

        emit PolicyTriggered(productId, policyId, pr.buyer, payoutUSD, result.reason);
    }

    // ═══════ CORE: settlePolicy (new trigger flow) ═══════

    /// @notice Settle a policy after safety window. Called by shield or keeper.
    function settlePolicy(bytes32 productId, uint256 policyId, bool triggered) external {
        PolicyRecord storage pr = policies[productId][policyId];
        require(pr.buyer != address(0), "Policy not found");
        require(!pr.triggered, "Already triggered");
        require(!pr.expired, "Already expired");

        // Only the shield itself can call this
        require(msg.sender == pr.shield, "Only shield");

        // [V5/M-RACE] Handle reservation based on outcome
        uint256 reserved = policyReservedUSD[productId][policyId];

        if (triggered) {
            pr.triggered = true;
            activePolicies--;
            totalTriggers++;

            uint256 payoutUSD = pr.payoutAmount / 1e6;
            require(payoutUSD > 0, "Payout too small for bond issuance");
            totalBondsIssuedUSD += payoutUSD;

            // Commit reservation before issuing bond
            if (reserved > 0) {
                policyReservedUSD[productId][policyId] = 0;
                bondVault.commitReservation(reserved);
            }

            bondVault.issueBond(pr.buyer, payoutUSD);

            emit PolicyTriggered(productId, policyId, pr.buyer, payoutUSD, "SETTLED_BY_KEEPER");
        } else {
            pr.expired = true;
            activePolicies--;

            // Release reservation — capacity becomes available again
            if (reserved > 0) {
                policyReservedUSD[productId][policyId] = 0;
                bondVault.releaseReservation(reserved);
            }

            emit PolicyExpired(productId, policyId);
        }
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

        // [V5/M-RACE] Release reserved capacity
        uint256 reserved = policyReservedUSD[productId][policyId];
        if (reserved > 0) {
            policyReservedUSD[productId][policyId] = 0;
            bondVault.releaseReservation(reserved);
        }

        emit PolicyExpired(productId, policyId);
    }

    // ═══════ VIEW ═══════

    function getProductCount() external view returns (uint256) {
        return productIds.length;
    }

    function getPolicy(bytes32 productId, uint256 policyId) external view returns (PolicyRecord memory) {
        return policies[productId][policyId];
    }

    /// @notice Get all active policy IDs for a given product (for keeper iteration).
    function getActivePolicyIds(bytes32 productId, uint256 maxResults)
        external
        view
        returns (uint256[] memory policyIds_)
    {
        uint256 total = totalPolicies;
        uint256[] memory temp = new uint256[](maxResults);
        uint256 count = 0;

        for (uint256 i = 1; i <= total && count < maxResults; i++) {
            PolicyRecord storage pr = policies[productId][i];
            if (pr.buyer != address(0) && !pr.triggered && !pr.expired) {
                temp[count] = i;
                count++;
            }
        }

        policyIds_ = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            policyIds_[j] = temp[j];
        }
    }

    function getStats()
        external
        view
        returns (
            uint256 _totalPolicies,
            uint256 _activePolicies,
            uint256 _totalTriggers,
            uint256 _totalBondsIssuedUSD,
            uint256 _availableCapacity
        )
    {
        _totalPolicies = totalPolicies;
        _activePolicies = activePolicies;
        _totalTriggers = totalTriggers;
        _totalBondsIssuedUSD = totalBondsIssuedUSD;
        _availableCapacity = bondVault.availableCapacityUSD();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
