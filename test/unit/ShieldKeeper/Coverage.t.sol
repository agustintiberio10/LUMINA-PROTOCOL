// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ShieldKeeper} from "../../../src/automation/ShieldKeeper.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @notice Minimal PolicyManager stub: zero products + zero active policies.
contract SKEmptyPolicyManager {
    function getProductCount() external pure returns (uint256) {
        return 0;
    }

    function productIds(uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function productShield(bytes32) external pure returns (address) {
        return address(0);
    }

    function getActivePolicyIds(bytes32, uint256) external pure returns (uint256[] memory ids) {
        ids = new uint256[](0);
    }

    function settlePolicy(bytes32, uint256, bool) external {}
}

contract ShieldKeeperCoverage is Test {
    ShieldKeeper keeper;
    SKEmptyPolicyManager pm;

    function setUp() public {
        vm.chainId(8453);
        pm = new SKEmptyPolicyManager();
        keeper = ProxyDeployer.deployShieldKeeper(address(pm));
    }

    /// @notice Covers L105 — final `return (false, "")` in checkUpkeep (no products + no active policies).
    function test_CheckUpkeep_NoProducts_ReturnsFalseEmpty() public view {
        (bool upkeepNeeded, bytes memory performData) = keeper.checkUpkeep("");
        assertFalse(upkeepNeeded, "expected upkeepNeeded false");
        assertEq(performData.length, 0, "expected empty performData");
    }
}
