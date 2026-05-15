// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract MockSolvencyOracle {
    uint8 public solvencyLevel;
    uint8 public momentumLevel;

    function setQuadrant(uint8 s, uint8 m) external {
        solvencyLevel = s;
        momentumLevel = m;
    }

    function getCurrentQuadrant() external view returns (uint8, uint8) {
        return (solvencyLevel, momentumLevel);
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }
}

/// @title AdaptiveFeeDistributorFuzz
/// @notice Fuzz tests for AdaptiveFeeDistributor distribution matrix.
contract AdaptiveFeeDistributorFuzz is Test {
    using ProxyDeployer for *;

    AdaptiveFeeDistributor distributor;
    MockSolvencyOracle oracle;

    function setUp() public {
        vm.chainId(8453);
        oracle = new MockSolvencyOracle();
        distributor = ProxyDeployer.deployAdaptiveFeeDistributor(address(oracle));
    }

    /// @notice Fuzz: all valid quadrant distributions must sum to exactly 10000 BPS.
    function testFuzz_AllQuadrants_SumTo10000(uint8 sLevel, uint8 mLevel) public view {
        sLevel = uint8(bound(sLevel, 0, 3));
        mLevel = uint8(bound(mLevel, 0, 3));

        (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintenanceBps) =
            distributor.lookupDistribution(sLevel, mLevel);

        assertEq(burnBps + buybackBps + opsBps + maintenanceBps, 10000, "Distribution must sum to 10000 BPS");
    }

    /// @notice Fuzz: invalid solvency or momentum levels must revert.
    function testFuzz_InvalidLevels_Revert(uint8 sLevel, uint8 mLevel) public {
        // At least one level must be >= 4
        vm.assume(sLevel >= 4 || mLevel >= 4);

        vm.expectRevert();
        distributor.lookupDistribution(sLevel, mLevel);
    }

    /// @notice Fuzz: maintenance BPS should always be >= 200 (the floor in the matrix).
    function testFuzz_MaintenanceAlwaysAboveFloor(uint8 sLevel, uint8 mLevel) public view {
        sLevel = uint8(bound(sLevel, 0, 3));
        mLevel = uint8(bound(mLevel, 0, 3));

        (,,, uint256 maintenanceBps) = distributor.lookupDistribution(sLevel, mLevel);

        assertGe(maintenanceBps, 200, "Maintenance BPS should be >= 200 (floor)");
    }
}
