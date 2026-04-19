// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MaintenanceReserve
/// @notice Holds USDC for protocol maintenance expenses (infra, audits, tooling, etc.).
///         Controlled via AccessControl with a SPENDER_ROLE for authorized withdrawals.
contract MaintenanceReserve is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════ ROLES ═══════
    bytes32 public constant SPENDER_ROLE = keccak256("SPENDER_ROLE");

    // ═══════ TYPES ═══════
    enum SpendCategory {
        Infrastructure,
        Audit,
        Tooling,
        Marketing,
        Legal,
        Other
    }

    // ═══════ STATE ═══════
    IERC20 public immutable usdc;

    /// @notice Optional monthly spending cap (0 = unlimited).
    uint256 public monthlyCap;

    /// @notice Tracks total spent in the current calendar month.
    uint256 public currentMonthSpent;

    /// @notice The month (year * 12 + month) of the last spend, used to reset monthly tracking.
    uint256 public currentMonth;

    /// @notice Total spent across all time.
    uint256 public totalSpent;

    // ═══════ SPEND HISTORY ═══════
    struct SpendRecord {
        address recipient;
        uint256 amount;
        SpendCategory category;
        string memo;
        uint256 timestamp;
    }

    SpendRecord[] public spendHistory;

    // ═══════ EVENTS ═══════
    event FundsSpent(
        address indexed recipient, uint256 amount, SpendCategory indexed category, string memo, uint256 timestamp
    );
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap);
    event TokenRecovered(address indexed token, uint256 amount);

    // ═══════ CONSTRUCTOR ═══════
    constructor(address _usdc, address _admin) {
        require(_usdc != address(0), "USDC zero");
        require(_admin != address(0), "Admin zero");

        usdc = IERC20(_usdc);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(SPENDER_ROLE, _admin);
    }

    // ═══════ SPEND ═══════

    /// @notice Spend USDC from the reserve for a maintenance purpose.
    /// @param recipient The address to send USDC to.
    /// @param amount The amount of USDC to send.
    /// @param category The spend category for tracking.
    /// @param memo A human-readable description of the expense.
    function spend(address recipient, uint256 amount, SpendCategory category, string calldata memo)
        external
        onlyRole(SPENDER_ROLE)
        nonReentrant
    {
        require(recipient != address(0), "Recipient zero");
        require(amount > 0, "Amount zero");

        _enforceMonthlycap(amount);

        currentMonthSpent += amount;
        totalSpent += amount;

        spendHistory.push(
            SpendRecord({
                recipient: recipient, amount: amount, category: category, memo: memo, timestamp: block.timestamp
            })
        );

        usdc.safeTransfer(recipient, amount);

        emit FundsSpent(recipient, amount, category, memo, block.timestamp);
    }

    // ═══════ MONTHLY CAP ═══════

    /// @notice Set the optional monthly spending cap. Set to 0 to disable.
    function setMonthlyCap(uint256 _cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldCap = monthlyCap;
        monthlyCap = _cap;
        emit MonthlyCapUpdated(oldCap, _cap);
    }

    function _enforceMonthlycamp() internal view returns (uint256) {
        // Derive a "month number" from timestamp: approximate month = timestamp / 30 days
        return block.timestamp / 30 days;
    }

    function _enforceMonthlycap(uint256 amount) internal {
        uint256 month = _enforceMonthlycamp();
        if (month != currentMonth) {
            currentMonth = month;
            currentMonthSpent = 0;
        }
        if (monthlyCap > 0) {
            require(currentMonthSpent + amount <= monthlyCap, "Monthly cap exceeded");
        }
    }

    // ═══════ VIEW ═══════

    /// @notice Returns the number of spend records.
    function spendCount() external view returns (uint256) {
        return spendHistory.length;
    }

    /// @notice Returns the current USDC balance held by this reserve.
    function balance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Returns remaining monthly budget (0 if no cap set).
    function monthlyRemaining() external view returns (uint256) {
        if (monthlyCap == 0) return type(uint256).max;
        uint256 month = block.timestamp / 30 days;
        if (month != currentMonth) return monthlyCap;
        if (currentMonthSpent >= monthlyCap) return 0;
        return monthlyCap - currentMonthSpent;
    }

    // ═══════ EMERGENCY: recover non-USDC tokens ═══════

    /// @notice Recover tokens accidentally sent to this contract (not USDC).
    function recoverToken(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(usdc), "Cannot recover USDC");
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokenRecovered(token, amount);
    }
}
