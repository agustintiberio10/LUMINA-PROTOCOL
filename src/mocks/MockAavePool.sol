// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockAavePool
/// @notice Aave-V3-compatible `IPool` mock for testnet (Sepolia) testing.
///         Mainnet uses real Aave V3; this contract is **testnet-only**
///         (decision Sprint H — see `testnet-deltas.md`).
/// @dev Lumina's consumer (`FounderVesting`) only reads
///      `getReserveData(asset).currentVariableBorrowRate`. The full ReserveData
///      struct is preserved so the surface stays compatible with the real Aave
///      V3 `IPool` interface (drop-in replacement).
///      Admin can mutate the per-asset rates (`setBorrowRate`, `setLiquidityRate`),
///      simulate stale data (`setStale`), and simulate provider outages
///      (`setRevert`). Rates are accepted in BPS for ergonomics and converted
///      internally to RAY (Aave's 1e27 convention).
///      [Sprint T-30a Phase B] RateShockShield removed (founder decision); only
///      FounderVesting still consumes this mock.
contract MockAavePool {
    /// @dev Mirror of Aave V3 `DataTypes.ReserveData`. Lumina only consumes
    ///      `currentVariableBorrowRate`, but the full layout keeps the ABI
    ///      identical to the real pool so external tooling (block explorers,
    ///      etherscan ABIs) decode it the same way.
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    address public owner;
    bool public shouldRevert;
    bool public stale;

    mapping(address => ReserveData) private _reserves;

    /// @dev BPS → RAY conversion: 1 BPS == 1e27 / 1e4 == 1e23.
    uint256 internal constant RAY_PER_BPS = 1e23;

    error NotOwner();
    error RevertSimulated();

    event BorrowRateUpdated(address indexed asset, uint256 oldRayRate, uint256 newRayRate);
    event LiquidityRateUpdated(address indexed asset, uint256 oldRayRate, uint256 newRayRate);
    event StaleStateChanged(bool stale);
    event RevertStateChanged(bool shouldRevert);
    event ReserveDataReplaced(address indexed asset);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ─────────────────── Admin: rate mutation ───────────────────

    /// @notice Set the variable borrow rate for `asset`. `rateBps` is APY in
    ///         basis points (e.g. 1000 = 10%). Stored as RAY (1e27-scaled).
    function setBorrowRate(address asset, uint256 rateBps) external onlyOwner {
        ReserveData storage r = _reserves[asset];
        uint256 oldRate = uint256(r.currentVariableBorrowRate);
        uint256 newRate = rateBps * RAY_PER_BPS;
        require(newRate <= type(uint128).max, "rate overflow uint128");
        r.currentVariableBorrowRate = uint128(newRate);
        if (!stale) {
            r.lastUpdateTimestamp = uint40(block.timestamp);
        }
        emit BorrowRateUpdated(asset, oldRate, newRate);
    }

    /// @notice Set the liquidity (supply) rate for `asset`. `rateBps` semantics
    ///         identical to `setBorrowRate`.
    function setLiquidityRate(address asset, uint256 rateBps) external onlyOwner {
        ReserveData storage r = _reserves[asset];
        uint256 oldRate = uint256(r.currentLiquidityRate);
        uint256 newRate = rateBps * RAY_PER_BPS;
        require(newRate <= type(uint128).max, "rate overflow uint128");
        r.currentLiquidityRate = uint128(newRate);
        if (!stale) {
            r.lastUpdateTimestamp = uint40(block.timestamp);
        }
        emit LiquidityRateUpdated(asset, oldRate, newRate);
    }

    /// @notice Replace the full `ReserveData` for `asset`. Useful when a test
    ///         needs to set arbitrary fields (aToken, indices, etc.) without
    ///         going through the BPS-only setters.
    function setReserveData(address asset, ReserveData calldata data) external onlyOwner {
        _reserves[asset] = data;
        emit ReserveDataReplaced(asset);
    }

    /// @notice Toggle stale mode. When enabled, `lastUpdateTimestamp` is
    ///         frozen 1 day in the past on toggle and not refreshed on
    ///         subsequent rate updates.
    function setStale(bool stale_) external onlyOwner {
        stale = stale_;
        // Apply stale window to all known assets, mirroring MockAggregatorV3 behavior.
        // Note: only assets that already had `setBorrowRate` called are tracked here;
        // any asset queried before any setter call returns zero-initialized data.
        // Tests that need the stale window for an asset must call `setBorrowRate` first.
        // (We don't track an array of assets — Solidity doesn't support iterating a mapping.)
        emit StaleStateChanged(stale_);
    }

    /// @notice Toggle revert-mode. When `true`, `getReserveData` reverts.
    function setRevert(bool shouldRevert_) external onlyOwner {
        shouldRevert = shouldRevert_;
        emit RevertStateChanged(shouldRevert_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ─────────────────── Aave-V3 surface ───────────────────

    /// @notice Drop-in replacement for `IPool.getReserveData(asset)` from Aave V3.
    ///         When `setStale(true)` was called, returns `lastUpdateTimestamp = block.timestamp - 1 days`.
    ///         When `setRevert(true)` was called, reverts with `RevertSimulated`.
    function getReserveData(address asset) external view returns (ReserveData memory data) {
        if (shouldRevert) revert RevertSimulated();
        data = _reserves[asset];
        if (stale) {
            data.lastUpdateTimestamp = uint40(block.timestamp - 1 days);
        }
    }

    /// @notice Direct getter for the variable borrow rate of `asset` (RAY).
    ///         Convenience for tests; not part of Aave's IPool but useful.
    function variableBorrowRateOf(address asset) external view returns (uint256) {
        if (shouldRevert) revert RevertSimulated();
        return uint256(_reserves[asset].currentVariableBorrowRate);
    }
}
