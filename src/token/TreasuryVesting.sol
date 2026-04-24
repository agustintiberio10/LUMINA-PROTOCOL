// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

    function release(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero address");
        require(block.timestamp >= deployedAt + LOCK_DURATION, "Still locked");
        require(amount > 0, "Zero amount");
        require(amount <= MAX_MONTHLY_RELEASE, "Exceeds monthly max");
        require(totalReleased + amount <= TOTAL_AMOUNT, "Exceeds total");

        uint256 currentMonth = (block.timestamp - deployedAt - LOCK_DURATION) / MONTH;
        require(currentMonth > lastReleaseMonth || totalReleased == 0, "Already released this month");

        lastReleaseMonth = currentMonth;
        totalReleased += amount;

        require(luminaToken.transfer(to, amount), "Transfer failed");
        emit Released(to, amount, currentMonth);
    }

    function isLocked() external view returns (bool) {
        return block.timestamp < deployedAt + LOCK_DURATION;
    }

    function available() external view returns (uint256) {
        if (block.timestamp < deployedAt + LOCK_DURATION) return 0;
        uint256 remaining = TOTAL_AMOUNT - totalReleased;
        return remaining < MAX_MONTHLY_RELEASE ? remaining : MAX_MONTHLY_RELEASE;
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
        _currentMonth =
            block.timestamp >= deployedAt + LOCK_DURATION ? (block.timestamp - deployedAt - LOCK_DURATION) / MONTH : 0;
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
