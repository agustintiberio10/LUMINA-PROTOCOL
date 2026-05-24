// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Slim IShieldV2 surface that flash shields (T-30a) actually expose.
interface ISlimShield {
    function createPolicy(uint256 policyId, address holder, uint256 coverage, uint64 startTimestamp, uint64 expiresAt)
        external;
    function verifyAndCalculate(uint256 policyId)
        external
        returns (bool triggered, uint256 payout, address holder, bytes32 reason);
    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (
            address holder,
            uint256 coverage,
            uint256 strikePrice,
            uint64 startTimestamp,
            uint64 expiresAt,
            bool finalized
        );
}

/// @notice Subset of PolicyManagerV2 used by the adapter for keeper-driven settlement.
interface IPolicyManagerSettle {
    function settlePolicy(bytes32 productId, uint256 policyId, bool triggered) external;
}

/// @title FlashShieldAdapter
/// @notice Sprint T-30b bridge: makes a slim T-30a flash shield speak the legacy
///         IShieldV2 surface that PolicyManagerV2 still expects (struct-based
///         createPolicy + PayoutResult return on verifyAndCalculate).
/// @dev    One adapter instance per slim shield. PolicyManagerV2 registers the
///         adapter (not the shield) for a given productId. The adapter assigns
///         policyIds with its own counter and forwards into the slim shield.
///         The shield trusts only the adapter (constructor `router` arg) — same
///         single-caller invariant as the production setup pre-adapter.
contract FlashShieldAdapter is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    ISlimShield public shield;
    bytes32 public productIdLocal;
    uint256 public nextPolicyId;

    /// @notice PolicyManagerV2 reference used by `checkAndSettlePolicy`. Optional —
    ///         if unset, the keeper-driven flow is disabled and only the legacy
    ///         router-driven `verifyAndCalculate` path remains usable. Set via
    ///         `setPolicyManager(address)` after the upgrade.
    address public policyManager;

    /// @notice Settlement authorities for `checkAndSettlePolicy` (F-01.3).
    ///         `keeper` is the ShieldKeeper automation contract; `relayer` is
    ///         the protocol relayer EOA/multisig. Either may settle. Both are
    ///         optional individually but at least one MUST be set for
    ///         `checkAndSettlePolicy` to be callable. Set via `setKeeper` /
    ///         `setRelayer` (onlyOwner). APPEND-ONLY storage (see gap note).
    /// @dev    CROSS-STREAM: `keeper` MUST be wired to the deployed ShieldKeeper
    ///         so its `performUpkeep` → `checkAndSettlePolicy` path keeps working.
    address public keeper;
    address public relayer;

    event PolicySettled(uint256 indexed policyId, bool triggered, bytes32 reason);
    event PolicyManagerUpdated(address indexed old, address indexed current);
    event KeeperUpdated(address indexed old, address indexed current);
    event RelayerUpdated(address indexed old, address indexed current);

    struct LegacyCreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        bytes extraData;
    }

    struct LegacyPayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }

    // ═══════ MODIFIERS ═══════

    /// @notice F-08: only PolicyManagerV2 may drive policy lifecycle entrypoints.
    modifier onlyPolicyManager() {
        require(msg.sender == policyManager, "ONLY_PM");
        _;
    }

    /// @notice F-01.3: only the wired keeper or relayer may settle.
    modifier onlyKeeperOrRelayer() {
        require(
            (keeper != address(0) && msg.sender == keeper) || (relayer != address(0) && msg.sender == relayer),
            "ONLY_KEEPER_OR_RELAYER"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the adapter proxy.
    /// @dev    F-05 (uninitialized-proxy takeover): `initialize` is `initializer`
    ///         guarded and sets the owner to `msg.sender` via `__Ownable_init`.
    ///         To eliminate the init-front-run window the deploy MUST be ATOMIC:
    ///         deploy the ERC1967Proxy with the initializer encoded in the same
    ///         transaction, e.g.
    ///           `new ERC1967Proxy(impl, abi.encodeCall(FlashShieldAdapter.initialize, (shield, productId)))`
    ///         so the proxy can never exist in an uninitialized state that an
    ///         attacker could front-run. The implementation contract itself is
    ///         protected by `_disableInitializers()` in the constructor.
    ///         The authoritative deploy-script fix is owned by the deploy stream
    ///         (see red-team F-05); this NatSpec is the contract-side guard +
    ///         cross-reference. Signature is intentionally UNCHANGED so deploy
    ///         scripts keep working.
    function initialize(address _shield, bytes32 _productId) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        require(_shield != address(0), "Zero shield");
        shield = ISlimShield(_shield);
        productIdLocal = _productId;
        nextPolicyId = 1;
    }

    function productId() external view returns (bytes32) {
        return productIdLocal;
    }

    /// @notice Forward legacy createPolicy into slim shield with adapter-assigned id.
    /// @dev    F-08: authenticated — only PolicyManagerV2 may create policies.
    function createPolicy(LegacyCreatePolicyParams calldata params)
        external
        onlyPolicyManager
        returns (uint256 policyId)
    {
        policyId = nextPolicyId++;
        uint64 startTs = uint64(block.timestamp);
        uint64 expiresAt = uint64(block.timestamp + params.durationSeconds);
        shield.createPolicy(policyId, params.buyer, params.coverageAmount, startTs, expiresAt);
    }

    /// @notice Forward legacy verifyAndCalculate to slim shield; oracleProof unused
    ///         (slim shields read Chainlink directly).
    /// @dev    F-08: authenticated — only PolicyManagerV2 may drive verification.
    function verifyAndCalculate(
        uint256 policyId,
        bytes calldata /*oracleProof*/
    )
        external
        onlyPolicyManager
        returns (LegacyPayoutResult memory r)
    {
        (bool triggered, uint256 payout, address holder, bytes32 reason) = shield.verifyAndCalculate(policyId);
        r = LegacyPayoutResult({triggered: triggered, payoutAmount: payout, recipient: holder, reason: reason});
    }

    /// @notice Forward legacy getPolicyInfo signature (uint8 status) onto slim
    ///         shield's (bool finalized). Status mapping: 0 = active, 2 = finalized.
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
        )
    {
        (address holder, uint256 coverage,,, uint64 end, bool finalized) = shield.getPolicyInfo(policyId);
        insuredAgent = holder;
        coverageAmount = coverage;
        premiumPaid = 0; // slim shields don't track premium; PolicyManagerV2 already has it
        maxPayout = (coverage * 8000) / 10_000;
        expiresAt = uint256(end);
        status = finalized ? 2 : 0;
    }

    /// @notice Keeper/relayer settlement entrypoint expected by ShieldKeeper.
    /// @dev    F-01.3: restricted to the wired keeper or relayer (was permissionless).
    ///
    ///         Calls `shield.verifyAndCalculate(policyId)` to obtain the trigger
    ///         decision and routes the outcome to
    ///         `policyManager.settlePolicy(productId, policyId, triggered)`.
    ///         The PM gates that call on `msg.sender == pr.shield`, and the
    ///         policy was registered against this adapter address.
    ///
    ///         F-03 / F-29 — oracle-aware settlement handling. The shield now
    ///         emits DISTINCT revert reasons; this method maps them as follows:
    ///         - "TRIGGER_DROP" (no revert, triggered=true) → settle TRUE.
    ///         - "WINDOW_EXPIRED" → the shield only emits this when the oracle
    ///           WAS evaluable at/after expiry and no sustained barrier breach
    ///           accrued → settle FALSE (release reservation). This is the ONLY
    ///           path that finalizes a non-triggered policy.
    ///         - "NEEDS_MORE_CONFIRMATIONS" / "DWELL_NOT_ELAPSED" → not yet
    ///           settleable; the policy stays PENDING (revert NOT_SETTLEABLE_YET
    ///           so the keeper retries). NEVER settled false here.
    ///         - "ORACLE_UNAVAILABLE" / "ORACLE_STALE" / "SEQUENCER_DOWN" /
    ///           "ORACLE_INVALID" / round-completeness reverts → oracle is down;
    ///           the policy is NOT auto-settled false. Reverts ORACLE_UNAVAILABLE
    ///           so the window-expired policy can be retried once the oracle
    ///           recovers. A window-expired policy is therefore NEVER finalized
    ///           as non-triggered while the oracle was unavailable.
    ///         - any other revert (ALREADY_FINALIZED, POLICY_NOT_FOUND, …)
    ///           bubbles up unchanged.
    function checkAndSettlePolicy(uint256 policyId) external onlyKeeperOrRelayer {
        require(policyManager != address(0), "Policy manager unset");
        bool triggered;
        bytes32 reason;
        try shield.verifyAndCalculate(policyId) returns (bool t, uint256, address, bytes32 r) {
            // F-01: the shield RETURNS (does not revert) on a successful accrual
            // step so the multi-block observation persists. Distinguish the
            // outcomes by `reason`:
            //   - triggered == true                  → settle TRUE.
            //   - reason == "WINDOW_EXPIRED"          → settle FALSE (the only
            //                                           non-triggered finalize;
            //                                           the shield emits this
            //                                           ONLY when the oracle was
            //                                           evaluable at expiry).
            //   - reason == "ACCRUING" / "RESET"      → still gathering
            //                                           confirmations; the
            //                                           observation has been
            //                                           PERSISTED by the shield.
            //                                           Do NOT settle; return so
            //                                           progress is kept.
            triggered = t;
            reason = r;
            if (!t && reason != bytes32("WINDOW_EXPIRED")) {
                // Accrual progressed (or reset) but not settleable yet.
                emit PolicySettled(policyId, false, reason);
                return;
            }
        } catch Error(string memory err) {
            bytes32 e = keccak256(bytes(err));
            if (
                e == keccak256(bytes("DWELL_NOT_ELAPSED")) || e == keccak256(bytes("SAME_BLOCK_OBSERVATION"))
                    || e == keccak256(bytes("STALE_ROUND_OBSERVATION"))
                    || e == keccak256(bytes("CONFIRMATION_TOO_SOON"))
            ) {
                // F-01: not settleable yet (dwell unmet / observation rejected
                // for spacing). No accrual state to lose. Leave PENDING.
                revert("NOT_SETTLEABLE_YET");
            } else if (
                e == keccak256(bytes("ORACLE_UNAVAILABLE")) || e == keccak256(bytes("ORACLE_STALE"))
                    || e == keccak256(bytes("SEQUENCER_DOWN")) || e == keccak256(bytes("ORACLE_INVALID"))
                    || e == keccak256(bytes("ORACLE_INCOMPLETE_ROUND"))
                    || e == keccak256(bytes("ORACLE_ROUND_NOT_COMPLETE")) || e == keccak256(bytes("ORACLE_FUTURE_TS"))
            ) {
                // F-03: oracle down → do NOT settle false; retry later.
                revert("ORACLE_UNAVAILABLE");
            } else {
                revert(err);
            }
        }
        IPolicyManagerSettle(policyManager).settlePolicy(productIdLocal, policyId, triggered);
        emit PolicySettled(policyId, triggered, reason);
    }

    /// @notice Wire the PolicyManagerV2 reference. One-shot in practice (idempotent).
    function setPolicyManager(address _pm) external onlyOwner {
        require(_pm != address(0), "Zero PM");
        address old = policyManager;
        policyManager = _pm;
        emit PolicyManagerUpdated(old, _pm);
    }

    /// @notice Wire the keeper authorised to call `checkAndSettlePolicy` (F-01.3).
    /// @dev    CROSS-STREAM: set this to the deployed ShieldKeeper address.
    function setKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "Zero keeper");
        address old = keeper;
        keeper = _keeper;
        emit KeeperUpdated(old, _keeper);
    }

    /// @notice Wire the relayer authorised to call `checkAndSettlePolicy` (F-01.3).
    function setRelayer(address _relayer) external onlyOwner {
        require(_relayer != address(0), "Zero relayer");
        address old = relayer;
        relayer = _relayer;
        emit RelayerUpdated(old, _relayer);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Storage gap. Shrunk 46 → 44 (F-01.3): two slots consumed by the
    ///      new `keeper` and `relayer` addresses (appended above `__gap`,
    ///      append-only layout preserved for UUPS upgrade compatibility).
    uint256[44] private __gap;
}
