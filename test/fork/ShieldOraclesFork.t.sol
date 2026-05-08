// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title ShieldOraclesFork
/// @notice Fork tests validating Chainlink oracle feeds used by LUMINA Shield products on Base.
contract ShieldOraclesFork is Test {
    uint256 baseFork;

    address constant CHAINLINK_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    modifier onlyFork() {
        if (block.chainid != 8453) return;
        _;
    }

    function setUp() public {
        // Skip the suite gracefully when BASE_RPC_URL is not set (e.g., CI without
        // the secret). Using vm.envOr avoids the cheatcode revert that vm.envString
        // emits on missing vars, which try/catch in Solidity cannot recover from.
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        baseFork = vm.createFork(rpcUrl);
        vm.selectFork(baseFork);
    }

    // ═══════ BTC/USD FEED ═══════

    function test_fork_ChainlinkBTCFeedReturnsPositive() public onlyFork {
        AggregatorV3Interface btcFeed = AggregatorV3Interface(CHAINLINK_BTC_USD);
        (, int256 answer,,,) = btcFeed.latestRoundData();
        assertGt(answer, 0, "BTC/USD feed should return a positive price");
    }

    // ═══════ ETH/USD FEED ═══════

    function test_fork_ChainlinkETHFeedReturnsPositive() public onlyFork {
        AggregatorV3Interface ethFeed = AggregatorV3Interface(CHAINLINK_ETH_USD);
        (, int256 answer,,,) = ethFeed.latestRoundData();
        assertGt(answer, 0, "ETH/USD feed should return a positive price");
    }

    // ═══════ FEED STALENESS ═══════

    function test_fork_ChainlinkBTCFeedTimestampRecent() public onlyFork {
        AggregatorV3Interface btcFeed = AggregatorV3Interface(CHAINLINK_BTC_USD);
        (,,, uint256 updatedAt,) = btcFeed.latestRoundData();

        uint256 staleness = block.timestamp - updatedAt;
        assertLe(staleness, 24 hours, "BTC/USD feed should have been updated within 24 hours");
    }

    function test_fork_ChainlinkETHFeedTimestampRecent() public onlyFork {
        AggregatorV3Interface ethFeed = AggregatorV3Interface(CHAINLINK_ETH_USD);
        (,,, uint256 updatedAt,) = ethFeed.latestRoundData();

        uint256 staleness = block.timestamp - updatedAt;
        assertLe(staleness, 24 hours, "ETH/USD feed should have been updated within 24 hours");
    }
}
