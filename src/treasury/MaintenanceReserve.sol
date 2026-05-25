// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MaintenanceReserve
/// @notice Holds USDC for protocol maintenance expenses.
/// @dev [V5.1] UUPS upgradeable proxy pattern.
contract MaintenanceReserve is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant SPENDER_ROLE = keccak256("SPENDER_ROLE");

    /// @notice [F-15] Default monthly spend cap applied at `initialize` time: $10,000 (6-dec USDC).
    /// @dev    Under the corrected semantics a cap of 0 DISABLES spending entirely (fail-closed),
    ///         so a sane non-zero default is set on init to keep the contract operable.
    uint256 public constant DEFAULT_MONTHLY_CAP = 10_000e6;

    enum SpendCategory {
        Infrastructure,
        Audit,
        Tooling,
        Marketing,
        Legal,
        Other
    }

    IERC20 public usdc;
    uint256 public monthlyCap;
    uint256 public currentMonthSpent;
    uint256 public currentMonth;
    uint256 public totalSpent;

    struct SpendRecord {
        address recipient;
        uint256 amount;
        SpendCategory category;
        string memo;
        uint256 timestamp;
    }

    SpendRecord[] public spendHistory;

    event FundsSpent(
        address indexed recipient, uint256 amount, SpendCategory indexed category, string memo, uint256 timestamp
    );
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap);
    event TokenRecovered(address indexed token, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @custom:coverage-exclude L52, L56-L58 OZ pattern (ADR-017 Sprint Y):
    ///         `_disableInitializers()` + `__XInit()` lines run via the impl-ctor
    ///         and proxy delegatecall; forge-coverage `--ir-minimum` quirk.
    ///         Exercised by `deployMaintenanceReserve` in tests.
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdc, address _admin) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_usdc != address(0), "USDC zero");
        require(_admin != address(0), "Admin zero");

        usdc = IERC20(_usdc);

        // [F-15] Fail-closed cap: 0 means "spending disabled", so seed a sane default at init so a
        // fresh deployment is operable without an extra setter call. Admin can adjust via setMonthlyCap.
        monthlyCap = DEFAULT_MONTHLY_CAP;
        emit MonthlyCapUpdated(0, DEFAULT_MONTHLY_CAP);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(SPENDER_ROLE, _admin);
    }

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

    /// @notice Set the monthly USDC spend cap (admin only).
    /// @dev    [F-15] Corrected semantics: `_cap == 0` DISABLES spending (fail-closed). To grant an
    ///         effectively unbounded budget, set a very large cap explicitly rather than relying on 0.
    function setMonthlyCap(uint256 _cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldCap = monthlyCap;
        monthlyCap = _cap;
        emit MonthlyCapUpdated(oldCap, _cap);
    }

    /// @notice [INFO-1 fix] Renamed from the misnamed `_enforceMonthlyCap()` (capital C),
    ///         which only returns the current month index and enforces nothing. The real
    ///         enforcer is `_enforceMonthlycap(uint256)` (lowercase c) below.
    function _currentMonthIndex() internal view returns (uint256) {
        return block.timestamp / 30 days;
    }

    function _enforceMonthlycap(uint256 amount) internal {
        uint256 month = _currentMonthIndex(); // [INFO-1 fix]
        if (month != currentMonth) {
            currentMonth = month;
            currentMonthSpent = 0;
        }
        // [F-15] Fail-closed: a cap of 0 means spending is DISABLED, not unlimited.
        require(monthlyCap > 0, "Spending disabled (cap=0)");
        require(currentMonthSpent + amount <= monthlyCap, "Monthly cap exceeded");
    }

    function spendCount() external view returns (uint256) {
        return spendHistory.length;
    }

    function balance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function monthlyRemaining() external view returns (uint256) {
        // [F-15] cap == 0 means spending is disabled -> 0 remaining (not unlimited).
        if (monthlyCap == 0) return 0;
        uint256 month = block.timestamp / 30 days;
        if (month != currentMonth) return monthlyCap;
        if (currentMonthSpent >= monthlyCap) return 0;
        return monthlyCap - currentMonthSpent;
    }

    function recoverToken(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(usdc), "Cannot recover USDC");
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokenRecovered(token, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private __gap;
}
