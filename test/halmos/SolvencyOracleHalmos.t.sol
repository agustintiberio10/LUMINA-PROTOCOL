// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";

/// @notice Test child that exposes `_classifySolvency` / `_classifyMomentum`
///         (internal pure) for Halmos symbolic verification.
contract SolvencyOracleExpose is SolvencyOracle {
    function expose_classifySolvency(uint256 bps) external pure returns (uint8) {
        return _classifySolvency(bps);
    }

    function expose_classifyMomentum(uint256 bps) external pure returns (uint8) {
        return _classifyMomentum(bps);
    }
}

/// @title SolvencyOracleHalmos
/// @notice Sprint Z — formal verification of pure classification logic.
///         Run with `halmos --contract SolvencyOracleHalmos --solver-timeout-assertion 300`.
contract SolvencyOracleHalmos is Test {
    SolvencyOracleExpose oracle;

    function setUp() public {
        oracle = new SolvencyOracleExpose();
    }

    /// @notice Property 1: _classifySolvency returns ∈ {0, 1, 2, 3} for ALL inputs (∀ uint256 bps).
    /// @dev Halmos proves this by symbolic execution over all uint256 inputs.
    function check_ClassifySolvency_Bounded_0to3(uint256 bps) public view {
        uint8 level = oracle.expose_classifySolvency(bps);
        assert(level <= 3);
    }

    /// @notice Property 2: _classifyMomentum returns ∈ {0, 1, 2, 3} for ALL inputs.
    function check_ClassifyMomentum_Bounded_0to3(uint256 bps) public view {
        uint8 level = oracle.expose_classifyMomentum(bps);
        assert(level <= 3);
    }

    /// @notice Property 3: classification is monotonically decreasing —
    ///         higher solvency bps ⇒ lower (or equal) level number (0=best, 3=worst).
    function check_ClassifySolvency_Monotonic(uint256 a, uint256 b) public view {
        vm.assume(a <= b);
        uint8 levelA = oracle.expose_classifySolvency(a);
        uint8 levelB = oracle.expose_classifySolvency(b);
        // levelA (lower bps) must be >= levelB (higher bps).
        assert(levelA >= levelB);
    }

    /// @notice Property 4: ULTRA threshold mapping — bps >= 20000 always yields level 0.
    function check_ClassifySolvency_UltraThreshold(uint256 bps) public view {
        vm.assume(bps >= oracle.SOLVENCY_ULTRA_BPS());
        uint8 level = oracle.expose_classifySolvency(bps);
        assert(level == 0);
    }

    /// @notice Property 5: critical bps < STRESSED threshold ⇒ level 3 (worst).
    function check_ClassifySolvency_StressedBoundary(uint256 bps) public view {
        vm.assume(bps < oracle.SOLVENCY_STRESSED_BPS());
        uint8 level = oracle.expose_classifySolvency(bps);
        assert(level == 3);
    }
}
