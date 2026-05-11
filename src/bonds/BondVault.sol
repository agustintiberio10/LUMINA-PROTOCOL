// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title BondVault
/// @notice Vault holding 70M LUMINA. Backs all ClaimBond payouts.
/// @dev LUMINA tokens are NOT locked or reserved — they sit passively.
///      Vault tracks bonds in USD (totalCommittedUSD), not in LUMINA.
///      Tokens only leave via redeemBond() when a bond matures.
///      Bond payouts are FIXED IN USD, settled in LUMINA at market price at redemption.
///
///      [V5.1] UUPS upgradeable proxy pattern.

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

contract BondVault is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    // ═══════ ROLES ═══════
    bytes32 public constant AUTHORIZED_CALLER_ADMIN_ROLE = keccak256("AUTHORIZED_CALLER_ADMIN_ROLE");

    // ═══════ STORAGE (was immutable, now upgradeable storage) ═══════
    IERC20 public lumina;
    IClaimBond public claimBond;
    IPriceOracle public priceOracle;
    address public policyManager;
    address private _deployer;
    bool private _policyManagerSet;

    // ═══════ CONSTANTS ═══════
    uint256 public constant SAFETY_FACTOR_BPS = 5000; // 50% — max commitment
    uint256 public constant MIN_REDEEM_PRICE = 0.001e18; // absolute floor for redemption

    /// @notice Bounds for `bondMaturitySeconds` setter (Sprint T, ADR-009).
    /// @dev MIN allows Sepolia E2E testing (≥60s); MAX caps at 10 years to
    ///      prevent admin error from creating effectively-immortal bonds.
    uint256 public constant MIN_BOND_MATURITY_SECONDS = 1 minutes;
    uint256 public constant MAX_BOND_MATURITY_SECONDS = 10 * 365 days; // 10 years

    /// @notice [Sprint W] Version constant to validate upgrade mechanism end-to-end.
    /// @dev Cosmetic-only change to a fresh impl deployed for upgrade testing.
    ///      Reachable only when the proxy points to a SET-C-derived impl that
    ///      includes this constant. After the upgrade test rolls back, the
    ///      proxy returns to the canonical SET C impl and `VERSION()` reverts.
    string public constant VERSION = "5.1.1-upgrade-validated";

    // ═══════ STATE ═══════
    uint256 public totalCommittedUSD; // total USD value of active bonds (18-dec USD-wei)
    uint256 public totalReservedUSD; // capacity reserved by active policies awaiting trigger (18-dec USD-wei)

    // [V5.0] Authorized callers for BuybackEngine integration
    mapping(address => bool) public authorizedCallers;

    /// @notice Bond maturity in seconds. Default 730 days (mainnet); settable
    ///         by admin within `[MIN_BOND_MATURITY_SECONDS, MAX_BOND_MATURITY_SECONDS]`.
    /// @dev    Sprint T (ADR-009) — converts the previous `constant 730 days` to
    ///         storage so Sepolia can run E2E redemption flows in seconds rather
    ///         than waiting 730 days. Mainnet keeps the 730d default.
    uint256 public bondMaturitySeconds;

    // ═══════ EVENTS ═══════
    event BondIssued(address indexed to, uint256 indexed epochId, uint256 usdAmount);
    event BondRedeemed(
        address indexed holder, uint256 indexed epochId, uint256 usdAmount, uint256 luminaAmount, uint256 priceUsed
    );
    event ObligationsDecreased(address indexed caller, uint256 amount, uint256 newTotal);
    event ReservesBurned(address indexed caller, uint256 amount, uint256 newBalance);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);
    event PolicyManagerSet(address indexed policyManager);
    event CapacityReserved(uint256 amount, uint256 newTotalReserved);
    event ReservationReleased(uint256 amount, uint256 newTotalReserved);
    event ReservationCommitted(uint256 amount, uint256 newTotalReserved);
    /// @notice [LOW-2 fix] Emitted on successful non-core token rescue (ERC-20 or ERC-1155).
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);
    /// @notice [Sprint T, ADR-009] Emitted when admin updates the bond maturity duration.
    event BondMaturityUpdated(uint256 oldValue, uint256 newValue);

    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();

    // ═══════ MODIFIERS ═══════
    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender], "BondVault: caller not authorized");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _lumina, address _claimBond, address _priceOracle, address _policyManager)
        public
        initializer
    {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        require(_lumina != address(0), "Zero lumina");
        require(_claimBond != address(0), "Zero claimBond");
        require(_priceOracle != address(0), "Zero oracle");
        // _policyManager can be address(0) for 2-step initialization pattern
        _deployer = msg.sender;

        lumina = IERC20(_lumina);
        claimBond = IClaimBond(_claimBond);
        priceOracle = IPriceOracle(_priceOracle);

        // [Sprint T, ADR-009] Default mainnet maturity. Admin may override via
        // setBondMaturitySeconds() — Sepolia uses 60s for E2E redemption tests.
        bondMaturitySeconds = 730 days;

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

    // ═══════ CAPACITY RESERVATION (called by PolicyManager at purchase/expiry/trigger) ═══════

    /// @notice Reserve capacity at policy purchase time to prevent race conditions.
    /// @param amount Amount in 18-dec USD-wei to reserve
    function reserveCapacity(uint256 amount) external {
        require(msg.sender == policyManager, "Only PolicyManager");
        require(amount > 0, "Zero amount");
        totalReservedUSD += amount;
        emit CapacityReserved(amount, totalReservedUSD);
    }

    /// @notice Release a reservation when a policy expires without triggering.
    /// @param amount Amount in 18-dec USD-wei to release
    function releaseReservation(uint256 amount) external {
        require(msg.sender == policyManager, "Only PolicyManager");
        require(amount > 0, "Zero amount");
        require(totalReservedUSD >= amount, "Insufficient reservation");
        totalReservedUSD -= amount;
        emit ReservationReleased(amount, totalReservedUSD);
    }

    /// @notice Convert a reservation into a commitment when a policy triggers.
    /// @param amount Amount in 18-dec USD-wei to commit
    function commitReservation(uint256 amount) external {
        require(msg.sender == policyManager, "Only PolicyManager");
        require(amount > 0, "Zero amount");
        require(totalReservedUSD >= amount, "Insufficient reservation");
        totalReservedUSD -= amount;
        emit ReservationCommitted(amount, totalReservedUSD);
    }

    // ═══════ ISSUE BONDS (called by PolicyManager on trigger) ═══════

    /// @notice Issue ClaimBond tokens when a policy triggers.
    /// @param to User whose bet triggered
    /// @param usdPayout Payout in USD (e.g., 800 = $800). 1 bond token = $1.
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

        uint256 maturityTimestamp = block.timestamp + bondMaturitySeconds;
        uint256 epochId = _timestampToEpoch(maturityTimestamp);

        // [V3/SR2] Normalize to 18-decimal USD (dollar-wei) to match maxCommitUSD units.
        totalCommittedUSD += usdPayout * 1e18;

        claimBond.mint(to, epochId, usdPayout);
        emit BondIssued(to, epochId, usdPayout);
    }

    // ═══════ REDEEM BONDS (called by holder at maturity) ═══════

    /// @notice Redeem matured bonds. Pays USD value in LUMINA at current market price.
    /// @param epochId Maturity epoch
    /// @param usdAmount USD amount to redeem (partial allowed)
    function redeemBond(uint256 epochId, uint256 usdAmount) external nonReentrant {
        require(usdAmount > 0, "Zero amount");
        require(claimBond.isMatured(epochId), "Not matured");
        require(claimBond.balanceOf(msg.sender, epochId) >= usdAmount, "Insufficient bonds");

        uint256 currentPrice = _getSafePrice();
        require(currentPrice >= MIN_REDEEM_PRICE, "Price too low");

        // [V2/SR2] Pay LUMINA in 18-decimal wei.
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
    function availableCapacityUSD() external view returns (uint256) {
        uint256 currentPrice = _getSafePrice();
        uint256 reserveBalance = lumina.balanceOf(address(this));
        uint256 reserveValueUSD18 = (reserveBalance * currentPrice) / 1e18;
        uint256 maxCommitUSD18 = (reserveValueUSD18 * SAFETY_FACTOR_BPS) / 10000;
        // [V5/M-RACE] Subtract BOTH committed and reserved to prevent race condition
        uint256 totalUsed = totalCommittedUSD + totalReservedUSD;
        if (maxCommitUSD18 <= totalUsed) return 0;
        return (maxCommitUSD18 - totalUsed) / 1e18; // return integer dollars
    }

    /// @notice [V2/SR2] Preview LUMINA (18-dec wei) for redeeming `usdAmount` integer dollars.
    function previewRedemption(uint256 usdAmount) external view returns (uint256 luminaAmount) {
        uint256 currentPrice = _getSafePrice();
        luminaAmount = (usdAmount * 1e36) / currentPrice;
    }

    /// @dev [V3/SR2] Returns committed/available/reserveValue in INTEGER DOLLARS for readability.
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
        // [V5/M-RACE] Account for reserved capacity in available calculation
        uint256 totalUsed = totalCommittedUSD + totalReservedUSD;
        availableUSD = maxCommit18 > totalUsed ? (maxCommit18 - totalUsed) / 1e18 : 0;
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

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ═══════ BOND MATURITY (Sprint T, ADR-009) ═══════

    /// @notice Update the bond maturity duration. Bounded between 1 minute and
    ///         10 years; restricted to `DEFAULT_ADMIN_ROLE` (consistent with
    ///         `_authorizeUpgrade`'s gating).
    /// @dev    Sepolia uses ~60s for E2E redemption testing. Mainnet keeps the
    ///         730-day default set in `initialize()`. The change takes effect
    ///         on the NEXT `issueBond` call — already-issued bonds keep their
    ///         original `maturityTimestamp` (encoded into the epoch ID at mint).
    /// @param  newMaturitySeconds New maturity in seconds.
    function setBondMaturitySeconds(uint256 newMaturitySeconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newMaturitySeconds >= MIN_BOND_MATURITY_SECONDS, "Below min maturity");
        require(newMaturitySeconds <= MAX_BOND_MATURITY_SECONDS, "Above max maturity");
        uint256 old = bondMaturitySeconds;
        bondMaturitySeconds = newMaturitySeconds;
        emit BondMaturityUpdated(old, newMaturitySeconds);
    }

    // ═══════ RESCUE (LOW-2 fix, audit #26) ═══════

    /// @notice Recover ERC-20 tokens accidentally sent to this contract.
    /// @dev    LUMINA and ClaimBond (as IERC20) are protected. Admin-gated, reentrancy-safe.
    function recoverToken(address token, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (_isCoreToken(token)) revert CoreTokenProtected(token);

        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, amount, to);
    }

    /// @notice Recover ERC-1155 tokens accidentally sent to this contract.
    /// @dev    ClaimBond is protected. Admin-gated, reentrancy-safe.
    function recoverERC1155(address token, uint256 id, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (_isCoreToken(token)) revert CoreTokenProtected(token);

        IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
        emit TokenRecovered(token, amount, to);
    }

    function _isCoreToken(address token) private view returns (bool) {
        return token == address(lumina) || token == address(claimBond);
    }

    // [Sprint T, ADR-009] Storage gap reduced from 50 → 49 to compensate for
    // the new `bondMaturitySeconds` storage variable. Total storage footprint
    // (existing state vars + new var + gap) preserved.
    uint256[49] private __gap;
}
