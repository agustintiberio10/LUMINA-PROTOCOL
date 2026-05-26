// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/oracles/CapacityOracle.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

/// @notice Mock Uniswap V3 pool whose TWAP can differ per window.
/// @dev `observe(secondsAgos)` returns cumulatives such that the derived
///      average tick equals `tickForWindow(secondsAgos[0])`. This lets a test
///      set the SHORT window (twapWindow, 1800s) and the LONG window
///      (LONG_TWAP_WINDOW, 7200s) to different ticks — exactly the deviation
///      the F-02 circuit-breaker must catch.
contract MockDualWindowPool {
    address public token0_;
    address public token1_;

    int24 public shortTick; // tick reported for the 1800s window
    int24 public longTick; // tick reported for the 7200s window
    uint32 public constant SHORT_WINDOW = 1800;
    uint32 public constant LONG_WINDOW = 7200;

    bool public revertOnLong; // simulate "pool too young" for the long window

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

    function setTicks(int24 _short, int24 _long) external {
        shortTick = _short;
        longTick = _long;
    }

    function setRevertOnLong(bool v) external {
        revertOnLong = v;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiq)
    {
        uint32 window = secondsAgos[0];
        int24 tick;
        if (window == LONG_WINDOW) {
            require(!revertOnLong, "no long observation");
            tick = longTick;
        } else {
            tick = shortTick;
        }
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(tick) * int56(int32(window));
        secondsPerLiq = new uint160[](2);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        // [MR-H01] Report a healthy observation cardinality so the freshness gate
        // (which now runs before the deviation logic these tests exercise) passes.
        return (0, shortTick, 0, 100, 100, 0, true);
    }

    // [MR-H01] Fresh latest observation so the staleness gate passes; these tests
    // target the deviation breaker, not freshness.
    function observations(uint256)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        return (uint32(block.timestamp), 0, 0, true);
    }
}

contract F02_OracleDeviationTest is Test {
    CapacityOracle oracle;
    MockDualWindowPool pool;
    address lumina = makeAddr("lumina");
    address usdc = makeAddr("usdc");

    function setUp() public {
        vm.chainId(8453);
        oracle = ProxyDeployer.deployCapacityOracle(address(0), lumina, usdc, 0.036e18);
        pool = new MockDualWindowPool(lumina, usdc);
        oracle.setPool(address(pool));
    }

    /// F-02: when the short and long TWAP windows diverge beyond MAX_DEVIATION_BPS
    /// the oracle must FAIL-CLOSED (revert), not return a manipulated price or a
    /// silent emergency fallback.
    function test_DeviationBetweenWindowsRevertsOrFlags() public {
        // Long window stable at -92000 (~$0.036). Short window grinded far up.
        // -80000 vs -92000 is ~ a >100% price gap → well over 5%.
        pool.setTicks(-80000, -92000);

        vm.expectRevert(); // PriceDeviationTooHigh
        oracle.getLuminaPrice();
    }

    /// F-02: a manipulation that only moves a SINGLE window is insufficient —
    /// because both windows must agree within MAX_DEVIATION_BPS, the attacker
    /// cannot push a usable price by grinding only the short window. The breaker
    /// trips (revert) rather than returning the manipulated short price.
    function test_SingleWindowManipulationInsufficient() public {
        // Honest reference: both windows agree → trustworthy, returns a price.
        pool.setTicks(-92000, -92000);
        uint256 honest = oracle.getLuminaPrice();
        assertGt(honest, 0, "honest price should be non-zero");

        // Attacker grinds ONLY the short window to a much higher tick.
        pool.setTicks(-50000, -92000);
        vm.expectRevert(); // breaker trips; attacker cannot harvest short price
        oracle.getLuminaPrice();

        // Sanity: small deviation within 5% is tolerated and returns the short price.
        // ~30 ticks ≈ 0.3% apart, well under MAX_DEVIATION_BPS (500 = 5%).
        pool.setTicks(-92000, -92030);
        uint256 ok = oracle.getLuminaPrice();
        assertGt(ok, 0, "within-band price should pass");
    }

    /// When the long window has no observation history (young pool), the oracle
    /// cannot run the breaker and conservatively falls back to emergencyPrice
    /// rather than trusting an unguarded short window for a value-bearing read.
    function test_LongWindowUnavailableFallsBackToEmergency() public {
        pool.setTicks(-92000, -92000);
        pool.setRevertOnLong(true);
        uint256 p = oracle.getLuminaPrice();
        assertEq(p, 0.036e18, "should fall back to emergencyPrice");
    }
}
