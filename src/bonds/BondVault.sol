// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ChainGuard} from "../utils/ChainGuard.sol";
import {IBurnable} from "../interfaces/IBurnable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title BondVault
/// @notice Vault holding 70M LUMINA. Backs all ClaimBond payouts.
/// @dev LUMINA tokens are NOT locked or reserved — they sit passively.
///      Vault tracks bonds in USD (totalCommittedUSD), not in LUMINA.
///      Tokens only leave via redeemBond() when a bond matures.
///      Bond payouts are FIXED IN USD, settled in LUMINA at market price at redemption.
///
///      [V5.1] UUPS upgradeable proxy pattern.

interface IClaimBond {
    function mint(address to, uint256 epochId, uint256 usdAmount) external;
    function burn(address from, uint256 epochId, uint256 usdAmount) external;
    function isMatured(uint256 epochId) external view returns (bool);
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @notice [Sprint Fix Audit Economic — R1] Minimal hook into CEXLiquidityReserve
///         so BondVault can pull emergency liquidity when capacity dips below
///         the safety threshold. Read-side helpers come from `lumina.balanceOf`.
interface ICexReserveInjector {
    function injectToVault(uint256 amount) external;
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
    /// @notice Absolute floor for redemption pricing.
    /// @dev    [F-02 fix] Raised from 0.001e18 -> 0.005e18. This is a HARD STOP,
    ///         not a settleable value: the redeem path requires `currentPrice >
    ///         MIN_REDEEM_PRICE` (strict), and `_getSafePrice()` is split into a
    ///         fail-closed variant (`_redeemPrice()`) that REVERTS with
    ///         `ORACLE_UNAVAILABLE` on oracle revert/zero rather than flooring.
    ///         Display/view paths may still use the floored `_getSafePrice()`.
    uint256 public constant MIN_REDEEM_PRICE = 0.005e18; // absolute floor for redemption ($0.005)

    /// @notice Bounds for `bondMaturitySeconds` setter (Sprint T, ADR-009).
    /// @dev MIN allows Sepolia E2E testing (≥60s); MAX caps at 10 years to
    ///      prevent admin error from creating effectively-immortal bonds.
    uint256 public constant MIN_BOND_MATURITY_SECONDS = 1 minutes;
    uint256 public constant MAX_BOND_MATURITY_SECONDS = 10 * 365 days; // 10 years

    /// @notice [Sprint T-30a, Phase D] Redemption throttle.
    /// @dev    Caps cumulative USD-value redeemed per 7-day epoch at 1.08% of
    ///         the current vault LUMINA balance (measured at the time of the
    ///         call). Over-cap redemptions are queued FIFO to the next epoch.
    ///         Founder decision: in a black-swan mass-redemption scenario the
    ///         vault drains at most ~13% in 12 weeks (12 * 1.08% ~= 12.96%).
    uint16 public constant MAX_REDEMPTION_PER_EPOCH_BPS = 108; // 1.08% of vault per epoch
    uint32 public constant EPOCH_DURATION = 7 days; // 604800 seconds

    // ═══════ QUEUE BOUNDS + PER-USER THROTTLE (F-10 fix) ═══════
    /// @notice [F-10 fix] Cap a single user's redemption per throttle-epoch at
    ///         10% of that epoch's cap, to deter a whale from monopolizing the
    ///         throttle window (immediate + queued combined).
    uint16 public constant MAX_USER_REDEEM_BPS = 1000; // 10% of epoch cap per user
    /// @notice [F-10 fix] Hard bound on queued entries per throttle-epoch to
    ///         prevent unbounded-array griefing / gas exhaustion on processQueue.
    uint256 public constant MAX_QUEUE_PER_EPOCH = 10_000;
    /// @notice [F-10 fix] Max queue entries drained in a single processQueue call
    ///         (paginated draining — keeps gas bounded, anyone can call again).
    uint256 public constant MAX_PROCESS_PER_CALL = 20;
    /// @notice [F-10 fix] Minimum queued entry size (integer USD) to deter dust
    ///         spam that would inflate the queue toward MAX_QUEUE_PER_EPOCH.
    uint256 public constant MIN_QUEUED_USD = 1; // $1 minimum to queue

    // ═══════ AUTO-INJECTION COOLDOWN (F-07 fix) ═══════
    /// @notice [F-07 fix] Minimum interval between CEX-reserve auto-injections.
    ///         A price-only capacity dip cannot fire injection more than once
    ///         per cooldown, so a manipulated TWAP cannot force-drain the CEX
    ///         reserve over a short window.
    uint256 public constant INJECTION_COOLDOWN = 1 days;

    // ═══════ AUTO-INJECTION + FLOOR (Sprint Fix Audit Economic — R1) ═══════
    /// @notice Threshold (bps of max-capacity) at-or-below which CEX Reserve
    ///         auto-injection is triggered. 5000 = 50% available capacity.
    uint16 public constant CAPACITY_RATIO_THRESHOLD_BPS = 5000;
    /// @notice LUMINA spot price (USD, 18-dec) at-or-below which `policiesPaused`
    ///         is set. Mirrors `MIN_PRICE_FOR_NEW_POLICIES` in CoverRouterV2.
    uint256 public constant LUMINA_FLOOR_PRICE = 5e15; // $0.005
    /// @notice Hysteresis multiplier (bps) on `LUMINA_FLOOR_PRICE` for unpause.
    ///         12000 = price must recover to 120% of floor (= $0.006) to unpause.
    uint16 public constant FLOOR_RECOVERY_HYSTERESIS_BPS = 12000;
    /// @notice Fraction (bps) of the CEX Reserve's current LUMINA balance pulled
    ///         per auto-injection trigger. 1000 = 10%.
    uint16 public constant INJECTION_AMOUNT_BPS = 1000;

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

    // ═══════ THROTTLE STORAGE (Sprint T-30a, Phase D) ═══════
    /// @notice Cumulative USD-value (18-dec USD-wei) redeemed per 7-day epoch.
    mapping(uint256 => uint256) public redeemedInEpoch;

    /// @notice One entry per over-cap bond redemption deferred to a future epoch.
    /// @dev    Bonds are burned from the holder at queue time (custody-by-debt).
    ///         When `processQueue()` drains an entry, LUMINA is transferred to
    ///         `holder` at the price observed at processing time.
    struct QueuedRedemption {
        address holder;
        uint256 epochIdBond; // ClaimBond ERC-1155 epoch ID (YYYYMM) — the bond's maturity epoch
        uint256 usdAmount; // integer dollars (matches redeemBond's `usdAmount` argument)
        uint64 queuedAt;
    }

    /// @notice FIFO queue per 7-day epoch (key = `currentEpoch()` value).
    mapping(uint256 => QueuedRedemption[]) public queueByEpoch;

    /// @notice Next index to process in `queueByEpoch[epoch]`.
    mapping(uint256 => uint256) public queueProcessedIndex;

    // ═══════ AUTO-INJECTION + FLOOR STORAGE (Sprint Fix Audit Economic — R1) ═══════
    /// @notice CEXLiquidityReserve authorized to push emergency liquidity here.
    ///         Set by admin via `setCexReserve(address)`. When unset (address(0))
    ///         the auto-injection branch of `_checkAndInject` is a no-op so the
    ///         feature is opt-in per deployment.
    address public cexReserve;

    /// @notice Soft-pause flag flipped when the LUMINA spot price crosses the
    ///         `LUMINA_FLOOR_PRICE` floor (with hysteresis on recovery). NOT
    ///         enforced inside BondVault itself — exposed for the SDK / dashboards
    ///         / CoverRouter to query before allowing new policies. Off-chain
    ///         enforcement is deliberate: Sprint Fix Audit Economic explicitly
    ///         keeps CoverRouterV2 out of scope.
    bool public policiesPaused;

    /// @notice Cumulative LUMINA (18-dec wei) pulled from `cexReserve` via the
    ///         auto-injection mechanism. Tracked for post-hoc accounting.
    uint256 public totalInjectedFromCex;

    // ═══════ RED-TEAM FIX STORAGE (APPEND-ONLY — must stay last before __gap) ═══════
    // These slots are appended AFTER all previously-deployed storage so the live
    // UUPS layout (BondVault gap was [43]) stays compatible. Do NOT reorder.

    /// @notice [F-04 fix] USD-value (18-dec USD-wei) of redemptions QUEUED but not
    ///         yet paid in LUMINA. Queued entries are reclassified from
    ///         `totalCommittedUSD` into this bucket at queue time and only leave
    ///         the vault's accounting at pay time in `processQueue`.
    ///         `availableCapacityUSD()` subtracts this so queued debt cannot be
    ///         counted as free backing (solvency-ceiling fix).
    uint256 public totalQueuedUSD;

    /// @notice [F-10 fix] Cumulative USD-value (18-dec USD-wei) a given user has
    ///         redeemed-or-queued within a throttle-epoch. Enforces
    ///         `MAX_USER_REDEEM_BPS` so no single account monopolizes the window.
    mapping(uint256 => mapping(address => uint256)) public redeemedByUserInEpoch;

    /// @notice [F-07 fix] Unix timestamp of the last auto-injection attempt.
    ///         Injection is gated to once per `INJECTION_COOLDOWN`.
    uint256 public lastInjectionTimestamp;

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

    /// @notice [Sprint T-30a, Phase D] Emitted when a redemption would exceed the
    ///         per-epoch cap and is deferred FIFO to the next epoch.
    /// @param  holder           Bond holder whose redemption was queued.
    /// @param  epochIdBond      ClaimBond epoch ID (YYYYMM) the queued bond belongs to.
    /// @param  usdAmount        USD amount queued (integer dollars).
    /// @param  targetThrottleEpoch  Throttle-epoch index the redemption is queued into.
    event BondQueued(
        address indexed holder, uint256 indexed epochIdBond, uint256 usdAmount, uint256 indexed targetThrottleEpoch
    );

    /// @notice [Sprint T-30a, Phase D] Emitted when `processQueue()` drains
    ///         queued redemptions in the current throttle-epoch.
    /// @param  throttleEpoch  Throttle-epoch processed.
    /// @param  count          Number of queue entries drained in this call.
    event QueueProcessed(uint256 indexed throttleEpoch, uint256 count);

    /// @notice [Sprint Fix Audit Economic — R1] CEX Reserve wired/rotated.
    event CexReserveSet(address indexed oldReserve, address indexed newReserve);
    /// @notice [Sprint Fix Audit Economic — R1] Capacity dropped under threshold;
    ///         emergency LUMINA pulled from CEX Reserve.
    event AutoInjectionTriggered(uint256 availableCapacityBps, uint256 amountInjected);
    /// @notice [Sprint Fix Audit Economic — R1] Spot LUMINA price crossed the
    ///         floor; `policiesPaused` set true.
    event FloorPriceBreached(uint256 luminaPrice);
    /// @notice [Sprint Fix Audit Economic — R1] `policiesPaused` flipped (true =
    ///         soft-pause active, false = recovered past hysteresis).
    event PoliciesPausedSet(bool paused);

    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();
    /// @notice [F-02 fix] Thrown on the redeem/processQueue settlement path when
    ///         the oracle reverts or returns a price at/under the redemption floor.
    error ORACLE_UNAVAILABLE();

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
    /// @dev [F-16 fix] Gated on `DEFAULT_ADMIN_ROLE` instead of the deployer EOA.
    ///      Binding to the deployer EOA was fragile (lost if the deployer key is
    ///      rotated/compromised, and not transferable to a Gnosis Safe admin).
    ///      The one-shot `!_policyManagerSet` guard is preserved so this remains
    ///      a single wiring step; rotation post-set is intentionally NOT allowed
    ///      here (kept minimal, matching prior semantics).
    function setPolicyManager(address _pm) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        ChainGuard.requireValidChain();
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

        // [Sprint Fix Audit Economic - R1] A new commitment may have moved the
        // available-capacity ratio under threshold even without a payout.
        _checkAndInject(currentPrice);
    }

    // ═══════ REDEEM BONDS (called by holder at maturity) ═══════

    /// @notice Redeem matured bonds. Pays USD value in LUMINA at current market price.
    /// @dev    [Sprint T-30a, Phase D] Subject to the per-epoch throttle
    ///         (`MAX_REDEMPTION_PER_EPOCH_BPS` of vault LUMINA per `EPOCH_DURATION`).
    ///         If the request would push the current throttle-epoch over its cap,
    ///         the bonds are burned from `msg.sender` (custody-by-debt) and the
    ///         redemption is enqueued FIFO for the next throttle-epoch. The
    ///         queued holder then receives LUMINA when `processQueue()` is called
    ///         in (or after) the target epoch. ClaimBond `totalCommittedUSD`
    ///         accounting is decremented up-front in BOTH paths so that available
    ///         capacity reflects the in-flight obligation.
    /// @param  epochId   ClaimBond maturity epoch (YYYYMM).
    /// @param  usdAmount Integer-dollar amount to redeem (partial allowed).
    function redeemBond(uint256 epochId, uint256 usdAmount) external nonReentrant {
        ChainGuard.requireValidChain();
        require(usdAmount > 0, "Zero amount");
        require(claimBond.isMatured(epochId), "Not matured");
        require(claimBond.balanceOf(msg.sender, epochId) >= usdAmount, "Insufficient bonds");

        // [F-02 fix] Fail-closed price: reverts ORACLE_UNAVAILABLE on oracle
        // revert/zero rather than flooring, and the floor is a strict hard stop
        // (`> MIN_REDEEM_PRICE`), not a settleable value.
        uint256 currentPrice = _redeemPrice();
        require(currentPrice > MIN_REDEEM_PRICE, "Price too low");

        // [Sprint T-30a, Phase D] Throttle check. Compute cap in 18-dec USD-wei
        // so it can be compared directly to `redeemedInEpoch`.
        uint256 throttleEpoch = currentEpoch();
        uint256 capUSD18 = _maxRedeemUSD18ThisEpoch(currentPrice);
        uint256 requestedUSD18 = usdAmount * 1e18;

        // [F-10 fix] Per-user throttle: a single account may redeem-or-queue at
        // most MAX_USER_REDEEM_BPS of the epoch cap. Counts immediate + queued.
        uint256 userCapUSD18 = (capUSD18 * uint256(MAX_USER_REDEEM_BPS)) / 10_000;
        require(redeemedByUserInEpoch[throttleEpoch][msg.sender] + requestedUSD18 <= userCapUSD18, "User epoch limit");
        redeemedByUserInEpoch[throttleEpoch][msg.sender] += requestedUSD18;

        if (redeemedInEpoch[throttleEpoch] + requestedUSD18 > capUSD18) {
            // Over cap: burn the bonds from the holder (custody-by-debt) and
            // enqueue for the NEXT throttle-epoch. LUMINA is paid out when
            // `processQueue()` is called against the target epoch.
            //
            // [F-10 fix] Enforce a minimum queued size (anti-dust) and a hard
            // per-epoch queue-length bound (anti-griefing).
            require(usdAmount >= MIN_QUEUED_USD, "Below min queue size");
            uint256 target = throttleEpoch + 1;
            require(queueByEpoch[target].length < MAX_QUEUE_PER_EPOCH, "Queue full");

            // [F-04 fix] DO NOT decrement totalCommittedUSD here. The obligation
            // is still backed by LUMINA that has NOT yet left the vault; moving
            // it out of `committed` now would free capacity before payment and
            // overstate available backing. Instead reclassify committed->queued.
            if (totalCommittedUSD >= requestedUSD18) {
                totalCommittedUSD -= requestedUSD18;
            } else {
                // [MR-L04 fix] Clamp edge (shouldn't happen in practice). The
                // per-user counter was charged the UNCLAMPED requestedUSD18 above;
                // refund the clamped-off portion so the user's epoch window
                // allowance is not over-debited for value that was never queued.
                uint256 clampedOff = requestedUSD18 - totalCommittedUSD;
                if (redeemedByUserInEpoch[throttleEpoch][msg.sender] >= clampedOff) {
                    redeemedByUserInEpoch[throttleEpoch][msg.sender] -= clampedOff;
                } else {
                    redeemedByUserInEpoch[throttleEpoch][msg.sender] = 0;
                }
                requestedUSD18 = totalCommittedUSD; // clamp
                totalCommittedUSD = 0;
            }
            totalQueuedUSD += requestedUSD18;

            claimBond.burn(msg.sender, epochId, usdAmount);
            queueByEpoch[target].push(
                QueuedRedemption({
                    holder: msg.sender, epochIdBond: epochId, usdAmount: usdAmount, queuedAt: uint64(block.timestamp)
                })
            );
            emit BondQueued(msg.sender, epochId, usdAmount, target);
            return;
        }

        // Within cap: redeem immediately.
        redeemedInEpoch[throttleEpoch] += requestedUSD18;

        // [F-04] Immediate path: LUMINA leaves the vault NOW, so decrement the
        // committed obligation at pay time (matches the cash outflow).
        if (totalCommittedUSD >= requestedUSD18) {
            totalCommittedUSD -= requestedUSD18;
        } else {
            totalCommittedUSD = 0;
        }

        // [V2/SR2] Pay LUMINA in 18-decimal wei.
        uint256 luminaAmount = (usdAmount * 1e36) / currentPrice;
        require(lumina.balanceOf(address(this)) >= luminaAmount, "Insufficient reserve");

        claimBond.burn(msg.sender, epochId, usdAmount);
        require(lumina.transfer(msg.sender, luminaAmount), "Transfer failed");

        emit BondRedeemed(msg.sender, epochId, usdAmount, luminaAmount, currentPrice);

        // [Sprint Fix Audit Economic - R1] After a payout the vault balance just
        // dropped; check whether we should pull liquidity from CEX Reserve and
        // whether the price floor still holds.
        _checkAndInject(currentPrice);
    }

    // ═══════ THROTTLE — PUBLIC VIEW HELPERS (Sprint T-30a, Phase D) ═══════

    /// @notice Current 7-day throttle epoch index (block.timestamp / EPOCH_DURATION).
    /// @dev    This is independent of ClaimBond's monthly `epochId` (YYYYMM).
    /// @dev    [F-27] block.timestamp boundary gaming: a validator can nudge the
    ///         timestamp by at most ~±15s (Ethereum) / sub-second (L2 sequencer).
    ///         Against a 7-day (604800s) throttle epoch and a 730-day bond
    ///         maturity, a ±15s drift is economically negligible (≈0.0025% of an
    ///         epoch) and cannot meaningfully shift which epoch/maturity bucket a
    ///         redemption lands in. Accepted as documented tolerance — no
    ///         additional grace window is warranted.
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_DURATION;
    }

    /// @notice Max USD-value redeemable in the current throttle-epoch.
    /// @dev    Returns INTEGER dollars (no 18-dec scaling) so wallets/UIs can
    ///         consume it directly. The value is `(vaultLuminaBalance *
    ///         currentPrice / 1e18) * MAX_REDEMPTION_PER_EPOCH_BPS / 10_000`,
    ///         then descaled to integer USD. Computed lazily — every call
    ///         re-reads vault balance + price, so it shrinks as the vault is
    ///         drained.
    function maxRedeemThisEpoch() external view returns (uint256) {
        uint256 currentPrice = _getSafePrice();
        return _maxRedeemUSD18ThisEpoch(currentPrice) / 1e18;
    }

    /// @dev Internal: USD-cap for the current throttle-epoch, in 18-dec USD-wei
    ///      so it lines up with `redeemedInEpoch[]` entries.
    function _maxRedeemUSD18ThisEpoch(uint256 currentPrice) internal view returns (uint256) {
        uint256 reserveBalance = lumina.balanceOf(address(this));
        uint256 reserveValueUSD18 = (reserveBalance * currentPrice) / 1e18;
        return (reserveValueUSD18 * uint256(MAX_REDEMPTION_PER_EPOCH_BPS)) / 10_000;
    }

    /// @notice Length of the FIFO queue for a given throttle-epoch.
    function queueLength(uint256 throttleEpoch) external view returns (uint256) {
        return queueByEpoch[throttleEpoch].length;
    }

    /// @notice Permissionless: drain as many queued redemptions as the current
    ///         throttle-epoch cap allows, in FIFO order. Anyone may call.
    /// @dev    Stops on the first entry that would breach the cap; remaining
    ///         entries stay queued for a subsequent call (later in this epoch
    ///         or in a future epoch). LUMINA is paid out at the price observed
    ///         AT PROCESSING TIME — same model as the immediate-redeem path.
    function processQueue() external nonReentrant {
        uint256 throttleEpoch = currentEpoch();
        // [F-02 fix] Fail-closed price (reverts ORACLE_UNAVAILABLE) + strict floor.
        uint256 currentPrice = _redeemPrice();
        require(currentPrice > MIN_REDEEM_PRICE, "Price too low");

        uint256 capUSD18 = _maxRedeemUSD18ThisEpoch(currentPrice);
        uint256 already = redeemedInEpoch[throttleEpoch];
        uint256 startIdx = queueProcessedIndex[throttleEpoch];
        QueuedRedemption[] storage queue = queueByEpoch[throttleEpoch];
        uint256 processed = 0;

        // [F-10 fix] Paginated skip-and-advance scan. `cursor` advances by EXACTLY
        // one per iteration (only `scanned` increments in the loop) so entries are
        // never skipped; an over-cap "fat" entry is left in place (no head-of-line
        // block) and `queueProcessedIndex` is advanced past the leading run of
        // fully-paid (usdAmount==0) entries AFTER the loop.
        uint256 scanned = 0;
        while (startIdx + scanned < queue.length && scanned < MAX_PROCESS_PER_CALL) {
            QueuedRedemption storage q = queue[startIdx + scanned];
            uint256 needUSD18 = q.usdAmount * 1e18;

            // Already-drained sentinel, or an entry that doesn't fit the remaining
            // cap → skip (leave in place) and keep scanning.
            if (q.usdAmount == 0 || already + needUSD18 > capUSD18) {
                unchecked {
                    ++scanned;
                }
                continue;
            }

            uint256 luminaAmount = (q.usdAmount * 1e36) / currentPrice;
            require(lumina.balanceOf(address(this)) >= luminaAmount, "Insufficient reserve");

            already += needUSD18;

            // [MR-M02 fix] Attribute this queued payout to the holder's per-user
            // counter for the PROCESSING epoch. The per-user cap was charged in the
            // QUEUE epoch at queue time, but the LUMINA actually leaves the vault
            // now (epoch `throttleEpoch`); without this, a holder could draw a fresh
            // full per-user amount via redeemBond in the same processing epoch while
            // their queued payout also consumed the epoch's global cap — ~2x the
            // intended per-user share. Charging it here reduces their fresh-redeem
            // headroom by exactly the queued amount. We only ATTRIBUTE (never revert):
            // the entry already passed the per-user cap at queue time.
            redeemedByUserInEpoch[throttleEpoch][q.holder] += needUSD18;

            // [MR-L10 fix] Pay time: the queued obligation leaves the vault now, so
            // remove it ONLY from `totalQueuedUSD`. It was already moved OUT of
            // `totalCommittedUSD` at queue time (committed -= x; queued += x). The
            // previous code ALSO decremented `totalCommittedUSD` here — a DOUBLE
            // decrement that, when other holders still had committed obligations,
            // wrongly wiped their committed value, understating `totalUsed` and
            // OVERSTATING `availableCapacityUSD` (over-issuance / under-collateral).
            // Decrement queued only.
            if (totalQueuedUSD >= needUSD18) {
                totalQueuedUSD -= needUSD18;
            } else {
                totalQueuedUSD = 0;
            }

            // Bonds were already burned at queue time — only LUMINA is moved here.
            require(lumina.transfer(q.holder, luminaAmount), "Transfer failed");

            emit BondRedeemed(q.holder, q.epochIdBond, q.usdAmount, luminaAmount, currentPrice);

            // Mark drained so a later scan won't re-pay it. usdAmount==0 is an
            // unambiguous "already paid" sentinel for skipped-over entries.
            q.usdAmount = 0;
            unchecked {
                ++processed;
                ++scanned;
            }
        }

        // [F-10 fix] Advance the persistent processed index over the leading run
        // of fully-paid entries (so a skipped fat entry stays at the head for a
        // later call, but everything paid before it is accounted for).
        uint256 idx = startIdx;
        while (idx < queue.length && queue[idx].usdAmount == 0) {
            unchecked {
                ++idx;
            }
        }

        redeemedInEpoch[throttleEpoch] = already;
        queueProcessedIndex[throttleEpoch] = idx;
        emit QueueProcessed(throttleEpoch, processed);

        // [Sprint Fix Audit Economic - R1] Queue processing drains the vault in
        // batches; mirror the redeemBond hook so capacity / floor stay in sync.
        _checkAndInject(currentPrice);
    }

    // ═══════ VIEW FUNCTIONS ═══════

    /// @notice Remaining USD capacity that can be issued as new bonds.
    function availableCapacityUSD() external view returns (uint256) {
        uint256 currentPrice = _getSafePrice();
        uint256 reserveBalance = lumina.balanceOf(address(this));
        uint256 reserveValueUSD18 = (reserveBalance * currentPrice) / 1e18;
        uint256 maxCommitUSD18 = (reserveValueUSD18 * SAFETY_FACTOR_BPS) / 10000;
        // [V5/M-RACE] Subtract BOTH committed and reserved to prevent race condition.
        // [F-04 fix] Also subtract `totalQueuedUSD`: queued redemptions are backed
        // by LUMINA still in the vault but already owed — counting that backing as
        // "free" would let new bonds breach the solvency ceiling before payout.
        uint256 totalUsed = totalCommittedUSD + totalReservedUSD + totalQueuedUSD;
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
        // [V5/M-RACE] Account for reserved capacity in available calculation.
        // [F-04 fix] Include `totalQueuedUSD` (queued-but-unpaid obligations).
        uint256 totalUsed = totalCommittedUSD + totalReservedUSD + totalQueuedUSD;
        availableUSD = maxCommit18 > totalUsed ? (maxCommit18 - totalUsed) / 1e18 : 0;
    }

    // ═══════ INTERNAL ═══════

    /// @notice [F-02] Defensive (display) price: floors to MIN_REDEEM_PRICE on
    ///         oracle revert/zero. Used ONLY by view/display paths
    ///         (availableCapacityUSD, getStatus, previewRedemption, throttle cap
    ///         views). MUST NOT be used to settle a redemption — see `_redeemPrice`.
    function _getSafePrice() internal view returns (uint256) {
        try priceOracle.getLuminaPrice() returns (uint256 p) {
            return p > 0 ? p : MIN_REDEEM_PRICE;
        } catch {
            return MIN_REDEEM_PRICE;
        }
    }

    /// @notice [F-02 fix] Fail-closed price used to SETTLE redemptions.
    /// @dev    On oracle revert OR a zero/below-floor reading we REVERT
    ///         (`ORACLE_UNAVAILABLE`) rather than flooring — an oracle-unavailable
    ///         or attacker-pushed-to-floor condition must NOT allow redemption at
    ///         an attacker-favorable price. Callers additionally require the
    ///         returned price be strictly `> MIN_REDEEM_PRICE`.
    function _redeemPrice() internal view returns (uint256) {
        try priceOracle.getLuminaPrice() returns (uint256 p) {
            if (p <= MIN_REDEEM_PRICE) revert ORACLE_UNAVAILABLE();
            return p;
        } catch {
            revert ORACLE_UNAVAILABLE();
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

    // ═══════ AUTO-INJECTION + FLOOR (Sprint Fix Audit Economic - R1) ═══════

    /// @notice Admin: wire (or rotate) the CEXLiquidityReserve authorized to
    ///         push emergency LUMINA into this vault. Setting `address(0)` is
    ///         allowed and turns the auto-injection branch into a no-op (the
    ///         floor-price branch keeps working independently).
    function setCexReserve(address _cexReserve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = cexReserve;
        cexReserve = _cexReserve;
        emit CexReserveSet(old, _cexReserve);
    }

    /// @notice Available-capacity ratio in bps (10000 = 100% available, 0 = full).
    /// @dev    Defined as `(maxCommitUSD18 - totalUsed) / maxCommitUSD18 * 10000`
    ///         with `totalUsed = totalCommittedUSD + totalReservedUSD`. Returns
    ///         0 when fully committed or when maxCommitUSD18 is 0 (degenerate).
    function availableCapacityRatioBps() external view returns (uint256) {
        return _availableCapacityRatioBps(_getSafePrice());
    }

    function _availableCapacityRatioBps(uint256 currentPrice) internal view returns (uint256) {
        uint256 reserveBalance = lumina.balanceOf(address(this));
        uint256 reserveValueUSD18 = (reserveBalance * currentPrice) / 1e18;
        uint256 maxCommitUSD18 = (reserveValueUSD18 * SAFETY_FACTOR_BPS) / 10000;
        if (maxCommitUSD18 == 0) return 0;
        // [F-04 fix] Mirror availableCapacityUSD: include queued obligations.
        uint256 totalUsed = totalCommittedUSD + totalReservedUSD + totalQueuedUSD;
        if (totalUsed >= maxCommitUSD18) return 0;
        return ((maxCommitUSD18 - totalUsed) * 10000) / maxCommitUSD18;
    }

    /// @notice [Sprint Fix Audit Economic - R1] Two-branch safety hook:
    ///         (1) if available capacity dips at/under `CAPACITY_RATIO_THRESHOLD_BPS`
    ///             and a CEX Reserve is wired with non-zero LUMINA balance, pull
    ///             `INJECTION_AMOUNT_BPS` of that balance into this vault;
    ///         (2) if spot LUMINA price is at/under `LUMINA_FLOOR_PRICE` and we
    ///             are not already paused, flip `policiesPaused = true`. On
    ///             recovery (`price >= floor * hysteresis`) flip back to false.
    /// @dev    No-throws: failures (insufficient reserve, oracle revert) MUST
    ///         NOT bubble back into the calling business path (redeem, processQueue,
    ///         issueBond). Hence the try/catch on injectToVault.
    function _checkAndInject(uint256 currentPrice) internal {
        // (1) Capacity check + injection
        //
        // [F-07 fix] Cooldown gate: a price-only capacity dip cannot fire injection
        // more than once per INJECTION_COOLDOWN, capping per-window LUMINA pulled
        // from the CEX reserve. Per-window cumulative cap now also enforced
        // reserve-side (MR-M03). cexReserve is address(0) today (dormant).
        //
        // [MR-M03 fix] The injection DECISION must use a FAIL-CLOSED price, never
        // the floored/synthesized `_getSafePrice()` that `pokeCheckAndInject` may
        // pass. A floored price understates capacity and could synthesize a
        // capacity breach during an oracle outage, force-pulling reserve on a price
        // the settlement path explicitly rejects. So we RE-READ the oracle here and
        // SKIP injection entirely unless we get a real reading > MIN_REDEEM_PRICE.
        // (The floor-pause branch below intentionally keeps using `currentPrice` —
        // pausing on a low/uncertain price is the conservative action.)
        if (cexReserve != address(0)) {
            uint256 injectionPrice = 0;
            try priceOracle.getLuminaPrice() returns (uint256 p) {
                if (p > MIN_REDEEM_PRICE) injectionPrice = p;
            } catch {
                // leave injectionPrice == 0 → skip injection (oracle unavailable)
            }
            uint256 ratioBps = injectionPrice == 0 ? 10001 : _availableCapacityRatioBps(injectionPrice);
            if (
                injectionPrice > 0 && ratioBps <= CAPACITY_RATIO_THRESHOLD_BPS
                    && block.timestamp >= lastInjectionTimestamp + INJECTION_COOLDOWN
            ) {
                uint256 reserveBalance = lumina.balanceOf(cexReserve);
                uint256 injectAmount = (reserveBalance * uint256(INJECTION_AMOUNT_BPS)) / 10000;
                if (injectAmount > 0) {
                    // Set the cooldown BEFORE the external call (CEI) so a
                    // re-entrant injectToVault cannot bypass the once-per-window
                    // guard even if the external reserve is malicious.
                    lastInjectionTimestamp = block.timestamp;
                    try ICexReserveInjector(cexReserve).injectToVault(injectAmount) {
                        totalInjectedFromCex += injectAmount;
                        emit AutoInjectionTriggered(ratioBps, injectAmount);
                    } catch {
                        // Swallow: emergency liquidity is best-effort. The
                        // floor-price branch below still runs. (Cooldown stays
                        // set; a failed pull still consumes the window — that is
                        // the conservative choice for F-07.)
                    }
                }
            }
        }

        // (2) Floor-price check with hysteresis
        if (currentPrice <= LUMINA_FLOOR_PRICE && !policiesPaused) {
            policiesPaused = true;
            emit FloorPriceBreached(currentPrice);
            emit PoliciesPausedSet(true);
        } else if (policiesPaused) {
            uint256 recoveryThreshold = (LUMINA_FLOOR_PRICE * uint256(FLOOR_RECOVERY_HYSTERESIS_BPS)) / 10000;
            if (currentPrice >= recoveryThreshold) {
                policiesPaused = false;
                emit PoliciesPausedSet(false);
            }
        }
    }

    /// @notice Permissionless: re-evaluate the auto-injection + floor flags
    ///         without going through a business action. Useful for keepers /
    ///         the SDK to nudge the vault into sync when no organic call has
    ///         happened recently.
    function pokeCheckAndInject() external {
        _checkAndInject(_getSafePrice());
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

    // [Sprint T, ADR-009] Storage gap reduced from 50 -> 49 to compensate for
    // the new `bondMaturitySeconds` storage variable. Total storage footprint
    // (existing state vars + new var + gap) preserved.
    // [Sprint T-30a, Phase D] Gap reduced further from 49 -> 46 to compensate
    // for three new mapping slots (`redeemedInEpoch`, `queueByEpoch`,
    // `queueProcessedIndex`). Mappings consume one slot each regardless of
    // value-type size (the QueuedRedemption struct lives in dynamic storage).
    // [Sprint Fix Audit Economic - R1] Gap reduced from 46 to 43 to make room
    // for `cexReserve` (slot), `policiesPaused` (slot), `totalInjectedFromCex`
    // (slot).
    // [Red-team fixes] Gap reduced from 43 to 40 to make room for three new
    // APPENDED storage slots (declared above the auto-injection storage block,
    // but slots are allocated in declaration order so layout stays append-only):
    //   - `totalQueuedUSD`          (F-04, 1 slot)
    //   - `redeemedByUserInEpoch`   (F-10, 1 mapping slot)
    //   - `lastInjectionTimestamp`  (F-07, 1 slot)
    uint256[40] private __gap;
}
