// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PolicyManager} from "../src/core/PolicyManager.sol";
import {IPolicyManager} from "../src/interfaces/IPolicyManager.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

/**
 * @title CorrelationGroupsTest
 * @notice Tests for the BSS+IL correlation group cap (70%).
 *         Verifies: individual cap, combined cap, release, uncorrelated independence.
 */
contract CorrelationGroupsTest is Test {
    PolicyManager pm;
    VolatileShortVault volatileShort;
    VolatileLongVault volatileLong;
    StableShortVault stableShort;

    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;

    address owner = address(0xA);
    address router = address(0xD);

    bytes32 constant BSS_ID = keccak256("BLACKSWAN-001");
    bytes32 constant DEPEG_ID = keccak256("DEPEG-STABLE-001");
    bytes32 constant IL_ID = keccak256("ILPROT-001");
    bytes32 constant EXPLOIT_ID = keccak256("EXPLOIT-001");
    bytes32 constant VOLATILE = keccak256("VOLATILE");
    bytes32 constant STABLE = keccak256("STABLE");
    bytes32 constant GROUP_ETH_CRASH = keccak256("GROUP_ETH_CRASH");

    function setUp() public {
        // Deploy mocks
        usdc = new MockERC20("USDC", "USDC", 6);
        aToken = new MockERC20("aUSDC", "aUSDC", 6);
        aavePool = new MockAavePool(address(aToken));
        usdc.mint(address(aavePool), 100_000_000e6);

        // Deploy PolicyManager (UUPS)
        PolicyManager pmImpl = new PolicyManager();
        bytes memory pmData = abi.encodeCall(PolicyManager.initialize, (owner, router));
        ERC1967Proxy pmProxy = new ERC1967Proxy(address(pmImpl), pmData);
        pm = PolicyManager(address(pmProxy));

        // Deploy VolatileShort vault (UUPS)
        VolatileShortVault vsImpl = new VolatileShortVault();
        bytes memory vsData = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, address(usdc), router, address(pm), address(aavePool), address(aToken))
        );
        ERC1967Proxy vsProxy = new ERC1967Proxy(address(vsImpl), vsData);
        volatileShort = VolatileShortVault(address(vsProxy));

        // Deploy VolatileLong vault (UUPS)
        VolatileLongVault vlImpl = new VolatileLongVault();
        bytes memory vlData = abi.encodeCall(
            VolatileLongVault.initialize,
            (owner, address(usdc), router, address(pm), address(aavePool), address(aToken))
        );
        ERC1967Proxy vlProxy = new ERC1967Proxy(address(vlImpl), vlData);
        volatileLong = VolatileLongVault(address(vlProxy));

        // Deploy StableShort vault (UUPS)
        StableShortVault ssImpl = new StableShortVault();
        bytes memory ssData = abi.encodeCall(
            StableShortVault.initialize,
            (owner, address(usdc), router, address(pm), address(aavePool), address(aToken))
        );
        ERC1967Proxy ssProxy = new ERC1967Proxy(address(ssImpl), ssData);
        stableShort = StableShortVault(address(ssProxy));

        // Register products (as router, since registerProduct allows owner OR router)
        vm.startPrank(owner);
        pm.registerProduct(BSS_ID, address(0x1), VOLATILE, 7000);   // 70% individual cap
        pm.registerProduct(IL_ID, address(0x2), VOLATILE, 7000);    // 70% individual cap
        pm.registerProduct(DEPEG_ID, address(0x3), STABLE, 5000);   // 50% individual cap
        pm.registerProduct(EXPLOIT_ID, address(0x4), STABLE, 5000); // 50% individual cap

        // Register vaults
        pm.registerVault(address(volatileShort), VOLATILE, 37 days, 1);
        pm.registerVault(address(volatileLong), VOLATILE, 97 days, 2);
        pm.registerVault(address(stableShort), STABLE, 97 days, 1);

        // Create correlation group: BSS + IL capped at 70% combined
        pm.createCorrelationGroup(GROUP_ETH_CRASH, 7000);
        pm.addProductToGroup(BSS_ID, GROUP_ETH_CRASH);
        pm.addProductToGroup(IL_ID, GROUP_ETH_CRASH);
        vm.stopPrank();

        // Deposit $100K into VolatileShort
        _depositToVault(address(volatileShort), 100_000e6);
        // Deposit $100K into StableShort
        _depositToVault(address(stableShort), 100_000e6);
    }

    function _depositToVault(address vault, uint256 amount) internal {
        address depositor = address(0xBEEF);
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(vault, amount);
        VolatileShortVault(vault).depositAssets(amount, depositor);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 1: BSS can use up to 70% individually
    // ═══════════════════════════════════════════════════════════

    function test_BSSCanUse70Percent() public {
        // BSS $70K should work (70% of $100K vault)
        vm.prank(router);
        address vault = pm.recordAllocation(BSS_ID, 1, 70_000e6, 14 days);
        assertEq(vault, address(volatileShort));

        // BSS $1 more should revert (exceeds 70% group cap)
        vm.prank(router);
        vm.expectRevert();
        pm.recordAllocation(BSS_ID, 2, 1e6, 14 days);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 2: IL can use up to 70% individually
    // ═══════════════════════════════════════════════════════════

    function test_ILCanUse70Percent() public {
        vm.prank(router);
        address vault = pm.recordAllocation(IL_ID, 1, 70_000e6, 14 days);
        assertEq(vault, address(volatileShort));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 3: BSS + IL combined cannot exceed 70%
    // ═══════════════════════════════════════════════════════════

    function test_CombinedCapBSSPlusIL() public {
        // BSS $40K → ok
        vm.prank(router);
        pm.recordAllocation(BSS_ID, 1, 40_000e6, 14 days);

        // IL $30K → ok (combined = 70K = 70%)
        vm.prank(router);
        pm.recordAllocation(IL_ID, 2, 30_000e6, 14 days);

        // IL $1K more → REVERT (combined would be 71K = 71%)
        vm.prank(router);
        vm.expectRevert();
        pm.recordAllocation(IL_ID, 3, 1_000e6, 14 days);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 4: Releasing capital frees correlation group space
    // ═══════════════════════════════════════════════════════════

    function test_ReleaseUpdatesCorrelationGroup() public {
        // BSS $70K → ok
        vm.prank(router);
        address vault = pm.recordAllocation(BSS_ID, 1, 70_000e6, 14 days);

        // Release the BSS allocation (policy expired)
        vm.prank(router);
        pm.releaseAllocation(BSS_ID, 1, 70_000e6, vault);

        // Now IL $70K should work (group freed)
        vm.prank(router);
        address vault2 = pm.recordAllocation(IL_ID, 2, 70_000e6, 14 days);
        assertEq(vault2, address(volatileShort));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 5: Uncorrelated products are independent
    // ═══════════════════════════════════════════════════════════

    function test_UncorrelatedProductsIndependent() public {
        // Depeg $50K → ok (no correlation group)
        vm.prank(router);
        pm.recordAllocation(DEPEG_ID, 1, 50_000e6, 14 days);

        // Exploit $40K → ok (no correlation group, independent)
        vm.prank(router);
        pm.recordAllocation(EXPLOIT_ID, 2, 40_000e6, 14 days);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 6: canAllocate reflects correlation group cap
    // ═══════════════════════════════════════════════════════════

    function test_CanAllocateRespectsGroupCap() public {
        // BSS $40K allocated
        vm.prank(router);
        pm.recordAllocation(BSS_ID, 1, 40_000e6, 14 days);

        // canAllocate IL $30K → should be allowed (combined = 70%)
        (bool allowed1,,) = pm.canAllocate(IL_ID, 30_000e6, 14 days);
        assertTrue(allowed1);

        // canAllocate IL $31K → should be denied (combined = 71%)
        (bool allowed2,, bytes32 reason) = pm.canAllocate(IL_ID, 31_000e6, 14 days);
        assertFalse(allowed2);
        assertEq(reason, "GROUP_CAP_EXCEEDED");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 7: Group cap view function returns correct data
    // ═══════════════════════════════════════════════════════════

    function test_CorrelationGroupState() public {
        // Check group setup
        IPolicyManager.CorrelationGroup memory group = pm.getCorrelationGroup(GROUP_ETH_CRASH);
        assertEq(group.maxAllocationBps, 7000);
        assertEq(group.currentAllocated, 0);
        assertEq(group.productIds.length, 2);

        // Allocate BSS $30K
        vm.prank(router);
        pm.recordAllocation(BSS_ID, 1, 30_000e6, 14 days);

        // Check group updated
        group = pm.getCorrelationGroup(GROUP_ETH_CRASH);
        assertEq(group.currentAllocated, 30_000e6);
    }
}
