// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockSolvencyOracle {
    uint8 public solvencyLevel = 1;
    uint8 public momentumLevel = 1;
    uint256 public mockSolvencyRatio = 15000;
    bool public mockHealthy = true;

    function setQuadrant(uint8 s, uint8 m) external {
        solvencyLevel = s;
        momentumLevel = m;
    }

    function setSolvencyRatio(uint256 ratio) external {
        mockSolvencyRatio = ratio;
    }

    function setHealthy(bool h) external {
        mockHealthy = h;
    }

    function getCurrentQuadrant() external view returns (uint8, uint8) {
        return (solvencyLevel, momentumLevel);
    }

    function getSolvencyRatio() external view returns (uint256) {
        return mockSolvencyRatio;
    }

    function isHealthy() external view returns (bool) {
        return mockHealthy;
    }
}
