// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockChainlinkOracle — TESTNET ONLY
/// @notice Minimal owner-settable Chainlink-style aggregator used to drive a
///         controlled trigger in the E2E test (Sprint E2E Mock). MUST NOT ship
///         to mainnet — flagged as a mainnet blocker (remove before launch).
contract MockChainlinkOracle {
    int256 private _price;
    uint256 private _timestamp;
    uint80 private _roundId;
    uint8 public decimals = 8;
    string public description = "MOCK BTC/USD";
    uint256 public version = 1;
    address public owner;

    constructor(int256 initialPrice) {
        _price = initialPrice;
        _timestamp = block.timestamp;
        _roundId = 1;
        owner = msg.sender;
    }

    function setPrice(int256 newPrice) external {
        require(msg.sender == owner, "Not owner");
        _price = newPrice;
        _timestamp = block.timestamp;
        _roundId++;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _timestamp, _timestamp, _roundId);
    }

    function getRoundData(uint80 _r)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_r, _price, _timestamp, _timestamp, _r);
    }
}
