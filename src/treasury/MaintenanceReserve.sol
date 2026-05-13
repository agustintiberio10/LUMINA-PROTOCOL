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

    function setMonthlyCap(uint256 _cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldCap = monthlyCap;
        monthlyCap = _cap;
        emit MonthlyCapUpdated(oldCap, _cap);
    }

    function _enforceMonthlyCap() internal view returns (uint256) {
        return block.timestamp / 30 days;
    }

    function _enforceMonthlycap(uint256 amount) internal {
        uint256 month = _enforceMonthlyCap();
        if (month != currentMonth) {
            currentMonth = month;
            currentMonthSpent = 0;
        }
        if (monthlyCap > 0) {
            require(currentMonthSpent + amount <= monthlyCap, "Monthly cap exceeded");
        }
    }

    function spendCount() external view returns (uint256) {
        return spendHistory.length;
    }

    function balance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function monthlyRemaining() external view returns (uint256) {
        if (monthlyCap == 0) return type(uint256).max;
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
