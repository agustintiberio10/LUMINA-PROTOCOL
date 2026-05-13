// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CEXLiquidityReserve} from "../../../src/treasury/CEXLiquidityReserve.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract CEXLiquidityReserveCoverage is Test {
    address lumina = makeAddr("lumina");
    address multisig = makeAddr("multisig");

    function test_Initialize_RevertIf_ZeroLumina() public {
        vm.expectRevert(bytes("Lumina zero address"));
        ProxyDeployer.deployCEXLiquidityReserve(address(0), multisig);
    }

    function test_Initialize_RevertIf_ZeroMultisig() public {
        vm.expectRevert(bytes("Multisig zero address"));
        ProxyDeployer.deployCEXLiquidityReserve(lumina, address(0));
    }

    function test_Initialize_HappyPath_StoresMultisigRoles() public {
        CEXLiquidityReserve r = ProxyDeployer.deployCEXLiquidityReserve(lumina, multisig);
        assertEq(address(r.lumina()), lumina);
        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), multisig));
        assertTrue(r.hasRole(r.ALLOCATOR_ROLE(), multisig));
    }
}
