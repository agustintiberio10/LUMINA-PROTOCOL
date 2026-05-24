// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title FlexAggregator
/// @notice Chainlink-compatible mock with INDEPENDENTLY settable round metadata
///         (roundId / updatedAt / answeredInRound). Needed by the red-team
///         fix tests (F-01 multi-block confirmation, F-06 round validation),
///         which the stock `MockAggregatorV3` cannot express because it ties
///         `answeredInRound == roundId` and `startedAt == updatedAt`.
/// @dev    Test-only mock. ABI-compatible with IChainlinkAggregator.
contract FlexAggregator {
    int256 public answer;
    uint80 public roundId;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    uint8 public decimalsVal = 8;
    bool public reverts;

    constructor(int256 _answer, uint256 _updatedAt) {
        answer = _answer;
        roundId = 1;
        updatedAt = _updatedAt;
        answeredInRound = 1;
    }

    /// @notice Push a new round: bumps roundId, sets answer, updatedAt, and
    ///         answeredInRound = roundId (the healthy case).
    function push(int256 _answer, uint256 _updatedAt) external {
        roundId += 1;
        answer = _answer;
        updatedAt = _updatedAt;
        answeredInRound = roundId;
    }

    /// @notice Set every field explicitly (for crafting incomplete/future rounds).
    function setRound(int256 _answer, uint80 _roundId, uint256 _updatedAt, uint80 _answeredInRound) external {
        answer = _answer;
        roundId = _roundId;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function decimals() external view returns (uint8) {
        return decimalsVal;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverts) revert("FEED_DOWN");
        // startedAt mirrored to updatedAt (Chainlink convention).
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// @title FlexSequencer
/// @notice Sequencer-uptime mock (0 = up, 1 = down) with controllable startedAt.
contract FlexSequencer {
    int256 public answer; // 0 = up
    uint256 public startedAt;

    constructor() {
        answer = 0;
        startedAt = block.timestamp > 2 hours ? block.timestamp - 2 hours : 0;
    }

    function setDown(bool down) external {
        answer = down ? int256(1) : int256(0);
        startedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}
