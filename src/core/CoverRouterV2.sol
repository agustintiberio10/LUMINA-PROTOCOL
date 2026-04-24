// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CoverRouterV2
/// @notice Single entry point for users (humans + AI agents) to buy policies.
/// @dev Simplified from V1: no vaults, no waterfall, no protocol fee split.
///      100% of premiums go to TWAPBurner for buy & burn.
///      Supports direct purchase + relayer pattern (purchasePolicyFor).
///
///      [V5.1] UUPS upgradeable proxy pattern.

interface IPriceOracleForRouter {
    function getLuminaPrice() external view returns (uint256);
}

interface IPolicyManagerV2 {
    function recordPolicy(
        bytes32 productId,
        address buyer,
        uint256 coverageAmount,
        uint256 premiumAmount,
        uint32 durationSeconds,
        bytes32 asset
    ) external returns (uint256 policyId);

    function triggerPayout(bytes32 productId, uint256 policyId, bytes calldata oracleProof) external;
}

interface ITWAPBurner {
    function receivePremium(uint256 amount) external;
}

contract CoverRouterV2 is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ═══════ STORAGE (was immutable, now upgradeable storage) ═══════
    IERC20 public usdc;

    // ═══════ CONSTANTS ═══════
    uint256 public constant MIN_PRICE_FOR_NEW_POLICIES = 5e15; // 0.005 USD in 18 dec
    uint256 public constant RESET_PRICE_FOR_NEW_POLICIES = 8e15; // 0.008 USD in 18 dec

    // ═══════ STATE ═══════
    IPolicyManagerV2 public policyManager;
    ITWAPBurner public twapBurner;
    IPriceOracleForRouter public capacityOracle;
    bool public paused;

    // Relayer pattern: authorized addresses that can buy on behalf of agents
    mapping(address => bool) public authorizedRelayers;

    // Product pricing config (stored here for the API/frontend to read)
    struct ProductConfig {
        bytes32 productId;
        uint256 payoutRatioBps; // 8000 = 80%
        uint256 triggerProbBps; // probability in bps (e.g., 20 = 0.20%)
        uint256 marginBps; // 15000 = 1.50x
        uint32 durationSeconds;
        bool active;
    }

    mapping(bytes32 => ProductConfig) public products;
    bytes32[] public productList;

    // ═══════ EVENTS ═══════
    event PolicyPurchased(
        bytes32 indexed productId,
        uint256 indexed policyId,
        address indexed buyer,
        uint256 coverage,
        uint256 premium,
        uint256 payout,
        address paidBy
    );
    event TriggerSubmitted(bytes32 indexed productId, uint256 indexed policyId, address submitter);
    event ProductConfigured(bytes32 indexed productId);
    event RelayerUpdated(address relayer, bool authorized);
    event Paused(bool state);
    /// @notice [LOW-2 fix] Emitted on successful non-core token rescue.
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);

    // ═══════ ERRORS ═══════
    error ContractPaused();
    error ProductNotConfigured(bytes32 productId);
    error ProductInactive(bytes32 productId);
    error InvalidCoverage(uint256 amount);
    error PremiumMismatch(uint256 expected, uint256 provided);
    error NotAuthorizedRelayer(address caller);
    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdc, address _policyManager, address _twapBurner) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_usdc != address(0), "Zero USDC");
        require(_policyManager != address(0), "Zero PM");
        require(_twapBurner != address(0), "Zero burner");

        usdc = IERC20(_usdc);
        policyManager = IPolicyManagerV2(_policyManager);
        twapBurner = ITWAPBurner(_twapBurner);
    }

    // ═══════ PURCHASE: Direct (user buys for themselves) ═══════

    /// @notice Buy a policy directly. User pays premium in USDC.
    function purchasePolicy(bytes32 productId, uint256 coverageAmount, bytes32 asset)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 policyId)
    {
        return _purchase(productId, coverageAmount, asset, msg.sender, msg.sender);
    }

    // ═══════ PURCHASE: Relayer pattern (agent buys via API) ═══════

    /// @notice Buy a policy on behalf of another address. For API/relayer use.
    function purchasePolicyFor(bytes32 productId, uint256 coverageAmount, bytes32 asset, address buyer)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 policyId)
    {
        if (!authorizedRelayers[msg.sender]) revert NotAuthorizedRelayer(msg.sender);
        require(buyer != address(0), "Zero buyer");
        return _purchase(productId, coverageAmount, asset, buyer, msg.sender);
    }

    // ═══════ TRIGGER: Submit oracle proof ═══════

    /// @notice Submit a trigger proof. Anyone can call (permissionless).
    function submitTrigger(bytes32 productId, uint256 policyId, bytes calldata oracleProof) external nonReentrant {
        policyManager.triggerPayout(productId, policyId, oracleProof);
        emit TriggerSubmitted(productId, policyId, msg.sender);
    }

    // ═══════ INTERNAL ═══════

    function _purchase(bytes32 productId, uint256 coverageAmount, bytes32 asset, address buyer, address payer)
        internal
        returns (uint256 policyId)
    {
        // Auto-pause: block new policies if LUMINA price is below safety threshold
        if (address(capacityOracle) != address(0)) {
            require(
                capacityOracle.getLuminaPrice() >= MIN_PRICE_FOR_NEW_POLICIES,
                "Protocol auto-paused: LUMINA price below safety threshold"
            );
        }

        ProductConfig storage config = products[productId];
        if (config.durationSeconds == 0) revert ProductNotConfigured(productId);
        if (!config.active) revert ProductInactive(productId);
        if (coverageAmount < 100e6) revert InvalidCoverage(coverageAmount); // min $100

        // Calculate premium: coverage × payoutRatio × triggerProb × margin / (10000^3)
        uint256 premium = (coverageAmount * config.payoutRatioBps * config.triggerProbBps * config.marginBps)
            / (10000 * 10000 * 10000);
        if (premium == 0) premium = 1; // minimum 1 unit USDC ($0.000001)

        // Transfer USDC from payer
        usdc.safeTransferFrom(payer, address(this), premium);

        // Send 100% to TWAPBurner for burn
        // [M-4] Use forceApprove to handle USDC-style approve-from-nonzero race.
        usdc.forceApprove(address(twapBurner), premium);
        twapBurner.receivePremium(premium);

        // Record policy in PolicyManager
        policyId = policyManager.recordPolicy(productId, buyer, coverageAmount, premium, config.durationSeconds, asset);

        uint256 payout = (coverageAmount * config.payoutRatioBps) / 10000;
        emit PolicyPurchased(productId, policyId, buyer, coverageAmount, premium, payout, payer);
    }

    // ═══════ ADMIN ═══════

    /// @notice Configure a product's pricing parameters.
    function configureProduct(
        bytes32 _productId,
        uint256 _payoutRatioBps,
        uint256 _triggerProbBps,
        uint256 _marginBps,
        uint32 _durationSeconds,
        bool _active
    ) external onlyOwner {
        require(_durationSeconds > 0, "Duration must be > 0");
        if (products[_productId].durationSeconds == 0) {
            productList.push(_productId);
        }
        products[_productId] = ProductConfig({
            productId: _productId,
            payoutRatioBps: _payoutRatioBps,
            triggerProbBps: _triggerProbBps,
            marginBps: _marginBps,
            durationSeconds: _durationSeconds,
            active: _active
        });
        emit ProductConfigured(_productId);
    }

    function setRelayer(address relayer, bool authorized) external onlyOwner {
        authorizedRelayers[relayer] = authorized;
        emit RelayerUpdated(relayer, authorized);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function setPolicyManager(address _pm) external onlyOwner {
        require(_pm != address(0), "Zero");
        policyManager = IPolicyManagerV2(_pm);
    }

    function setTwapBurner(address _burner) external onlyOwner {
        require(_burner != address(0), "Zero");
        twapBurner = ITWAPBurner(_burner);
    }

    function setCapacityOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Zero");
        capacityOracle = IPriceOracleForRouter(_oracle);
    }

    // ═══════ VIEW ═══════

    /// @notice Calculate premium for a given product and coverage.
    function quotePremium(bytes32 productId, uint256 coverageAmount)
        external
        view
        returns (uint256 premium, uint256 payout)
    {
        ProductConfig storage config = products[productId];
        require(config.durationSeconds > 0, "Product not configured");
        premium = (coverageAmount * config.payoutRatioBps * config.triggerProbBps * config.marginBps)
            / (10000 * 10000 * 10000);
        if (premium == 0) premium = 1;
        payout = (coverageAmount * config.payoutRatioBps) / 10000;
    }

    function getProductConfig(bytes32 productId) external view returns (ProductConfig memory) {
        return products[productId];
    }

    function getProductCount() external view returns (uint256) {
        return productList.length;
    }

    /// @notice Returns true if LUMINA price is below the safety threshold for new policies.
    function isProtocolAutoPaused() external view returns (bool) {
        if (address(capacityOracle) == address(0)) return false;
        return capacityOracle.getLuminaPrice() < MIN_PRICE_FOR_NEW_POLICIES;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ═══════ RESCUE (LOW-2 fix, audit #26) ═══════

    /// @notice Recover non-USDC ERC-20 tokens sent to this contract by mistake.
    function recoverToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (token == address(usdc)) revert CoreTokenProtected(token);

        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, amount, to);
    }

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
