// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BondVault
/// @notice Immutable vault holding 82M LUMINA. Backs all ClaimBond payouts.
/// @dev NO owner. NO withdraw. NO upgrade. NO admin. NO escape hatch.
///      LUMINA tokens are NOT locked or reserved — they sit passively.
///      Vault tracks bonds in USD (totalCommittedUSD), not in LUMINA.
///      Tokens only leave via redeemBond() when a bond matures.
///      Bond payouts are FIXED IN USD, settled in LUMINA at market price at redemption.
///      Even the founder cannot access these tokens. Verifiable on-chain.

interface IClaimBond {
    function mint(address to, uint256 epochId, uint256 usdAmount) external;
    function burn(address from, uint256 epochId, uint256 usdAmount) external;
    function isMatured(uint256 epochId) external view returns (bool);
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IPriceOracle {
    /// @notice Current $LUMINA price in USD with 18 decimals.
    /// @return price e.g., 36000000000000000 = $0.036
    function getLuminaPrice() external view returns (uint256 price);
}

contract BondVault is ReentrancyGuard {
    // ═══════ IMMUTABLES ═══════
    IERC20 public immutable lumina;
    IClaimBond public immutable claimBond;
    IPriceOracle public immutable priceOracle;
    address public immutable policyManager;

    // ═══════ CONSTANTS ═══════
    uint256 public constant SAFETY_FACTOR_BPS = 5000;     // 50% — max commitment
    uint256 public constant BOND_MATURITY_SECONDS = 730 days; // 24 months
    uint256 public constant MIN_PRICE = 0.005e18;         // $0.005 circuit breaker
    uint256 public constant RESET_PRICE = 0.008e18;       // $0.008 hysteresis reset
    uint256 public constant MIN_REDEEM_PRICE = 0.001e18;  // absolute floor for redemption
    uint256 public constant BREAKER_COOLDOWN = 1 hours;   // [H-3] min wait between breaker trigger and reset

    // ═══════ STATE ═══════
    uint256 public totalCommittedUSD; // total USD value of active bonds
    bool public paused; // circuit breaker — only blocks new issuance, NEVER blocks redemption
    uint256 public lastBreakerTriggerTime; // [H-3] timestamp of most recent breaker activation

    // ═══════ EVENTS ═══════
    event BondIssued(address indexed to, uint256 indexed epochId, uint256 usdAmount);
    event BondRedeemed(
        address indexed holder,
        uint256 indexed epochId,
        uint256 usdAmount,
        uint256 luminaAmount,
        uint256 priceUsed
    );
    event CircuitBreakerTriggered(uint256 price);
    event CircuitBreakerReset(uint256 price);

    constructor(
        address _lumina,
        address _claimBond,
        address _priceOracle,
        address _policyManager
    ) {
        require(_lumina != address(0), "Zero lumina");
        require(_claimBond != address(0), "Zero claimBond");
        require(_priceOracle != address(0), "Zero oracle");
        require(_policyManager != address(0), "Zero policyManager");

        lumina = IERC20(_lumina);
        claimBond = IClaimBond(_claimBond);
        priceOracle = IPriceOracle(_priceOracle);
        policyManager = _policyManager;
    }

    // ═══════ ISSUE BONDS (called by PolicyManager on trigger) ═══════

    /// @notice Issue ClaimBond tokens when a policy triggers.
    /// @param to User whose bet triggered
    /// @param usdPayout Payout in USD (e.g., 800 = $800). 1 bond token = $1.
    /// @dev At issuance: no LUMINA calculation. Only USD accounting.
    ///      LUMINA price is read at redemption (24 months later), not now.
    function issueBond(address to, uint256 usdPayout) external nonReentrant {
        require(msg.sender == policyManager, "Only PolicyManager");
        require(!paused, "Circuit breaker active");
        require(to != address(0), "Zero address");
        require(usdPayout > 0, "Zero payout");

        uint256 currentPrice = priceOracle.getLuminaPrice();
        // [SR3] Price-below-floor: revert only (state change before revert would be
        // discarded by EVM). Persistent pause is via the separate triggerBreaker() fn.
        require(currentPrice >= MIN_PRICE, "Price below circuit breaker");

        uint256 reserveBalance = lumina.balanceOf(address(this));
        uint256 reserveValueUSD = (reserveBalance * currentPrice) / 1e18;
        uint256 maxCommitUSD = (reserveValueUSD * SAFETY_FACTOR_BPS) / 10000;
        // [V3/SR2] Compare in matching 18-dec USD-wei units.
        require(totalCommittedUSD + (usdPayout * 1e18) <= maxCommitUSD, "Exceeds capacity");

        uint256 maturityTimestamp = block.timestamp + BOND_MATURITY_SECONDS;
        uint256 epochId = _timestampToEpoch(maturityTimestamp);

        // [V3/SR2] Normalize to 18-decimal USD (dollar-wei) to match maxCommitUSD units.
        // Fixes silent capacity bypass where integer-dollars were compared against 18-dec USD.
        totalCommittedUSD += usdPayout * 1e18;

        claimBond.mint(to, epochId, usdPayout);
        emit BondIssued(to, epochId, usdPayout);
    }

    // ═══════ REDEEM BONDS (called by holder at maturity) ═══════

    /// @notice Redeem matured bonds. Pays USD value in LUMINA at current market price.
    /// @param epochId Maturity epoch
    /// @param usdAmount USD amount to redeem (partial allowed)
    /// @dev Redemption is ALWAYS available — even if circuit breaker is active.
    ///      Price is read HERE, at the moment of redemption.
    ///      $800 bond always pays $800 worth of LUMINA, regardless of market conditions.
    function redeemBond(uint256 epochId, uint256 usdAmount) external nonReentrant {
        require(usdAmount > 0, "Zero amount");
        require(claimBond.isMatured(epochId), "Not matured");
        require(claimBond.balanceOf(msg.sender, epochId) >= usdAmount, "Insufficient bonds");

        uint256 currentPrice = _getSafePrice();
        require(currentPrice >= MIN_REDEEM_PRICE, "Price too low");

        // [V2/SR2] Pay LUMINA in 18-decimal wei.
        // usdAmount is integer-dollar units (1 bond token = $1 USD).
        // currentPrice is 18-dec USD per WHOLE LUMINA (1 LUMINA = 1e18 wei).
        // Correct formula: luminaAmount_wei = usdAmount_dollars * 1e36 / price_18dec.
        // (Previously missing one 1e18 factor → paid dust.)
        uint256 luminaAmount = (usdAmount * 1e36) / currentPrice;
        require(lumina.balanceOf(address(this)) >= luminaAmount, "Insufficient reserve");

        // [V3/SR2] totalCommittedUSD is in 18-dec USD-wei. Remove the same scaled amount.
        uint256 commitmentToRemove = usdAmount * 1e18;
        if (totalCommittedUSD >= commitmentToRemove) {
            totalCommittedUSD -= commitmentToRemove;
        } else {
            totalCommittedUSD = 0;
        }

        claimBond.burn(msg.sender, epochId, usdAmount);
        require(lumina.transfer(msg.sender, luminaAmount), "Transfer failed");

        emit BondRedeemed(msg.sender, epochId, usdAmount, luminaAmount, currentPrice);
    }

    // ═══════ CIRCUIT BREAKER ═══════

    /// @notice [SR3] Permissionless trigger for persistent pause.
    /// @dev Anyone can call. If current price is below MIN_PRICE, sets paused=true.
    ///      This is separate from issueBond() because a revert inside issueBond
    ///      would discard the state change. This function lets the state persist.
    function triggerBreaker() external {
        require(!paused, "Already paused");
        uint256 currentPrice = priceOracle.getLuminaPrice();
        require(currentPrice < MIN_PRICE, "Price above floor");
        paused = true;
        lastBreakerTriggerTime = block.timestamp;
        emit CircuitBreakerTriggered(currentPrice);
    }

    /// @notice Reset circuit breaker when price recovers to $0.008 (hysteresis).
    /// @dev [H-3] Permissionless but enforces BREAKER_COOLDOWN (1 hour) between trigger
    ///      and reset to prevent flap-attacks on thin-liquidity spot flashes.
    function resetCircuitBreaker() external {
        require(paused, "Not paused");
        require(
            block.timestamp >= lastBreakerTriggerTime + BREAKER_COOLDOWN,
            "Cooldown active"
        );
        uint256 currentPrice = priceOracle.getLuminaPrice();
        require(currentPrice >= RESET_PRICE, "Price not recovered enough");
        paused = false;
        emit CircuitBreakerReset(currentPrice);
    }

    // ═══════ VIEW FUNCTIONS ═══════

    /// @notice Remaining USD capacity that can be issued as new bonds.
    /// @dev [V3/SR2] Internal accounting is 18-dec USD; this view returns INTEGER DOLLARS
    ///      for API/frontend readability.
    function availableCapacityUSD() external view returns (uint256) {
        uint256 currentPrice = _getSafePrice();
        uint256 reserveBalance = lumina.balanceOf(address(this));
        uint256 reserveValueUSD18 = (reserveBalance * currentPrice) / 1e18;
        uint256 maxCommitUSD18 = (reserveValueUSD18 * SAFETY_FACTOR_BPS) / 10000;
        if (maxCommitUSD18 <= totalCommittedUSD) return 0;
        return (maxCommitUSD18 - totalCommittedUSD) / 1e18; // return integer dollars
    }

    /// @notice [V2/SR2] Preview LUMINA (18-dec wei) for redeeming `usdAmount` integer dollars.
    function previewRedemption(uint256 usdAmount) external view returns (uint256 luminaAmount) {
        uint256 currentPrice = _getSafePrice();
        luminaAmount = (usdAmount * 1e36) / currentPrice;
    }

    /// @dev [V3/SR2] Returns committed/available/reserveValue in INTEGER DOLLARS for readability.
    ///      Internal accounting is 18-dec USD-wei.
    function getStatus() external view returns (
        uint256 reserveBalance,
        uint256 reserveValueUSD,
        uint256 committed,
        uint256 availableUSD,
        uint256 currentPrice,
        bool isPaused
    ) {
        currentPrice = _getSafePrice();
        reserveBalance = lumina.balanceOf(address(this));
        uint256 reserveValueUSD18 = (reserveBalance * currentPrice) / 1e18;
        uint256 maxCommit18 = (reserveValueUSD18 * SAFETY_FACTOR_BPS) / 10000;
        reserveValueUSD = reserveValueUSD18 / 1e18;
        committed = totalCommittedUSD / 1e18;
        availableUSD = maxCommit18 > totalCommittedUSD ? (maxCommit18 - totalCommittedUSD) / 1e18 : 0;
        isPaused = paused;
    }

    // ═══════ INTERNAL ═══════

    function _getSafePrice() internal view returns (uint256) {
        try priceOracle.getLuminaPrice() returns (uint256 p) {
            return p > 0 ? p : MIN_REDEEM_PRICE;
        } catch {
            return MIN_REDEEM_PRICE;
        }
    }

    function _timestampToEpoch(uint256 ts) internal pure returns (uint256) {
        uint256 BASE_TS = 1767225600; // Jan 1 2026 UTC
        require(ts >= BASE_TS, "Before base");
        uint256 monthsFromBase = (ts - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }

    // ═══════ NO withdraw(), NO owner, NO admin, NO upgrade ═══════
    // This contract is fully immutable by design.
    // Only exit: redeemBond() when a bond has matured.
}
