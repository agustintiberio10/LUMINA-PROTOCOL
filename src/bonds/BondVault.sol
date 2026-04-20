// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title BondVault
/// @notice Immutable vault holding 70M LUMINA. Backs all ClaimBond payouts.
/// @dev NO owner. NO withdraw. NO upgrade. NO escape hatch.
///      LUMINA tokens are NOT locked or reserved — they sit passively.
///      Vault tracks bonds in USD (totalCommittedUSD), not in LUMINA.
///      Tokens only leave via redeemBond() when a bond matures.
///      Bond payouts are FIXED IN USD, settled in LUMINA at market price at redemption.
///      Even the founder cannot access these tokens. Verifiable on-chain.

interface IBurnable {
    function burn(uint256 amount) external;
}

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

contract BondVault is ReentrancyGuard, AccessControl {
    // ═══════ ROLES ═══════
    bytes32 public constant AUTHORIZED_CALLER_ADMIN_ROLE = keccak256("AUTHORIZED_CALLER_ADMIN_ROLE");

    // ═══════ IMMUTABLES ═══════
    IERC20 public immutable lumina;
    IClaimBond public immutable claimBond;
    IPriceOracle public immutable priceOracle;
    address public policyManager;
    address private immutable _deployer;
    bool private _policyManagerSet;

    // ═══════ CONSTANTS ═══════
    uint256 public constant SAFETY_FACTOR_BPS = 5000; // 50% — max commitment
    uint256 public constant BOND_MATURITY_SECONDS = 730 days; // 24 months
    uint256 public constant MIN_REDEEM_PRICE = 0.001e18; // absolute floor for redemption

    // ═══════ STATE ═══════
    uint256 public totalCommittedUSD; // total USD value of active bonds (18-dec USD-wei)

    // [V5.0] Authorized callers for BuybackEngine integration
    mapping(address => bool) public authorizedCallers;

    // ═══════ EVENTS ═══════
    event BondIssued(address indexed to, uint256 indexed epochId, uint256 usdAmount);
    event BondRedeemed(
        address indexed holder, uint256 indexed epochId, uint256 usdAmount, uint256 luminaAmount, uint256 priceUsed
    );
    event ObligationsDecreased(address indexed caller, uint256 amount, uint256 newTotal);
    event ReservesBurned(address indexed caller, uint256 amount, uint256 newBalance);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);
    event PolicyManagerSet(address indexed policyManager);

    // ═══════ MODIFIERS ═══════
    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender], "BondVault: caller not authorized");
        _;
    }

    constructor(address _lumina, address _claimBond, address _priceOracle, address _policyManager) {
        require(_lumina != address(0), "Zero lumina");
        require(_claimBond != address(0), "Zero claimBond");
        require(_priceOracle != address(0), "Zero oracle");
        // _policyManager can be address(0) for 2-step initialization pattern
        _deployer = msg.sender;

        lumina = IERC20(_lumina);
        claimBond = IClaimBond(_claimBond);
        priceOracle = IPriceOracle(_priceOracle);

        // Grant deployer admin roles for initial wiring
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUTHORIZED_CALLER_ADMIN_ROLE, msg.sender);

        if (_policyManager != address(0)) {
            policyManager = _policyManager;
            _policyManagerSet = true;
        }
    }

    /// @notice One-shot setter for PolicyManager (resolves circular deploy dependency).
    /// @dev Only callable by the original deployer, and only once.
    function setPolicyManager(address _pm) external {
        require(msg.sender == _deployer, "Only deployer");
        require(!_policyManagerSet, "PolicyManager already set");
        require(_pm != address(0), "Zero address");
        policyManager = _pm;
        _policyManagerSet = true;
        emit PolicyManagerSet(_pm);
    }

    // ═══════ ISSUE BONDS (called by PolicyManager on trigger) ═══════

    /// @notice Issue ClaimBond tokens when a policy triggers.
    /// @param to User whose bet triggered
    /// @param usdPayout Payout in USD (e.g., 800 = $800). 1 bond token = $1.
    /// @dev At issuance: no LUMINA calculation. Only USD accounting.
    ///      LUMINA price is read at redemption (24 months later), not now.
    function issueBond(address to, uint256 usdPayout) external nonReentrant {
        require(msg.sender == policyManager, "Only PolicyManager");
        require(to != address(0), "Zero address");
        require(usdPayout > 0, "Zero payout");

        uint256 currentPrice = priceOracle.getLuminaPrice();

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
    function getStatus()
        external
        view
        returns (
            uint256 reserveBalance,
            uint256 reserveValueUSD,
            uint256 committed,
            uint256 availableUSD,
            uint256 currentPrice
        )
    {
        currentPrice = _getSafePrice();
        reserveBalance = lumina.balanceOf(address(this));
        uint256 reserveValueUSD18 = (reserveBalance * currentPrice) / 1e18;
        uint256 maxCommit18 = (reserveValueUSD18 * SAFETY_FACTOR_BPS) / 10000;
        reserveValueUSD = reserveValueUSD18 / 1e18;
        committed = totalCommittedUSD / 1e18;
        availableUSD = maxCommit18 > totalCommittedUSD ? (maxCommit18 - totalCommittedUSD) / 1e18 : 0;
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

    // ═══════ V5.0: BUYBACK ENGINE INTEGRATION ═══════

    /// @notice Reduce obligations after a bond is burned by BuybackEngine
    /// @param amount Amount in 18-dec USD-wei to reduce
    function decreaseObligations(uint256 amount) external onlyAuthorized {
        require(amount > 0, "Amount must be > 0");
        require(totalCommittedUSD >= amount, "Amount exceeds committed");
        totalCommittedUSD -= amount;
        emit ObligationsDecreased(msg.sender, amount, totalCommittedUSD);
    }

    /// @notice Burn LUMINA from vault reserves (Double Burn by BuybackEngine)
    /// @param amount Quantity of LUMINA to burn
    function burnFromReserves(uint256 amount) external onlyAuthorized {
        require(amount > 0, "Amount must be > 0");
        uint256 currentBalance = lumina.balanceOf(address(this));
        require(currentBalance >= amount, "Insufficient reserves");
        // Cap: max 5% of vault per tx
        uint256 maxBurnPerTx = (currentBalance * 5) / 100;
        require(amount <= maxBurnPerTx, "Exceeds 5% per-tx cap");
        // Burn via ERC20Burnable.burn (BondVault holds the tokens)
        IBurnable(address(lumina)).burn(amount);
        emit ReservesBurned(msg.sender, amount, lumina.balanceOf(address(this)));
    }

    /// @notice Authorize/revoke a caller (e.g. BuybackEngine) for decreaseObligations/burnFromReserves
    /// @param caller Address to modify
    /// @param authorized true to authorize, false to revoke
    function setAuthorizedCaller(address caller, bool authorized) external onlyRole(AUTHORIZED_CALLER_ADMIN_ROLE) {
        require(caller != address(0), "Zero address");
        authorizedCallers[caller] = authorized;
        emit AuthorizedCallerUpdated(caller, authorized);
    }

    // ═══════ NO withdraw(), NO owner, NO upgrade ═══════
    // Exits: redeemBond() for matured bonds, burnFromReserves() for authorized callers.
    // Authorization: AUTHORIZED_CALLER_ADMIN_ROLE manages authorized callers.
}

