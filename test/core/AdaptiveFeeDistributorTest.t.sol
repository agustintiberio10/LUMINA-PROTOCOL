// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {MockSolvencyOracle} from "../mocks/MockSolvencyOracle.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AdaptiveFeeDistributorTest is Test {
    using ProxyDeployer for *;

    AdaptiveFeeDistributor distributor;
    MockSolvencyOracle oracle;

    function setUp() public {
        oracle = new MockSolvencyOracle();
        distributor = ProxyDeployer.deployAdaptiveFeeDistributor(address(oracle));
    }

    // ═══════ SUM VALIDATION ═══════

    function test_AllSixteenQuadrants_SumTo10000() public view {
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(s, m);
                assertEq(b + bb + o + mt, 10000, "Sum must be 10000");
            }
        }
    }

    // ═══════ ROW 0: ULTRA SOLVENCY ═══════

    function test_Quadrant_0_0_UltraRally() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(0, 0);
        assertEq(b, 9500);
        assertEq(bb, 0);
        assertEq(o, 0);
        assertEq(mt, 500);
    }

    function test_Quadrant_0_1_UltraStable() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(0, 1);
        assertEq(b, 9000);
        assertEq(bb, 500);
        assertEq(o, 0);
        assertEq(mt, 500);
    }

    function test_Quadrant_0_2_UltraDecline() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(0, 2);
        assertEq(b, 8500);
        assertEq(bb, 1000);
        assertEq(o, 0);
        assertEq(mt, 500);
    }

    function test_Quadrant_0_3_UltraCrash() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(0, 3);
        assertEq(b, 7500);
        assertEq(bb, 2000);
        assertEq(o, 0);
        assertEq(mt, 500);
    }

    // ═══════ ROW 1: HEALTHY ═══════

    function test_Quadrant_1_0_HealthyRally() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(1, 0);
        assertEq(b, 9000);
        assertEq(bb, 500);
        assertEq(o, 0);
        assertEq(mt, 500);
    }

    function test_Quadrant_1_1_HealthyStable() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(1, 1);
        assertEq(b, 8500);
        assertEq(bb, 800);
        assertEq(o, 200);
        assertEq(mt, 500);
    }

    function test_Quadrant_1_2_HealthyDecline() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(1, 2);
        assertEq(b, 7000);
        assertEq(bb, 2100);
        assertEq(o, 200);
        assertEq(mt, 700);
    }

    function test_Quadrant_1_3_HealthyCrash() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(1, 3);
        assertEq(b, 5500);
        assertEq(bb, 3500);
        assertEq(o, 200);
        assertEq(mt, 800);
    }

    // ═══════ ROW 2: STRESSED ═══════

    function test_Quadrant_2_0_StressedRally() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(2, 0);
        assertEq(b, 7500);
        assertEq(bb, 1800);
        assertEq(o, 200);
        assertEq(mt, 500);
    }

    function test_Quadrant_2_1_StressedStable() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(2, 1);
        assertEq(b, 5500);
        assertEq(bb, 3500);
        assertEq(o, 200);
        assertEq(mt, 800);
    }

    function test_Quadrant_2_2_StressedDecline() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(2, 2);
        assertEq(b, 3800);
        assertEq(bb, 5500);
        assertEq(o, 200);
        assertEq(mt, 500);
    }

    function test_Quadrant_2_3_StressedCrash() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(2, 3);
        assertEq(b, 1800);
        assertEq(bb, 7500);
        assertEq(o, 200);
        assertEq(mt, 500);
    }

    // ═══════ ROW 3: CRISIS ═══════

    function test_Quadrant_3_0_CrisisRally() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(3, 0);
        assertEq(b, 4800);
        assertEq(bb, 4500);
        assertEq(o, 200);
        assertEq(mt, 500);
    }

    function test_Quadrant_3_1_CrisisStable() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(3, 1);
        assertEq(b, 2800);
        assertEq(bb, 6500);
        assertEq(o, 200);
        assertEq(mt, 500);
    }

    function test_Quadrant_3_2_CrisisDecline() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(3, 2);
        assertEq(b, 800);
        assertEq(bb, 8500);
        assertEq(o, 200);
        assertEq(mt, 500);
    }

    function test_Quadrant_3_3_CrisisCrash() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(3, 3);
        assertEq(b, 0);
        assertEq(bb, 9600);
        assertEq(o, 200);
        assertEq(mt, 200);
    }

    // ═══════ DELEGATION & VALIDATION ═══════

    function test_GetDistribution_DelegatesToOracle() public {
        oracle.setQuadrant(2, 1);
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.getDistribution();
        assertEq(b, 5500);
        assertEq(bb, 3500);
        assertEq(o, 200);
        assertEq(mt, 800);
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
        AdaptiveFeeDistributor impl = new AdaptiveFeeDistributor();
        vm.expectRevert();
        new ERC1967Proxy(address(impl), abi.encodeWithSelector(AdaptiveFeeDistributor.initialize.selector, address(0)));
    }

    // ═══════ MAINTENANCE-SPECIFIC TESTS ═══════

    function test_MaintenanceAlwaysAtLeast2Percent() public view {
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (,,, uint256 mt) = distributor.lookupDistribution(s, m);
                assertGe(mt, 200, "Maintenance must be >= 200 bps (2%)");
            }
        }
    }

    function test_HealthyStable_Returns_85_8_2_5() public view {
        (uint256 b, uint256 bb, uint256 o, uint256 mt) = distributor.lookupDistribution(1, 1);
        assertEq(b, 8500, "Burn should be 85%");
        assertEq(bb, 800, "Buyback should be 8%");
        assertEq(o, 200, "Ops should be 2%");
        assertEq(mt, 500, "Maintenance should be 5%");
    }
}
