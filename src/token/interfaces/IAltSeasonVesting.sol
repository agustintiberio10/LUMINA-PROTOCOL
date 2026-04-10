// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAltSeasonVesting {
    function altSeasonTriggered() external view returns (bool);
    function triggerTimestamp() external view returns (uint256);
    function tranchesReleased() external view returns (uint256);
    function getConditions() external view returns (bool condA, bool condB, bool condC);
    function getStatus() external view returns (bool, uint256, uint256, uint256, uint256);
    function checkAltSeason() external;
    function releaseTranche() external;
}
