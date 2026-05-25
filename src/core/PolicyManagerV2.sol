// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ChainGuard} from "../utils/ChainGuard.sol";

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
    /// @notice [Sprint Cleanup] Emitted when a productId is removed from `productIds[]`.
    ///         Does NOT clear `productShield` or `productActive` mappings — those
    ///         persist (and `productActive` should already be `false`). Used for
    ///         array cleanup of duplicates that accumulated through repeated
    ///         `registerProduct` calls (the function is append-only by design).
    event ProductRemoved(bytes32 indexed productId);
    /// @notice [Fix audit #27 INFO-5] Emitted when router address is updated.
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    /// @notice [Sprint V-A] Emitted when bondVault address is updated.
    event BondVaultUpdated(address indexed oldVault, address indexed newVault);
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
    /// @notice [F-03 fix] markExpired refused to finalize-as-untriggered because
    ///         a fresh shield evaluation reverted as oracle-unavailable. The
    ///         policy stays pending; retry once the oracle/sequencer recovers.
    error OracleUnavailableRetry(bytes32 productId, uint256 policyId);
    /// @notice [F-03 fix] markExpired refused to finalize-as-untriggered because
    ///         a fresh shield evaluation reports the policy DID trigger. Route
    ///         the settlement through the trigger path (submitTrigger /
    ///         checkAndSettlePolicy) instead of expiring it.
    error PolicyTriggerable(bytes32 productId, uint256 policyId);

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

    /// @notice [Sprint V-A, ADR-013] Re-wire BondVault address post-deploy.
    /// @dev Permanent setter so the proxy can migrate to a new vault without
    ///      an impl upgrade. Restricted to owner; mainnet owner is a
    ///      Gnosis Safe (TimelockController in prod). Zero address rejected.
    function setBondVault(address _bondVault) external onlyOwner {
        require(_bondVault != address(0), "Zero bondVault");
        address old = address(bondVault);
        bondVault = IBondVault(_bondVault);
        emit BondVaultUpdated(old, _bondVault);
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

    /// @notice [Sprint Cleanup] Remove every occurrence of `productId` from
    ///         `productIds[]` via swap-and-pop. Mappings `productShield` and
    ///         `productActive` are NOT touched — callers should `deactivateProduct`
    ///         first if they want to disable purchases, then `removeProduct`
    ///         to compact the array.
    /// @dev    Cleans up duplicates that accumulated when `registerProduct` was
    ///         called multiple times for the same `productId` (append-only push).
    ///         Owner-only; reverts if no occurrence of `productId` is found.
    function removeProduct(bytes32 productId) external onlyOwner {
        _removeProduct(productId);
    }

    /// @notice [Sprint Cleanup] Batch version of `removeProduct`. Each entry is
    ///         processed independently; if ANY entry is not in the array the
    ///         whole call reverts (no partial cleanup).
    function removeProductBatch(bytes32[] calldata _productIds) external onlyOwner {
        for (uint256 i = 0; i < _productIds.length; i++) {
            _removeProduct(_productIds[i]);
        }
    }

    /// @dev Internal swap-and-pop that strips every occurrence of `productId`
    ///      from `productIds[]`. Reverts if zero occurrences. Single
    ///      `ProductRemoved` event per call (regardless of how many duplicates
    ///      were removed) — the event signals intent, not multiplicity.
    function _removeProduct(bytes32 productId) internal {
        uint256 length = productIds.length;
        bool found = false;
        uint256 i = 0;
        while (i < length) {
            if (productIds[i] == productId) {
                productIds[i] = productIds[length - 1];
                productIds.pop();
                length--;
                found = true;
                // do NOT advance i — recheck this slot, which now holds the
                // formerly-last element (which itself could be a duplicate).
            } else {
                i++;
            }
        }
        require(found, "PM: productId not in array");
        emit ProductRemoved(productId);
    }

    // ═══════ CORE: recordPolicy (called by CoverRouter) ═══════

    /// @notice Record a new policy. Called by CoverRouterV2 after receiving premium.
    /// @notice Uses integer-dollar capacity model for gas efficiency.
    /// @dev Precision tradeoff intentional: capacity is rounded to whole USD units.
    ///      `coverageAmount` is 6-dec USDC; `payoutAmount = coverage * 80%`; the
    ///      `payoutUSD = payoutAmount / 1e6` truncation drops sub-dollar
    ///      fractions. Reservation is then re-scaled to 18-dec USD-wei
    ///      (`payoutUSD * 1e18`) so BondVault keeps unit consistency. The
    ///      truncation is bounded above by $1 per policy and is acceptable for
    ///      capacity bookkeeping — see ADR-017 (Sprint Y) for rationale.
    /// @return policyId The ID of the newly created policy within the shield
    function recordPolicy(
        bytes32 productId,
        address buyer,
        uint256 coverageAmount,
        uint256 premiumAmount,
        uint32 durationSeconds,
        bytes32 asset
    ) external onlyRouter returns (uint256 policyId) {
        ChainGuard.requireValidChain();
        if (productShield[productId] == address(0)) revert ProductNotFound(productId);
        if (!productActive[productId]) revert ProductNotActive(productId);

        // Check BondVault capacity (can we back this policy if it triggers?)
        uint256 payoutAmount = (coverageAmount * 8000) / 10000; // 6-dec USDC
        uint256 payoutUSD = payoutAmount / 1e6; // integer dollars
        // [MR-L01 fix] Fail fast if the integer-dollar truncation collapses the
        // payout to zero. A policy recorded with payoutUSD == 0 reserves no
        // capacity and can never issue a bond on trigger (triggerPayout /
        // settlePolicy both require payoutUSD > 0), leaving an un-settleable
        // policy on-chain. Reject it here, before any state change / external
        // call, so every recorded policy is always settleable.
        require(payoutUSD > 0, "PM: payout truncates to zero");
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
    /// @notice Uses integer-dollar capacity model for gas efficiency.
    /// @dev Precision tradeoff intentional: bond face value is rounded to
    ///      whole USD units via `payoutUSD = payoutAmount / 1e6`. Sub-dollar
    ///      fractions are truncated. The previously stored reservation is in
    ///      18-dec USD-wei and is committed verbatim to BondVault so the
    ///      capacity bookkeeping stays consistent across the lifecycle. See
    ///      ADR-017 (Sprint Y).
    function triggerPayout(bytes32 productId, uint256 policyId, bytes calldata oracleProof) external onlyRouter {
        ChainGuard.requireValidChain();
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
    /// @notice Uses integer-dollar capacity model for gas efficiency.
    /// @dev See `triggerPayout` and ADR-017 (Sprint Y) for the truncation
    ///      tradeoff. On settle-with-trigger, the same `/1e6` truncation
    ///      applies; on settle-without-trigger the reservation is released
    ///      in full at the stored 18-dec USD-wei precision.
    function settlePolicy(bytes32 productId, uint256 policyId, bool triggered) external {
        ChainGuard.requireValidChain();
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
    /// @dev    [F-03 fix] A policy may only be finalized-as-untriggered when a
    ///         FRESH shield evaluation confirms the oracle was usable during the
    ///         window AND reports no trigger. Previously this finalized blindly
    ///         on `block.timestamp > expiresAt`, so a policy whose oracle was
    ///         unavailable during a true depeg could be expired with no payout
    ///         (silent loss for the insured).
    ///
    ///         New flow:
    ///         - Call the shield's `verifyAndCalculate`. The flash shields
    ///           settle false ONLY when the oracle is evaluable under the
    ///           settlement-staleness tolerance; otherwise they revert
    ///           `ORACLE_UNAVAILABLE`.
    ///         - If evaluation reverts oracle-unavailable → revert
    ///           `OracleUnavailableRetry`; the policy stays pending for retry
    ///           once the feed/sequencer recovers (NOT silently expired).
    ///         - If evaluation reports `triggered == true` → revert
    ///           `PolicyTriggerable`; settlement must go through the trigger
    ///           path so the bond is issued (markExpired must never bury a
    ///           genuine trigger).
    ///         - Only if evaluation succeeds with no trigger do we finalize as
    ///           expired and release the reservation.
    ///
    ///         Signature unchanged. Permissionless like before — the safety
    ///         comes from the oracle gate, not the caller set. Reentrancy is a
    ///         non-issue: effects (`expired`, `activePolicies`, reservation
    ///         clear) precede the only external call (`releaseReservation`),
    ///         and the shield evaluation is a finalizing call guarded by the
    ///         shield's own `ALREADY_FINALIZED` check.
    function markExpired(bytes32 productId, uint256 policyId) external {
        PolicyRecord storage pr = policies[productId][policyId];
        require(pr.buyer != address(0), "Policy not found");
        require(!pr.triggered, "Already triggered");
        require(!pr.expired, "Already expired");
        require(block.timestamp > pr.expiresAt, "Not expired yet");

        // [F-03 fix] Gate on a fresh shield evaluation. The shield reverts
        // ORACLE_UNAVAILABLE (or oracle-staleness reasons) when it cannot prove
        // the window outcome; in that case we MUST NOT finalize-as-untriggered.
        //
        // [MR-L03 note] This gate call is STATE-MUTATING on the shield
        // (`verifyAndCalculate` finalizes the policy on a trigger). Correctness of
        // the `result.triggered` branch below relies on TX-ATOMIC ROLLBACK: when we
        // `revert PolicyTriggerable`, the shield's finalization is rolled back with
        // it, so the policy stays settleable via the trigger path. DO NOT refactor
        // this into a low-level call that swallows the inner error — doing so would
        // leave the shield finalized while the PM record stays open, stranding the
        // reservation. A future hardening is a dedicated side-effect-free view probe
        // on the shield; until then, the atomicity requirement is load-bearing.
        address shield = pr.shield;
        try IShieldV2(shield).verifyAndCalculate(policyId, "") returns (IShieldV2.PayoutResult memory result) {
            if (result.triggered) {
                // A genuine trigger exists — do not bury it under an expiry.
                revert PolicyTriggerable(productId, policyId);
            }
            // Evaluation succeeded with no trigger: safe to finalize-untriggered.
        } catch Error(string memory reason) {
            if (_isOracleUnavailable(reason)) {
                revert OracleUnavailableRetry(productId, policyId);
            }
            // Any other string revert is unexpected for an expired-window
            // evaluation; surface it rather than silently expiring.
            revert(reason);
        } catch (bytes memory) {
            // Non-string (custom error / panic) revert: treat conservatively as
            // not-evaluable and leave the policy pending for retry.
            revert OracleUnavailableRetry(productId, policyId);
        }

        // [M-1] CEI: effects before the external releaseReservation interaction.
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

    /// @dev [F-03 fix] Matches the shield's oracle-unavailability revert reasons.
    ///      Kept permissive across the family the shields stream emits
    ///      (`ORACLE_UNAVAILABLE`, `ORACLE_STALE`, `SEQUENCER_DOWN`) so a feed
    ///      outage during the window can never finalize a policy as untriggered.
    function _isOracleUnavailable(string memory reason) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(reason));
        return h == keccak256(bytes("ORACLE_UNAVAILABLE")) || h == keccak256(bytes("ORACLE_STALE"))
            || h == keccak256(bytes("SEQUENCER_DOWN"));
    }

    // ═══════ VIEW ═══════

    function getProductCount() external view returns (uint256) {
        return productIds.length;
    }

    function getPolicy(bytes32 productId, uint256 policyId) external view returns (PolicyRecord memory) {
        return policies[productId][policyId];
    }

    /// @notice Get all active policy IDs for a given product (for keeper iteration).
    /// @dev [MR-L02] The loop uses the GLOBAL `totalPolicies` as a loose upper
    ///      bound on the per-product policyId space. This is correct only
    ///      because per-product policyIds are dense and 1-based (the shield's
    ///      `createPolicy` assigns sequential ids starting at 1), so every valid
    ///      id for `productId` falls within `[1, totalPolicies]`. The bound is
    ///      intentionally loose: it over-scans slots belonging to other products
    ///      (which read back as empty `PolicyRecord`s and are skipped). A future
    ///      per-product active-count / per-product id counter would give a
    ///      tighter, cheaper bound. Logic is unchanged here.
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
