// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../../src/products/FlashETHShield48h.sol";
import {RateShockShield} from "../../../../src/products/RateShockShield.sol";

/**
 * @title InitializerSecurityShields
 * @notice Initializer security audit for the 7 concrete Shield products.
 *
 * Shields inherit BaseShield and delegate to `__BaseShield_init(router_, oracle_)`,
 * which enforces the two zero-address checks and calls the Ownable/UUPS init
 * helpers. RateShockShield adds two further direct zero-address checks.
 *
 * 8 test types are exercised per shield:
 *   (1) CannotBeCalledTwice
 *   (2) ImplementationLocked (via _disableInitializers)
 *   (3) OnlyOwnerCanUpgrade
 *   (4) OwnerSetCorrectly (msg.sender deploying the proxy)
 *   (5) RevertsOnZeroAddress (router_ = 0)
 *   (6) ParentInitializersCalled (owner() returns a value; BaseShield state set)
 *   (7) InitialStateCorrect (router & oracle storage set)
 *   (8) FrontRunningProtected (direct impl.initialize reverts under attacker prank)
 */
contract InitializerSecurityShields is Test {
    address internal constant ROUTER = address(0xC1);
    address internal constant ORACLE = address(0xC2);
    address internal constant AAVE = address(0xC3);
    address internal constant USDC = address(0xC4);

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield1h
    // ─────────────────────────────────────────────────────────────
    function test_Init_FlashBTCShield1h_CannotBeCalledTwice() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(ROUTER, ORACLE);
        vm.expectRevert();
        s.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashBTCShield1h_ImplementationLocked() public {
        FlashBTCShield1h impl = new FlashBTCShield1h();
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashBTCShield1h_OnlyOwnerCanUpgrade() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(ROUTER, ORACLE);
        address newImpl = address(new FlashBTCShield1h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Init_FlashBTCShield1h_OwnerSetCorrectly() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashBTCShield1h_RevertsOnZeroAddressParams() public {
        FlashBTCShield1h impl = new FlashBTCShield1h();
        bytes memory data = abi.encodeWithSelector(FlashBTCShield1h.initialize.selector, address(0), ORACLE);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_FlashBTCShield1h_ParentInitializersCalled() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
        assertEq(s.router(), ROUTER);
    }

    function test_Init_FlashBTCShield1h_InitialStateCorrect() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(ROUTER, ORACLE);
        assertEq(s.router(), ROUTER);
        assertEq(s.oracle(), ORACLE);
        assertEq(s.totalPolicies(), 0);
        assertEq(s.activePolicies(), 0);
    }

    function test_Init_FlashBTCShield1h_FrontRunningProtected() public {
        FlashBTCShield1h impl = new FlashBTCShield1h();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield24h
    // ─────────────────────────────────────────────────────────────
    function test_Init_FlashBTCShield24h_CannotBeCalledTwice() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(ROUTER, ORACLE);
        vm.expectRevert();
        s.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashBTCShield24h_ImplementationLocked() public {
        FlashBTCShield24h impl = new FlashBTCShield24h();
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashBTCShield24h_OnlyOwnerCanUpgrade() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(ROUTER, ORACLE);
        address newImpl = address(new FlashBTCShield24h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Init_FlashBTCShield24h_OwnerSetCorrectly() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashBTCShield24h_RevertsOnZeroAddressParams() public {
        FlashBTCShield24h impl = new FlashBTCShield24h();
        bytes memory data = abi.encodeWithSelector(FlashBTCShield24h.initialize.selector, address(0), ORACLE);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_FlashBTCShield24h_ParentInitializersCalled() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashBTCShield24h_InitialStateCorrect() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(ROUTER, ORACLE);
        assertEq(s.router(), ROUTER);
        assertEq(s.oracle(), ORACLE);
    }

    function test_Init_FlashBTCShield24h_FrontRunningProtected() public {
        FlashBTCShield24h impl = new FlashBTCShield24h();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield48h
    // ─────────────────────────────────────────────────────────────
    function test_Init_FlashBTCShield48h_CannotBeCalledTwice() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(ROUTER, ORACLE);
        vm.expectRevert();
        s.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashBTCShield48h_ImplementationLocked() public {
        FlashBTCShield48h impl = new FlashBTCShield48h();
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashBTCShield48h_OnlyOwnerCanUpgrade() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(ROUTER, ORACLE);
        address newImpl = address(new FlashBTCShield48h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Init_FlashBTCShield48h_OwnerSetCorrectly() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashBTCShield48h_RevertsOnZeroAddressParams() public {
        FlashBTCShield48h impl = new FlashBTCShield48h();
        bytes memory data = abi.encodeWithSelector(FlashBTCShield48h.initialize.selector, address(0), ORACLE);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_FlashBTCShield48h_ParentInitializersCalled() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashBTCShield48h_InitialStateCorrect() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(ROUTER, ORACLE);
        assertEq(s.router(), ROUTER);
        assertEq(s.oracle(), ORACLE);
    }

    function test_Init_FlashBTCShield48h_FrontRunningProtected() public {
        FlashBTCShield48h impl = new FlashBTCShield48h();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield1h
    // ─────────────────────────────────────────────────────────────
    function test_Init_FlashETHShield1h_CannotBeCalledTwice() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(ROUTER, ORACLE);
        vm.expectRevert();
        s.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashETHShield1h_ImplementationLocked() public {
        FlashETHShield1h impl = new FlashETHShield1h();
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashETHShield1h_OnlyOwnerCanUpgrade() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(ROUTER, ORACLE);
        address newImpl = address(new FlashETHShield1h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Init_FlashETHShield1h_OwnerSetCorrectly() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashETHShield1h_RevertsOnZeroAddressParams() public {
        FlashETHShield1h impl = new FlashETHShield1h();
        bytes memory data = abi.encodeWithSelector(FlashETHShield1h.initialize.selector, address(0), ORACLE);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_FlashETHShield1h_ParentInitializersCalled() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashETHShield1h_InitialStateCorrect() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(ROUTER, ORACLE);
        assertEq(s.router(), ROUTER);
        assertEq(s.oracle(), ORACLE);
    }

    function test_Init_FlashETHShield1h_FrontRunningProtected() public {
        FlashETHShield1h impl = new FlashETHShield1h();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield24h
    // ─────────────────────────────────────────────────────────────
    function test_Init_FlashETHShield24h_CannotBeCalledTwice() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(ROUTER, ORACLE);
        vm.expectRevert();
        s.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashETHShield24h_ImplementationLocked() public {
        FlashETHShield24h impl = new FlashETHShield24h();
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashETHShield24h_OnlyOwnerCanUpgrade() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(ROUTER, ORACLE);
        address newImpl = address(new FlashETHShield24h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Init_FlashETHShield24h_OwnerSetCorrectly() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashETHShield24h_RevertsOnZeroAddressParams() public {
        FlashETHShield24h impl = new FlashETHShield24h();
        bytes memory data = abi.encodeWithSelector(FlashETHShield24h.initialize.selector, address(0), ORACLE);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_FlashETHShield24h_ParentInitializersCalled() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashETHShield24h_InitialStateCorrect() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(ROUTER, ORACLE);
        assertEq(s.router(), ROUTER);
        assertEq(s.oracle(), ORACLE);
    }

    function test_Init_FlashETHShield24h_FrontRunningProtected() public {
        FlashETHShield24h impl = new FlashETHShield24h();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield48h
    // ─────────────────────────────────────────────────────────────
    function test_Init_FlashETHShield48h_CannotBeCalledTwice() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(ROUTER, ORACLE);
        vm.expectRevert();
        s.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashETHShield48h_ImplementationLocked() public {
        FlashETHShield48h impl = new FlashETHShield48h();
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    function test_Init_FlashETHShield48h_OnlyOwnerCanUpgrade() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(ROUTER, ORACLE);
        address newImpl = address(new FlashETHShield48h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Init_FlashETHShield48h_OwnerSetCorrectly() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashETHShield48h_RevertsOnZeroAddressParams() public {
        FlashETHShield48h impl = new FlashETHShield48h();
        bytes memory data = abi.encodeWithSelector(FlashETHShield48h.initialize.selector, address(0), ORACLE);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_FlashETHShield48h_ParentInitializersCalled() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(ROUTER, ORACLE);
        assertEq(s.owner(), address(this));
    }

    function test_Init_FlashETHShield48h_InitialStateCorrect() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(ROUTER, ORACLE);
        assertEq(s.router(), ROUTER);
        assertEq(s.oracle(), ORACLE);
    }

    function test_Init_FlashETHShield48h_FrontRunningProtected() public {
        FlashETHShield48h impl = new FlashETHShield48h();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE);
    }

    // ─────────────────────────────────────────────────────────────
    // RateShockShield (4 addr params — 2 extra zero-addr checks)
    // ─────────────────────────────────────────────────────────────
    function test_Init_RateShockShield_CannotBeCalledTwice() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(ROUTER, ORACLE, AAVE, USDC);
        vm.expectRevert();
        s.initialize(ROUTER, ORACLE, AAVE, USDC);
    }

    function test_Init_RateShockShield_ImplementationLocked() public {
        RateShockShield impl = new RateShockShield();
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE, AAVE, USDC);
    }

    function test_Init_RateShockShield_OnlyOwnerCanUpgrade() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(ROUTER, ORACLE, AAVE, USDC);
        address newImpl = address(new RateShockShield());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Init_RateShockShield_OwnerSetCorrectly() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(ROUTER, ORACLE, AAVE, USDC);
        assertEq(s.owner(), address(this));
    }

    function test_Init_RateShockShield_RevertsOnZeroAddressParams() public {
        RateShockShield impl = new RateShockShield();
        bytes memory data = abi.encodeWithSelector(RateShockShield.initialize.selector, address(0), ORACLE, AAVE, USDC);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_RateShockShield_RevertsOnZeroAavePool() public {
        RateShockShield impl = new RateShockShield();
        bytes memory data =
            abi.encodeWithSelector(RateShockShield.initialize.selector, ROUTER, ORACLE, address(0), USDC);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_RateShockShield_RevertsOnZeroUSDC() public {
        RateShockShield impl = new RateShockShield();
        bytes memory data =
            abi.encodeWithSelector(RateShockShield.initialize.selector, ROUTER, ORACLE, AAVE, address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_RateShockShield_ParentInitializersCalled() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(ROUTER, ORACLE, AAVE, USDC);
        assertEq(s.owner(), address(this));
    }

    function test_Init_RateShockShield_InitialStateCorrect() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(ROUTER, ORACLE, AAVE, USDC);
        assertEq(s.router(), ROUTER);
        assertEq(s.oracle(), ORACLE);
        assertEq(address(s.aavePool()), AAVE);
        assertEq(s.usdc(), USDC);
    }

    function test_Init_RateShockShield_FrontRunningProtected() public {
        RateShockShield impl = new RateShockShield();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        impl.initialize(ROUTER, ORACLE, AAVE, USDC);
    }
}
