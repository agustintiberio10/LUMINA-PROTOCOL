// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockAggregatorV3} from "../../src/mocks/MockAggregatorV3.sol";

/// @title DeployMockOracles
/// @notice Sprint G: deploys 5 Chainlink-compatible mock feeds to Sepolia.
///         Each is a `MockAggregatorV3` initialized with a realistic price
///         (8-dec convention). Admin = deployer EOA.
/// @dev Run with:
///   forge script script/deploy/DeployMockOracles.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
contract DeployMockOracles is Script {
    // ─────────────────── Initial prices (8-dec, USD) ───────────────────
    int256 internal constant BTC_USD = int256(60_000) * 1e8; // $60,000
    int256 internal constant ETH_USD = int256(3_000) * 1e8; // $3,000
    int256 internal constant USDC_USD = int256(1) * 1e8; // $1.00
    int256 internal constant USDT_USD = int256(1) * 1e8; // $1.00
    int256 internal constant DAI_USD = int256(1) * 1e8; // $1.00

    uint8 internal constant DECIMALS = 8;

    function run() external {
        vm.startBroadcast();

        MockAggregatorV3 btc = new MockAggregatorV3(BTC_USD, DECIMALS, "BTC / USD MOCK");
        MockAggregatorV3 eth = new MockAggregatorV3(ETH_USD, DECIMALS, "ETH / USD MOCK");
        MockAggregatorV3 usdc = new MockAggregatorV3(USDC_USD, DECIMALS, "USDC / USD MOCK");
        MockAggregatorV3 usdt = new MockAggregatorV3(USDT_USD, DECIMALS, "USDT / USD MOCK");
        MockAggregatorV3 dai = new MockAggregatorV3(DAI_USD, DECIMALS, "DAI / USD MOCK");

        vm.stopBroadcast();

        // Final log block — easy to grep from broadcast output for the manifest.
        console.log("===== MOCK CHAINLINK FEEDS DEPLOYED (Sepolia) =====");
        console.log("BTC/USD  MOCK:", address(btc));
        console.log("ETH/USD  MOCK:", address(eth));
        console.log("USDC/USD MOCK:", address(usdc));
        console.log("USDT/USD MOCK:", address(usdt));
        console.log("DAI/USD  MOCK:", address(dai));
        console.log("===================================================");
    }
}
