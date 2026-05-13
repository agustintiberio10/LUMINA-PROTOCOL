// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MaintenanceReserve} from "../../../src/treasury/MaintenanceReserve.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract MaintenanceReserveCoverage is Test {
    address usdc = makeAddr("usdc");
    address admin = makeAddr("admin");

    function test_Initialize_RevertIf_ZeroUSDC() public {
        MaintenanceReserve impl = new MaintenanceReserve();
        bytes memory initData = abi.encodeWithSelector(MaintenanceReserve.initialize.selector, address(0), admin);
        vm.expectRevert(bytes("USDC zero"));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertIf_ZeroAdmin() public {
        MaintenanceReserve impl = new MaintenanceReserve();
        bytes memory initData = abi.encodeWithSelector(MaintenanceReserve.initialize.selector, usdc, address(0));
        vm.expectRevert(bytes("Admin zero"));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_HappyPath_GrantsRoles() public {
        MaintenanceReserve r = ProxyDeployer.deployMaintenanceReserve(usdc, admin);
        assertEq(address(r.usdc()), usdc);
        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(r.hasRole(r.SPENDER_ROLE(), admin));
    }
}
