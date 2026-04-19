// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock del IAdaptiveFeeDistributor para tests (4-bucket)
contract MockFeeDistributor {
    bool public healthy = true;
    uint256 public burnBps = 8500;
    uint256 public buybackBps = 800;
    uint256 public opsBps = 200;
    uint256 public maintenanceBps = 500;

    bool public revertOnHealthy = false;
    bool public revertOnGetDistribution = false;

    function setHealthy(bool _h) external {
        healthy = _h;
    }

    function setDistribution(uint256 b, uint256 bb, uint256 o, uint256 m) external {
        burnBps = b;
        buybackBps = bb;
        opsBps = o;
        maintenanceBps = m;
    }

    function setRevertOnHealthy(bool _r) external {
        revertOnHealthy = _r;
    }

    function setRevertOnGetDistribution(bool _r) external {
        revertOnGetDistribution = _r;
    }

    function isHealthy() external view returns (bool) {
        require(!revertOnHealthy, "Mock: isHealthy revert");
        return healthy;
    }

    function getDistribution() external view returns (uint256, uint256, uint256, uint256) {
        require(!revertOnGetDistribution, "Mock: getDistribution revert");
        return (burnBps, buybackBps, opsBps, maintenanceBps);
    }
}
