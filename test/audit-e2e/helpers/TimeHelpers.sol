// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @title TimeHelpers
/// @notice vm.warp wrappers for canonical V5.1 time windows
abstract contract TimeHelpers is Test {
    uint256 internal constant ONE_HOUR = 1 hours;
    uint256 internal constant FOUR_HOURS = 4 hours;
    uint256 internal constant ONE_DAY = 1 days;
    uint256 internal constant ONE_WEEK = 7 days;
    uint256 internal constant ONE_MONTH = 30 days;
    uint256 internal constant TWO_YEARS = 730 days;

    /// @notice Advance time by `secs` and roll one block.
    function advance(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }

    /// @notice Snap to the start of the next month boundary (UTC). Used for
    ///         epoch-aligned bond maturity tests.
    function snapToNextMonth() internal {
        uint256 ts = block.timestamp;
        uint256 daysSinceEpoch = ts / 1 days;
        uint256 nextDayBoundary = (daysSinceEpoch + 1) * 1 days;
        // Approximate next month as +30d; tests don't need calendar precision.
        vm.warp(nextDayBoundary + 30 days);
    }

    /// @notice Warp 730 days forward to mature any bond.
    function warpToBondMaturity() internal {
        advance(TWO_YEARS + 1 hours);
    }

    /// @notice Warp past the V5.1 H-5 24h proof age limit (FIX M-8).
    function warpPastProofAge() internal {
        advance(86400 + 1);
    }
}
