// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/oracles/CapacityOracle.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

/// @title MR-H01 PoC — CapacityOracle serves a STALE frozen-pool price
/// @notice Sprint 7.3 Manual Review. Demonstrates that `getLuminaPrice()` has NO
///         observation-age / cardinality freshness gate: an idle pool (no swaps)
///         returns a well-formed, non-zero, STALE price, and the F-02 deviation
///         breaker cannot detect it because both windows read the same frozen tick
///         (dev == 0). NOT executed on testnet/mainnet — local forge only
///         (deferred to CI Linux per the via_ir OOM constraint on the Windows host).
///
/// Key point vs F-02: the deviation breaker defends against intra-pool *divergence*.
/// Whole-pool *staleness* produces zero divergence, so it sails through.
///
/// A real Uniswap V3 `observe()` does NOT revert on an idle pool — it extrapolates
/// the last observation to `block.timestamp` at the last tick. This mock reproduces
/// that: its `observe()` output depends only on the configured tick, never on time.
contract MockFrozenPool {
    address public token0_;
    address public token1_;
    int24 public tick; // last recorded tick — frozen until a swap moves it

    uint32 public constant LONG_WINDOW = 7200;

    constructor(address _t0, address _t1) {
        token0_ = _t0;
        token1_ = _t1;
    }

    function token0() external view returns (address) {
        return token0_;
    }

    function token1() external view returns (address) {
        return token1_;
    }

    function setTick(int24 _t) external {
        tick = _t;
    }

    /// @dev Time-independent: a frozen pool returns the same average tick for any
    ///      window at any `block.timestamp` — the defining property of staleness.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiq)
    {
        uint32 window = secondsAgos[0];
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(tick) * int56(int32(window));
        secondsPerLiq = new uint160[](2);
    }

    // cardinality = 1 here: a shallow pool. The oracle never reads this getter,
    // which is the whole point of MR-H01.
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, tick, 0, 1, 1, 0, true);
    }
}

contract MR_H01_OracleStaleness_PoC is Test {
    CapacityOracle oracle;
    MockFrozenPool pool;
    address lumina = makeAddr("lumina");
    address usdc = makeAddr("usdc");

    function setUp() public {
        vm.chainId(8453);
        // emergencyPrice seed = $0.036 (bootstrap floor); irrelevant here because the
        // TWAP path does NOT fall back when observe() succeeds with a stale value.
        oracle = ProxyDeployer.deployCapacityOracle(address(0), lumina, usdc, 0.036e18);
        pool = new MockFrozenPool(lumina, usdc);
        oracle.setPool(address(pool));
    }

    /// MR-H01: a price recorded at T0 is still returned, unchanged and WITHOUT a
    /// revert, an arbitrary amount of wall-clock time later, even though the pool
    /// has seen no trading. The deviation breaker (dev == 0) does not trip.
    function test_StalePriceServedAfterLongIdlePeriod() public {
        // T0: last swap fixed LUMINA ~ $0.50 (tick chosen so both windows agree).
        pool.setTick(-69080); // ~ $0.001 scale tick; exact value irrelevant — see assertion
        uint256 priceAtT0 = oracle.getLuminaPrice();
        assertGt(priceAtT0, 0, "T0 price should be non-zero");

        // Market moves / pool goes idle for 24h. No swaps => pool tick frozen.
        vm.warp(block.timestamp + 24 hours);
        vm.roll(block.number + 7200);

        // BUG: the oracle happily returns the SAME stale price with no revert.
        uint256 priceAfterIdle = oracle.getLuminaPrice();
        assertEq(priceAfterIdle, priceAtT0, "stale price served unchanged after 24h idle (MR-H01)");

        // A correct implementation with an observation-age gate would have reverted
        // here (fail-closed) because the latest observation is 24h old. There is no
        // such gate, so this assertion passes — proving the defect.
    }

    /// MR-H01: confirm the F-02 deviation breaker provides NO protection against
    /// staleness — both windows of a frozen pool yield identical ticks => dev == 0.
    function test_DeviationBreakerBlindToStaleness() public {
        pool.setTick(-69080);
        // Does not revert; returns a price. The breaker only sees dev==0.
        uint256 p = oracle.getLuminaPrice();
        assertGt(p, 0, "frozen pool passes the deviation breaker (dev==0)");
    }
}
