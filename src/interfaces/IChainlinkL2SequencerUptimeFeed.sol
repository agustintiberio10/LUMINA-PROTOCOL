// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IChainlinkL2SequencerUptimeFeed
/// @notice Minimal interface for Chainlink's L2 Sequencer Uptime Feed.
/// @dev    answer == 0 => sequencer up. answer == 1 => sequencer down.
///         startedAt reflects the moment the current status began; callers
///         should apply a grace period before trusting "up" again after a
///         down/up transition.
interface IChainlinkL2SequencerUptimeFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
