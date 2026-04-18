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
}
