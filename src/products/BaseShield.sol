// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "../interfaces/IShield.sol";
import {IOracle} from "../interfaces/IOracle.sol";

/**
 * @title BaseShield
 * @author Lumina Protocol
 * @notice Abstract base for ALL Shield products. Handles:
 *         - Policy storage & lifecycle (create, mark, query)
 *         - onlyRouter access control
 *         - Oracle signature verification helper
 *         - Counters: totalPolicies, activePolicies, totalActiveCoverage
 *
 *         Each concrete Shield overrides:
 *           _doCreatePolicy()      — product-specific storage (strikePrice, stablecoin, etc.)
 *           _doVerifyAndCalculate() — trigger logic + payout calculation
 *           Metadata: productId, riskType, maxAllocationBps, durationRange, waitingPeriod
 *
 * @dev NOT upgradeable. If a Shield needs changes → deploy new, re-register in Router.
 *      Gas-optimized for M2M: bytes32 reasons, no strings, immutables where possible.
 */
abstract contract BaseShield is IShield {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    /// @notice Grace period after expiry for agents to submit claims on-chain.
    ///         The oracle event (verifiedAt) must have occurred DURING coverage,
    ///         but the on-chain TX can arrive up to CLAIM_GRACE_PERIOD after expiry.
    ///         [FIX] Addresses race condition: crash 5 min before expiry → oracle
    ///         needs time for TWAP → agent TX lands after expiresAt.
    ///         [FIX R2] Changed from 1h to 24h: L2 sequencer downtime during
    ///         catastrophic events (Base, Arbitrum precedent) can block TXs for hours.
    ///         24h costs nothing (capital already in _allocatedAssets) but saves UX.
    uint256 public constant CLAIM_GRACE_PERIOD = 24 hours;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS (additional)
    // ═══════════════════════════════════════════════════════════

    /// @notice [FIX] Proper error for zero address in constructor (was reusing OnlyRouter)
    error ZeroAddress(string param);

    /// @notice [FIX] Oracle event occurred after policy expiry (not during coverage)
    error EventAfterExpiry(uint256 policyId, uint256 verifiedAt, uint256 expiresAt);

    // ═══════════════════════════════════════════════════════════
    //  IMMUTABLES
    // ═══════════════════════════════════════════════════════════

    /// @notice CoverRouter — the ONLY caller for lifecycle functions
    address public immutable router;

    /// @notice Oracle contract for signature verification
    address public immutable oracle;

    // ═══════════════════════════════════════════════════════════
    //  STORAGE
    // ═══════════════════════════════════════════════════════════

    /// @dev Core policy data conforming to IShield.PolicyInfo
    struct CorePolicy {
        address insuredAgent;
        uint256 coverageAmount;     // 6 decimals (USDC scale)
        uint256 premiumPaid;
        uint256 maxPayout;
        uint256 startTimestamp;
        uint256 waitingEndsAt;
        uint256 expiresAt;
        uint256 cleanupAt;
        bool finalized;             // true once PAID_OUT or EXPIRED
        PolicyStatus finalStatus;   // only meaningful when finalized == true
    }

    mapping(uint256 => CorePolicy) internal _policies;
    uint256 private _policyCounter;
    uint256 private _activePolicies;
    uint256 private _totalActiveCoverage;

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor(address router_, address oracle_) {
        if (router_ == address(0)) revert ZeroAddress("router");
        if (oracle_ == address(0)) revert ZeroAddress("oracle");
        router = router_;
        oracle = oracle_;
    }

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyRouter() {
        if (msg.sender != router) revert OnlyRouter();
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  POLICY LIFECYCLE — called by CoverRouter only
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IShield
    function createPolicy(
        CreatePolicyParams calldata params
    ) external onlyRouter returns (uint256 policyId) {
        // Validate duration
        (uint32 minD, uint32 maxD) = this.durationRange();
        if (params.durationSeconds < minD || params.durationSeconds > maxD) {
            revert DurationOutOfRange(params.durationSeconds, minD, maxD);
        }

        // Validate coverage
        if (params.coverageAmount < _minCoverage()) {
            revert CoverageOutOfRange(params.coverageAmount, _minCoverage(), type(uint256).max);
        }

        // Generate policyId (1-indexed)
        unchecked { _policyCounter++; }
        policyId = _policyCounter;

        // Compute maxPayout (product-specific)
        uint256 maxPay = _calculateMaxPayout(params.coverageAmount, params);

        // Compute timestamps
        uint32 wp = this.waitingPeriod();
        uint256 waitEnds = block.timestamp + wp;
        uint256 expires = waitEnds + params.durationSeconds;
        uint256 cleanup = _calculateCleanupAt(expires);

        // Store core policy
        _policies[policyId] = CorePolicy({
            insuredAgent: params.buyer,
            coverageAmount: params.coverageAmount,
            premiumPaid: params.premiumAmount,
            maxPayout: maxPay,
            startTimestamp: block.timestamp,
            waitingEndsAt: waitEnds,
            expiresAt: expires,
            cleanupAt: cleanup,
            finalized: false,
            finalStatus: PolicyStatus.NONEXISTENT
        });

        // Let concrete Shield store product-specific data
        _doCreatePolicy(policyId, params);

        // Update counters
        _activePolicies++;
        _totalActiveCoverage += params.coverageAmount;

        emit PolicyCreated(
            policyId, params.buyer, params.coverageAmount,
            params.premiumAmount, params.durationSeconds, waitEnds, expires
        );
    }

    /// @inheritdoc IShield
    function verifyAndCalculate(
        uint256 policyId,
        bytes calldata oracleProof
    ) external onlyRouter returns (PayoutResult memory result) {
        CorePolicy storage cp = _policies[policyId];
        if (cp.insuredAgent == address(0)) revert PolicyNotFound(policyId);
        if (cp.finalized) {
            revert InvalidPolicyStatus(policyId, cp.finalStatus, PolicyStatus.ACTIVE);
        }

        PolicyStatus current = _computeStatus(cp);

        // Product-specific status check (IL Index requires SETTLEMENT, others require ACTIVE)
        _validateStatusForTrigger(policyId, current);

        // Delegate to concrete Shield
        result = _doVerifyAndCalculate(policyId, oracleProof);

        // Enforce maxPayout cap
        if (result.payoutAmount > cp.maxPayout) {
            result.payoutAmount = cp.maxPayout;
        }

        // Enforce recipient = insuredAgent
        result.recipient = cp.insuredAgent;
    }

    /// @inheritdoc IShield
    function markPaidOut(uint256 policyId) external onlyRouter {
        CorePolicy storage cp = _policies[policyId];
        if (cp.insuredAgent == address(0)) revert PolicyNotFound(policyId);
        if (cp.finalized) {
            revert InvalidPolicyStatus(policyId, cp.finalStatus, PolicyStatus.ACTIVE);
        }

        cp.finalized = true;
        cp.finalStatus = PolicyStatus.PAID_OUT;

        _activePolicies--;
        _totalActiveCoverage -= cp.coverageAmount;

        // Product-specific cleanup hook (e.g., ExploitShield wallet tracking)
        _afterFinalize(policyId, cp);

        emit PolicyPaidOut(policyId, cp.insuredAgent, cp.maxPayout, "PAID_OUT");
    }

    /// @inheritdoc IShield
    function markExpired(uint256 policyId) external onlyRouter {
        CorePolicy storage cp = _policies[policyId];
        if (cp.insuredAgent == address(0)) revert PolicyNotFound(policyId);
        if (cp.finalized) {
            revert InvalidPolicyStatus(policyId, cp.finalStatus, PolicyStatus.ACTIVE);
        }

        cp.finalized = true;
        cp.finalStatus = PolicyStatus.EXPIRED;

        _activePolicies--;
        _totalActiveCoverage -= cp.coverageAmount;

        // Product-specific cleanup hook
        _afterFinalize(policyId, cp);

        emit PolicyExpired(policyId);
    }

    // ═══════════════════════════════════════════════════════════
    //  QUERIES
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IShield
    function getPolicyInfo(uint256 policyId) external view returns (PolicyInfo memory info) {
        CorePolicy storage cp = _policies[policyId];
        if (cp.insuredAgent == address(0)) revert PolicyNotFound(policyId);

        info = PolicyInfo({
            policyId: policyId,
            insuredAgent: cp.insuredAgent,
            coverageAmount: cp.coverageAmount,
            premiumPaid: cp.premiumPaid,
            maxPayout: cp.maxPayout,
            startTimestamp: cp.startTimestamp,
            waitingEndsAt: cp.waitingEndsAt,
            expiresAt: cp.expiresAt,
            cleanupAt: cp.cleanupAt,
            status: getPolicyStatus(policyId)
        });
    }

    /// @inheritdoc IShield
    function getPolicyStatus(uint256 policyId) public view returns (PolicyStatus) {
        CorePolicy storage cp = _policies[policyId];
        if (cp.insuredAgent == address(0)) return PolicyStatus.NONEXISTENT;
        if (cp.finalized) return cp.finalStatus;
        return _computeStatus(cp);
    }

    /// @inheritdoc IShield
    function totalPolicies() external view returns (uint256) { return _policyCounter; }

    /// @inheritdoc IShield
    function activePolicies() external view returns (uint256) { return _activePolicies; }

    /// @inheritdoc IShield
    function totalActiveCoverage() external view returns (uint256) { return _totalActiveCoverage; }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — STATUS COMPUTATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Status computation for non-finalized policies.
     *
     *      TIMELINE:
     *        |---WAITING---|--------ACTIVE--------|--GRACE PERIOD (24h)--|--EXPIRED-->
     *                      waitingEndsAt    expiresAt          cleanupAt
     *
     *      IMPORTANT: For Router compatibility, non-finalized policies past expiresAt
     *      return ACTIVE (not EXPIRED). This allows:
     *        1. Agents to submit late claims during CLAIM_GRACE_PERIOD (24h)
     *        2. Router.cleanupExpiredPolicy() to work (requires ACTIVE || SETTLEMENT)
     *
     *      Safety is enforced at two levels:
     *        - _validateStatusForTrigger: rejects claims after cleanupAt
     *        - Each Shield's _doVerifyAndCalculate: checks verifiedAt is in-coverage
     *
     *      IL Index: uses SETTLEMENT status (48h window) instead of ACTIVE grace.
     */
    function _computeStatus(CorePolicy storage cp) internal view returns (PolicyStatus) {
        if (block.timestamp < cp.waitingEndsAt) return PolicyStatus.WAITING;
        if (block.timestamp < cp.expiresAt) return PolicyStatus.ACTIVE;
        // IL Index: between expiresAt and cleanupAt → SETTLEMENT
        if (_hasSettlementWindow() && block.timestamp < cp.cleanupAt) {
            return PolicyStatus.SETTLEMENT;
        }
        // Expired but not finalized → return ACTIVE for Router cleanup compatibility
        return PolicyStatus.ACTIVE;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — ORACLE VERIFICATION HELPER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Verify an oracle-signed proof
     * @param dataHash keccak256 of the encoded data
     * @param signature Oracle signature over dataHash
     * @return true if signature is from the authorized oracle key
     */
    function _verifyOracleSignature(
        bytes32 dataHash,
        bytes memory signature
    ) internal view returns (bool) {
        address signer = IOracle(oracle).verifySignature(dataHash, signature);
        return signer == IOracle(oracle).oracleKey();
    }

    // ═══════════════════════════════════════════════════════════
    //  ABSTRACT — PRODUCT-SPECIFIC (must override)
    // ═══════════════════════════════════════════════════════════

    /// @dev Store product-specific data (strikePrice, stablecoin, etc.)
    function _doCreatePolicy(uint256 policyId, CreatePolicyParams calldata params) internal virtual;

    /// @dev Verify trigger + calculate payout. Must set triggered, payoutAmount, reason.
    function _doVerifyAndCalculate(
        uint256 policyId,
        bytes calldata oracleProof
    ) internal virtual returns (PayoutResult memory);

    /// @dev Calculate maxPayout for this product (e.g., coverage * 80% for BSS)
    function _calculateMaxPayout(
        uint256 coverageAmount,
        CreatePolicyParams calldata params
    ) internal view virtual returns (uint256);

    /// @dev Return cleanupAt. Default: expiresAt + CLAIM_GRACE_PERIOD.
    ///      [FIX] Grace period prevents bots from cleaning up before agents can claim
    ///      events that occurred near expiry. IL Index overrides with 48h settlement.
    function _calculateCleanupAt(uint256 expiresAt) internal view virtual returns (uint256) {
        return expiresAt + CLAIM_GRACE_PERIOD;
    }

    /// @dev Whether this product has a settlement window (IL Index: true, others: false)
    function _hasSettlementWindow() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev Minimum coverage in USDC (6 decimals). Default: $100 = 100e6
    function _minCoverage() internal pure virtual returns (uint256) {
        return 100e6;
    }

    /// @dev Hook called after a policy is finalized (paid out or expired).
    ///      Override for product-specific cleanup (e.g., ExploitShield wallet coverage release).
    function _afterFinalize(uint256 policyId, CorePolicy storage cp) internal virtual {
        // Default: no-op. Suppress unused variable warnings.
        policyId;
        cp;
    }

    /// @dev Validate status is correct for triggering.
    ///      [FIX] Changed from `block.timestamp < expiresAt` to `block.timestamp < cleanupAt`.
    ///      This creates a CLAIM_GRACE_PERIOD (24h) after expiry where agents can still submit
    ///      claims for events that occurred during coverage. Each Shield's _doVerifyAndCalculate
    ///      MUST verify `verifiedAt <= expiresAt` to ensure the event was during coverage.
    ///
    ///      Timeline: |---WAITING---|--------ACTIVE--------|--GRACE (24h)--|--CLEANUP-->
    ///                              waitingEndsAt    expiresAt    cleanupAt
    ///
    ///      IL Index overrides: requires SETTLEMENT status (48h window replaces grace).
    /// @dev [H-5] The dual check (status == ACTIVE && timestamp < cleanupAt) is intentional.
    ///      _computeStatus returns ACTIVE for expired-but-not-finalized policies (for Router
    ///      compatibility), so the cleanupAt check is the actual temporal boundary.
    ///      Both checks are needed: status prevents finalized policies, cleanupAt prevents stale claims.
    function _validateStatusForTrigger(uint256 policyId, PolicyStatus current) internal view virtual {
        if (current != PolicyStatus.ACTIVE) {
            revert InvalidPolicyStatus(policyId, current, PolicyStatus.ACTIVE);
        }
        // Allow claims during grace period (expiresAt → cleanupAt)
        // but reject after grace period ends
        CorePolicy storage cp = _policies[policyId];
        if (block.timestamp >= cp.cleanupAt) {
            revert InvalidPolicyStatus(policyId, PolicyStatus.EXPIRED, PolicyStatus.ACTIVE);
        }
    }
}
