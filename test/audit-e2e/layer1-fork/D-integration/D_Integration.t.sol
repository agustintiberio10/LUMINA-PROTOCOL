// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ForkSetup} from "../../helpers/ForkSetup.sol";
import {TimeHelpers} from "../../helpers/TimeHelpers.sol";
import {ReportLogger} from "../../helpers/ReportLogger.sol";
import {
    IPolicyManagerV51,
    ICoverRouterV51,
    IShieldV51,
    IUSDCMockV51,
    IGlobalPauseRegistryV51
} from "../../helpers/IV51.sol";

/// @title D_Integration
/// @notice Layer-1 (fork) integration coverage for the V5.1 Sepolia deploy.
///         These eight tests exercise on-chain behaviour that the layer-2
///         HTTP suite cannot reach (cross-layer concerns are stubbed with
///         logInfo placeholders and verified end-to-end by the off-chain
///         harness in test/audit-e2e/layer2-sepolia/).
contract D_Integration is ForkSetup, TimeHelpers, ReportLogger {
    // Canonical product id used across the audit suite.
    bytes32 constant BTC_24H_PRODUCT_ID = keccak256("FLASHBTC24-001");

    IPolicyManagerV51 internal policyManager;
    ICoverRouterV51 internal coverRouter;
    IUSDCMockV51 internal usdc;

    // Coverage amount that comfortably fits inside the BTC-24h cap (10k USDC).
    uint256 internal constant COVERAGE_USDC = 10_000 * 1e6;
    uint256 internal constant ALICE_BUDGET_USDC = 1_000_000 * 1e6;

    function setUp() public virtual {
        policyManager = IPolicyManagerV51(POLICY_MANAGER);
        coverRouter = ICoverRouterV51(COVER_ROUTER);
        usdc = IUSDCMockV51(USDC);

        setupActor(alice, 10 ether, ALICE_BUDGET_USDC);
        setupActor(bob, 10 ether, ALICE_BUDGET_USDC);
        setupActor(carol, 1 ether, 0);
    }

    // ?????????????????????????????????????????????????????????????????????
    //  TEST 1 - API ? smart-contract data consistency (layer-1 placeholder)
    // ?????????????????????????????????????????????????????????????????????
    function testApiSmartContractDataConsistency() public {
        // On-chain state we *would* compare against the indexer/API in L2.
        bool active = policyManager.productActive(BTC_24H_PRODUCT_ID);
        address shield = policyManager.productShield(BTC_24H_PRODUCT_ID);

        assertTrue(active, "BTC-24h product must be active on the pinned deploy");
        assertEq(shield, SHIELD_FLASH_BTC_24H, "PolicyManager.productShield drift");

        logInfo("api-consistency", "Layer-1 read-back of productActive + productShield succeeded");
        logInfo("api-consistency", "See layer-2 HTTP suite for actual API<->chain comparison");
        logInfo("api-consistency", "Cross-layer contract: indexer must surface productActive=true and shield=SHIELD_FLASH_BTC_24H");
    }

    // ?????????????????????????????????????????????????????????????????????
    //  TEST 2 - DB ? blockchain idempotency (layer-1 placeholder)
    // ?????????????????????????????????????????????????????????????????????
    function testDBBlockchainIdempotency() public {
        // The on-chain side is trivially idempotent: re-reading the same slot
        // returns the same value. The actual DB-vs-chain reconciliation lives
        // in layer-2.
        bool a = policyManager.productActive(BTC_24H_PRODUCT_ID);
        bool b = policyManager.productActive(BTC_24H_PRODUCT_ID);
        assertEq(a, b, "View calls must be idempotent at the contract level");

        logInfo("db-idempotency", "Layer-1 view-call idempotency verified (productActive read twice)");
        logInfo("db-idempotency", "Layer-2 territory: DB write replay safety, indexer cursor recovery");
        logInfo("db-idempotency", "See layer2-sepolia/idempotency.spec for actual DB<->chain reconciliation");
    }

    // ?????????????????????????????????????????????????????????????????????
    //  TEST 3 - Cache invalidation (on-chain proxy: deactivate/reactivate)
    // ?????????????????????????????????????????????????????????????????????
    function testCacheInvalidation() public {
        // Sanity: starts active.
        assertTrue(policyManager.productActive(BTC_24H_PRODUCT_ID), "must start active");

        vm.prank(DEPLOYER);
        policyManager.deactivateProduct(BTC_24H_PRODUCT_ID);
        assertFalse(
            policyManager.productActive(BTC_24H_PRODUCT_ID),
            "productActive must flip false immediately (no on-chain cache lag)"
        );

        vm.prank(DEPLOYER);
        policyManager.reactivateProduct(BTC_24H_PRODUCT_ID);
        assertTrue(
            policyManager.productActive(BTC_24H_PRODUCT_ID),
            "productActive must flip true immediately on reactivate"
        );

        logInfo("cache-invalidation", "On-chain state has zero read-after-write delay (storage-backed)");
        logInfo("cache-invalidation", "Off-chain caches MUST listen to ProductDeactivated/ProductReactivated events");
        logInfo("cache-invalidation", "FIX M-1 (reactivateProduct) verified end-to-end on the pinned deploy");
    }

    // ?????????????????????????????????????????????????????????????????????
    //  TEST 4 - Error propagation across the router stack
    // ?????????????????????????????????????????????????????????????????????
    function testErrorPropagation() public {
        // Class A: zero coverage must revert. The exact selector is
        // implementation-defined (InvalidCoverage / ZeroAmount / etc.) so we
        // assert *any* revert and document the class.
        vm.startPrank(alice);
        usdc.approve(COVER_ROUTER, ALICE_BUDGET_USDC);

        vm.expectRevert();
        coverRouter.purchasePolicyFor(BTC_24H_PRODUCT_ID, 0, bytes32("BTC"), alice);
        logInfo("error-propagation", "Class-A (zero coverage) reverts at CoverRouter as expected");

        // Class B: unknown product id must revert from PolicyManager
        // (ProductNotFound / NotRegistered).
        bytes32 ghostProduct = keccak256("DOES-NOT-EXIST-001");
        vm.expectRevert();
        coverRouter.purchasePolicyFor(ghostProduct, COVERAGE_USDC, bytes32("BTC"), alice);
        logInfo("error-propagation", "Class-B (unknown productId) reverts up the call stack to the caller");

        // Class C: paused router must revert. We exercise this via setPaused
        // to confirm the propagation path is wired.
        vm.stopPrank();

        vm.prank(DEPLOYER);
        coverRouter.setPaused(true);
        assertTrue(coverRouter.paused(), "router should report paused");

        vm.startPrank(alice);
        vm.expectRevert();
        coverRouter.purchasePolicyFor(BTC_24H_PRODUCT_ID, COVERAGE_USDC, bytes32("BTC"), alice);
        vm.stopPrank();

        vm.prank(DEPLOYER);
        coverRouter.setPaused(false);
        logInfo("error-propagation", "Class-C (router paused) reverts and unwinds via Pausable");
    }

    // ?????????????????????????????????????????????????????????????????????
    //  TEST 5 - Retry logic (no built-in: clients must retry)
    // ?????????????????????????????????????????????????????????????????????
    function testRetryLogic() public {
        // Pause -> attempt -> revert -> unpause -> retry -> succeeds.
        vm.prank(DEPLOYER);
        coverRouter.setPaused(true);

        vm.startPrank(alice);
        usdc.approve(COVER_ROUTER, ALICE_BUDGET_USDC);
        vm.expectRevert();
        coverRouter.purchasePolicyFor(BTC_24H_PRODUCT_ID, COVERAGE_USDC, bytes32("BTC"), alice);
        vm.stopPrank();

        vm.prank(DEPLOYER);
        coverRouter.setPaused(false);

        vm.prank(alice);
        uint256 policyId = coverRouter.purchasePolicyFor(
            BTC_24H_PRODUCT_ID, COVERAGE_USDC, bytes32("BTC"), alice
        );
        assertGt(policyId, 0, "retry after unpause must succeed");

        logInfo("retry-logic", "V5.1 has NO built-in retry/queue: paused calls revert, no auto-replay");
        logInfo("retry-logic", "Clients (relayers, frontend) MUST implement exponential backoff + retry");
        logInfo("retry-logic", "Verified: same call after unpause succeeds with the original calldata");
    }

    // ?????????????????????????????????????????????????????????????????????
    //  TEST 6 - Concurrent requests (race-safe via _policyCounter++)
    // ?????????????????????????????????????????????????????????????????????
    function testConcurrentRequests() public {
        vm.prank(alice);
        usdc.approve(COVER_ROUTER, ALICE_BUDGET_USDC);
        vm.prank(bob);
        usdc.approve(COVER_ROUTER, ALICE_BUDGET_USDC);

        vm.prank(alice);
        uint256 policyAlice = coverRouter.purchasePolicyFor(
            BTC_24H_PRODUCT_ID, COVERAGE_USDC, bytes32("BTC"), alice
        );

        vm.prank(bob);
        uint256 policyBob = coverRouter.purchasePolicyFor(
            BTC_24H_PRODUCT_ID, COVERAGE_USDC, bytes32("BTC"), bob
        );

        assertGt(policyAlice, 0, "alice policy id must be non-zero");
        assertGt(policyBob, 0, "bob policy id must be non-zero");
        assertTrue(policyAlice != policyBob, "concurrent purchases must yield distinct policyIds");

        // And the buyers must be distinct on the storage record.
        (, , address aliceBuyer, , , , , , ,) =
            policyManager.policies(BTC_24H_PRODUCT_ID, policyAlice);
        (, , address bobBuyer, , , , , , ,) =
            policyManager.policies(BTC_24H_PRODUCT_ID, policyBob);
        assertEq(aliceBuyer, alice, "alice buyer slot");
        assertEq(bobBuyer, bob, "bob buyer slot");

        logInfo("concurrent-requests", "Two purchases in same block return distinct policyIds (counter++)");
        logInfo("concurrent-requests", "Race-safe by construction: PolicyManager._policyCounter is monotonic");
        logInfo("concurrent-requests", "L2 caveat: indexer must order by (blockNumber, logIndex), not timestamp");
    }

    // ?????????????????????????????????????????????????????????????????????
    //  TEST 7 - Long-running operations (read after extreme time skip)
    // ?????????????????????????????????????????????????????????????????????
    function testLongRunningOperations() public {
        vm.prank(alice);
        usdc.approve(COVER_ROUTER, ALICE_BUDGET_USDC);

        vm.prank(alice);
        uint256 policyId = coverRouter.purchasePolicyFor(
            BTC_24H_PRODUCT_ID, COVERAGE_USDC, bytes32("BTC"), alice
        );
        assertGt(policyId, 0, "policy id must be non-zero");

        // Advance ~720 days. The policy should remain readable; only its
        // status flips to expired.
        advance(720 days);

        (
            bytes32 productId_,
            address shield_,
            address buyer_,
            uint256 coverageAmount_,
            ,
            ,
            ,
            ,
            ,
        ) = policyManager.policies(BTC_24H_PRODUCT_ID, policyId);

        assertEq(productId_, BTC_24H_PRODUCT_ID, "productId stable after 720d");
        assertEq(buyer_, alice, "buyer stable after 720d");
        assertEq(coverageAmount_, COVERAGE_USDC, "coverage stable after 720d");
        assertTrue(shield_ != address(0), "shield pointer stable after 720d");

        logInfo("long-running", "Policy storage is durable across 720d; only computed status flips to EXPIRED");
        logInfo("long-running", "queryFilter() over multi-year ranges is an indexer concern (no on-chain pagination)");
        logInfo("long-running", "Fork tests don't carry indexer history; layer-2 suite asserts log retention SLA");
    }

    // ?????????????????????????????????????????????????????????????????????
    //  TEST 8 - Disconnection recovery (layer-2 placeholder)
    // ?????????????????????????????????????????????????????????????????????
    function testDisconnectionRecovery() public {
        // On-chain proxy for "RPC disconnected": call a contract at an
        // address with no code and confirm the staticcall reverts. This is
        // NOT a real RPC drop - that's a layer-2 concern - but it documents
        // the failure mode the harness expects.
        address badProvider = address(0xDEADBEEF);
        IPolicyManagerV51 ghostPm = IPolicyManagerV51(badProvider);

        vm.expectRevert();
        ghostPm.productActive(BTC_24H_PRODUCT_ID);

        // And confirm the *real* deploy is still reachable in the same test.
        bool stillAlive = policyManager.productActive(BTC_24H_PRODUCT_ID);
        assertTrue(stillAlive, "real PolicyManager remains reachable after a bad-provider call");

        logInfo("disconnection-recovery", "On-chain stand-in: call to no-code address reverts as a staticcall");
        logInfo("disconnection-recovery", "Real RPC-disconnect handling is a layer-2 / client concern (websocket reconnect, request replay)");
        logInfo("disconnection-recovery", "See layer2-sepolia/disconnection.spec for actual websocket fail-over coverage");
    }
}
