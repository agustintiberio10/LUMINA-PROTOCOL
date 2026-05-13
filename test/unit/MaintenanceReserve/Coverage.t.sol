// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MaintenanceReserve} from "../../../src/treasury/MaintenanceReserve.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract MaintenanceReserveCoverage is Test {
    address usdc = makeAddr("usdc");
    address admin = makeAddr("admin");

    function test_Initialize_RevertIf_ZeroUSDC() public {
        vm.expectRevert(bytes("USDC zero"));
        ProxyDeployer.deployMaintenanceReserve(address(0), admin);
    }

    function test_Initialize_RevertIf_ZeroAdmin() public {
        vm.expectRevert(bytes("Admin zero"));
        ProxyDeployer.deployMaintenanceReserve(usdc, address(0));
    }

    function test_Initialize_HappyPath_GrantsRoles() public {
        MaintenanceReserve r = ProxyDeployer.deployMaintenanceReserve(usdc, admin);
        assertEq(address(r.usdc()), usdc);
        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(r.hasRole(r.SPENDER_ROLE(), admin));
    }
}
