// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAggregatorV3
 * @notice Minimal Chainlink AggregatorV3Interface for price feed reads.
 * @dev Only includes latestRoundData() — sufficient for Lumina's needs.
 *      Full interface at chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol
 */
interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );

    function decimals() external view returns (uint8);

    function description() external view returns (string memory);
}
