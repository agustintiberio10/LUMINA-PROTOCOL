// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MonthCalculator} from "../libraries/MonthCalculator.sol";

/// @dev [V5.1] UUPS upgradeable proxy pattern.
///      Tier-1 redesign: the original three sub-bucket model
///      (ImmediateUse / VestingLinear / StrategicReserve) has been removed
///      in favour of a single flat 14M reserve gated only by the mutable
///      `monthlyCap`. Allocations now consume `totalAllocated` until the
///      hard ceiling `TOTAL_AMOUNT` is hit, with no per-bucket sub-caps,
///      no time-locked strategic carve-out, and no linear vesting curve.
contract CEXLiquidityReserve is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    /// @notice [DEPRECATED — kept only so external indexers and existing
    ///         clients that still reference the old enum keep ABI-compiling.
    ///         The contract no longer reads or writes any SubBucket value.
    ///         New integrations should NOT pass this through any function;
    ///         `allocate()` no longer accepts a SubBucket parameter.]
    enum SubBucket {
        ImmediateUse,
        VestingLinear,
        StrategicReserve
    }

    enum Purpose {
        DEX_SECONDARY_POOL,
        CEX_LISTING_TIER_3,
        CEX_LISTING_TIER_2,
        CEX_LISTING_TIER_1,
        MARKET_MAKER_LOAN
    }

    /// @notice Per-allocation record. The `subBucket` field has been
    ///         removed in the Tier-1 redesign — allocate() no longer
    ///         takes one and the contract no longer tracks per-bucket
    ///         spending.
    struct Allocation {
        address recipient;
        uint256 amount;
        Purpose purpose;
        string description;
        uint256 timestamp;
        address allocator;
    }

    IERC20 public lumina;
    uint256 public deploymentTimestamp;
    uint256 public constant TOTAL_AMOUNT = 14_000_000 * 1e18;
    uint256 public constant DEFAULT_MONTHLY_CAP = 1_000_000 * 1e18;
    uint256 public constant MAX_MONTHLY_CAP = TOTAL_AMOUNT;

    /// @dev [V1 STORAGE — DEPRECATED, DO NOT REUSE]
    ///      Slots 2/3/4 were occupied by `allocatedFromImmediate`,
    ///      `allocatedFromVesting`, `allocatedFromStrategic` in V1.
    ///      They are preserved with `__deprecated_*` names to keep the
    ///      UUPS storage layout backward-compatible after upgrade.
    ///      `initializeV2` reads these once to seed `totalAllocated`,
    ///      after which they remain frozen for the life of the proxy.
    uint256 private __deprecated_allocatedFromImmediate;
    uint256 private __deprecated_allocatedFromVesting;
    uint256 private __deprecated_allocatedFromStrategic;

    mapping(uint256 => uint256) public monthlyAllocations;
    Allocation[] public allocationHistory;

    /// @notice Mutable monthly allocation cap. Use `setMonthlyCap` to update.
    /// @dev    Occupies the first slot of the original `__gap[50]` so that
    ///         storage layouts of pre-existing deployments (V5.1) remain
    ///         compatible after this upgrade. `__gap` shrinks to [49].
    uint256 public monthlyCap;

    /// @notice Cumulative LUMINA allocated through the lifetime of the proxy.
    ///         Replaces the V1 `allocatedFromImmediate + allocatedFromVesting
    ///         + allocatedFromStrategic` triple. Hard-capped at `TOTAL_AMOUNT`.
    /// @dev    Appended AFTER `monthlyCap` so existing slots 0..7 are
    ///         untouched. Lives in what was formerly the first reserved
    ///         gap slot (now consumed). `__gap` shrinks accordingly.
    uint256 public totalAllocated;

    event Allocated(
        address indexed recipient, uint256 amount, Purpose purpose, string description, address indexed allocator
    );
    event MonthlyCapWarning(uint256 month, uint256 spent, uint256 cap);
    /// @notice Emitted when DEFAULT_ADMIN_ROLE updates the monthly cap.
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap, address indexed updater, uint256 timestamp);
    /// @notice [LOW-2 fix] Emitted on successful non-core token rescue.
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);

    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _lumina, address _multisigOwner) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_lumina != address(0), "Lumina zero address");
        require(_multisigOwner != address(0), "Multisig zero address");
        lumina = IERC20(_lumina);
        deploymentTimestamp = block.timestamp;
        monthlyCap = DEFAULT_MONTHLY_CAP;
        _grantRole(DEFAULT_ADMIN_ROLE, _multisigOwner);
        _grantRole(ALLOCATOR_ROLE, _multisigOwner);
    }

    /// @notice Re-init hook for existing deployments upgrading from the
    ///         constant-cap / sub-bucket version. Sets `monthlyCap` to the
    ///         default 1M so post-upgrade allocates do not revert from a
    ///         zero cap, and seeds `totalAllocated` from the deprecated
    ///         per-bucket counters so the new flat ceiling correctly
    ///         reflects pre-upgrade spending.
    /// @dev    `reinitializer(2)` enforces this runs at most once per proxy
    ///         and only after the original `initialize()` (version 1).
    ///         Gated by `DEFAULT_ADMIN_ROLE` so a stranger cannot front-run
    ///         the multisig and reset the cap to default.
    function initializeV2() external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        monthlyCap = DEFAULT_MONTHLY_CAP;
        totalAllocated = __deprecated_allocatedFromImmediate + __deprecated_allocatedFromVesting
            + __deprecated_allocatedFromStrategic;
    }

    /// @notice Allocate LUMINA from the flat 14M reserve. No sub-bucket,
    ///         no time-lock, no vesting curve — only the mutable monthly
    ///         cap and the lifetime `TOTAL_AMOUNT` ceiling apply.
    function allocate(address recipient, uint256 amount, Purpose purpose, string calldata description)
        external
        onlyRole(ALLOCATOR_ROLE)
        nonReentrant
    {
        require(recipient != address(0), "Zero recipient");
        require(amount > 0, "Zero amount");
        require(bytes(description).length > 0, "Description required");
        require(bytes(description).length <= 200, "Description too long");
        require(totalAllocated + amount <= TOTAL_AMOUNT, "Exceeds total reserve");
        _enforceMonthlyCap(amount);

        totalAllocated += amount;
        allocationHistory.push(
            Allocation({
                recipient: recipient,
                amount: amount,
                purpose: purpose,
                description: description,
                timestamp: block.timestamp,
                allocator: msg.sender
            })
        );

        lumina.safeTransfer(recipient, amount);
        emit Allocated(recipient, amount, purpose, description, msg.sender);
    }

    /// @dev Charges `amount` against the current 30-day bucket and reverts
    ///      if it would push spending past `monthlyCap`. Also emits a
    ///      MonthlyCapWarning when the bucket crosses 80% utilisation.
    function _enforceMonthlyCap(uint256 amount) internal {
        uint256 currentMonth = getCurrentMonth();
        uint256 monthlySpent = monthlyAllocations[currentMonth];
        require(monthlySpent + amount <= monthlyCap, "Monthly cap exceeded");
        monthlyAllocations[currentMonth] = monthlySpent + amount;
        if (monthlyAllocations[currentMonth] > (monthlyCap * 80) / 100) {
            emit MonthlyCapWarning(currentMonth, monthlyAllocations[currentMonth], monthlyCap);
        }
    }

    function getTotalAllocated() external view returns (uint256) {
        return totalAllocated;
    }

    function getAllocationHistoryLength() external view returns (uint256) {
        return allocationHistory.length;
    }

    /// @dev [Fix M-9] Routed through `MonthCalculator` for protocol-wide
    ///      formula consistency. Anchor = `deploymentTimestamp` (preserves
    ///      pre-fix semantics: month 0 spans the first 30 days post-deploy).
    function getCurrentMonth() public view returns (uint256) {
        return MonthCalculator.currentMonthSinceDeploy(deploymentTimestamp);
    }

    function getMonthlyCapRemaining() external view returns (uint256) {
        uint256 spent = monthlyAllocations[getCurrentMonth()];
        if (spent >= monthlyCap) return 0;
        return monthlyCap - spent;
    }

    /// @notice Update the global monthly allocation cap. Multisig admin only.
    /// @dev    Effective immediately for the current 30-day bucket. Already-
    ///         consumed `monthlyAllocations[currentMonth]` is preserved — a
    ///         decrease in cap can leave `spent > newCap`, which simply means
    ///         no further allocates are possible until the next bucket.
    /// @param  newCap New cap, in LUMINA wei (18 decimals). Must be in
    ///                (0, MAX_MONTHLY_CAP].
    function setMonthlyCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCap > 0, "Cap zero");
        require(newCap <= MAX_MONTHLY_CAP, "Cap exceeds total reserve");
        uint256 oldCap = monthlyCap;
        monthlyCap = newCap;
        emit MonthlyCapUpdated(oldCap, newCap, msg.sender, block.timestamp);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ═══════ RESCUE (LOW-2 fix, audit #26) ═══════

    /// @notice Recover non-LUMINA ERC-20 tokens sent to this contract by mistake.
    function recoverToken(address token, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (token == address(lumina)) revert CoreTokenProtected(token);

        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, amount, to);
    }

    uint256[48] private __gap;
}
