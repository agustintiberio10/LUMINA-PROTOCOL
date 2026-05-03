// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IShield} from "../interfaces/IShield.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IOracleV2} from "../interfaces/IOracleV2.sol";

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
 * @dev [V5.1] UUPS upgradeable proxy pattern. Each concrete Shield deploys behind a proxy.
 */
abstract contract BaseShield is Initializable, UUPSUpgradeable, OwnableUpgradeable, IShield {
    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 public constant CLAIM_GRACE_PERIOD = 24 hours;
    uint256 public constant SAFETY_WINDOW = 24 hours;

    /// @notice [Audit fix H-13] Hard cap on the grace extension granted
    ///         at trigger time when sequencer / Chainlink were down.
    ///         Without this cap, a malformed oracle (or a buggy
    ///         IOracle implementation that returned `type(uint256).max`)
    ///         could keep claims open indefinitely. 30 days mirrors the
    ///         maximum policy lifetime used elsewhere in the protocol
    ///         and is well above any realistic real-world feed outage.
    uint256 public constant MAX_GRACE_EXTENSION = 30 days;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS (additional)
    // ═══════════════════════════════════════════════════════════

    error ZeroAddress(string param);
    error EventAfterExpiry(uint256 policyId, uint256 verifiedAt, uint256 expiresAt);
    error SafetyWindowNotPassed(uint256 policyId, uint256 earliest, uint256 current);

    // ═══════════════════════════════════════════════════════════
    //  STORAGE (was immutable)
    // ═══════════════════════════════════════════════════════════

    address public router;
    address public oracle;

    // ═══════════════════════════════════════════════════════════
    //  STORAGE
    // ═══════════════════════════════════════════════════════════

    struct CorePolicy {
        address insuredAgent;
        uint256 coverageAmount;
        uint256 premiumPaid;
        uint256 maxPayout;
        uint256 startTimestamp;
        uint256 waitingEndsAt;
        uint256 expiresAt;
        uint256 cleanupAt;
        bool finalized;
        PolicyStatus finalStatus;
    }

    mapping(uint256 => CorePolicy) internal _policies;
    uint256 private _policyCounter;
    uint256 private _activePolicies;
    uint256 private _totalActiveCoverage;

    // ═══════════════════════════════════════════════════════════
    //  INITIALIZER (replaces constructor)
    // ═══════════════════════════════════════════════════════════

    // solhint-disable-next-line func-name-mixedcase
    function __BaseShield_init(address router_, address oracle_) internal onlyInitializing {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
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
    function createPolicy(CreatePolicyParams calldata params) external onlyRouter returns (uint256 policyId) {
        (uint32 minD, uint32 maxD) = this.durationRange();
        if (params.durationSeconds < minD || params.durationSeconds > maxD) {
            revert DurationOutOfRange(params.durationSeconds, minD, maxD);
        }

        if (params.coverageAmount < _minCoverage()) {
            revert CoverageOutOfRange(params.coverageAmount, _minCoverage(), type(uint256).max);
        }

        unchecked {
            _policyCounter++;
        }
        policyId = _policyCounter;

        uint256 maxPay = _calculateMaxPayout(params.coverageAmount, params);

        uint32 wp = this.waitingPeriod();
        uint256 waitEnds = block.timestamp + wp;
        uint256 expires = waitEnds + params.durationSeconds;
        uint256 cleanup = _calculateCleanupAt(expires);

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

        _doCreatePolicy(policyId, params);

        _activePolicies++;
        _totalActiveCoverage += params.coverageAmount;

        emit PolicyCreated(
            policyId,
            params.buyer,
            params.coverageAmount,
            params.premiumAmount,
            params.durationSeconds,
            waitEnds,
            expires
        );
    }

    /// @inheritdoc IShield
    function verifyAndCalculate(uint256 policyId, bytes calldata oracleProof)
        external
        onlyRouter
        returns (PayoutResult memory result)
    {
        CorePolicy storage cp = _policies[policyId];
        if (cp.insuredAgent == address(0)) revert PolicyNotFound(policyId);
        if (cp.finalized) {
            revert InvalidPolicyStatus(policyId, cp.finalStatus, PolicyStatus.ACTIVE);
        }

        PolicyStatus current = _computeStatus(cp);
        _validateStatusForTrigger(policyId, current);

        result = _doVerifyAndCalculate(policyId, oracleProof);

        if (result.payoutAmount > cp.maxPayout) {
            result.payoutAmount = cp.maxPayout;
        }

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

        _afterFinalize(policyId, cp);

        emit PolicyExpired(policyId);
    }

    // ═══════════════════════════════════════════════════════════
    //  NEW TRIGGER FLOW — permissionless settlement
    // ═══════════════════════════════════════════════════════════

    function checkAndSettlePolicy(uint256 policyId) external {
        CorePolicy storage cp = _policies[policyId];
        if (cp.insuredAgent == address(0)) revert PolicyNotFound(policyId);
        if (cp.finalized) {
            revert InvalidPolicyStatus(policyId, cp.finalStatus, PolicyStatus.ACTIVE);
        }

        uint256 earliest = cp.expiresAt + SAFETY_WINDOW;
        if (block.timestamp < earliest) {
            revert SafetyWindowNotPassed(policyId, earliest, block.timestamp);
        }

        bool triggered = _checkTriggerCondition(policyId);

        cp.finalized = true;
        _activePolicies--;
        _totalActiveCoverage -= cp.coverageAmount;

        if (triggered) {
            cp.finalStatus = PolicyStatus.PAID_OUT;
            _afterFinalize(policyId, cp);
            emit PolicySettledTriggered(policyId, cp.insuredAgent, cp.maxPayout);
        } else {
            cp.finalStatus = PolicyStatus.EXPIRED;
            _afterFinalize(policyId, cp);
            emit PolicySettledExpired(policyId);
        }
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
    function totalPolicies() external view returns (uint256) {
        return _policyCounter;
    }

    /// @inheritdoc IShield
    function activePolicies() external view returns (uint256) {
        return _activePolicies;
    }

    /// @inheritdoc IShield
    function totalActiveCoverage() external view returns (uint256) {
        return _totalActiveCoverage;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — STATUS COMPUTATION
    // ═══════════════════════════════════════════════════════════

    function _computeStatus(CorePolicy storage cp) internal view returns (PolicyStatus) {
        if (block.timestamp < cp.waitingEndsAt) return PolicyStatus.WAITING;
        if (block.timestamp < cp.expiresAt) return PolicyStatus.ACTIVE;
        if (_hasSettlementWindow() && block.timestamp <= cp.cleanupAt) {
            return PolicyStatus.SETTLEMENT;
        }
        return PolicyStatus.EXPIRED;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — ORACLE VERIFICATION HELPER
    // ═══════════════════════════════════════════════════════════

    function _verifyOracleSignature(bytes32 dataHash, bytes memory signature) internal view returns (bool) {
        address signer = IOracle(oracle).verifySignature(dataHash, signature);
        return signer == IOracle(oracle).oracleKey();
    }

    function _verifyPriceProofEIP712(int256 price, bytes32 asset, uint256 verifiedAt, bytes memory signature)
        internal
        view
        returns (bool)
    {
        address signer = IOracleV2(oracle).verifyPriceProofEIP712(price, asset, verifiedAt, signature);
        return signer != address(0);
    }

    function _verifyExploitGovProofEIP712(
        int256 govTokenPrice,
        int256 govTokenPrice24hAgo,
        bytes32 protocolId,
        uint256 verifiedAt,
        bytes memory signature
    ) internal view returns (bool) {
        address signer = IOracleV2(oracle)
            .verifyExploitGovProofEIP712(govTokenPrice, govTokenPrice24hAgo, protocolId, verifiedAt, signature);
        return signer != address(0);
    }

    // ═══════════════════════════════════════════════════════════
    //  ABSTRACT — PRODUCT-SPECIFIC (must override)
    // ═══════════════════════════════════════════════════════════

    function _doCreatePolicy(uint256 policyId, CreatePolicyParams calldata params) internal virtual;

    function _doVerifyAndCalculate(uint256 policyId, bytes calldata oracleProof)
        internal
        virtual
        returns (PayoutResult memory);

    function _checkTriggerCondition(uint256 policyId) internal view virtual returns (bool);

    function _calculateMaxPayout(uint256 coverageAmount, CreatePolicyParams calldata params)
        internal
        view
        virtual
        returns (uint256);

    function _calculateCleanupAt(uint256 expiresAt) internal view virtual returns (uint256) {
        return expiresAt + CLAIM_GRACE_PERIOD;
    }

    function _hasSettlementWindow() internal pure virtual returns (bool) {
        return false;
    }

    function _minCoverage() internal pure virtual returns (uint256) {
        return 100e6;
    }

    function _afterFinalize(uint256 policyId, CorePolicy storage cp) internal virtual {
        policyId;
        cp;
    }

    /// @dev [Audit fix H-13] Each shield identifies the Chainlink asset
    ///      whose downtime should extend its claim window. Defaulting to
    ///      `bytes32(0)` (= "no Chainlink dependency") makes the
    ///      Chainlink-grace path a no-op for shields that do not consume
    ///      a price feed — the SUF grace stays in effect regardless.
    function _chainlinkGraceAsset() internal view virtual returns (bytes32) {
        return bytes32(0);
    }

    /// @notice [Audit fix H-13 follow-up] Public read of the asset this
    ///         shield depends on for its Chainlink-grace extension.
    ///         Useful for off-chain monitors that want to confirm a shield
    ///         is wired against the right feed before broadcast — and as
    ///         a coverage anchor for the per-shield override tests.
    function chainlinkGraceAsset() external view returns (bytes32) {
        return _chainlinkGraceAsset();
    }

    function _validateStatusForTrigger(uint256 policyId, PolicyStatus current) internal view virtual {
        if (current != PolicyStatus.ACTIVE && current != PolicyStatus.EXPIRED) {
            revert InvalidPolicyStatus(policyId, current, PolicyStatus.ACTIVE);
        }
        CorePolicy storage cp = _policies[policyId];
        // [Audit fix H-13] Sum the existing sequencer-uptime grace with
        // a new Chainlink-feed grace so an honest user cannot lose a
        // payout because the price feed was stale at claim time. Hard-
        // capped at MAX_GRACE_EXTENSION as defence-in-depth against an
        // adversarial / buggy oracle returning a huge number.
        uint256 sequencerDowntime = IOracle(oracle).getSequencerDowntime(cp.expiresAt);
        uint256 chainlinkDowntime = 0;
        bytes32 graceAsset = _chainlinkGraceAsset();
        if (graceAsset != bytes32(0)) {
            chainlinkDowntime = IOracle(oracle).getChainlinkDowntime(graceAsset, cp.expiresAt);
        }
        uint256 totalDowntime = sequencerDowntime + chainlinkDowntime;
        if (totalDowntime > MAX_GRACE_EXTENSION) {
            totalDowntime = MAX_GRACE_EXTENSION;
        }
        uint256 adjustedCleanupAt = cp.cleanupAt + totalDowntime;
        if (block.timestamp >= adjustedCleanupAt) {
            revert InvalidPolicyStatus(policyId, PolicyStatus.EXPIRED, PolicyStatus.ACTIVE);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
