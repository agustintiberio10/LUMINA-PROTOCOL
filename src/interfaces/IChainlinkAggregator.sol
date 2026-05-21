// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IChainlinkAggregator
/// @notice Minimal Chainlink price-feed interface used by the new flash
///         shields. Mirrors AggregatorV3Interface but kept local so the
///         shields module has no cross-file coupling beyond this folder.
/// @dev    A parallel `IAggregatorV3` exists for legacy oracle wiring.
///         Both are kept to avoid a wide refactor; new code MUST use this one.
interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}
