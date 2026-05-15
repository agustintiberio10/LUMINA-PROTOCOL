// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal mock matching ILuminaOracleReader.getLatestPrice
///         signature plus Echidna-fuzzable setters.
contract MockChainlinkAggregator {
    int256 private _ethPrice;
    int256 private _btcPrice;

    function setEthPrice(int256 p) external {
        _ethPrice = p;
    }

    function setBtcPrice(int256 p) external {
        _btcPrice = p;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (asset == bytes32("ETH")) return _ethPrice;
        if (asset == bytes32("BTC")) return _btcPrice;
        return 0;
    }
}
