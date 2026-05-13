// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CEXLiquidityReserve} from "../../../src/treasury/CEXLiquidityReserve.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract CEXLiquidityReserveCoverage is Test {
    address lumina = makeAddr("lumina");
    address multisig = makeAddr("multisig");

    function test_Initialize_RevertIf_ZeroLumina() public {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        bytes memory initData = abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, address(0), multisig);
        vm.expectRevert(bytes("Lumina zero address"));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertIf_ZeroMultisig() public {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        bytes memory initData = abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, lumina, address(0));
        vm.expectRevert(bytes("Multisig zero address"));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_HappyPath_StoresMultisigRoles() public {
        CEXLiquidityReserve r = ProxyDeployer.deployCEXLiquidityReserve(lumina, multisig);
        assertEq(address(r.lumina()), lumina);
        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), multisig));
        assertTrue(r.hasRole(r.ALLOCATOR_ROLE(), multisig));
    }
}
