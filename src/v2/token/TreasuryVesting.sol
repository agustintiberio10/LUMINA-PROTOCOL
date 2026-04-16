// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TreasuryVesting
/// @notice 3M LUMINA locked 6 months, then max 250K/month.
/// @dev Controlled by Gnosis Safe (owner). Never sold on open market.
///      Used only for: liquidity top-ups, market maker deals,
///      bug bounties, emergency bond reserve top-up.
contract TreasuryVesting is Ownable {
    uint256 public constant TOTAL_AMOUNT = 3_000_000 * 1e18;
    uint256 public constant LOCK_DURATION = 180 days;           // 6 months
    uint256 public constant MAX_MONTHLY_RELEASE = 250_000 * 1e18; // 250K/month
    uint256 public constant MONTH = 30 days;

    IERC20 public immutable luminaToken;
    uint256 public immutable deployedAt;

    uint256 public totalReleased;
    uint256 public lastReleaseMonth;  // tracks which month was last released

    event Released(address indexed to, uint256 amount, uint256 month);

    constructor(address _luminaToken) Ownable(msg.sender) {
        require(_luminaToken != address(0), "Zero token");
        luminaToken = IERC20(_luminaToken);
        deployedAt = block.timestamp;
    }

    /// @notice Release tokens after lock period. Max 250K per month.
    /// @param to Destination address (liquidity pool, bounty recipient, etc.)
    /// @param amount Amount to release (must be <= MAX_MONTHLY_RELEASE)
    function release(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero address");
        require(block.timestamp >= deployedAt + LOCK_DURATION, "Still locked");
        require(amount > 0, "Zero amount");
        require(amount <= MAX_MONTHLY_RELEASE, "Exceeds monthly max");
        require(totalReleased + amount <= TOTAL_AMOUNT, "Exceeds total");

        // Calculate current month (0-indexed from end of lock)
        uint256 currentMonth = (block.timestamp - deployedAt - LOCK_DURATION) / MONTH;
        // [V4/SR2] Use totalReleased==0 as "never released" sentinel. Previous code used
        // lastReleaseMonth==0 which collided with the valid state "currently in month 0",
        // allowing unlimited releases within the first 30 days post-lock.
        require(currentMonth > lastReleaseMonth || totalReleased == 0, "Already released this month");

        lastReleaseMonth = currentMonth;
        totalReleased += amount;

        require(luminaToken.transfer(to, amount), "Transfer failed");
        emit Released(to, amount, currentMonth);
    }

    // ═══════ VIEW FUNCTIONS ═══════
    function isLocked() external view returns (bool) {
        return block.timestamp < deployedAt + LOCK_DURATION;
    }

    function available() external view returns (uint256) {
        if (block.timestamp < deployedAt + LOCK_DURATION) return 0;
        uint256 remaining = TOTAL_AMOUNT - totalReleased;
        return remaining < MAX_MONTHLY_RELEASE ? remaining : MAX_MONTHLY_RELEASE;
    }

    function getStatus() external view returns (
        uint256 _totalAmount,
        uint256 _totalReleased,
        uint256 _remaining,
        bool _isLocked,
        uint256 _unlockDate,
        uint256 _currentMonth
    ) {
        _totalAmount = TOTAL_AMOUNT;
        _totalReleased = totalReleased;
        _remaining = TOTAL_AMOUNT - totalReleased;
        _isLocked = block.timestamp < deployedAt + LOCK_DURATION;
        _unlockDate = deployedAt + LOCK_DURATION;
        _currentMonth = block.timestamp >= deployedAt + LOCK_DURATION
            ? (block.timestamp - deployedAt - LOCK_DURATION) / MONTH
            : 0;
    }
}
