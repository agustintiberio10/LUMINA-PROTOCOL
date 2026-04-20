// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CoverRouterV2
/// @notice Single entry point for users (humans + AI agents) to buy policies.
/// @dev Simplified from V1: no vaults, no waterfall, no protocol fee split.
///      100% of premiums go to TWAPBurner for buy & burn.
///      Supports direct purchase + relayer pattern (purchasePolicyFor).

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

contract CoverRouterV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════ IMMUTABLES ═══════
    IERC20 public immutable usdc;

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

    // ═══════ ERRORS ═══════
    error ContractPaused();
    error ProductNotConfigured(bytes32 productId);
    error ProductInactive(bytes32 productId);
    error InvalidCoverage(uint256 amount);
    error PremiumMismatch(uint256 expected, uint256 provided);
    error NotAuthorizedRelayer(address caller);

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    constructor(address _usdc, address _policyManager, address _twapBurner) Ownable(msg.sender) {
        require(_usdc != address(0), "Zero USDC");
        require(_policyManager != address(0), "Zero PM");
        require(_twapBurner != address(0), "Zero burner");

        usdc = IERC20(_usdc);
        policyManager = IPolicyManagerV2(_policyManager);
        twapBurner = ITWAPBurner(_twapBurner);
    }

    // ═══════ PURCHASE: Direct (user buys for themselves) ═══════

    /// @notice Buy a policy directly. User pays premium in USDC.
    /// @param productId Product identifier (e.g., keccak256("FLASHBTC1H-001"))
    /// @param coverageAmount Coverage in USDC (6 decimals). E.g., 1000e6 = $1,000
    /// @param asset Asset being covered (e.g., "BTC", "ETH", "USDT")
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
    /// @param buyer The address that will own the policy and receive any bond
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
    /// @param productId Product
    /// @param policyId Policy ID within the shield
    /// @param oracleProof Encoded oracle proof (price, asset, timestamp, signature)
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
        require(_durationSeconds > 0, "Duration must be > 0"); // [L-?] prevents duration=0 sentinel confusion
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
}
