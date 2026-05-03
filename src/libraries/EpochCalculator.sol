// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EpochCalculator
/// @notice [Fix L-2] Drift-free epoch arithmetic for any contract that
///         tracks recurring fixed-duration periods. Companion to
///         `MonthCalculator` (FIX #25), which is specialised for 30-day
///         months — `EpochCalculator` accepts an arbitrary epoch
///         duration so it can model 1h, 4h, 24h, etc.
///
/// @dev    The classic "drift" pattern looks like:
///
///             if (block.timestamp >= currentEpochEnd) {
///                 currentEpochEnd = block.timestamp + EPOCH_DURATION;
///             }
///
///         Each missed cycle pushes the schedule forward by `delay`
///         beyond a fixed-cadence anchor. Replace with:
///
///             uint256 epoch = EpochCalculator.currentEpoch(anchor, EPOCH_DURATION);
///             (uint256 start, uint256 end) =
///                 EpochCalculator.epochBoundaries(anchor, EPOCH_DURATION);
///
///         The output is always pinned to `anchor + N * duration` for
///         integer N; missed cycles do NOT affect future timing.
///
/// @dev    Pure library — no storage. Each consumer passes its own
///         `(anchor, epochDuration)` pair.
///
/// @dev    **Survey at fix-time (commit 6a3ce42):** none of the existing
///         protocol contracts use the drift pattern. `TWAPBurner.lastBurnTimestamp`,
///         `SolvencyOracle.lastEvaluation`, and `BuybackEngine.dailyConfig.validUntil`
///         are all cooldown / single-shot expirations, NOT recurring
///         fixed-cadence epochs. This library is therefore **preventive**:
///         future contracts that need recurring epochs MUST use it
///         instead of inlining the drift pattern.
library EpochCalculator {
    /// @notice Current epoch index since `anchor`, where epoch 0 spans
    ///         `[anchor, anchor + epochDuration)`, epoch 1 spans
    ///         `[anchor + epochDuration, anchor + 2 * epochDuration)`,
    ///         and so on.
    /// @param  anchor Reference timestamp.
    /// @param  epochDuration Length of a single epoch in seconds.
    /// @dev    Reverts when `epochDuration == 0` or when `block.timestamp
    ///         < anchor`. Production callers SHOULD ensure both are valid
    ///         at the call site; this revert is defense-in-depth.
    function currentEpoch(uint256 anchor, uint256 epochDuration) internal view returns (uint256) {
        require(epochDuration > 0, "EpochCalculator: zero duration");
        require(block.timestamp >= anchor, "EpochCalculator: anchor in future");
        return (block.timestamp - anchor) / epochDuration;
    }

    /// @notice Returns the half-open `[start, end)` interval of the
    ///         current epoch.
    /// @return start Inclusive lower bound of the current epoch (in
    ///         seconds since Unix epoch).
    /// @return end Exclusive upper bound of the current epoch (= start
    ///         + epochDuration).
    function epochBoundaries(uint256 anchor, uint256 epochDuration) internal view returns (uint256 start, uint256 end) {
        uint256 idx = currentEpoch(anchor, epochDuration);
        start = anchor + idx * epochDuration;
        end = start + epochDuration;
    }

    /// @notice Returns `(start, end)` for an arbitrary epoch index.
    ///         Useful for off-chain scheduling helpers and for tests
    ///         that need to construct future-epoch boundaries.
    function epochBoundariesAt(uint256 anchor, uint256 epochDuration, uint256 epochIndex)
        internal
        pure
        returns (uint256 start, uint256 end)
    {
        require(epochDuration > 0, "EpochCalculator: zero duration");
        start = anchor + epochIndex * epochDuration;
        end = start + epochDuration;
    }

    /// @notice True iff `timestamp` falls inside epoch `epochIndex`
    ///         (i.e. inside `[anchor + idx*duration, anchor + (idx+1)*duration)`).
    function isInEpoch(uint256 anchor, uint256 epochDuration, uint256 epochIndex, uint256 timestamp)
        internal
        pure
        returns (bool)
    {
        require(epochDuration > 0, "EpochCalculator: zero duration");
        if (timestamp < anchor) return false;
        uint256 idx = (timestamp - anchor) / epochDuration;
        return idx == epochIndex;
    }
}
