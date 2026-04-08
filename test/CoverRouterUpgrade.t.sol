// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CoverRouter} from "../src/core/CoverRouter.sol";
import {PolicyManager} from "../src/core/PolicyManager.sol";
import {IShield} from "../src/interfaces/IShield.sol";
import {ICoverRouter} from "../src/interfaces/ICoverRouter.sol";

/// @notice Minimal IShield mock — only `productId()` is exercised by
///         `CoverRouter.updateProductShield`. Everything else reverts so
///         tests fail loudly if the dispatcher tries to call into the mock
///         beyond the productId check.
contract MockShield {
    bytes32 public PRODUCT_ID_VAL;

    constructor(bytes32 id) {
        PRODUCT_ID_VAL = id;
    }

    function productId() external view returns (bytes32) {
        return PRODUCT_ID_VAL;
    }

    fallback() external {
        revert("MockShield: not implemented");
    }
}

contract CoverRouterUpgradeTest is Test {
    CoverRouter router;
    PolicyManager pm;

    address owner       = address(0xA11CE);
    address attacker    = address(0xBADBAD);
    address oracle      = address(0x1001);
    address phala       = address(0x1002);
    address usdc        = address(0x1003);
    address feeReceiver = address(0x1004);

    bytes32 constant DEPEG_ID  = keccak256("DEPEG-STABLE-001");
    bytes32 constant OTHER_ID  = keccak256("OTHER-PRODUCT-001");
    bytes32 constant STABLE    = keccak256("STABLE");

    MockShield depegV1;
    MockShield depegV2;
    MockShield wrongIdShield; // productId == OTHER_ID, used to test mismatch

    event ProductShieldUpdated(bytes32 indexed productId, address indexed oldShield, address indexed newShield);

    function setUp() public {
        // Deploy PolicyManager behind proxy
        PolicyManager pmImpl = new PolicyManager();
        // Initial router_ field is a placeholder; we patch it after CoverRouter
        // exists by re-deploying with the real address. Two-step bootstrap so
        // the cross-references match production.
        bytes memory pmInit = abi.encodeCall(PolicyManager.initialize, (owner, address(0xCAFE)));
        ERC1967Proxy pmProxy = new ERC1967Proxy(address(pmImpl), pmInit);
        pm = PolicyManager(address(pmProxy));

        // Deploy CoverRouter behind proxy, owned by `owner`
        CoverRouter routerImpl = new CoverRouter();
        bytes memory routerInit = abi.encodeCall(
            CoverRouter.initialize,
            (owner, oracle, phala, address(pm), usdc, false, feeReceiver, 300)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerInit);
        router = CoverRouter(address(routerProxy));

        // Patch PolicyManager's router pointer to the real CoverRouter address
        // so that CoverRouter.registerProduct/updateProductShield can call
        // PolicyManager from the authorised caller.
        vm.prank(owner);
        pm.setRouter(address(router));

        // Deploy the two shields the tests will swap between, plus a wrong-id
        // shield used to exercise the mismatch guard.
        depegV1       = new MockShield(DEPEG_ID);
        depegV2       = new MockShield(DEPEG_ID);
        wrongIdShield = new MockShield(OTHER_ID);

        // Register DEPEG-STABLE-001 → depegV1 via the normal flow
        vm.prank(owner);
        router.registerProduct(DEPEG_ID, address(depegV1), STABLE, 2000);
    }

    // ═══════════════════════════════════════════════════════════
    //  1. only owner
    // ═══════════════════════════════════════════════════════════

    function test_updateProductShield_onlyOwner_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount(attacker)
        router.updateProductShield(DEPEG_ID, address(depegV2));
    }

    // ═══════════════════════════════════════════════════════════
    //  2. zero address
    // ═══════════════════════════════════════════════════════════

    function test_updateProductShield_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CoverRouter.ZeroAddress.selector, "shield"));
        router.updateProductShield(DEPEG_ID, address(0));
    }

    // ═══════════════════════════════════════════════════════════
    //  3. product not registered
    // ═══════════════════════════════════════════════════════════

    function test_updateProductShield_productNotRegistered_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICoverRouter.ProductNotAvailable.selector, OTHER_ID));
        router.updateProductShield(OTHER_ID, address(depegV2));
    }

    // ═══════════════════════════════════════════════════════════
    //  4. productId mismatch on the new shield
    // ═══════════════════════════════════════════════════════════

    function test_updateProductShield_productIdMismatch_reverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CoverRouter.ProductIdMismatch.selector, DEPEG_ID, OTHER_ID)
        );
        router.updateProductShield(DEPEG_ID, address(wrongIdShield));
    }

    // ═══════════════════════════════════════════════════════════
    //  5. happy path: getProductShield returns new + event emitted
    // ═══════════════════════════════════════════════════════════

    function test_updateProductShield_success_updatesMappingAndEmitsEvent() public {
        // Sanity: starts pointing to depegV1
        assertEq(router.getProductShield(DEPEG_ID), address(depegV1));

        vm.expectEmit(true, true, true, false);
        emit ProductShieldUpdated(DEPEG_ID, address(depegV1), address(depegV2));

        vm.prank(owner);
        router.updateProductShield(DEPEG_ID, address(depegV2));

        assertEq(router.getProductShield(DEPEG_ID), address(depegV2));
    }

    // ═══════════════════════════════════════════════════════════
    //  6. propagation: PolicyManager sees the new shield too
    // ═══════════════════════════════════════════════════════════

    function test_updateProductShield_propagatesToPolicyManager() public {
        vm.prank(owner);
        router.updateProductShield(DEPEG_ID, address(depegV2));

        // PolicyManager exposes its product registration via canAllocate's
        // PRODUCT_NOT_FOUND path. We use the public _products getter via
        // the IPolicyManager-defined interface (no direct getter exists, so
        // we re-call canAllocate which internally reads _products[id].shield).
        // A simpler check is the events: ProductShieldUpdated must have
        // fired on PolicyManager too.
        vm.recordLogs();
        vm.prank(owner);
        router.updateProductShield(DEPEG_ID, address(depegV1));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find at least one ProductShieldUpdated event from PolicyManager
        // (topic[0] is keccak256 of the signature).
        bytes32 sig = keccak256("ProductShieldUpdated(bytes32,address,address)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == sig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "PolicyManager should have emitted ProductShieldUpdated");
    }
}
