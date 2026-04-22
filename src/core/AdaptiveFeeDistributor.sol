// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev [V5.1] UUPS upgradeable proxy pattern.

interface ISolvencyOracleForDist {
    function getCurrentQuadrant() external view returns (uint8 solvencyLevel, uint8 momentumLevel);
    function isHealthy() external view returns (bool);
}

/// @title AdaptiveFeeDistributor
/// @notice Hardcoded 4x4 distribution matrix (4-bucket) based on SolvencyOracle quadrant.
contract AdaptiveFeeDistributor is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    ISolvencyOracleForDist public solvencyOracle;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _solvencyOracle) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_solvencyOracle != address(0), "Oracle zero");
        solvencyOracle = ISolvencyOracleForDist(_solvencyOracle);
    }

    function getDistribution()
        external
        view
        returns (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintenanceBps)
    {
        (uint8 sLevel, uint8 mLevel) = solvencyOracle.getCurrentQuadrant();
        return _lookupDistribution(sLevel, mLevel);
    }

    function isHealthy() external view returns (bool) {
        return solvencyOracle.isHealthy();
    }

    function lookupDistribution(uint8 sLevel, uint8 mLevel) external pure returns (uint256, uint256, uint256, uint256) {
        return _lookupDistribution(sLevel, mLevel);
    }

    function _lookupDistribution(uint8 sLevel, uint8 mLevel)
        internal
        pure
        returns (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintenanceBps)
    {
        require(sLevel < 4, "Invalid solvency level");
        require(mLevel < 4, "Invalid momentum level");

        if (sLevel == 0) {
            if (mLevel == 0) return (9500, 0, 0, 500);
            if (mLevel == 1) return (9000, 500, 0, 500);
            if (mLevel == 2) return (8500, 1000, 0, 500);
            return (7500, 2000, 0, 500);
        }
        if (sLevel == 1) {
            if (mLevel == 0) return (9000, 500, 0, 500);
            if (mLevel == 1) return (8500, 800, 200, 500);
            if (mLevel == 2) return (7000, 2100, 200, 700);
            return (5500, 3500, 200, 800);
        }
        if (sLevel == 2) {
            if (mLevel == 0) return (7500, 1800, 200, 500);
            if (mLevel == 1) return (5500, 3500, 200, 800);
            if (mLevel == 2) return (3800, 5500, 200, 500);
            return (1800, 7500, 200, 500);
        }
        if (mLevel == 0) return (4800, 4500, 200, 500);
        if (mLevel == 1) return (2800, 6500, 200, 500);
        if (mLevel == 2) return (800, 8500, 200, 500);
        return (0, 9600, 200, 200);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[50] private __gap;
}
