// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISolvencyOracleForDist {
    function getCurrentQuadrant() external view returns (uint8 solvencyLevel, uint8 momentumLevel);
    function isHealthy() external view returns (bool);
}

/// @title AdaptiveFeeDistributor
/// @notice Hardcoded 4x4 distribution matrix based on SolvencyOracle quadrant.
contract AdaptiveFeeDistributor {
    ISolvencyOracleForDist public immutable solvencyOracle;

    constructor(address _solvencyOracle) {
        require(_solvencyOracle != address(0), "Oracle zero");
        solvencyOracle = ISolvencyOracleForDist(_solvencyOracle);
    }

    function getDistribution() external view returns (uint256 burnBps, uint256 buybackBps, uint256 opsBps) {
        (uint8 sLevel, uint8 mLevel) = solvencyOracle.getCurrentQuadrant();
        return _lookupDistribution(sLevel, mLevel);
    }

    function isHealthy() external view returns (bool) {
        return solvencyOracle.isHealthy();
    }

    function lookupDistribution(uint8 sLevel, uint8 mLevel) external pure returns (uint256, uint256, uint256) {
        return _lookupDistribution(sLevel, mLevel);
    }

    function _lookupDistribution(uint8 sLevel, uint8 mLevel)
        internal
        pure
        returns (uint256 burnBps, uint256 buybackBps, uint256 opsBps)
    {
        require(sLevel < 4, "Invalid solvency level");
        require(mLevel < 4, "Invalid momentum level");

        // Solvency: 0=Ultra, 1=Healthy, 2=Stressed, 3=Crisis
        // Momentum: 0=Rally, 1=Stable, 2=Decline, 3=Crash
        if (sLevel == 0) {
            if (mLevel == 0) return (10000, 0, 0);
            if (mLevel == 1) return (9500, 500, 0);
            if (mLevel == 2) return (9000, 1000, 0);
            return (8000, 2000, 0);
        }
        if (sLevel == 1) {
            if (mLevel == 0) return (9500, 500, 0);
            if (mLevel == 1) return (8800, 1000, 200);
            if (mLevel == 2) return (7500, 2300, 200);
            return (6000, 3800, 200);
        }
        if (sLevel == 2) {
            if (mLevel == 0) return (8000, 1800, 200);
            if (mLevel == 1) return (6000, 3800, 200);
            if (mLevel == 2) return (4000, 5800, 200);
            return (2000, 7800, 200);
        }
        // Crisis
        if (mLevel == 0) return (5000, 4800, 200);
        if (mLevel == 1) return (3000, 6800, 200);
        if (mLevel == 2) return (1000, 8800, 200);
        return (0, 9800, 200);
    }
}
