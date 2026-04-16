// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PolicyManager} from "../src/core/PolicyManager.sol";
import {IPolicyManager} from "../src/interfaces/IPolicyManager.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

contract ProductFreezeTest is Test {
    PolicyManager pm;
    VolatileShortVault volatileShort;

    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;

    address owner = address(0xA);
    address router = address(0xD);

    bytes32 constant BSS_ID = keccak256("BLACKSWAN-001");
    bytes32 constant IL_ID = keccak256("ILPROT-001");
    bytes32 constant VOLATILE = keccak256("VOLATILE");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        aToken = new MockERC20("aUSDC", "aUSDC", 6);
        aavePool = new MockAavePool(address(aToken));
        usdc.mint(address(aavePool), 100_000_000e6);

        PolicyManager pmImpl = new PolicyManager();
        bytes memory pmData = abi.encodeCall(PolicyManager.initialize, (owner, router));
        ERC1967Proxy pmProxy = new ERC1967Proxy(address(pmImpl), pmData);
        pm = PolicyManager(address(pmProxy));

        VolatileShortVault vsImpl = new VolatileShortVault();
        bytes memory vsData = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, address(usdc), router, address(pm), address(aavePool), address(aToken))
        );
        ERC1967Proxy vsProxy = new ERC1967Proxy(address(vsImpl), vsData);
        volatileShort = VolatileShortVault(address(vsProxy));

        vm.startPrank(owner);
        pm.registerProduct(BSS_ID, address(0x1), VOLATILE, 7000);
        pm.registerProduct(IL_ID, address(0x2), VOLATILE, 7000);
        pm.registerVault(address(volatileShort), VOLATILE, 37 days, 1);
        vm.stopPrank();

        // Deposit $100K
        address depositor = address(0xBEEF);
        usdc.mint(depositor, 100_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(volatileShort), 100_000e6);
        volatileShort.depositAssets(100_000e6, depositor);
        vm.stopPrank();
    }

    function test_FreezeBlocksNewAllocations() public {
        // Freeze BSS
        vm.prank(owner);
        pm.freezeProduct(BSS_ID);

        // Attempt to allocate BSS — should revert
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(PolicyManager.ProductFrozen.selector, BSS_ID));
        pm.recordAllocation(BSS_ID, 1, 10_000e6, 14 days);
    }

    function test_FreezeDoesNotAffectOtherProducts() public {
        // Freeze BSS
        vm.prank(owner);
        pm.freezeProduct(BSS_ID);

        // IL should still work
        vm.prank(router);
        address vault = pm.recordAllocation(IL_ID, 1, 10_000e6, 14 days);
        assertEq(vault, address(volatileShort));
    }

    function test_UnfreezeAllowsAllocations() public {
        // Freeze then unfreeze BSS
        vm.startPrank(owner);
        pm.freezeProduct(BSS_ID);
        pm.unfreezeProduct(BSS_ID);
        vm.stopPrank();

        // BSS should work again
        vm.prank(router);
        address vault = pm.recordAllocation(BSS_ID, 1, 10_000e6, 14 days);
        assertEq(vault, address(volatileShort));
    }

    function test_CanAllocateReturnsFrozenReason() public {
        vm.prank(owner);
        pm.freezeProduct(BSS_ID);

        (bool allowed,, bytes32 reason) = pm.canAllocate(BSS_ID, 10_000e6, 14 days);
        assertFalse(allowed);
        assertEq(reason, "PRODUCT_FROZEN");
    }

    function test_OnlyAdminCanFreeze() public {
        vm.prank(address(0x999));
        vm.expectRevert();
        pm.freezeProduct(BSS_ID);
    }

    event ProductFreezeChanged(bytes32 indexed productId, bool frozen);

    function test_FreezeEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ProductFreezeChanged(BSS_ID, true);
        pm.freezeProduct(BSS_ID);
    }

    function test_DefaultNotFrozen() public {
        assertFalse(pm.productFrozen(BSS_ID));
        assertFalse(pm.productFrozen(IL_ID));
    }
}
