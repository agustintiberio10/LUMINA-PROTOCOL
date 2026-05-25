// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaOracleV2} from "../../src/oracles/LuminaOracleV2.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Generic mock Chainlink aggregator with mutable round data.
contract MockAggregator is IAggregatorV3 {
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    uint8 public override decimals;

    constructor(int256 _answer) {
        decimals = 8;
        roundId = 1;
        answer = _answer;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function description() external pure override returns (string memory) {
        return "Mock";
    }

    function setRound(uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
        external
    {
        roundId = _roundId;
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
    }
}

/// @title MRL07_SequencerStartedAt
/// @notice [MR-L07 fix] `_checkSequencer` now reverts when the sequencer uptime
///         feed reports an uninitialized round (startedAt == 0) BEFORE the grace
///         comparison. Without the guard, `block.timestamp - 0` is huge and
///         silently passes the grace window even though the round is invalid.
contract MRL07_SequencerStartedAtTest is Test {
    LuminaOracleV2 oracle;
    MockAggregator sequencer;
    MockAggregator priceFeed;

    address deployer = address(this);
    address oracleKey = address(0xBEEF);
    bytes32 constant ASSET = bytes32("BTC");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);

        // Sequencer feed: status=0 (UP) but startedAt==0 (uninitialized round).
        sequencer = new MockAggregator(0); // answer == status field for the uptime feed
        sequencer.setRound({_roundId: 1, _answer: 0, _startedAt: 0, _updatedAt: block.timestamp, _answeredInRound: 1});

        oracle = new LuminaOracleV2(deployer, oracleKey, address(sequencer));

        // Register a healthy price feed so the only failure path is the sequencer guard.
        priceFeed = new MockAggregator(65000e8);
        oracle.registerFeed(ASSET, address(priceFeed), 1 hours);
    }

    function test_getLatestPrice_revertsWhenSequencerStartedAtZero() public {
        vm.expectRevert(LuminaOracleV2.SequencerGracePeriodNotOver.selector);
        oracle.getLatestPrice(ASSET);
    }

    function test_getLatestRoundData_revertsWhenSequencerStartedAtZero() public {
        vm.expectRevert(LuminaOracleV2.SequencerGracePeriodNotOver.selector);
        oracle.getLatestRoundData(ASSET);
    }

    function test_getLatestPrice_succeedsOnceSequencerInitializedAndPastGrace() public {
        // A real (initialized) round whose startedAt is older than the grace period.
        sequencer.setRound({
            _roundId: 2,
            _answer: 0,
            _startedAt: block.timestamp - oracle.SEQUENCER_GRACE_PERIOD() - 1,
            _updatedAt: block.timestamp,
            _answeredInRound: 2
        });
        int256 p = oracle.getLatestPrice(ASSET);
        assertEq(p, 65000e8, "price read after sequencer healthy");
    }
}
