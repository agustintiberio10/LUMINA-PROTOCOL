// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev [V5.1] UUPS upgradeable proxy pattern.
contract CEXLiquidityReserve is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

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

    struct Allocation {
        address recipient;
        uint256 amount;
        SubBucket subBucket;
        Purpose purpose;
        string description;
        uint256 timestamp;
        address allocator;
    }

    IERC20 public lumina;
    uint256 public deploymentTimestamp;

    /// @notice [Sprint Fix Audit Economic — R1] BondVault address authorized
    ///         to pull emergency liquidity via `injectToVault`. Set once after
    ///         deployment by admin; can be rotated if the vault is upgraded.
    address public bondVault;

    /// @notice [Sprint Fix Audit Economic — R1] Cumulative LUMINA pushed out via
    ///         `injectToVault` (NOT counted in any allocation sub-bucket — this
    ///         is emergency liquidity outside the normal CEX-listing allocator
    ///         flow). Tracked for transparency and post-hoc accounting.
    uint256 public totalInjected;
    uint256 public constant TOTAL_AMOUNT = 14_000_000 * 1e18;
    uint256 public constant IMMEDIATE_AMOUNT = 2_800_000 * 1e18;
    uint256 public constant VESTING_AMOUNT = 8_400_000 * 1e18;
    uint256 public constant STRATEGIC_AMOUNT = 2_800_000 * 1e18;
    uint256 public constant VESTING_DURATION = 730 days;
    uint256 public constant STRATEGIC_LOCK = 547 days;
    uint256 public constant MONTHLY_CAP = 1_000_000 * 1e18;
    /// @notice [MR-M03 fix] Independent reserve-side guardrails on `injectToVault`,
    ///         enforced regardless of the (upgradeable) BondVault caller.
    uint256 public constant INJECTION_COOLDOWN = 1 days;
    uint256 public constant MAX_INJECTION_BPS = 1000; // 10% of balance per window
    uint256 public allocatedFromImmediate;
    uint256 public allocatedFromVesting;
    uint256 public allocatedFromStrategic;
    mapping(uint256 => uint256) public monthlyAllocations;
    Allocation[] public allocationHistory;
    /// @notice [MR-M03 fix] Timestamp of the last `injectToVault`. Appended storage
    ///         slot (added AFTER `allocationHistory`, BEFORE `__gap`); `__gap` reduced
    ///         from 48 to 47 to preserve the upgrade-safe storage layout.
    uint256 public lastInjectionTimestamp;

    event AllocationExecuted(
        uint256 indexed allocationId,
        address indexed recipient,
        uint256 amount,
        SubBucket subBucket,
        Purpose purpose,
        string description
    );
    event MonthlyCapWarning(uint256 month, uint256 spent, uint256 cap);
    /// @notice [LOW-2 fix] Emitted on successful non-core token rescue.
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);
    /// @notice [Sprint Fix Audit Economic — R1] BondVault wired/rotated.
    event BondVaultSet(address indexed oldVault, address indexed newVault);
    /// @notice [Sprint Fix Audit Economic — R1] Emergency LUMINA injected into BondVault.
    event InjectedToVault(uint256 amount, uint256 totalInjected);

    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @custom:coverage-exclude L74, L78-L80 OZ pattern (ADR-017 Sprint Y):
    ///         `_disableInitializers()` + `__XInit()` lines run via the impl-ctor
    ///         and proxy delegatecall respectively; forge-coverage `--ir-minimum`
    ///         does not credit either. Functionally exercised by `deployCEXLiquidityReserve`.
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
        _grantRole(DEFAULT_ADMIN_ROLE, _multisigOwner);
        _grantRole(ALLOCATOR_ROLE, _multisigOwner);
    }

    function allocate(
        address recipient,
        uint256 amount,
        SubBucket subBucket,
        Purpose purpose,
        string calldata description
    ) external onlyRole(ALLOCATOR_ROLE) nonReentrant {
        require(recipient != address(0), "Recipient zero");
        require(amount > 0, "Amount zero");
        require(bytes(description).length > 0, "Description required");
        require(bytes(description).length <= 200, "Description too long");
        uint256 available = getAvailableInBucket(subBucket);
        require(amount <= available, "Insufficient in sub-bucket");
        uint256 currentMonth = getCurrentMonth();
        uint256 monthlySpent = monthlyAllocations[currentMonth];
        require(monthlySpent + amount <= MONTHLY_CAP, "Monthly cap exceeded");
        if (subBucket == SubBucket.ImmediateUse) allocatedFromImmediate += amount;
        else if (subBucket == SubBucket.VestingLinear) allocatedFromVesting += amount;
        else allocatedFromStrategic += amount;
        monthlyAllocations[currentMonth] += amount;
        uint256 allocationId = allocationHistory.length;
        allocationHistory.push(
            Allocation({
                recipient: recipient,
                amount: amount,
                subBucket: subBucket,
                purpose: purpose,
                description: description,
                timestamp: block.timestamp,
                allocator: msg.sender
            })
        );
        lumina.safeTransfer(recipient, amount);
        if (monthlyAllocations[currentMonth] > (MONTHLY_CAP * 80) / 100) {
            emit MonthlyCapWarning(currentMonth, monthlyAllocations[currentMonth], MONTHLY_CAP);
        }
        emit AllocationExecuted(allocationId, recipient, amount, subBucket, purpose, description);
    }

    function getAvailableInBucket(SubBucket subBucket) public view returns (uint256) {
        if (subBucket == SubBucket.ImmediateUse) {
            return IMMEDIATE_AMOUNT - allocatedFromImmediate;
        } else if (subBucket == SubBucket.VestingLinear) {
            uint256 vested = getVestedAmount();
            if (vested <= allocatedFromVesting) return 0;
            return vested - allocatedFromVesting;
        } else {
            if (block.timestamp < deploymentTimestamp + STRATEGIC_LOCK) return 0;
            return STRATEGIC_AMOUNT - allocatedFromStrategic;
        }
    }

    function getVestedAmount() public view returns (uint256) {
        uint256 elapsed = block.timestamp - deploymentTimestamp;
        if (elapsed >= VESTING_DURATION) return VESTING_AMOUNT;
        return (VESTING_AMOUNT * elapsed) / VESTING_DURATION;
    }

    function getTotalAllocated() external view returns (uint256) {
        return allocatedFromImmediate + allocatedFromVesting + allocatedFromStrategic;
    }

    function getAllocationHistoryLength() external view returns (uint256) {
        return allocationHistory.length;
    }

    function getCurrentMonth() public view returns (uint256) {
        return (block.timestamp - deploymentTimestamp) / 30 days;
    }

    function getMonthlyCapRemaining() external view returns (uint256) {
        uint256 spent = monthlyAllocations[getCurrentMonth()];
        if (spent >= MONTHLY_CAP) return 0;
        return MONTHLY_CAP - spent;
    }

    // ═══════ AUTO-INJECTION TO BOND VAULT (Sprint Fix Audit Economic — R1) ═══════

    /// @notice Admin-only: wire (or rotate) the BondVault that may pull
    ///         emergency liquidity via `injectToVault`. Setting to address(0)
    ///         is forbidden — use a UUPS upgrade to remove the feature.
    function setBondVault(address _bondVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_bondVault == address(0)) revert ZeroAddressNotAllowed();
        address old = bondVault;
        bondVault = _bondVault;
        emit BondVaultSet(old, _bondVault);
    }

    /// @notice [Sprint Fix Audit Economic — R1] Emergency liquidity push to BondVault.
    /// @dev    Callable ONLY by the wired BondVault. Bypasses the bucket / monthly-cap
    ///         allocator path — this is deliberately outside the CEX-listing budget
    ///         model. Use is gated upstream by BondVault's capacity-ratio threshold,
    ///         so casual triggers are not possible.
    /// @param  amount LUMINA (18-dec wei) to transfer to BondVault.
    function injectToVault(uint256 amount) external nonReentrant {
        require(msg.sender == bondVault, "Not BondVault");
        require(amount > 0, "Zero injection");
        require(lumina.balanceOf(address(this)) >= amount, "Insufficient reserve");

        // [MR-M03 fix] Independent (defense-in-depth) per-window cap + cooldown,
        // enforced by the reserve itself and NOT relying on the upgradeable caller.
        require(block.timestamp >= lastInjectionTimestamp + INJECTION_COOLDOWN, "CLR: injection cooldown");
        require(
            amount <= (lumina.balanceOf(address(this)) * MAX_INJECTION_BPS) / 10000, "CLR: exceeds per-window cap"
        );
        // [MR-M03 fix] CEI: record the window before the external transfer.
        lastInjectionTimestamp = block.timestamp;

        totalInjected += amount;
        lumina.safeTransfer(bondVault, amount);
        emit InjectedToVault(amount, totalInjected);
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

    // [Sprint Fix Audit Economic — R1] Gap reduced from 50 to 48 to make room
    // for `bondVault` (slot) + `totalInjected` (slot).
    // [MR-M03 fix] Gap reduced from 48 to 47 to make room for `lastInjectionTimestamp` (slot).
    uint256[47] private __gap;
}
