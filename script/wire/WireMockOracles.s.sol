// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {LuminaOracleV2} from "../../src/oracles/LuminaOracleV2.sol";

/// @title WireMockOracles
/// @notice Sprint G: registers the 5 mock Chainlink feeds (deployed by
///         `DeployMockOracles.s.sol`) into the live `LuminaOracleV2` on Sepolia.
///         Asset keys match the shield convention (`bytes32("BTC")`, etc.).
/// @dev Required env vars:
///        - LUMINA_ORACLE_V2 (the deployed proxy address)
///        - MOCK_BTC_USD, MOCK_ETH_USD, MOCK_USDC_USD, MOCK_USDT_USD, MOCK_DAI_USD
///        Run with the deployer key (it owns the LuminaOracleV2 proxy):
///          forge script script/wire/WireMockOracles.s.sol \
///            --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_PRIVATE_KEY --broadcast
contract WireMockOracles is Script {
    /// @dev 1 hour staleness window — matches typical Chainlink heartbeats.
    uint256 internal constant MAX_STALENESS = 1 hours;

    function run() external {
        LuminaOracleV2 oracleV2 = LuminaOracleV2(vm.envAddress("LUMINA_ORACLE_V2"));

        vm.startBroadcast();
        _register(oracleV2, bytes32("BTC"), vm.envAddress("MOCK_BTC_USD"));
        _register(oracleV2, bytes32("ETH"), vm.envAddress("MOCK_ETH_USD"));
        _register(oracleV2, bytes32("USDC"), vm.envAddress("MOCK_USDC_USD"));
        _register(oracleV2, bytes32("USDT"), vm.envAddress("MOCK_USDT_USD"));
        _register(oracleV2, bytes32("DAI"), vm.envAddress("MOCK_DAI_USD"));
        vm.stopBroadcast();

        console.log("===== 5 MOCK FEEDS WIRED TO LUMINA-ORACLE-V2 =====");
    }

    /// @dev Helper extracted to avoid Yul stack-too-deep under via_ir.
    function _register(LuminaOracleV2 oracleV2, bytes32 asset, address feed) internal {
        oracleV2.registerFeed(asset, feed, MAX_STALENESS);
        console.log("Registered feed:", feed);
    }
}
