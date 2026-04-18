// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {MockSolvencyOracle} from "../mocks/MockSolvencyOracle.sol";

contract AdaptiveFeeDistributorTest is Test {
    AdaptiveFeeDistributor distributor;
    MockSolvencyOracle oracle;

    function setUp() public {
        oracle = new MockSolvencyOracle();
        distributor = new AdaptiveFeeDistributor(address(oracle));
    }

    function test_AllSixteenQuadrants_SumTo10000() public view {
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(s, m);
                assertEq(b + bb + o, 10000, "Sum must be 10000");
            }
        }
    }

    function test_Quadrant_0_0_UltraRally() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(0, 0);
        assertEq(b, 10000);
        assertEq(bb, 0);
        assertEq(o, 0);
    }

    function test_Quadrant_1_1_HealthyStable() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(1, 1);
        assertEq(b, 8800);
        assertEq(bb, 1000);
        assertEq(o, 200);
    }

    function test_Quadrant_3_3_CrisisCrash() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(3, 3);
        assertEq(b, 0);
        assertEq(bb, 9800);
        assertEq(o, 200);
    }

    function test_GetDistribution_DelegatesToOracle() public {
        oracle.setQuadrant(2, 1);
        (uint256 b, uint256 bb, uint256 o) = distributor.getDistribution();
        assertEq(b, 6000);
        assertEq(bb, 3800);
        assertEq(o, 200);
    }

    function test_IsHealthy_Delegates() public {
        oracle.setHealthy(true);
        assertTrue(distributor.isHealthy());
        oracle.setHealthy(false);
        assertFalse(distributor.isHealthy());
    }

    function test_RevertIf_InvalidSolvencyLevel() public {
        vm.expectRevert("Invalid solvency level");
        distributor.lookupDistribution(4, 0);
    }

    function test_RevertIf_InvalidMomentumLevel() public {
        vm.expectRevert("Invalid momentum level");
        distributor.lookupDistribution(0, 4);
    }

    function test_Constructor_RevertIfZeroOracle() public {
        vm.expectRevert("Oracle zero");
        new AdaptiveFeeDistributor(address(0));
    }

    function test_Quadrant_0_1_UltraStable() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(0, 1);
        assertEq(b, 9500);
        assertEq(bb, 500);
        assertEq(o, 0);
    }

    function test_Quadrant_0_2_UltraDecline() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(0, 2);
        assertEq(b, 9000);
        assertEq(bb, 1000);
        assertEq(o, 0);
    }

    function test_Quadrant_0_3_UltraCrash() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(0, 3);
        assertEq(b, 8000);
        assertEq(bb, 2000);
        assertEq(o, 0);
    }

    function test_Quadrant_1_2_HealthyDecline() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(1, 2);
        assertEq(b, 7500);
        assertEq(bb, 2300);
        assertEq(o, 200);
    }

    function test_Quadrant_1_3_HealthyCrash() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(1, 3);
        assertEq(b, 6000);
        assertEq(bb, 3800);
        assertEq(o, 200);
    }

    function test_Quadrant_2_0_StressedRally() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(2, 0);
        assertEq(b, 8000);
        assertEq(bb, 1800);
        assertEq(o, 200);
    }

    function test_Quadrant_2_1_StressedStable() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(2, 1);
        assertEq(b, 6000);
        assertEq(bb, 3800);
        assertEq(o, 200);
    }

    function test_Quadrant_2_2_StressedDecline() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(2, 2);
        assertEq(b, 4000);
        assertEq(bb, 5800);
        assertEq(o, 200);
    }

    function test_Quadrant_2_3_StressedCrash() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(2, 3);
        assertEq(b, 2000);
        assertEq(bb, 7800);
        assertEq(o, 200);
    }

    function test_Quadrant_3_0_CrisisRally() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(3, 0);
        assertEq(b, 5000);
        assertEq(bb, 4800);
        assertEq(o, 200);
    }

    function test_Quadrant_3_1_CrisisStable() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(3, 1);
        assertEq(b, 3000);
        assertEq(bb, 6800);
        assertEq(o, 200);
    }

    function test_Quadrant_3_2_CrisisDecline() public view {
        (uint256 b, uint256 bb, uint256 o) = distributor.lookupDistribution(3, 2);
        assertEq(b, 1000);
        assertEq(bb, 8800);
        assertEq(o, 200);
    }
}
