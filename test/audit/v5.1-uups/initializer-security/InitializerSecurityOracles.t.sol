// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {CapacityOracle} from "../../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../../src/oracles/SolvencyOracle.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../src/treasury/MaintenanceReserve.sol";
import {TreasuryVesting} from "../../../../src/token/TreasuryVesting.sol";

contract MockBondVaultOR {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function totalCommittedUSD() external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title InitializerSecurityOracles
 * @notice Initializer security audit for CapacityOracle, SolvencyOracle,
 *         CEXLiquidityReserve, MaintenanceReserve, TreasuryVesting (5 contracts).
 */
contract InitializerSecurityOracles is Test {
    // ─────────────────────────────────────────────────────────────
    // CapacityOracle
    // ─────────────────────────────────────────────────────────────

    function _caDeploy() internal returns (CapacityOracle) {
        return ProxyDeployer.deployCapacityOracle(address(0), makeAddr("l"), makeAddr("u"), 0.036e18);
    }

    function test_Init_CapacityOracle_CannotBeCalledTwice() public {
        CapacityOracle o = _caDeploy();
        vm.expectRevert();
        o.initialize(address(0), makeAddr("l"), makeAddr("u"), 0.036e18);
    }

    function test_Init_CapacityOracle_ImplementationLocked() public {
        CapacityOracle impl = new CapacityOracle();
        vm.expectRevert();
        impl.initialize(address(0), makeAddr("l"), makeAddr("u"), 0.036e18);
    }

    function test_Init_CapacityOracle_OnlyOwnerCanUpgrade() public {
        CapacityOracle o = _caDeploy();
        address newImpl = address(new CapacityOracle());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        o.upgradeToAndCall(newImpl, "");
        o.upgradeToAndCall(newImpl, "");
    }

    function test_Init_CapacityOracle_OwnerSetCorrectly() public {
        CapacityOracle o = _caDeploy();
        assertEq(o.owner(), address(this));
    }

    function test_Init_CapacityOracle_RevertsOnZeroLumina() public {
        CapacityOracle impl = new CapacityOracle();
        bytes memory data =
            abi.encodeWithSelector(CapacityOracle.initialize.selector, address(0), address(0), makeAddr("u"), 0.036e18);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_CapacityOracle_RevertsOnZeroUSDC() public {
        CapacityOracle impl = new CapacityOracle();
        bytes memory data =
            abi.encodeWithSelector(CapacityOracle.initialize.selector, address(0), makeAddr("l"), address(0), 0.036e18);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_CapacityOracle_RevertsOnZeroEmergencyPrice() public {
        CapacityOracle impl = new CapacityOracle();
        bytes memory data = abi.encodeWithSelector(
            CapacityOracle.initialize.selector, address(0), makeAddr("l"), makeAddr("u"), uint256(0)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_CapacityOracle_ParentInitializersCalled() public {
        CapacityOracle o = _caDeploy();
        assertEq(o.owner(), address(this));
    }

    function test_Init_CapacityOracle_InitialStateCorrect() public {
        CapacityOracle o = _caDeploy();
        assertEq(o.pool(), address(0));
        assertEq(o.luminaToken(), makeAddr("l"));
        assertEq(o.usdcToken(), makeAddr("u"));
        assertEq(o.emergencyPrice(), 0.036e18);
        assertEq(uint256(o.twapWindow()), 1800);
    }

    function test_Init_CapacityOracle_FrontRunningProtected() public {
        CapacityOracle impl = new CapacityOracle();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(address(0), makeAddr("l"), makeAddr("u"), 0.036e18);
    }

    // ─────────────────────────────────────────────────────────────
    // SolvencyOracle (AccessControl; _admin param)
    // ─────────────────────────────────────────────────────────────

    function _soDeploy(address admin) internal returns (SolvencyOracle) {
        MockBondVaultOR bv = new MockBondVaultOR(makeAddr("lumina"));
        return ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), admin);
    }

    function test_Init_SolvencyOracle_CannotBeCalledTwice() public {
        SolvencyOracle so = _soDeploy(address(this));
        vm.expectRevert();
        so.initialize(makeAddr("bv"), makeAddr("co"), address(this));
    }

    function test_Init_SolvencyOracle_ImplementationLocked() public {
        SolvencyOracle impl = new SolvencyOracle();
        vm.expectRevert();
        impl.initialize(makeAddr("bv"), makeAddr("co"), address(this));
    }

    function test_Init_SolvencyOracle_OnlyAdminCanUpgrade() public {
        SolvencyOracle so = _soDeploy(address(this));
        address newImpl = address(new SolvencyOracle());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        so.upgradeToAndCall(newImpl, "");
        so.upgradeToAndCall(newImpl, "");
    }

    function test_Init_SolvencyOracle_AdminRoleOnlyGrantedToParam() public {
        address admin = makeAddr("admin");
        SolvencyOracle so = _soDeploy(admin);
        assertTrue(so.hasRole(so.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(so.hasRole(so.ADMIN_ROLE(), admin));
        // msg.sender (this test contract) does NOT get DEFAULT_ADMIN — only param.
        assertFalse(so.hasRole(so.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_SolvencyOracle_RevertsOnZeroBondVault() public {
        SolvencyOracle impl = new SolvencyOracle();
        bytes memory data =
            abi.encodeWithSelector(SolvencyOracle.initialize.selector, address(0), makeAddr("co"), address(this));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_SolvencyOracle_RevertsOnZeroAdmin() public {
        MockBondVaultOR bv = new MockBondVaultOR(makeAddr("lumina"));
        SolvencyOracle impl = new SolvencyOracle();
        bytes memory data =
            abi.encodeWithSelector(SolvencyOracle.initialize.selector, address(bv), makeAddr("co"), address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_SolvencyOracle_ParentInitializersCalled() public {
        SolvencyOracle so = _soDeploy(address(this));
        assertTrue(so.hasRole(so.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_SolvencyOracle_InitialStateCorrect() public {
        SolvencyOracle so = _soDeploy(address(this));
        (uint8 s, uint8 m) = so.getCurrentQuadrant();
        assertEq(s, 1);
        assertEq(m, 1);
        assertEq(so.lastEvaluation(), block.timestamp);
        assertEq(so.lastQuadrantChange(), block.timestamp);
        assertFalse(so.emergencyPaused());
    }

    function test_Init_SolvencyOracle_FrontRunningProtected() public {
        SolvencyOracle impl = new SolvencyOracle();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(makeAddr("bv"), makeAddr("co"), address(this));
    }

    function test_Init_SolvencyOracle_NonAdminCannotGrantRoles() public {
        SolvencyOracle so = _soDeploy(address(this));
        bytes32 role = so.ADMIN_ROLE();
        address atk = makeAddr("atk");
        vm.prank(atk);
        vm.expectRevert();
        so.grantRole(role, atk);
    }

    // ─────────────────────────────────────────────────────────────
    // CEXLiquidityReserve (AccessControl; _multisigOwner param)
    // ─────────────────────────────────────────────────────────────

    function test_Init_CEXLiquidityReserve_CannotBeCalledTwice() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        vm.expectRevert();
        c.initialize(makeAddr("l"), address(this));
    }

    function test_Init_CEXLiquidityReserve_ImplementationLocked() public {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        vm.expectRevert();
        impl.initialize(makeAddr("l"), address(this));
    }

    function test_Init_CEXLiquidityReserve_OnlyAdminCanUpgrade() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        address newImpl = address(new CEXLiquidityReserve());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        c.upgradeToAndCall(newImpl, "");
        c.upgradeToAndCall(newImpl, "");
    }

    function test_Init_CEXLiquidityReserve_AdminRoleOnlyGrantedToParam() public {
        address multisig = makeAddr("multisig");
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), multisig);
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), multisig));
        assertTrue(c.hasRole(c.ALLOCATOR_ROLE(), multisig));
        assertFalse(c.hasRole(c.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_CEXLiquidityReserve_RevertsOnZeroLumina() public {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        bytes memory data = abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, address(0), address(this));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_CEXLiquidityReserve_RevertsOnZeroMultisig() public {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        bytes memory data = abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, makeAddr("l"), address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_CEXLiquidityReserve_ParentInitializersCalled() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_CEXLiquidityReserve_InitialStateCorrect() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        assertEq(address(c.lumina()), makeAddr("l"));
        assertEq(c.deploymentTimestamp(), block.timestamp);
        // Tier-1 redesign — single flat counter replaces V1 per-bucket trio.
        assertEq(c.totalAllocated(), 0);
        assertEq(c.monthlyCap(), c.DEFAULT_MONTHLY_CAP());
    }

    function test_Init_CEXLiquidityReserve_FrontRunningProtected() public {
        CEXLiquidityReserve impl = new CEXLiquidityReserve();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(makeAddr("l"), address(this));
    }

    function test_Init_CEXLiquidityReserve_NonAdminCannotGrantRoles() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        bytes32 role = c.ALLOCATOR_ROLE();
        address atk = makeAddr("atk");
        vm.prank(atk);
        vm.expectRevert();
        c.grantRole(role, atk);
    }

    // ─────────────────────────────────────────────────────────────
    // MaintenanceReserve (AccessControl; _admin param)
    // ─────────────────────────────────────────────────────────────

    function test_Init_MaintenanceReserve_CannotBeCalledTwice() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        vm.expectRevert();
        m.initialize(makeAddr("u"), address(this));
    }

    function test_Init_MaintenanceReserve_ImplementationLocked() public {
        MaintenanceReserve impl = new MaintenanceReserve();
        vm.expectRevert();
        impl.initialize(makeAddr("u"), address(this));
    }

    function test_Init_MaintenanceReserve_OnlyAdminCanUpgrade() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        address newImpl = address(new MaintenanceReserve());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        m.upgradeToAndCall(newImpl, "");
        m.upgradeToAndCall(newImpl, "");
    }

    function test_Init_MaintenanceReserve_AdminRoleOnlyGrantedToParam() public {
        address admin = makeAddr("admin");
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), admin);
        assertTrue(m.hasRole(m.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(m.hasRole(m.SPENDER_ROLE(), admin));
        assertFalse(m.hasRole(m.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_MaintenanceReserve_RevertsOnZeroUSDC() public {
        MaintenanceReserve impl = new MaintenanceReserve();
        bytes memory data = abi.encodeWithSelector(MaintenanceReserve.initialize.selector, address(0), address(this));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_MaintenanceReserve_RevertsOnZeroAdmin() public {
        MaintenanceReserve impl = new MaintenanceReserve();
        bytes memory data = abi.encodeWithSelector(MaintenanceReserve.initialize.selector, makeAddr("u"), address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_MaintenanceReserve_ParentInitializersCalled() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        assertTrue(m.hasRole(m.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_MaintenanceReserve_InitialStateCorrect() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        assertEq(address(m.usdc()), makeAddr("u"));
        assertEq(m.totalSpent(), 0);
        assertEq(m.currentMonthSpent(), 0);
    }

    function test_Init_MaintenanceReserve_FrontRunningProtected() public {
        MaintenanceReserve impl = new MaintenanceReserve();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(makeAddr("u"), address(this));
    }

    function test_Init_MaintenanceReserve_NonAdminCannotGrantRoles() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        bytes32 role = m.SPENDER_ROLE();
        address atk = makeAddr("atk");
        vm.prank(atk);
        vm.expectRevert();
        m.grantRole(role, atk);
    }

    // ─────────────────────────────────────────────────────────────
    // TreasuryVesting
    // ─────────────────────────────────────────────────────────────

    function test_Init_TreasuryVesting_CannotBeCalledTwice() public {
        TreasuryVesting t = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        vm.expectRevert();
        t.initialize(makeAddr("l"));
    }

    function test_Init_TreasuryVesting_ImplementationLocked() public {
        TreasuryVesting impl = new TreasuryVesting();
        vm.expectRevert();
        impl.initialize(makeAddr("l"));
    }

    function test_Init_TreasuryVesting_OnlyOwnerCanUpgrade() public {
        TreasuryVesting t = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        address newImpl = address(new TreasuryVesting());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        t.upgradeToAndCall(newImpl, "");
        t.upgradeToAndCall(newImpl, "");
    }

    function test_Init_TreasuryVesting_OwnerSetCorrectly() public {
        TreasuryVesting t = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        assertEq(t.owner(), address(this));
    }

    function test_Init_TreasuryVesting_RevertsOnZeroAddressParams() public {
        TreasuryVesting impl = new TreasuryVesting();
        bytes memory data = abi.encodeWithSelector(TreasuryVesting.initialize.selector, address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_TreasuryVesting_ParentInitializersCalled() public {
        TreasuryVesting t = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        assertEq(t.owner(), address(this));
    }

    function test_Init_TreasuryVesting_InitialStateCorrect() public {
        TreasuryVesting t = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        assertEq(address(t.luminaToken()), makeAddr("l"));
        assertEq(t.deployedAt(), block.timestamp);
        assertEq(t.totalReleased(), 0);
        assertEq(t.lastReleaseMonth(), 0);
    }

    function test_Init_TreasuryVesting_FrontRunningProtected() public {
        TreasuryVesting impl = new TreasuryVesting();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(makeAddr("l"));
    }
}
