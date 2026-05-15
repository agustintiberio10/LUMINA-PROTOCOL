// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaOracleV2} from "../../src/oracles/LuminaOracleV2.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Mock Chainlink aggregator with knobs for staleness/incomplete-round/price tests.
contract MockAggregator is IAggregatorV3 {
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    uint8 public override decimals;

    constructor() {
        decimals = 8;
        roundId = 100;
        answer = 65000e8;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 100;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function description() external pure override returns (string memory) {
        return "MockBTC";
    }

    function setRound(uint80 _roundId, int256 _answer, uint256 _updatedAt, uint80 _answeredInRound) external {
        roundId = _roundId;
        answer = _answer;
        startedAt = _updatedAt;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
    }
}

    /// @title LuminaOracleV2 — Sprint X.1 Chainlink hardening tests
    /// @notice Validates the answeredInRound + updatedAt staleness checks
    ///         added to `registerFeed` and `updateFeed` in Sprint X.1.
    contract LuminaOracleV2RegisterFeedTest is Test {
        LuminaOracleV2 oracle;
        MockAggregator feed;
        address deployer = address(this);
        address oracleKey = address(0xBEEF);
        bytes32 constant ASSET_BTC = bytes32("BTC");

        function setUp() public {
            vm.chainId(8453);
            vm.warp(1767225600 + 30 days);
            oracle = new LuminaOracleV2(deployer, oracleKey, address(0));
            feed = new MockAggregator();
        }

        // ═══════ registerFeed ═══════

        function test_RegisterFeed_HappyPath() public {
            oracle.registerFeed(ASSET_BTC, address(feed), 1 hours);
            // sanity: getLatestPrice now returns the mocked answer
            int256 p = oracle.getLatestPrice(ASSET_BTC);
            assertEq(p, 65000e8);
        }

        function test_RegisterFeed_RevertsOnStaleRound() public {
            // answeredInRound < roundId → incomplete round
            feed.setRound({_roundId: 100, _answer: 65000e8, _updatedAt: block.timestamp, _answeredInRound: 99});
            vm.expectRevert(
                abi.encodeWithSelector(LuminaOracleV2.IncompleteRound.selector, ASSET_BTC, uint80(100), uint80(99))
            );
            oracle.registerFeed(ASSET_BTC, address(feed), 1 hours);
        }

        function test_RegisterFeed_FutureRoundOk() public {
            // answeredInRound > roundId → valid (more recent round answered the request)
            feed.setRound({_roundId: 100, _answer: 65000e8, _updatedAt: block.timestamp, _answeredInRound: 101});
            oracle.registerFeed(ASSET_BTC, address(feed), 1 hours);
            int256 p = oracle.getLatestPrice(ASSET_BTC);
            assertEq(p, 65000e8);
        }

        function test_RegisterFeed_RevertsOnStaleUpdatedAt() public {
            uint256 oldTime = block.timestamp - 2 hours;
            feed.setRound({_roundId: 100, _answer: 65000e8, _updatedAt: oldTime, _answeredInRound: 100});
            vm.expectRevert(
                abi.encodeWithSelector(LuminaOracleV2.StalePriceAsset.selector, ASSET_BTC, oldTime, uint256(1 hours))
            );
            oracle.registerFeed(ASSET_BTC, address(feed), 1 hours);
        }

        function test_RegisterFeed_RevertsOnInvalidPrice() public {
            feed.setRound({_roundId: 100, _answer: 0, _updatedAt: block.timestamp, _answeredInRound: 100});
            vm.expectRevert(abi.encodeWithSelector(LuminaOracleV2.InvalidPriceAsset.selector, ASSET_BTC, int256(0)));
            oracle.registerFeed(ASSET_BTC, address(feed), 1 hours);
        }

        // ═══════ updateFeed ═══════

        function test_UpdateFeed_HappyPath() public {
            oracle.registerFeed(ASSET_BTC, address(feed), 1 hours);

            MockAggregator newFeed = new MockAggregator();
            newFeed.setRound({_roundId: 200, _answer: 66000e8, _updatedAt: block.timestamp, _answeredInRound: 200});
            oracle.updateFeed(ASSET_BTC, address(newFeed), 2 hours);

            int256 p = oracle.getLatestPrice(ASSET_BTC);
            assertEq(p, 66000e8);
        }

        function test_UpdateFeed_RevertsOnStaleRound() public {
            oracle.registerFeed(ASSET_BTC, address(feed), 1 hours);

            MockAggregator newFeed = new MockAggregator();
            newFeed.setRound({_roundId: 200, _answer: 66000e8, _updatedAt: block.timestamp, _answeredInRound: 199});
            vm.expectRevert(
                abi.encodeWithSelector(LuminaOracleV2.IncompleteRound.selector, ASSET_BTC, uint80(200), uint80(199))
            );
            oracle.updateFeed(ASSET_BTC, address(newFeed), 2 hours);
        }
    }
