// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/oracles/CapacityOracle.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

/// @notice Mock Uniswap V3 pool with configurable cardinality + last-observation
///         timestamp, so we can simulate a FRESH, a STALE (idle), and a THIN
///         (low-cardinality) pool. `observe()` is time-independent (frozen tick),
///         mirroring how a real idle pool extrapolates — the staleness must be
///         caught by the observation-age gate, not by `observe()` reverting.
contract MockFreshnessPool {
    address public token0_;
    address public token1_;
    int24 public tick;
    uint16 public cardinality;
    uint32 public lastObsTs;
    bool public obsInitialized = true;

    constructor(address _t0, address _t1) {
        token0_ = _t0;
        token1_ = _t1;
        tick = -69080;
        cardinality = 50;
    }

    function token0() external view returns (address) { return token0_; }
    function token1() external view returns (address) { return token1_; }

    function setCardinality(uint16 c) external { cardinality = c; }
    function setLastObsTs(uint32 t) external { lastObsTs = t; }
    function setInitialized(bool v) external { obsInitialized = v; }

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

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        // observationIndex = 0 (latest observation lives at index 0 in this mock).
        return (0, tick, 0, cardinality, cardinality, 0, true);
    }

    function observations(uint256)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized)
    {
        return (lastObsTs, 0, 0, obsInitialized);
    }
}

contract MRH01_TwapStalenessTest is Test {
    CapacityOracle oracle;
    MockFreshnessPool pool;
    address lumina = makeAddr("lumina");
    address usdc = makeAddr("usdc");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1_700_000_000);
        oracle = ProxyDeployer.deployCapacityOracle(address(0), lumina, usdc, 0.036e18);
        pool = new MockFreshnessPool(lumina, usdc);
        oracle.setPool(address(pool));
    }

    /// NO-AFTER: a fresh, deep pool returns a price (gate passes).
    function test_FreshPoolReturnsPrice() public {
        pool.setCardinality(50);
        pool.setLastObsTs(uint32(block.timestamp)); // just observed
        uint256 p = oracle.getLuminaPrice();
        assertGt(p, 0, "fresh deep pool should yield a price");
    }

    /// BUG-BEFORE (pre-fix this returned a stale price): an idle pool whose latest
    /// observation is older than maxObservationAge now REVERTS (fail-closed).
    function test_StalePoolReverts() public {
        pool.setCardinality(50);
        pool.setLastObsTs(uint32(block.timestamp - 2 hours)); // > 1h default
        vm.expectRevert(
            abi.encodeWithSelector(CapacityOracle.OracleStale.selector, uint256(2 hours), oracle.maxObservationAge())
        );
        oracle.getLuminaPrice();
    }

    /// BUG-BEFORE: a thin pool (cardinality below the minimum) now REVERTS — the
    /// window TWAP would otherwise be silently extrapolated from a single tick.
    function test_ThinPoolReverts() public {
        pool.setCardinality(5); // < DEFAULT_MIN_CARDINALITY (10)
        pool.setLastObsTs(uint32(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(CapacityOracle.OracleInsufficientCardinality.selector, uint256(5), oracle.minCardinality())
        );
        oracle.getLuminaPrice();
    }

    /// Boundary: exactly at maxObservationAge is allowed; one second older reverts.
    function test_AgeBoundary() public {
        pool.setCardinality(50);
        uint256 maxAge = oracle.maxObservationAge();
        pool.setLastObsTs(uint32(block.timestamp - maxAge)); // == maxAge → allowed
        assertGt(oracle.getLuminaPrice(), 0, "age == maxAge should pass");

        pool.setLastObsTs(uint32(block.timestamp - maxAge - 1)); // > maxAge → revert
        vm.expectRevert();
        oracle.getLuminaPrice();
    }

    /// Ops can tighten/loosen within bounds; out-of-bounds reverts.
    function test_SetFreshnessParamsBounded() public {
        oracle.setFreshnessParams(300, 20);
        assertEq(oracle.maxObservationAge(), 300);
        assertEq(oracle.minCardinality(), 20);

        vm.expectRevert(bytes("age out of bounds"));
        oracle.setFreshnessParams(30, 20); // below MIN_OBSERVATION_AGE_FLOOR (60)

        vm.expectRevert(bytes("age out of bounds"));
        oracle.setFreshnessParams(25 hours, 20); // above ceiling
    }
}
