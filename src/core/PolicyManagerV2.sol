// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IPriceOracle} from "../bonds/BondVault.sol";

/// @title PolicyManagerV2
/// @notice Simplified brain of Lumina V2 — no vaults, no waterfall.
/// @dev Registers products (shields), tracks active policies,
///      and coordinates with BondVault for bond issuance on trigger.
///      Owner = Gnosis Safe (TimelockController in prod).
///
///      [V5.1] UUPS upgradeable proxy pattern.

interface IBondVault {
    /// @dev [Audit fix H-6] `priceSnapshot` is the LUMINA/USD price (18-dec)
    ///      captured at policy purchase time. BondVault uses it (instead of
    ///      the spot oracle price) to evaluate the capacity gate, so a price
    ///      drop between purchase and trigger never strands the buyer.
    function issueBond(address to, uint256 usdPayout, uint256 priceSnapshot) external;
    function availableCapacityUSD() external view returns (uint256);
    function reserveCapacity(uint256 amount) external;
    function releaseReservation(uint256 amount) external;
    function commitReservation(uint256 amount) external;
    function priceOracle() external view returns (IPriceOracle);
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

    /// @notice [Audit fix H-6] LUMINA/USD price (18-dec) at the moment a
    ///         policy was recorded. Honoured at trigger time so the buyer
    ///         always gets the bond the protocol promised, even if the
    ///         spot price has dropped enough to fail the capacity gate
    ///         that would otherwise be evaluated against `priceOracle`.
    mapping(bytes32 => mapping(uint256 => uint256)) public policyPriceSnapshot;

    // ═══════ EVENTS ═══════
    event ProductRegistered(bytes32 indexed productId, address shield);
    event ProductDeactivated(bytes32 indexed productId);
    /// @notice Emitted when a previously-deactivated product is reinstated.
    ///         Pairs with `ProductDeactivated` for full state-transition audit.
    event ProductReactivated(bytes32 indexed productId);
    /// @notice [Fix audit #27 INFO-5] Emitted when router address is updated.
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
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
        address old = router;
        router = _router;
        emit RouterUpdated(old, _router);
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

    /// @notice Reinstate a previously-deactivated product. Same authority and
    ///         immediate effect as `deactivateProduct` — no timelock. Designed
    ///         for the "false positive" case where a shield was disabled in
    ///         crisis but turns out to be safe; without this, a deactivation
    ///         is irreversible and stuck-policy holders lose their trigger
    ///         capacity permanently.
    /// @dev    Reverts if the product was never registered (so a stranger
    ///         cannot create a "fake" reactivation event for an arbitrary id)
    ///         and if the product is already active (idempotent guard, makes
    ///         operator mistakes loud rather than silent).
    function reactivateProduct(bytes32 _productId) external onlyOwner {
        require(productShield[_productId] != address(0), "Product not registered");
        require(!productActive[_productId], "Product already active");
        productActive[_productId] = true;
        emit ProductReactivated(_productId);
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

        // [Audit fix H-6] Snapshot the LUMINA price NOW so trigger time
        // can issue the bond at the price the buyer was quoted, even if
        // spot has since dropped. Captured before the reservation so a
        // zero/oracle-failure here aborts the whole purchase atomically.
        uint256 priceSnapshot = bondVault.priceOracle().getLuminaPrice();
        require(priceSnapshot > 0, "Zero price at purchase");

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

        // [Audit fix H-6] Persist the price snapshot keyed by policyId so
        // it is available to triggerPayout / settlePolicy.
        policyPriceSnapshot[productId][policyId] = priceSnapshot;

        emit PolicyCreated(productId, policyId, buyer, coverageAmount, premiumAmount, payoutAmount);
    }

    // ═══════ CORE: triggerPayout (called by CoverRouter) ═══════

    /// @notice Process a trigger. Verifies with shield, issues bond via BondVault.
    /// @dev    [Audit V5.1 fix H-5] Reverts if the product was deactivated.
    ///         `deactivateProduct` only blocks NEW policies in `recordPolicy`,
    ///         so without this check an admin who disables a buggy shield
    ///         could not stop already-issued policies from being triggered
    ///         fraudulently. Per founder decision, leaving holders with a
    ///         non-payable but un-exploitable policy ("stuck > drained") is
    ///         the desired outcome — bonds already minted in BondVault are
    ///         unaffected and remain redeemable. The companion
    ///         `reactivateProduct` flow (added in h5-followup) lets an
    ///         admin restore the product without re-deploying.
    function triggerPayout(bytes32 productId, uint256 policyId, bytes calldata oracleProof) external onlyRouter {
        if (!productActive[productId]) revert ProductNotActive(productId);

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

        bondVault.issueBond(pr.buyer, payoutUSD, _resolvePriceSnapshot(productId, policyId));

        emit PolicyTriggered(productId, policyId, pr.buyer, payoutUSD, result.reason);
    }

    /// @dev [Audit fix H-6] Returns the LUMINA price snapshot stored for
    ///      a policy at purchase, falling back to the live oracle price
    ///      for any pre-fix policy that was created before this mapping
    ///      existed. The fallback keeps the upgrade backwards-compatible
    ///      and never reverts on legacy state. New policies always have
    ///      a non-zero snapshot, so the fallback is dormant in practice.
    function _resolvePriceSnapshot(bytes32 productId, uint256 policyId) internal view returns (uint256) {
        uint256 snap = policyPriceSnapshot[productId][policyId];
        if (snap == 0) {
            return bondVault.priceOracle().getLuminaPrice();
        }
        return snap;
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

            bondVault.issueBond(pr.buyer, payoutUSD, _resolvePriceSnapshot(productId, policyId));

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
    /// @dev [Audit fix H-6] Reduced from 50 to 49 to make room for
    ///      `policyPriceSnapshot`. Storage layout remains UUPS-safe:
    ///      the new mapping consumes one logical slot that was previously
    ///      part of the gap, so any V5.1 deployment can upgrade without
    ///      shifting any pre-existing storage variable.
    uint256[49] private __gap;
}
