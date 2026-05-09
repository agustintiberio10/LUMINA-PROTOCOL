// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title MockAggregatorV3
/// @notice Chainlink-compatible AggregatorV3 mock for testnet (Sepolia) testing.
///         Mainnet uses real Chainlink feeds; this contract is **testnet-only**
///         (decision Sprint G — see `testnet-deltas.md`).
/// @dev Admin can manipulate the reported price + simulate stale data + simulate
///      provider outage, so the protocol's downstream behavior on each scenario
///      can be exercised end-to-end without waiting for real Chainlink moves.
///      Implements `IAggregatorV3` (`latestRoundData`, `decimals`, `description`)
///      verbatim, so `LuminaOracleV2.registerFeed` / `getLatestPrice` accept it.
contract MockAggregatorV3 is IAggregatorV3 {
    /// @notice Address allowed to mutate state. Set on construction.
    address public owner;

    /// @notice Latest reported price (Chainlink convention: `_decimals`-scaled int256).
    int256 public answer;

    /// @notice Monotonically increasing round id (incremented on every `setPrice`).
    uint80 public roundId;

    /// @notice Last update timestamp. Read by `LuminaOracleV2` against `maxStaleness`.
    ///         When `stale == true`, this is frozen 1 day in the past on toggle.
    uint256 public updatedAt;

    /// @notice When `true`, `latestRoundData` reverts with `RevertSimulated`.
    ///         Lets tests exercise oracle-outage paths.
    bool public shouldRevert;

    /// @notice When `true`, `updatedAt` is locked 1 day behind `block.timestamp`,
    ///         so `LuminaOracleV2.getLatestPrice` trips its staleness guard.
    bool public stale;

    uint8 private _decimals;
    string private _description;

    error NotOwner();
    error RevertSimulated();

    event PriceUpdated(int256 oldPrice, int256 newPrice, uint80 indexed newRoundId, uint256 timestamp);
    event StaleStateChanged(bool stale);
    event RevertStateChanged(bool shouldRevert);
    event DecimalsUpdated(uint8 oldDecimals, uint8 newDecimals);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param initialPrice  Seed price (8-dec convention for USD pairs).
    /// @param initialDecimals  Decimals reported by `decimals()`. Chainlink pairs are 8.
    /// @param pairDescription  Free-form description (e.g. `"BTC / USD MOCK"`).
    constructor(int256 initialPrice, uint8 initialDecimals, string memory pairDescription) {
        owner = msg.sender;
        answer = initialPrice;
        _decimals = initialDecimals;
        _description = pairDescription;
        roundId = 1;
        updatedAt = block.timestamp;
        emit PriceUpdated(0, initialPrice, 1, block.timestamp);
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ─────────────────── Admin: state mutation ───────────────────

    /// @notice Set the reported price + bump the round id. Refreshes `updatedAt`
    ///         to `block.timestamp` unless `stale` is on (then the stale window
    ///         is preserved so a subsequent `setPrice` doesn't accidentally
    ///         "un-stale" the feed).
    function setPrice(int256 newPrice) external onlyOwner {
        int256 prev = answer;
        answer = newPrice;
        unchecked {
            roundId += 1;
        }
        if (!stale) {
            updatedAt = block.timestamp;
        }
        emit PriceUpdated(prev, newPrice, roundId, updatedAt);
    }

    /// @notice Toggle stale mode. When enabled, `updatedAt` is fixed to
    ///         `block.timestamp - 1 days`, which exceeds typical Chainlink
    ///         maxStaleness windows (~1 hour) and trips downstream guards.
    function setStale(bool stale_) external onlyOwner {
        stale = stale_;
        if (stale_) {
            updatedAt = block.timestamp - 1 days;
        } else {
            updatedAt = block.timestamp;
        }
        emit StaleStateChanged(stale_);
    }

    /// @notice Toggle revert-mode. When `true`, `latestRoundData` reverts with
    ///         `RevertSimulated`, simulating a fully unavailable provider.
    function setRevert(bool shouldRevert_) external onlyOwner {
        shouldRevert = shouldRevert_;
        emit RevertStateChanged(shouldRevert_);
    }

    /// @notice Override decimals (defaults to whatever was passed at construction).
    function setDecimals(uint8 newDecimals) external onlyOwner {
        emit DecimalsUpdated(_decimals, newDecimals);
        _decimals = newDecimals;
    }

    /// @notice Transfer admin to `newOwner`. Cannot be the zero address.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ─────────────────── IAggregatorV3 surface ───────────────────

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldRevert) revert RevertSimulated();
        // Chainlink convention: startedAt == updatedAt == round timestamp.
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }
}
