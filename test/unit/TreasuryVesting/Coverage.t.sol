// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TreasuryVesting} from "../../../src/token/TreasuryVesting.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract TreasuryVestingCoverage is Test {
    address token = makeAddr("lumina");

    function test_Initialize_RevertIf_ZeroToken() public {
        vm.expectRevert(bytes("Zero token"));
        ProxyDeployer.deployTreasuryVesting(address(0));
    }

    function test_Initialize_HappyPath_StoresToken() public {
        TreasuryVesting v = ProxyDeployer.deployTreasuryVesting(token);
        assertEq(address(v.luminaToken()), token);
    }
}
