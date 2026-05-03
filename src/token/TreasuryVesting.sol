// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MonthCalculator} from "../libraries/MonthCalculator.sol";

/// @title TreasuryVesting
/// @notice 3M LUMINA locked 6 months, then max 250K/month.
/// @dev [V5.1] UUPS upgradeable proxy pattern.
contract TreasuryVesting is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_AMOUNT = 3_000_000 * 1e18;
    uint256 public constant LOCK_DURATION = 180 days;
    uint256 public constant MAX_MONTHLY_RELEASE = 250_000 * 1e18;
    uint256 public constant MONTH = 30 days;

    IERC20 public luminaToken;
    uint256 public deployedAt;

    uint256 public totalReleased;
    /// @notice [Audit fix H-9 — DEPRECATED] No longer read or written.
    ///         Pre-fix the release flow used this slot to enforce a
    ///         "one release per month" check that quietly forfeited any
    ///         month the multisig forgot. The new accumulating cap
    ///         (`available()`) makes the slot unnecessary, but it is
    ///         preserved here so the UUPS storage layout of any V5.1
    ///         deployment remains backwards-compatible after upgrade.
    uint256 public lastReleaseMonth;

    event Released(address indexed to, uint256 amount, uint256 month);
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

    function initialize(address _luminaToken) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_luminaToken != address(0), "Zero token");
        luminaToken = IERC20(_luminaToken);
        deployedAt = block.timestamp;
    }

    /// @notice Release `amount` of LUMINA to `to`. Multisig admin only.
    /// @dev    [Audit fix H-9] The previous "one release per calendar month
    ///         OR nothing" gate forfeited any month the multisig forgot.
    ///         The new check is `amount <= available()`, where `available()`
    ///         returns `monthsSinceUnlock × MAX_MONTHLY_RELEASE − totalReleased`,
    ///         so a missed month carries forward into the next call instead
    ///         of vanishing. The lifetime cap `TOTAL_AMOUNT` is enforced
    ///         identically as before. `nonReentrant` added for defence in
    ///         depth even though `transfer` to a known LUMINA token is the
    ///         only external call.
    function release(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero address");
        require(block.timestamp >= deployedAt + LOCK_DURATION, "Still locked");
        require(amount > 0, "Zero amount");
        require(amount <= _available(), "Exceeds available");
        require(totalReleased + amount <= TOTAL_AMOUNT, "Exceeds total");

        // [Merge consolidation: H-9 deprecated `lastReleaseMonth` and replaced
        //  the per-month gate with the accumulating `_available()` cap. M-9's
        //  library substitution still applies to the surviving inline formula
        //  used purely for the event payload below.]
        totalReleased += amount;

        // `month` field of the event keeps its pre-fix meaning so any
        // off-chain consumer that filters by month continues to work.
        // [Fix M-9] Routed through MonthCalculator for protocol-wide
        // formula consistency. Anchor = `deployedAt + LOCK_DURATION`.
        uint256 currentMonth = MonthCalculator.currentMonthSinceDeploy(deployedAt + LOCK_DURATION);

        require(luminaToken.transfer(to, amount), "Transfer failed");
        emit Released(to, amount, currentMonth);
    }

    function isLocked() external view returns (bool) {
        return block.timestamp < deployedAt + LOCK_DURATION;
    }

    /// @dev [Audit fix H-9] Internal helper shared by the public `available()`
    ///      view and the `release()` gate. Implements the accumulating-cap
    ///      formula: `min(monthsSinceUnlock × MAX_MONTHLY_RELEASE, TOTAL_AMOUNT) − totalReleased`.
    ///      `monthsSinceUnlock` starts at 1 at the unlock instant so the
    ///      first 250K is immediately available without waiting an extra month.
    function _available() internal view returns (uint256) {
        if (block.timestamp < deployedAt + LOCK_DURATION) return 0;
        uint256 monthsSinceUnlock = (block.timestamp - (deployedAt + LOCK_DURATION)) / MONTH + 1;
        uint256 maxAccessibleSoFar = monthsSinceUnlock * MAX_MONTHLY_RELEASE;
        if (maxAccessibleSoFar > TOTAL_AMOUNT) maxAccessibleSoFar = TOTAL_AMOUNT;
        if (totalReleased >= maxAccessibleSoFar) return 0;
        return maxAccessibleSoFar - totalReleased;
    }

    function available() external view returns (uint256) {
        return _available();
    }

    function getStatus()
        external
        view
        returns (
            uint256 _totalAmount,
            uint256 _totalReleased,
            uint256 _remaining,
            bool _isLocked,
            uint256 _unlockDate,
            uint256 _currentMonth
        )
    {
        _totalAmount = TOTAL_AMOUNT;
        _totalReleased = totalReleased;
        _remaining = TOTAL_AMOUNT - totalReleased;
        _isLocked = block.timestamp < deployedAt + LOCK_DURATION;
        _unlockDate = deployedAt + LOCK_DURATION;
        // [Fix M-9] Same library call as `release()` for the post-lock branch;
        // the pre-lock branch returns 0 (consistent with previous behavior).
        _currentMonth = block.timestamp >= deployedAt + LOCK_DURATION
            ? MonthCalculator.currentMonthSinceDeploy(deployedAt + LOCK_DURATION)
            : 0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ═══════ RESCUE (LOW-2 fix, audit #26) ═══════

    /// @notice Recover non-LUMINA ERC-20 tokens sent to this contract by mistake.
    /// @dev    `ReentrancyGuardUpgradeable` added to inheritance; namespaced
    ///         ERC-7201 storage means no initialization is required for the
    ///         non-entered default to work — `$._status == 0 != ENTERED(2)`.
    function recoverToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (token == address(luminaToken)) revert CoreTokenProtected(token);

        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, amount, to);
    }

    uint256[50] private __gap;
}
