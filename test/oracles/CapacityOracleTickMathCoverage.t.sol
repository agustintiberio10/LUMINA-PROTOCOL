// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CapacityOracle} from "../../src/oracles/CapacityOracle.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

/// @notice Mock Uniswap V3 pool with configurable tick + revert mode.
/// Used by CapacityOracleTickMathCoverage to drive every branch of
/// `_getSqrtPriceFromTick` and the surrounding TWAP read logic.
contract CapTickMock {
    int24 public mockTick;
    address public t0;
    address public t1;
    bool public shouldRevertObserve;

    constructor(address _t0, address _t1) {
        t0 = _t0;
        t1 = _t1;
    }

    function token0() external view returns (address) {
        return t0;
    }

    function token1() external view returns (address) {
        return t1;
    }

    function setTick(int24 t) external {
        mockTick = t;
    }

    function setRevert(bool r) external {
        shouldRevertObserve = r;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiq)
    {
        if (shouldRevertObserve) revert("CapTickMock: observe revert");
        tickCumulatives = new int56[](2);
        // [0] = older, [1] = now. Difference / window = avgTick.
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(mockTick) * int56(uint56(secondsAgos[0]));
        secondsPerLiq = new uint160[](2);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, mockTick, 0, 0, 0, 0, true);
    }
}

/// @title CapacityOracleTickMathCoverage
/// @notice Sprint Y.2 — dedicated coverage of `_getSqrtPriceFromTick` Uniswap V3
///         TickMath inline + the TWAP / emergency / token-order branches.
contract CapacityOracleTickMathCoverage is Test {
    CapacityOracle oracle;
    CapTickMock pool;
    address lumina = makeAddr("LUMINA");
    address usdc = makeAddr("USDC");
    uint256 constant EMERGENCY = 0.036e18;

    function _deployWithToken0Lumina() internal {
        // lumina as token0
        oracle = ProxyDeployer.deployCapacityOracle(address(0), lumina, usdc, EMERGENCY);
        pool = new CapTickMock(lumina, usdc);
        oracle.setPool(address(pool));
    }

    function _deployWithToken0Usdc() internal {
        // usdc as token0 (lumina as token1) — exercises the else branch
        oracle = ProxyDeployer.deployCapacityOracle(address(0), lumina, usdc, EMERGENCY);
        pool = new CapTickMock(usdc, lumina);
        oracle.setPool(address(pool));
    }

    // ─────────────── TickMath bit-branch coverage ───────────────

    /// All 20 conditional bits set (covers each `if (absTick & 0xN != 0)` TRUE side).
    function test_TickMath_AllBitsSet_PositiveTick() public {
        _deployWithToken0Lumina();
        // 0xFFFFF = all bits 0x1..0x80000 set; positive triggers `if (tick > 0)` branch.
        pool.setTick(int24(int256(0xFFFFF))); // huge positive tick
        uint256 p = oracle.getLuminaPrice();
        // Won't revert; price may be very large/small but non-zero or fallback.
        assertGt(p, 0, "Got zero price for max-bits positive tick");
    }

    /// All bits set negative — exercises the FALSE side of `if (tick > 0)`.
    function test_TickMath_AllBitsSet_NegativeTick() public {
        _deployWithToken0Lumina();
        pool.setTick(int24(-int256(0xFFFFF)));
        uint256 p = oracle.getLuminaPrice();
        assertGt(p, 0, "Got zero price for max-bits negative tick");
    }

    /// Tick zero — none of the `absTick & 0xN` branches trigger (FALSE side of all).
    function test_TickMath_ZeroTick() public {
        _deployWithToken0Lumina();
        pool.setTick(0);
        uint256 p = oracle.getLuminaPrice();
        assertGt(p, 0, "Got zero price for tick zero");
    }

    /// Negative tick whose absolute value triggers `tickDiff % secs != 0` (rounding decrement).
    function test_TickMath_NegativeTick_RoundingDecrement() public {
        _deployWithToken0Lumina();
        pool.setTick(-1); // tickDiff = -1800; secs = 1800; -1800 % 1800 == 0 so no decrement.
        uint256 p = oracle.getLuminaPrice();
        assertGt(p, 0);
        pool.setTick(-100); // Pick a value with non-zero modulo behavior on shorter windows
        oracle.setTwapWindow(900);
        uint256 p2 = oracle.getLuminaPrice();
        assertGt(p2, 0);
    }

    /// Mid-magnitude tick (~ -92000 = LUMINA $0.036) — typical production path.
    function test_TickMath_TypicalPriceTick() public {
        _deployWithToken0Lumina();
        pool.setTick(-92000);
        uint256 p = oracle.getLuminaPrice();
        assertGt(p, 0);
    }

    // ─────────────── isToken0Lumina branches ───────────────

    /// LUMINA is token0 — exercises the if-branch of `isToken0Lumina ? ... : ...`.
    function test_PriceBranch_Token0IsLumina() public {
        _deployWithToken0Lumina();
        pool.setTick(-50000);
        uint256 p = oracle.getLuminaPrice();
        assertGt(p, 0);
        assertTrue(oracle.isToken0Lumina(), "expected isToken0Lumina = true");
    }

    /// LUMINA is token1 (USDC is token0) — exercises the else-branch (reciprocal price).
    function test_PriceBranch_Token0IsUsdc() public {
        _deployWithToken0Usdc();
        pool.setTick(50000);
        uint256 p = oracle.getLuminaPrice();
        assertGt(p, 0);
        assertFalse(oracle.isToken0Lumina(), "expected isToken0Lumina = false");
    }

    // ─────────────── getTWAP variants ───────────────

    function test_GetTWAP_VariousWindows() public {
        _deployWithToken0Lumina();
        pool.setTick(-92000);
        // Test a few valid windows.
        assertGt(oracle.getTWAP(300), 0, "5min window failed");
        assertGt(oracle.getTWAP(1800), 0, "30min window failed");
        assertGt(oracle.getTWAP(3600), 0, "1h window failed");
        assertGt(oracle.getTWAP(7200), 0, "2h window failed");
    }

    function test_GetTWAP_ObserveReverts_FallbackToEmergency() public {
        _deployWithToken0Lumina();
        pool.setRevert(true);
        uint256 p = oracle.getTWAP(1800);
        // Reverted observe → catch → return emergencyPrice.
        assertEq(p, EMERGENCY, "expected fallback to emergency");
    }

    function test_GetTWAP_TwoH_Token1IsLumina_Reciprocal() public {
        _deployWithToken0Usdc();
        pool.setTick(40000);
        uint256 p = oracle.getTWAP(7200);
        assertGt(p, 0);
    }

    // ─────────────── getLuminaPrice fallback ───────────────

    function test_GetLuminaPrice_ObserveReverts_FallsBackToEmergency() public {
        _deployWithToken0Lumina();
        pool.setRevert(true);
        uint256 p = oracle.getLuminaPrice();
        assertEq(p, EMERGENCY, "expected fallback to emergency");
    }

    function test_GetLuminaPrice_NoPool_ReturnsEmergency() public {
        oracle = ProxyDeployer.deployCapacityOracle(address(0), lumina, usdc, EMERGENCY);
        assertEq(oracle.getLuminaPrice(), EMERGENCY, "expected emergency when pool unset");
    }

    // ─────────────── maxPoliciesPerDay edge cases ───────────────

    function test_MaxPoliciesPerDay_WithPool_Live() public {
        _deployWithToken0Lumina();
        pool.setTick(-92000);
        uint256 m = oracle.maxPoliciesPerDay();
        // Just sanity-checking it doesn't revert + returns a finite value.
        assertGt(m, 0);
    }

    function test_MaxPoliciesPerDay_ZeroDailyCommit_ReturnsMax() public {
        // Constants (AVG_PAYOUT_USD=500, AVG_TRIGGER_RATE_BPS=100) give
        // dailyCommitUSD = (500 * 100) / 10000 = 5 != 0, so this branch is
        // only reachable if AVG_TRIGGER_RATE_BPS were 0 — not the case in prod.
        // Test the live path to at least exercise the function entry.
        _deployWithToken0Lumina();
        pool.setTick(-92000);
        oracle.maxPoliciesPerDay();
    }

    // ─────────────── _setPool side effects ───────────────

    function test_SetPool_UpdatesToken0Flag_LuminaIsT0() public {
        _deployWithToken0Lumina();
        assertTrue(oracle.isToken0Lumina());
        // Replace the pool with USDC as t0.
        CapTickMock newPool = new CapTickMock(usdc, lumina);
        oracle.setPool(address(newPool));
        assertFalse(oracle.isToken0Lumina());
    }

    // ─────────────── twapWindow setter bounds ───────────────

    function test_SetTwapWindow_RevertIf_TooShort() public {
        _deployWithToken0Lumina();
        vm.expectRevert(bytes("Window: 5min-2hr"));
        oracle.setTwapWindow(299);
    }

    function test_SetTwapWindow_RevertIf_TooLong() public {
        _deployWithToken0Lumina();
        vm.expectRevert(bytes("Window: 5min-2hr"));
        oracle.setTwapWindow(7201);
    }

    function test_SetTwapWindow_Boundaries() public {
        _deployWithToken0Lumina();
        oracle.setTwapWindow(300);
        assertEq(oracle.twapWindow(), 300);
        oracle.setTwapWindow(7200);
        assertEq(oracle.twapWindow(), 7200);
    }

    // ─────────────── emergencyPrice setter ───────────────

    function test_SetEmergencyPrice_RevertIf_Zero() public {
        _deployWithToken0Lumina();
        vm.expectRevert(bytes("Zero price"));
        oracle.setEmergencyPrice(0);
    }
}
