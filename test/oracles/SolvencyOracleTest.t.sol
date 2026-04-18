// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";
import {MockCapacityOracleV5} from "../mocks/MockCapacityOracleV5.sol";

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
    SolvencyOracle oracle;
    MockBVForSolvency bondVault;
    MockCapacityOracleV5 capOracle;
    MockLuminaERC20 lumina;
    address admin = makeAddr("admin");

    function setUp() public {
        lumina = new MockLuminaERC20();
        bondVault = new MockBVForSolvency(address(lumina));
        capOracle = new MockCapacityOracleV5();
        capOracle.setPrice(0.036e18);
        oracle = new SolvencyOracle(address(bondVault), address(capOracle), admin);
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
}
