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
 *   - _isTestnet guard for _convertToUSDY
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
    address private _usdyToken;
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

    // ═══════════════════════════════════════════════════════════
    //  EVENTS (additional, not in interface)
    // ═══════════════════════════════════════════════════════════

    event UsdyTokenUpdated(address indexed oldToken, address indexed newToken);
    event PolicyManagerUpdated(address indexed oldManager, address indexed newManager);
    event TestnetModeChanged(bool isTestnet);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS (additional)
    // ═══════════════════════════════════════════════════════════

    error ZeroAddress(string param);
    error ProductAlreadyRegistered(bytes32 productId);
    error InvalidAllocationBps(uint16 bps);
    error USDYConversionNotImplemented();

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
        address usdyToken_,
        bool isTestnet_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress("owner");
        if (oracle_ == address(0)) revert ZeroAddress("oracle");
        if (phalaVerifier_ == address(0)) revert ZeroAddress("phalaVerifier");
        if (policyManager_ == address(0)) revert ZeroAddress("policyManager");
        if (usdyToken_ == address(0)) revert ZeroAddress("usdyToken");

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _oracle = oracle_;
        _phalaVerifier = phalaVerifier_;
        _policyManager = policyManager_;
        _usdyToken = usdyToken_;
        _isTestnet = isTestnet_;

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

    // ═══════════════════════════════════════════════════════════
    //  AGENT OPERATIONS
    // ═══════════════════════════════════════════════════════════

    function purchasePolicy(
        SignedQuote calldata quote,
        bytes calldata signature
    ) external nonReentrant whenNotPaused returns (PurchaseResult memory result) {

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

        // 4. Transfer premium to the SPECIFIC vault that backs this policy
        uint256 usdyPremium = _convertToUSDY(quote.premiumAmount);
        IERC20(_usdyToken).safeTransferFrom(msg.sender, address(this), usdyPremium);
        IERC20(_usdyToken).forceApprove(vault, usdyPremium);
        IVault(vault).receivePremium(usdyPremium, quote.productId, policyId);
        IERC20(_usdyToken).forceApprove(vault, 0); // Clear residual allowance

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

        // 3. Mark resolved BEFORE external calls
        _policyResolved[productId][policyId] = true;

        // 4. Mark paid + release allocation from the SPECIFIC vault
        IShield(shield).markPaidOut(policyId);
        address vault = _policyVault[productId][policyId];
        if (vault == address(0)) revert InvalidPolicyForPayout(policyId);
        IPolicyManager(_policyManager).releaseAllocation(productId, policyId, info.coverageAmount, vault);

        // 5. Execute payout from the SPECIFIC vault
        uint256 usdyPayout = _convertToUSDYSafe(pr.payoutAmount);
        if (usdyPayout > 0) {
            IVault(vault).executePayout(pr.recipient, usdyPayout, productId, policyId);
        }

        emit PayoutTriggered(policyId, productId, pr.recipient, pr.payoutAmount);
    }

    /**
     * @notice Cleanup expired policy — NOT paused
     */
    function cleanupExpiredPolicy(bytes32 productId, uint256 policyId) external nonReentrant {
        if (_policyResolved[productId][policyId]) revert PolicyAlreadyResolved(productId, policyId);

        address shield = _products[productId];
        if (shield == address(0)) revert ProductNotAvailable(productId);

        IShield.PolicyInfo memory info = IShield(shield).getPolicyInfo(policyId);
        IShield.PolicyStatus status = IShield(shield).getPolicyStatus(policyId);

        if (status != IShield.PolicyStatus.ACTIVE && status != IShield.PolicyStatus.SETTLEMENT)
            revert InvalidPolicyForPayout(policyId);
        if (block.timestamp <= info.cleanupAt) revert InvalidPolicyForPayout(policyId);

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

    function setUsdyToken(address newUsdyToken) external onlyOwner {
        if (newUsdyToken == address(0)) revert ZeroAddress("usdyToken");
        address old = _usdyToken;
        _usdyToken = newUsdyToken;
        emit UsdyTokenUpdated(old, newUsdyToken);
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

    function isNonceUsed(uint256 nonce) external view returns (bool) { return _usedNonces[nonce]; }
    function isPaused() external view returns (bool) { return _paused; }

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

    function _convertToUSDY(uint256 usdAmount) internal view returns (uint256) {
        if (!_isTestnet) revert USDYConversionNotImplemented();
        return usdAmount;
    }

    function _convertToUSDYSafe(uint256 usdAmount) internal view returns (uint256) {
        if (_isTestnet) return usdAmount;
        // Mainnet: try oracle, fallback to 1:1
        return usdAmount; // Placeholder until oracle implemented
    }

    function _authorizeUpgrade(address /* newImplementation */) internal override onlyOwner {}
}
