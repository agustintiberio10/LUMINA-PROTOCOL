// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MonthCalculator
/// @notice [Fix M-9] Canonical formula for "months since an anchor
///         timestamp", shared across protocol contracts that count
///         months for cap-tracking, vesting, and other periodic state.
/// @dev    Pure library — no storage. Each consumer passes its own
///         anchor (deployedAt + lock, deploymentTimestamp, or 0 for
///         absolute month-since-epoch). The formula is identical
///         across consumers, so the same `block.timestamp` evaluated
///         against the same anchor always yields the same month.
///
///         **Excepted from the library:**
///         - `FounderVesting` is immutable and uses a 31-day
///           `TRANCHE_INTERVAL` (not 30-day months) — its periodicity
///           is structurally different and will not be unified.
library MonthCalculator {
    /// @notice One canonical "month" duration in seconds. 30 days is
    ///         the convention already used by every consumer
    ///         pre-fix; this constant codifies it.
    uint256 internal constant MONTH = 30 days;

    /// @notice Current month index since `anchor`, where month 0 spans
    ///         `[anchor, anchor + MONTH)`, month 1 spans `[anchor +
    ///         MONTH, anchor + 2*MONTH)`, and so on.
    /// @param  anchor Reference timestamp. Pass `0` for absolute
    ///         month-since-epoch (legacy MaintenanceReserve semantics).
    ///         Pass `deployedAt + LOCK_DURATION` for vesting that
    ///         counts only after lock ends. Pass `deploymentTimestamp`
    ///         for plain since-deploy counters.
    /// @dev    Reverts if `block.timestamp < anchor` — the library's
    ///         contract is "anchor must not be in the future".
    ///         Production callers gate this themselves (e.g.
    ///         TreasuryVesting requires `block.timestamp >= deployedAt
    ///         + LOCK_DURATION` before calling), so the revert is
    ///         defense-in-depth.
    function currentMonthSinceDeploy(uint256 anchor) internal view returns (uint256) {
        // Solidity 0.8.x reverts on underflow, so an explicit check
        // is unnecessary — but we surface a clearer error.
        require(block.timestamp >= anchor, "MonthCalculator: anchor in future");
        return (block.timestamp - anchor) / MONTH;
    }
}
