// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";
import {MockCapacityOracleV5} from "../mocks/MockCapacityOracleV5.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract MockBVForSolvency {
    uint256 public totalCommittedUSD;
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function setCommitted(uint256 c) external {
        totalCommittedUSD = c;
    }
}

contract MockLuminaERC20 {
    mapping(address => uint256) public balanceOf;

    function setBalance(address a, uint256 b) external {
        balanceOf[a] = b;
    }
}

contract SolvencyOracleTest is Test {
    using ProxyDeployer for *;

    // Mirror events for vm.expectEmit
    event QuadrantChanged(uint8 oldS, uint8 oldM, uint8 newS, uint8 newM, uint256 sBps, uint256 mBps);
    event EvaluationExecuted(uint256 solvencyBps, uint256 momentumBps);
    SolvencyOracle oracle;
    MockBVForSolvency bondVault;
    MockCapacityOracleV5 capOracle;
    MockLuminaERC20 lumina;
    address admin = makeAddr("admin");

    function setUp() public {
        vm.chainId(8453);
        lumina = new MockLuminaERC20();
        bondVault = new MockBVForSolvency(address(lumina));
        capOracle = new MockCapacityOracleV5();
        capOracle.setPrice(0.036e18);
        oracle = ProxyDeployer.deploySolvencyOracle(address(bondVault), address(capOracle), admin);
    }

    function test_Constructor_CorrectInit() public view {
        (uint8 s, uint8 m) = oracle.getCurrentQuadrant();
        assertEq(s, 1); // Healthy
        assertEq(m, 1); // Stable
    }

    function test_SolvencyRatio_Healthy() public {
        lumina.setBalance(address(bondVault), 70_000_000 * 1e18);
        bondVault.setCommitted(1_000_000 * 1e18); // $1M committed (18-dec)
        uint256 ratio = oracle.getSolvencyRatio();
        // (70M * 0.036 / 1e18) * 10000 / (1M * 1e18 / 1e18) = 2.52M * 10000 / 1M = 25200
        assertGt(ratio, 20000, "Should be Ultra solvent");
    }

    function test_SolvencyRatio_NoObligations() public view {
        uint256 ratio = oracle.getSolvencyRatio();
        assertEq(ratio, type(uint256).max, "Max if no obligations");
    }

    function test_Evaluate_RespectsInterval() public {
        vm.expectRevert("Evaluation interval not reached");
        oracle.evaluate();
    }

    function test_Evaluate_Success_After24h() public {
        lumina.setBalance(address(bondVault), 70_000_000 * 1e18);
        bondVault.setCommitted(1_000_000 * 1e18);
        vm.warp(block.timestamp + 1 days + 1);
        oracle.evaluate();
        assertEq(oracle.lastEvaluation(), block.timestamp);
    }

    function test_IsHealthy_True() public view {
        assertTrue(oracle.isHealthy());
    }

    function test_IsHealthy_FalseWhenPaused() public {
        vm.prank(admin);
        oracle.setEmergencyPause(true);
        assertFalse(oracle.isHealthy());
    }

    function test_IsHealthy_FalseWhenStale() public {
        vm.warp(block.timestamp + 8 days);
        assertFalse(oracle.isHealthy());
    }

    function test_SetEmergencyPause_OnlyAdmin() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        oracle.setEmergencyPause(true);
    }

    function test_Evaluate_QuadrantChangeRespectsCooldown() public {
        lumina.setBalance(address(bondVault), 70_000_000 * 1e18);
        bondVault.setCommitted(100_000_000 * 1e18); // Crisis level
        // First eval (need to warp past initial interval from constructor)
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 days + 1);
        oracle.evaluate();
        // Second eval (warp past interval again but still within 7d cooldown)
        vm.warp(t0 + 2 days + 2);
        bool changed = oracle.evaluate();
        assertFalse(changed, "Should not change within 7d cooldown");
    }

    // ---- New tests ----

    function test_Evaluate_UpdatesHistory() public {
        lumina.setBalance(address(bondVault), 70_000_000 * 1e18);
        bondVault.setCommitted(1_000_000 * 1e18);
        uint256 t0 = block.timestamp;

        // 3 evaluations filling the circular buffer
        vm.warp(t0 + 1 days + 1);
        oracle.evaluate();
        vm.warp(t0 + 2 days + 2);
        oracle.evaluate();
        vm.warp(t0 + 3 days + 3);
        oracle.evaluate();

        // All 3 slots should be populated (non-zero solvency)
        assertGt(oracle.solvencyHistory(0), 0, "History[0] populated");
        assertGt(oracle.solvencyHistory(1), 0, "History[1] populated");
        assertGt(oracle.solvencyHistory(2), 0, "History[2] populated");
    }

    function test_Evaluate_Reverts_WhenPaused() public {
        vm.prank(admin);
        oracle.setEmergencyPause(true);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert("Oracle paused");
        oracle.evaluate();
    }

    function test_IsHealthy_FalseWhenOraclePriceReverts() public {
        capOracle.setRevertOnPrice(true);
        assertFalse(oracle.isHealthy(), "Unhealthy when price reverts");
    }

    function test_ClassifySolvency_AllFourLevels() public {
        // We test via evaluate() and observe currentSolvencyLevel changes.
        // Level 0 (Ultra): bps >= 20000
        // Level 1 (Healthy): 10000 <= bps < 20000
        // Level 2 (Stressed): 7000 <= bps < 10000
        // Level 3 (Crisis): bps < 7000

        // Setup: obligations = 1M USD (1e24 with 18 dec), price = 0.036e18
        // To get ratio X bps: need bal * price / 1e18 * 10000 / obligations = X
        // bal = X * obligations / (price * 10000)
        // obligations = 1_000_000 * 1e18
        // bal = X * 1_000_000 * 1e18 / (0.036e18 * 10000)
        //     = X * 1_000_000 / 360

        bondVault.setCommitted(1_000_000 * 1e18);
        uint256 t0 = block.timestamp;

        // Ultra: ratio >= 20000 => bal >= 20000 * 1M / 360 = ~55.56M
        lumina.setBalance(address(bondVault), 56_000_000 * 1e18);
        // Need 3 evaluations to fill history for avg to settle
        vm.warp(t0 + 1 days + 1);
        oracle.evaluate();
        vm.warp(t0 + 2 days + 2);
        oracle.evaluate();
        vm.warp(t0 + 3 days + 3);
        oracle.evaluate();
        // Warp past cooldown for quadrant change
        vm.warp(t0 + 8 days);
        oracle.evaluate();
        (uint8 s,) = oracle.getCurrentQuadrant();
        assertEq(s, 0, "Ultra solvency");

        // Healthy: 10000 <= ratio < 20000 => bal ~27.8M
        lumina.setBalance(address(bondVault), 28_000_000 * 1e18);
        vm.warp(t0 + 9 days + 1);
        oracle.evaluate();
        vm.warp(t0 + 10 days + 2);
        oracle.evaluate();
        vm.warp(t0 + 11 days + 3);
        oracle.evaluate();
        vm.warp(t0 + 16 days);
        oracle.evaluate();
        (s,) = oracle.getCurrentQuadrant();
        assertEq(s, 1, "Healthy solvency");

        // Stressed: 7000 <= ratio < 10000 => bal ~22.2M for ~8000 bps
        lumina.setBalance(address(bondVault), 22_200_000 * 1e18);
        vm.warp(t0 + 17 days + 1);
        oracle.evaluate();
        vm.warp(t0 + 18 days + 2);
        oracle.evaluate();
        vm.warp(t0 + 19 days + 3);
        oracle.evaluate();
        vm.warp(t0 + 24 days);
        oracle.evaluate();
        (s,) = oracle.getCurrentQuadrant();
        assertEq(s, 2, "Stressed solvency");

        // Crisis: ratio < 7000 => bal ~16.6M for ~6000 bps
        lumina.setBalance(address(bondVault), 16_600_000 * 1e18);
        vm.warp(t0 + 25 days + 1);
        oracle.evaluate();
        vm.warp(t0 + 26 days + 2);
        oracle.evaluate();
        vm.warp(t0 + 27 days + 3);
        oracle.evaluate();
        vm.warp(t0 + 32 days);
        oracle.evaluate();
        (s,) = oracle.getCurrentQuadrant();
        assertEq(s, 3, "Crisis solvency");
    }

    function test_ClassifyMomentum_AllFourLevels() public {
        // Momentum is hardcoded to 10000 in evaluate(), which maps to:
        // >= 9500 (STABLE_LOW) => level 1 (Stable)
        // Since we can't change momentum from external input, we verify the default.
        // The classification boundaries: Rally(0)>=11000, Stable(1)>=9500, Decline(2)>=8500, Crisis(3)<8500
        // With momentum always 10000, avg will always be 10000 => level 1
        lumina.setBalance(address(bondVault), 70_000_000 * 1e18);
        bondVault.setCommitted(1_000_000 * 1e18);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 days + 1);
        oracle.evaluate();
        (, uint8 m) = oracle.getCurrentQuadrant();
        assertEq(m, 1, "Momentum level 1 (Stable) with 10000 bps");

        // Verify boundary constants exist and are correct
        assertEq(oracle.MOMENTUM_RALLY_BPS(), 11000);
        assertEq(oracle.MOMENTUM_STABLE_LOW_BPS(), 9500);
        assertEq(oracle.MOMENTUM_DECLINE_BPS(), 8500);
    }

    function test_QuadrantChange_EmitsEvent_AfterCooldown() public {
        // Set up crisis-level solvency to force a quadrant change from default (1,1)
        lumina.setBalance(address(bondVault), 16_600_000 * 1e18);
        bondVault.setCommitted(1_000_000 * 1e18);
        uint256 t0 = block.timestamp;

        // Fill history buffer with crisis ratios
        vm.warp(t0 + 1 days + 1);
        oracle.evaluate();
        vm.warp(t0 + 2 days + 2);
        oracle.evaluate();
        vm.warp(t0 + 3 days + 3);
        oracle.evaluate();

        // Now warp past 7-day cooldown
        vm.warp(t0 + 8 days);
        vm.expectEmit(false, false, false, false);
        emit QuadrantChanged(0, 0, 0, 0, 0, 0);
        bool changed = oracle.evaluate();
        assertTrue(changed, "Quadrant should change after cooldown");
    }

    function test_EvaluationExecutedEvent_AlwaysEmitted() public {
        lumina.setBalance(address(bondVault), 70_000_000 * 1e18);
        bondVault.setCommitted(1_000_000 * 1e18);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectEmit(false, false, false, false);
        emit EvaluationExecuted(0, 0);
        oracle.evaluate();
    }
}
