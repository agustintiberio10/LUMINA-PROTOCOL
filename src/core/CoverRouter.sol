// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICoverRouter} from "../interfaces/ICoverRouter.sol";
import {IShield} from "../interfaces/IShield.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IPhalaVerifier} from "../interfaces/IPhalaVerifier.sol";
import {IPolicyManager} from "../interfaces/IPolicyManager.sol";
import {IVault} from "../interfaces/IVault.sol";
import {EmergencyPause} from "./EmergencyPause.sol";

/**
 * @title CoverRouter
 * @author Lumina Protocol
 * @notice Single entry point for ALL agent interactions. UUPS upgradable.
 * @dev Version 6.0 — Post-pivot: 4 vaults, waterfall, cooldown, ALM.
 * 
 * KEY CHANGES (v6):
 *   - Vault selected by PolicyManager via waterfall (not from Shield)
 *   - policyVault mapping tracks which vault backs each policy
 *   - registerProduct takes riskType instead of vault address
 *   - Premium goes to the specific vault that backs the policy
 * 
 * RETAINED FROM PREVIOUS AUDITS:
 *   - SafeERC20, nonReentrant, whenNotPaused (purchases only)
 *   - Composite _policyResolved key: [productId][policyId]
 *   - Recipient validation (pr.recipient == info.insuredAgent)
 *   - Payout cap (pr.payoutAmount ≤ info.maxPayout)
 *   - Payout=0 guard, nonce before external calls, ceiling allowance clear
 *   - triggerPayout/cleanup NOT paused (agents must always collect)
 *   - EIP-712 with fork detection
 *   - USDC 1:1 USD conversion (both 6 decimals, no oracle needed)
 */
contract CoverRouter is
    ICoverRouter,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  STORAGE — 🔴 NEVER reorder. Only APPEND.
    // ═══════════════════════════════════════════════════════════

    address private _oracle;
    address private _phalaVerifier;
    address private _policyManager;
    address private _usdcToken;
    bool private _paused;

    mapping(uint256 => bool) private _usedNonces;
    mapping(bytes32 => address) private _products;          // productId → Shield
    mapping(bytes32 => bool) private _productActive;

    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;
    bytes32[] private _productIds;
    bool private _isTestnet;

    mapping(bytes32 => mapping(uint256 => bool)) private _policyResolved;

    /// @notice NEW: tracks which vault backs each policy (needed for payout/cleanup)
    mapping(bytes32 => mapping(uint256 => address)) private _policyVault;

    /// @notice Protocol fee in basis points (300 = 3%).
    /// @dev Adapted from MutualLumina V1. Fee charged on BOTH:
    ///   - purchasePolicy: 3% of premium → feeReceiver, 97% → vault
    ///   - triggerPayout: 3% of payout → feeReceiver, 97% → agent
    uint16 private _protocolFeeBps;

    /// @notice Address that receives protocol fees.
    address private _feeReceiver;

    // ═══ V2: Relayer authorization ═══
    mapping(address => bool) public authorizedRelayers;

    // ═══ V3: Session Approval (buyer consent for relayer purchases) ═══
    struct RelayerSession {
        uint256 maxAmount;      // max total USDC the relayer can spend on behalf of buyer
        uint256 spent;          // total USDC spent so far in this session
        uint256 deadline;       // session expires after this timestamp
    }
    // buyer → relayer → session
    mapping(address => mapping(address => RelayerSession)) public relayerSessions;

    event SessionApproved(address indexed buyer, address indexed relayer, uint256 maxAmount, uint256 deadline);

    // ═══ Oracle Mitigations ═══
    uint256 public largePayoutThreshold;
    uint256 public largePayoutDelay;

    struct ScheduledPayout {
        address beneficiary;
        uint256 amount;
        uint256 executeAfter;
        bool cancelled;
        bool executed;
        bytes32 productId;
        uint256 policyId;
        address vault;
        uint256 coverageAmount; // [FIX DRAIN-8.1] needed for deferred releaseAllocation
    }
    mapping(bytes32 => ScheduledPayout) public scheduledPayouts;

    uint256 public maxPayoutsPerDay;
    uint256 public dailyPayoutCount;
    uint256 public lastPayoutCountReset;

    /// @notice Global emergency pause contract (APPENDED — UUPS-safe)
    address public emergencyPause;

    /// @dev Storage gap for future UUPS upgrades
    uint256[49] private __gap_router;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS (additional, not in interface)
    // ═══════════════════════════════════════════════════════════

    event UsdcTokenUpdated(address indexed oldToken, address indexed newToken);
    event PolicyManagerUpdated(address indexed oldManager, address indexed newManager);
    event TestnetModeChanged(bool isTestnet);
    event FeeCollected(bytes32 indexed productId, uint256 indexed policyId, uint256 feeAmount, string feeType);
    event ProtocolFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event FeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS (additional)
    // ═══════════════════════════════════════════════════════════

    error ZeroAddress(string param);
    error ProductAlreadyRegistered(bytes32 productId);
    error InvalidAllocationBps(uint16 bps);
    error USDCConversionNotImplemented();
    error InvalidFeeBps(uint16 feeBps);
    error ZeroFeeReceiver();
    error UnauthorizedRelayer(address caller);

    event RelayerAuthorized(address indexed relayer, bool authorized);

    // ═══ Oracle Mitigation Events ═══
    event PayoutScheduled(bytes32 indexed payoutId, address indexed beneficiary, uint256 amount, uint256 executeAfter);
    event ScheduledPayoutExecuted(bytes32 indexed payoutId, address indexed beneficiary, uint256 amount);
    event ScheduledPayoutCancelled(bytes32 indexed payoutId);

    // ═══════════════════════════════════════════════════════════
    //  EIP-712
    // ═══════════════════════════════════════════════════════════

    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "SignedQuote("
        "bytes32 productId,"
        "uint256 coverageAmount,"
        "uint256 premiumAmount,"
        "uint32 durationSeconds,"
        "bytes32 asset,"
        "bytes32 stablecoin,"
        "address protocol,"
        "address buyer,"
        "uint256 deadline,"
        "uint256 nonce"
        ")"
    );

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // ═══════════════════════════════════════════════════════════
    //  INITIALIZER
    // ═══════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address owner_,
        address oracle_,
        address phalaVerifier_,
        address policyManager_,
        address usdcToken_,
        bool isTestnet_,
        address feeReceiver_,
        uint16 feeBps_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress("owner");
        if (oracle_ == address(0)) revert ZeroAddress("oracle");
        if (phalaVerifier_ == address(0)) revert ZeroAddress("phalaVerifier");
        if (policyManager_ == address(0)) revert ZeroAddress("policyManager");
        if (usdcToken_ == address(0)) revert ZeroAddress("usdcToken");
        if (feeReceiver_ == address(0)) revert ZeroFeeReceiver();
        if (feeBps_ > 1000) revert InvalidFeeBps(feeBps_);

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _oracle = oracle_;
        _phalaVerifier = phalaVerifier_;
        _policyManager = policyManager_;
        _usdcToken = usdcToken_;
        _isTestnet = isTestnet_;
        _feeReceiver = feeReceiver_;
        _protocolFeeBps = feeBps_;

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _computeDomainSeparator();
    }

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier whenNotPaused() {
        if (_paused) revert ProtocolIsPaused();
        _;
    }

    modifier whenProtocolNotPaused() {
        if (emergencyPause != address(0) && EmergencyPause(emergencyPause).protocolPaused()) {
            revert ProtocolIsPaused();
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  AGENT OPERATIONS
    // ═══════════════════════════════════════════════════════════

    function purchasePolicy(
        SignedQuote calldata quote,
        bytes calldata signature
    ) external nonReentrant whenNotPaused whenProtocolNotPaused returns (PurchaseResult memory result) {

        // ── CHECKS ──
        if (quote.buyer != msg.sender) revert BuyerMismatch(quote.buyer, msg.sender);
        if (block.timestamp > quote.deadline) revert QuoteExpired(quote.deadline, block.timestamp);
        if (_usedNonces[quote.nonce]) revert NonceAlreadyUsed(quote.nonce);

        // Mark nonce BEFORE external calls
        _usedNonces[quote.nonce] = true;

        address shield = _products[quote.productId];
        if (shield == address(0) || !_productActive[quote.productId])
            revert ProductNotAvailable(quote.productId);

        // Verify EIP-712 signature
        bytes32 structHash = _hashQuote(quote);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        address signer = IOracle(_oracle).verifySignature(digest, signature);
        if (signer != IOracle(_oracle).oracleKey()) revert InvalidQuoteSignature();

        // Coverage and premium sanity checks
        require(quote.coverageAmount > 0, "Zero coverage");
        require(quote.premiumAmount > 0, "Zero premium");
        require(quote.premiumAmount >= quote.coverageAmount / 1000, "Premium below minimum");

        // ── INTERACTIONS ──

        // 1. Create policy in Shield (to get policyId)
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: quote.buyer,
            coverageAmount: quote.coverageAmount,
            premiumAmount: quote.premiumAmount,
            durationSeconds: quote.durationSeconds,
            asset: quote.asset,
            stablecoin: quote.stablecoin,
            protocol: quote.protocol,
            extraData: ""
        });
        uint256 policyId = IShield(shield).createPolicy(params);

        // 2. PolicyManager selects vault via waterfall + locks collateral
        //    NOW PASSES durationSeconds for ALM check
        IPolicyManager pm = IPolicyManager(_policyManager);
        address vault = pm.recordAllocation(
            quote.productId,
            policyId,
            quote.coverageAmount,
            quote.durationSeconds
        );

        // 3. Store policy → vault mapping (needed for payout/cleanup)
        _policyVault[quote.productId][policyId] = vault;

        // 4. Transfer premium: split between protocol fee and vault
        uint256 usdcPremium = _convertToUSDC(quote.premiumAmount);
        IERC20(_usdcToken).safeTransferFrom(msg.sender, address(this), usdcPremium);

        // Protocol fee: 3% of premium → feeReceiver
        uint256 premiumFee = 0;
        if (_protocolFeeBps > 0 && _feeReceiver != address(0)) {
            premiumFee = (usdcPremium * _protocolFeeBps) / 10000;
            if (premiumFee > 0) {
                IERC20(_usdcToken).safeTransfer(_feeReceiver, premiumFee);
                emit FeeCollected(quote.productId, policyId, premiumFee, "PREMIUM");
            }
        }

        // Remaining premium → vault (risk premium)
        uint256 vaultPremium = usdcPremium - premiumFee;
        IERC20(_usdcToken).forceApprove(vault, vaultPremium);
        IVault(vault).receivePremium(vaultPremium, quote.productId, policyId);
        IERC20(_usdcToken).forceApprove(vault, 0);

        // 5. Build result
        IShield.PolicyInfo memory info = IShield(shield).getPolicyInfo(policyId);
        result = PurchaseResult({
            policyId: policyId,
            productId: quote.productId,
            vault: vault,
            coverageAmount: quote.coverageAmount,
            premiumPaid: quote.premiumAmount,
            startsAt: info.waitingEndsAt,
            expiresAt: info.expiresAt
        });

        emit PolicyPurchased(
            policyId, quote.productId, quote.buyer, vault,
            quote.coverageAmount, quote.premiumAmount, quote.durationSeconds
        );
    }

    /**
     * @notice Trigger payout — NOT paused (agents must always collect)
     */
    function triggerPayout(
        bytes32 productId,
        uint256 policyId,
        bytes calldata oracleProof
    ) external nonReentrant {

        // ═══ Oracle Mitigation 3: Daily trigger rate limit ═══
        if (maxPayoutsPerDay > 0) {
            if (block.timestamp > lastPayoutCountReset + 1 days) {
                dailyPayoutCount = 0;
                lastPayoutCountReset = block.timestamp;
            }
            require(dailyPayoutCount < maxPayoutsPerDay, "Daily payout limit reached");
            dailyPayoutCount++;
        }

        if (_policyResolved[productId][policyId]) revert PolicyAlreadyResolved(productId, policyId);

        address shield = _products[productId];
        if (shield == address(0)) revert ProductNotAvailable(productId);

        // 1. Product verifies trigger
        IShield.PayoutResult memory pr = IShield(shield).verifyAndCalculate(policyId, oracleProof);
        if (!pr.triggered) revert TriggerNotMet(policyId);

        // 2. Get policy info + validate
        IShield.PolicyInfo memory info = IShield(shield).getPolicyInfo(policyId);
        if (pr.recipient != info.insuredAgent) revert RecipientMismatch(info.insuredAgent, pr.recipient);
        if (pr.payoutAmount > info.maxPayout) pr.payoutAmount = info.maxPayout;

        // [FIX H-8] Anti-griefing: only insured agent, authorized relayers, or owner
        // [FIX N-4] After 6h anyone can trigger to protect agents who are offline
        if (msg.sender != info.insuredAgent && !authorizedRelayers[msg.sender] && msg.sender != owner()) {
            require(block.timestamp >= info.waitingEndsAt + 6 hours, "Only agent/relayer/owner (or anyone after 6h)");
        }

        // 3. Mark resolved BEFORE external calls
        _policyResolved[productId][policyId] = true;

        // 4. Mark paid out + resolve vault reference
        IShield(shield).markPaidOut(policyId);
        address vault = _policyVault[productId][policyId];
        if (vault == address(0)) revert InvalidPolicyForPayout(policyId);

        // 5. Execute payout: split between protocol fee and agent
        uint256 usdcPayout = _convertToUSDCSafe(pr.payoutAmount);
        if (usdcPayout > 0) {
            // ═══ Oracle Mitigation 1: Large payout delay ═══
            // [FIX DRAIN-8.1] Do NOT release allocation yet — collateral stays locked until execution
            if (largePayoutThreshold > 0 && usdcPayout > largePayoutThreshold) {
                bytes32 payoutId = keccak256(abi.encodePacked(productId, policyId, pr.recipient, usdcPayout, block.timestamp));
                uint256 executeAfter = block.timestamp + largePayoutDelay;
                scheduledPayouts[payoutId] = ScheduledPayout({
                    beneficiary: pr.recipient,
                    amount: usdcPayout,
                    executeAfter: executeAfter,
                    cancelled: false,
                    executed: false,
                    productId: productId,
                    policyId: policyId,
                    vault: vault,
                    coverageAmount: info.coverageAmount
                });
                emit PayoutScheduled(payoutId, pr.recipient, usdcPayout, executeAfter);
                emit PayoutTriggered(policyId, productId, pr.recipient, pr.payoutAmount);
                return; // Collateral remains locked until executeScheduledPayout
            }

            // [FIX P-4] Fee charged from vault reserves, not from agent's payout.
            // Agent receives 100% of calculated payout; fee is a separate withdrawal.
            uint256 payoutFee = 0;
            if (_protocolFeeBps > 0 && _feeReceiver != address(0)) {
                payoutFee = (usdcPayout * _protocolFeeBps) / 10000;
            }
            uint256 totalFromVault = usdcPayout + payoutFee;

            // [FIX N-7] Execute payout BEFORE releasing allocation to prevent
            // accounting desync if executePayout reverts or queues internally.
            IVault(vault).executePayout(address(this), totalFromVault, productId, policyId, pr.recipient);

            // Release allocation AFTER successful payout execution
            IPolicyManager(_policyManager).releaseAllocation(productId, policyId, info.coverageAmount, vault);

            // Protocol fee → feeReceiver (from vault reserves, not agent's payout)
            if (payoutFee > 0) {
                IERC20(_usdcToken).safeTransfer(_feeReceiver, payoutFee);
                emit FeeCollected(productId, policyId, payoutFee, "CLAIM");
            }

            // Full payout → agent (100% of calculated payout)
            IERC20(_usdcToken).safeTransfer(pr.recipient, usdcPayout);
        }

        emit PayoutTriggered(policyId, productId, pr.recipient, pr.payoutAmount);
    }

    /**
     * @notice Cleanup expired policy — NOT paused.
     * @dev [M-5] Anyone can call this to release collateral from expired policies.
     *      This is by design: it incentivizes keepers/bots to free locked capital,
     *      and there is no harm since the policy has already expired past its grace period.
     */
    function cleanupExpiredPolicy(bytes32 productId, uint256 policyId) external nonReentrant {
        if (_policyResolved[productId][policyId]) revert PolicyAlreadyResolved(productId, policyId);

        address shield = _products[productId];
        if (shield == address(0)) revert ProductNotAvailable(productId);

        IShield.PolicyInfo memory info = IShield(shield).getPolicyInfo(policyId);
        IShield.PolicyStatus status = IShield(shield).getPolicyStatus(policyId);

        // [FIX L-1] Also accept EXPIRED status: _computeStatus now correctly returns
        // EXPIRED for non-finalized policies past expiresAt/cleanupAt.
        if (status != IShield.PolicyStatus.ACTIVE && status != IShield.PolicyStatus.SETTLEMENT && status != IShield.PolicyStatus.EXPIRED)
            revert InvalidPolicyForPayout(policyId);
        // [FIX M-9] Extend cleanup deadline by sequencer downtime
        uint256 downtime = IOracle(_oracle).getSequencerDowntime(info.expiresAt);
        if (block.timestamp <= info.cleanupAt + downtime) revert InvalidPolicyForPayout(policyId);

        _policyResolved[productId][policyId] = true;

        IShield(shield).markExpired(policyId);
        address vault = _policyVault[productId][policyId];
        if (vault == address(0)) revert InvalidPolicyForPayout(policyId);
        IPolicyManager(_policyManager).releaseAllocation(productId, policyId, info.coverageAmount, vault);

        emit PolicyCleanedUp(policyId, productId);
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN OPERATIONS
    // ═══════════════════════════════════════════════════════════

    function registerProduct(
        bytes32 productId, address shield, bytes32 riskType, uint16 maxAllocationBps
    ) external onlyOwner {
        if (_products[productId] != address(0)) revert ProductAlreadyRegistered(productId);
        if (shield == address(0)) revert ZeroAddress("shield");
        if (maxAllocationBps == 0 || maxAllocationBps > 10000) revert InvalidAllocationBps(maxAllocationBps);

        _products[productId] = shield;
        _productActive[productId] = true;
        _productIds.push(productId);
        IPolicyManager(_policyManager).registerProduct(productId, shield, riskType, maxAllocationBps);

        emit ProductUpdated(productId, shield, true);
    }

    function setProductActive(bytes32 productId, bool active) external onlyOwner {
        if (_products[productId] == address(0)) revert ProductNotAvailable(productId);
        _productActive[productId] = active;
        IPolicyManager(_policyManager).setProductActive(productId, active);
        emit ProductUpdated(productId, _products[productId], active);
    }

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress("oracle");
        address old = _oracle;
        _oracle = newOracle;
        emit OracleUpdated(old, newOracle);
    }

    function setPhalaVerifier(address newVerifier) external onlyOwner {
        if (newVerifier == address(0)) revert ZeroAddress("phalaVerifier");
        address old = _phalaVerifier;
        _phalaVerifier = newVerifier;
        emit PhalaVerifierUpdated(old, newVerifier);
    }

    function setUsdcToken(address newUsdcToken) external onlyOwner {
        if (newUsdcToken == address(0)) revert ZeroAddress("usdcToken");
        address old = _usdcToken;
        _usdcToken = newUsdcToken;
        emit UsdcTokenUpdated(old, newUsdcToken);
    }

    function setPolicyManager(address newPolicyManager) external onlyOwner {
        if (newPolicyManager == address(0)) revert ZeroAddress("policyManager");
        address old = _policyManager;
        _policyManager = newPolicyManager;
        emit PolicyManagerUpdated(old, newPolicyManager);
    }

    function setTestnetMode(bool isTestnet_) external onlyOwner {
        _isTestnet = isTestnet_;
        emit TestnetModeChanged(isTestnet_);
    }

    function setPaused(bool paused_) external onlyOwner {
        _paused = paused_;
        emit ProtocolPausedChanged(paused_);
    }

    function setProtocolFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > 1000) revert InvalidFeeBps(newFeeBps);
        uint16 old = _protocolFeeBps;
        _protocolFeeBps = newFeeBps;
        emit ProtocolFeeUpdated(old, newFeeBps);
    }

    function setFeeReceiver(address newReceiver) external onlyOwner {
        if (newReceiver == address(0)) revert ZeroFeeReceiver();
        address old = _feeReceiver;
        _feeReceiver = newReceiver;
        emit FeeReceiverUpdated(old, newReceiver);
    }

    function setRelayer(address relayer, bool authorized) external onlyOwner {
        if (relayer == address(0)) revert ZeroAddress("relayer");
        authorizedRelayers[relayer] = authorized;
        emit RelayerAuthorized(relayer, authorized);
    }

    // ═══ Oracle Mitigation Setters ═══

    function setLargePayoutThreshold(uint256 _threshold) external onlyOwner { largePayoutThreshold = _threshold; }
    function setLargePayoutDelay(uint256 _delay) external onlyOwner {
        require(_delay >= 1 hours || _delay == 0, "Delay too short");
        largePayoutDelay = _delay;
    }
    function setMaxPayoutsPerDay(uint256 _max) external onlyOwner { maxPayoutsPerDay = _max; }

    function setEmergencyPause(address _emergencyPause) external onlyOwner {
        emergencyPause = _emergencyPause;
    }

    // ═══ Oracle Mitigation: Scheduled Payout Management ═══

    function executeScheduledPayout(bytes32 payoutId) external nonReentrant {
        ScheduledPayout storage sp = scheduledPayouts[payoutId];
        require(sp.amount > 0, "Not found");
        require(!sp.cancelled, "Cancelled");
        require(!sp.executed, "Already executed");
        require(block.timestamp >= sp.executeAfter, "Too early");

        sp.executed = true;

        // [FIX P-4] Fee charged from vault reserves, not from agent's payout
        uint256 payoutFee = 0;
        if (_protocolFeeBps > 0 && _feeReceiver != address(0)) {
            payoutFee = (sp.amount * _protocolFeeBps) / 10000;
        }
        uint256 totalFromVault = sp.amount + payoutFee;

        // [FIX N-7] Execute payout BEFORE releasing allocation
        IVault(sp.vault).executePayout(address(this), totalFromVault, sp.productId, sp.policyId, sp.beneficiary);

        // [FIX DRAIN-8.1] Release allocation AFTER successful payout execution
        IPolicyManager(_policyManager).releaseAllocation(sp.productId, sp.policyId, sp.coverageAmount, sp.vault);

        // Protocol fee → feeReceiver (from vault reserves)
        if (payoutFee > 0) {
            IERC20(_usdcToken).safeTransfer(_feeReceiver, payoutFee);
            emit FeeCollected(sp.productId, sp.policyId, payoutFee, "CLAIM");
        }

        // Full payout → beneficiary (100% of calculated payout)
        IERC20(_usdcToken).safeTransfer(sp.beneficiary, sp.amount);

        emit ScheduledPayoutExecuted(payoutId, sp.beneficiary, sp.amount);
    }

    function cancelScheduledPayout(bytes32 payoutId) external onlyOwner {
        revert("PayoutCannotBeCancelled");
    }

    // ═══════════════════════════════════════════════════════════
    //  SESSION APPROVAL (buyer consent for relayer purchases)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Buyer approves a relayer to spend up to maxAmount USDC on their behalf.
     * @dev Called directly by the buyer (msg.sender = buyer). No signature needed —
     *      the buyer is calling from their own wallet.
     * @param relayer Address of the authorized relayer
     * @param maxAmount Maximum total USDC (6 decimals) the relayer can spend
     * @param deadline Session expires after this timestamp
     */
    function approveSession(address relayer, uint256 maxAmount, uint256 deadline) external {
        require(relayer != address(0), "Zero relayer");
        require(maxAmount > 0, "Zero amount");
        require(deadline > block.timestamp, "Deadline in past");

        relayerSessions[msg.sender][relayer] = RelayerSession({
            maxAmount: maxAmount,
            spent: 0,
            deadline: deadline
        });

        emit SessionApproved(msg.sender, relayer, maxAmount, deadline);
    }

    // ═══════════════════════════════════════════════════════════
    //  RELAYER OPERATIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Purchase a policy on behalf of the buyer via an authorized relayer.
     * @dev [FIX ACCESS-2.1] Requires buyer to have an active session for this relayer.
     *      Session limits max spending and has a deadline. Buyer calls approveSession() first.
     */
    function purchasePolicyFor(
        SignedQuote calldata quote,
        bytes calldata signature
    ) external nonReentrant whenNotPaused whenProtocolNotPaused returns (PurchaseResult memory result) {

        // ── CHECKS ──
        if (!authorizedRelayers[msg.sender]) revert UnauthorizedRelayer(msg.sender);
        if (block.timestamp > quote.deadline) revert QuoteExpired(quote.deadline, block.timestamp);
        if (_usedNonces[quote.nonce]) revert NonceAlreadyUsed(quote.nonce);

        // Mark nonce BEFORE external calls
        _usedNonces[quote.nonce] = true;

        address shield = _products[quote.productId];
        if (shield == address(0) || !_productActive[quote.productId])
            revert ProductNotAvailable(quote.productId);

        // Verify EIP-712 signature
        bytes32 structHash = _hashQuote(quote);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        address signer = IOracle(_oracle).verifySignature(digest, signature);
        if (signer != IOracle(_oracle).oracleKey()) revert InvalidQuoteSignature();

        // Coverage and premium sanity checks
        require(quote.coverageAmount > 0, "Zero coverage");
        require(quote.premiumAmount > 0, "Zero premium");
        require(quote.premiumAmount >= quote.coverageAmount / 1000, "Premium below minimum");

        // [FIX ACCESS-2.1] Verify buyer session — relayer must have active session from buyer
        // [FIX L-2] Cache USDC conversion to avoid redundant _convertToUSDC call
        uint256 usdcPremium = _convertToUSDC(quote.premiumAmount);
        {
            RelayerSession storage session = relayerSessions[quote.buyer][msg.sender];
            require(session.maxAmount > 0, "No session: buyer must call approveSession first");
            require(block.timestamp <= session.deadline, "Session expired");
            require(session.spent + usdcPremium <= session.maxAmount, "Session spending limit exceeded");
            session.spent += usdcPremium;
        }

        // ── INTERACTIONS ──

        // 1. Create policy in Shield (to get policyId)
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: quote.buyer,
            coverageAmount: quote.coverageAmount,
            premiumAmount: quote.premiumAmount,
            durationSeconds: quote.durationSeconds,
            asset: quote.asset,
            stablecoin: quote.stablecoin,
            protocol: quote.protocol,
            extraData: ""
        });
        uint256 policyId = IShield(shield).createPolicy(params);

        // 2. PolicyManager selects vault via waterfall + locks collateral
        IPolicyManager pm = IPolicyManager(_policyManager);
        address vault = pm.recordAllocation(
            quote.productId,
            policyId,
            quote.coverageAmount,
            quote.durationSeconds
        );

        // 3. Store policy → vault mapping (needed for payout/cleanup)
        _policyVault[quote.productId][policyId] = vault;

        // 4. Transfer premium FROM THE BUYER (not msg.sender/relayer)
        // usdcPremium already cached above from session check
        IERC20(_usdcToken).safeTransferFrom(quote.buyer, address(this), usdcPremium);

        // Protocol fee: 3% of premium → feeReceiver
        uint256 premiumFee = 0;
        if (_protocolFeeBps > 0 && _feeReceiver != address(0)) {
            premiumFee = (usdcPremium * _protocolFeeBps) / 10000;
            if (premiumFee > 0) {
                IERC20(_usdcToken).safeTransfer(_feeReceiver, premiumFee);
                emit FeeCollected(quote.productId, policyId, premiumFee, "PREMIUM");
            }
        }

        // Remaining premium → vault (risk premium)
        uint256 vaultPremium = usdcPremium - premiumFee;
        IERC20(_usdcToken).forceApprove(vault, vaultPremium);
        IVault(vault).receivePremium(vaultPremium, quote.productId, policyId);
        IERC20(_usdcToken).forceApprove(vault, 0);

        // 5. Build result
        IShield.PolicyInfo memory info = IShield(shield).getPolicyInfo(policyId);
        result = PurchaseResult({
            policyId: policyId,
            productId: quote.productId,
            vault: vault,
            coverageAmount: quote.coverageAmount,
            premiumPaid: quote.premiumAmount,
            startsAt: info.waitingEndsAt,
            expiresAt: info.expiresAt
        });

        emit PolicyPurchased(
            policyId, quote.productId, quote.buyer, vault,
            quote.coverageAmount, quote.premiumAmount, quote.durationSeconds
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    function oracle() external view returns (address) { return _oracle; }
    function phalaVerifier() external view returns (address) { return _phalaVerifier; }
    function policyManager() external view returns (address) { return _policyManager; }

    function isProductAvailable(bytes32 productId) external view returns (bool) {
        return _products[productId] != address(0) && _productActive[productId];
    }

    function getProductShield(bytes32 productId) external view returns (address) {
        return _products[productId];
    }

    function getPolicyVault(bytes32 productId, uint256 policyId) external view returns (address) {
        return _policyVault[productId][policyId];
    }

    function protocolFeeBps() external view returns (uint16) { return _protocolFeeBps; }
    function feeReceiver() external view returns (address) { return _feeReceiver; }

    function isNonceUsed(uint256 nonce) external view returns (bool) { return _usedNonces[nonce]; }
    function isPaused() external view returns (bool) { return _paused; }

    /// @notice Check if a policy has been resolved (paid out or cleaned up)
    function isPolicyResolved(bytes32 productId, uint256 policyId) external view returns (bool) {
        return _policyResolved[productId][policyId];
    }

    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == _cachedChainId) return _cachedDomainSeparator;
        return _computeDomainSeparator();
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════

    function _hashQuote(SignedQuote calldata q) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            QUOTE_TYPEHASH, q.productId, q.coverageAmount, q.premiumAmount,
            q.durationSeconds, q.asset, q.stablecoin, q.protocol,
            q.buyer, q.deadline, q.nonce
        ));
    }

    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH, keccak256("LuminaProtocol"), keccak256("1"), block.chainid, address(this)
        ));
    }

    /// @dev [M-2/M-3] USDC is pegged 1:1 to USD, both 6 decimals. No conversion needed.
    function _convertToUSDC(uint256 usdAmount) internal pure returns (uint256) {
        return usdAmount;
    }

    /// @dev [M-2/M-3] USDC is pegged 1:1 to USD, both 6 decimals. No conversion needed.
    function _convertToUSDCSafe(uint256 usdAmount) internal pure returns (uint256) {
        return usdAmount;
    }

    function _authorizeUpgrade(address /* newImplementation */) internal override onlyOwner {}
}
