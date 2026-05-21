// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/token/LuminaTokenV2.sol";
import "../../../src/bonds/ClaimBond.sol";
import "../../../src/bonds/BondVault.sol";
import "../../../src/core/PolicyManagerV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════ Minimal Mock Oracle ═══════
contract MockPriceOracleCR {
    uint256 public price = 0.036e18; // $0.036

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

// ═══════ Minimal Mock Shield (slim IShieldV2 — Sprint T-30b) ═══════
contract MockShieldCR {
    bytes32 public productId;
    bool public triggerResult = true;

    constructor(bytes32 _productId) {
        productId = _productId;
    }

    function setTriggerResult(bool _result) external {
        triggerResult = _result;
    }

    function createPolicy(uint256, address, uint256, uint64, uint64) external {}

    function verifyAndCalculate(uint256)
        external
        view
        returns (bool triggered, uint256 payout, address holder, bytes32 reason)
    {
        return (triggerResult, 0, address(0), "MOCK_TRIGGER");
    }

    function getPolicyInfo(uint256) external pure returns (address, uint256, uint256, uint64, uint64, bool) {
        return (address(0), 0, 0, 0, 0, false);
    }
}

// ═══════ Test Contract ═══════
contract CapacityReservationTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    PolicyManagerV2 pm;
    MockPriceOracleCR oracle;
    MockShieldCR shield;

    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-001");

    address deployer;
    address buyer1 = makeAddr("buyer1");
    address buyer2 = makeAddr("buyer2");
    address buyer3 = makeAddr("buyer3");

    function setUp() public {
        vm.chainId(8453);
        // Warp past ClaimBond.BASE_TIMESTAMP
        vm.warp(1767225600 + 30 days);

        deployer = address(this);
        oracle = new MockPriceOracleCR();
        claimBond = ProxyDeployer.deployClaimBond();
        token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("tempVault"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        // Deploy BondVault with address(0) policyManager (2-step init)
        vault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(0));

        // Deploy PolicyManager
        pm = ProxyDeployer.deployPolicyManagerV2(address(vault));

        // Wire up: BondVault -> PolicyManager
        vault.setPolicyManager(address(pm));

        // Wire up: ClaimBond -> BondVault
        claimBond.setBondVault(address(vault));

        // Fund vault with 70M LUMINA
        deal(address(token), address(vault), 70_000_000 * 1e18);

        // Set this test contract as router for PolicyManager
        pm.setRouter(address(this));

        // Register shield
        shield = new MockShieldCR(PRODUCT_ID);
        pm.registerProduct(PRODUCT_ID, address(shield));
    }

    // ═══════════════════════════════════════════════
    //  1. Basic reservation: recordPolicy reserves capacity
    // ═══════════════════════════════════════════════
    function test_recordPolicy_reserves_capacity() public {
        uint256 capBefore = vault.availableCapacityUSD();

        // Coverage = 1000 USDC (6-dec), payout = 80% = 800 USDC = $800
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");

        uint256 capAfter = vault.availableCapacityUSD();
        assertEq(vault.totalReservedUSD(), 800 * 1e18, "Should reserve 800 USD-wei");
        assertEq(capBefore - capAfter, 800, "Available capacity should decrease by 800 integer dollars");
    }

    // ═══════════════════════════════════════════════
    //  2. Reservation stored per-policy
    // ═══════════════════════════════════════════════
    function test_policyReservedUSD_stored() public {
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");
        uint256 reserved = pm.policyReservedUSD(PRODUCT_ID, 1);
        assertEq(reserved, 800 * 1e18, "Policy reservation should be stored");
    }

    // ═══════════════════════════════════════════════
    //  3. RACE CONDITION FIX: two concurrent purchases
    // ═══════════════════════════════════════════════
    function test_concurrent_purchases_capacity_race_prevented() public {
        // Set capacity to exactly $1000
        // Reserve value = 70M * $0.036 = $2.52M, 50% = $1.26M
        // We need to fill capacity to leave only ~$1000 available.
        // Current available: ~1,260,000 (integer dollars)
        uint256 available = vault.availableCapacityUSD();

        // Create a policy that nearly fills capacity, leaving room for $1000 but not $2000
        // We need: payoutUSD = available - 1000. Coverage = payoutUSD * 1e6 / 0.8
        uint256 targetPayout = available - 1000; // leave $1000
        uint256 coverage = (targetPayout * 1e6 * 10000) / 8000;

        pm.recordPolicy(PRODUCT_ID, buyer1, coverage, 1e6, 3600, "BTC");

        uint256 remaining = vault.availableCapacityUSD();
        assertLe(remaining, 1000, "Should have ~$1000 remaining");

        // First purchase for $800 should succeed
        pm.recordPolicy(PRODUCT_ID, buyer2, 1000e6, 1e6, 3600, "BTC");

        // Second purchase for $800 should FAIL (only ~$200 left)
        vm.expectRevert();
        pm.recordPolicy(PRODUCT_ID, buyer3, 1000e6, 1e6, 3600, "BTC");
    }

    // ═══════════════════════════════════════════════
    //  4. Trigger payout commits reservation
    // ═══════════════════════════════════════════════
    function test_triggerPayout_commits_reservation() public {
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");

        uint256 reservedBefore = vault.totalReservedUSD();
        uint256 committedBefore = vault.totalCommittedUSD();
        assertEq(reservedBefore, 800 * 1e18);
        assertEq(committedBefore, 0);

        // Trigger
        pm.triggerPayout(PRODUCT_ID, 1, "");

        uint256 reservedAfter = vault.totalReservedUSD();
        uint256 committedAfter = vault.totalCommittedUSD();
        assertEq(reservedAfter, 0, "Reservation should be cleared after trigger");
        assertEq(committedAfter, 800 * 1e18, "Committed should increase by payout amount");
    }

    // ═══════════════════════════════════════════════
    //  5. Mark expired releases reservation
    // ═══════════════════════════════════════════════
    function test_markExpired_releases_reservation() public {
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");

        uint256 reservedBefore = vault.totalReservedUSD();
        assertEq(reservedBefore, 800 * 1e18);

        // Warp past expiry
        vm.warp(block.timestamp + 3601);

        pm.markExpired(PRODUCT_ID, 1);

        uint256 reservedAfter = vault.totalReservedUSD();
        assertEq(reservedAfter, 0, "Reservation should be released on expiry");
    }

    // ═══════════════════════════════════════════════
    //  6. Expired policy frees capacity for new purchases
    // ═══════════════════════════════════════════════
    function test_expired_policy_frees_capacity() public {
        uint256 capBefore = vault.availableCapacityUSD();
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");
        uint256 capDuring = vault.availableCapacityUSD();

        // Expire the policy
        vm.warp(block.timestamp + 3601);
        pm.markExpired(PRODUCT_ID, 1);

        uint256 capAfter = vault.availableCapacityUSD();
        assertEq(capAfter, capBefore, "Capacity should be fully restored after expiry");
        assertGt(capAfter, capDuring, "Capacity should increase after expiry");
    }

    // ═══════════════════════════════════════════════
    //  7. BondVault: reserveCapacity only callable by PolicyManager
    // ═══════════════════════════════════════════════
    function test_reserveCapacity_onlyPolicyManager() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert("Only PolicyManager");
        vault.reserveCapacity(100 * 1e18);
    }

    // ═══════════════════════════════════════════════
    //  8. BondVault: releaseReservation only callable by PolicyManager
    // ═══════════════════════════════════════════════
    function test_releaseReservation_onlyPolicyManager() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert("Only PolicyManager");
        vault.releaseReservation(100 * 1e18);
    }

    // ═══════════════════════════════════════════════
    //  9. BondVault: commitReservation only callable by PolicyManager
    // ═══════════════════════════════════════════════
    function test_commitReservation_onlyPolicyManager() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert("Only PolicyManager");
        vault.commitReservation(100 * 1e18);
    }

    // ═══════════════════════════════════════════════
    // 10. BondVault: releaseReservation reverts on insufficient
    // ═══════════════════════════════════════════════
    function test_releaseReservation_reverts_insufficient() public {
        // Reserve some capacity first
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");

        // Try to release more than reserved (direct call as policyManager)
        vm.prank(address(pm));
        vm.expectRevert("Insufficient reservation");
        vault.releaseReservation(900 * 1e18); // reserved is 800
    }

    // ═══════════════════════════════════════════════
    // 11. BondVault: commitReservation reverts on insufficient
    // ═══════════════════════════════════════════════
    function test_commitReservation_reverts_insufficient() public {
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");

        vm.prank(address(pm));
        vm.expectRevert("Insufficient reservation");
        vault.commitReservation(900 * 1e18);
    }

    // ═══════════════════════════════════════════════
    // 12. Multiple policies: reservations accumulate
    // ═══════════════════════════════════════════════
    function test_multiple_policies_reservations_accumulate() public {
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC"); // 800 USD
        pm.recordPolicy(PRODUCT_ID, buyer2, 2000e6, 4e6, 3600, "BTC"); // 1600 USD

        assertEq(vault.totalReservedUSD(), (800 + 1600) * 1e18, "Reservations should accumulate");
    }

    // ═══════════════════════════════════════════════
    // 13. Trigger one of multiple policies: partial release
    // ═══════════════════════════════════════════════
    function test_trigger_one_of_multiple_partial_reservation() public {
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC"); // policyId=1, 800 USD
        pm.recordPolicy(PRODUCT_ID, buyer2, 2000e6, 4e6, 3600, "BTC"); // policyId=2, 1600 USD

        uint256 reservedBefore = vault.totalReservedUSD();
        assertEq(reservedBefore, 2400 * 1e18);

        // Trigger policy 1
        pm.triggerPayout(PRODUCT_ID, 1, "");

        assertEq(vault.totalReservedUSD(), 1600 * 1e18, "Only policy 2's reservation should remain");
        assertEq(vault.totalCommittedUSD(), 800 * 1e18, "Policy 1 should be committed");
    }

    // ═══════════════════════════════════════════════
    // 14. settlePolicy (triggered) commits reservation
    // ═══════════════════════════════════════════════
    function test_settlePolicy_triggered_commits_reservation() public {
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");

        // settlePolicy must be called by shield
        vm.prank(address(shield));
        pm.settlePolicy(PRODUCT_ID, 1, true);

        assertEq(vault.totalReservedUSD(), 0, "Reservation should be committed");
        assertEq(vault.totalCommittedUSD(), 800 * 1e18, "Should be committed");
    }

    // ═══════════════════════════════════════════════
    // 15. settlePolicy (not triggered) releases reservation
    // ═══════════════════════════════════════════════
    function test_settlePolicy_notTriggered_releases_reservation() public {
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");

        uint256 capBefore = vault.availableCapacityUSD();

        // Settle as not triggered (expired via keeper)
        vm.prank(address(shield));
        pm.settlePolicy(PRODUCT_ID, 1, false);

        assertEq(vault.totalReservedUSD(), 0, "Reservation should be released");
        assertEq(vault.totalCommittedUSD(), 0, "Nothing should be committed");

        uint256 capAfter = vault.availableCapacityUSD();
        assertGt(capAfter, capBefore, "Capacity should be restored");
    }

    // ═══════════════════════════════════════════════
    // 16. getStatus reflects reserved capacity
    // ═══════════════════════════════════════════════
    function test_getStatus_reflects_reservation() public {
        (,,, uint256 availBefore,) = vault.getStatus();

        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");

        (,,, uint256 availAfter,) = vault.getStatus();
        assertEq(availBefore - availAfter, 800, "getStatus should reflect reserved capacity");
    }

    // ═══════════════════════════════════════════════
    // 17. Zero amount reservation reverts
    // ═══════════════════════════════════════════════
    function test_reserveCapacity_zero_reverts() public {
        vm.prank(address(pm));
        vm.expectRevert("Zero amount");
        vault.reserveCapacity(0);
    }

    // ═══════════════════════════════════════════════
    // 18. Full lifecycle: purchase -> trigger -> redeem
    // ═══════════════════════════════════════════════
    function test_full_lifecycle_purchase_trigger_redeem() public {
        // Purchase
        pm.recordPolicy(PRODUCT_ID, buyer1, 1000e6, 2e6, 3600, "BTC");
        assertEq(vault.totalReservedUSD(), 800 * 1e18);
        assertEq(vault.totalCommittedUSD(), 0);

        // Trigger
        pm.triggerPayout(PRODUCT_ID, 1, "");
        assertEq(vault.totalReservedUSD(), 0);
        assertEq(vault.totalCommittedUSD(), 800 * 1e18);

        // Bond was minted — warp to maturity and redeem
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        vm.warp(claimBond.maturityDate(epochId) + 1);

        vm.prank(buyer1);
        vault.redeemBond(epochId, 800);

        assertEq(vault.totalCommittedUSD(), 0, "Committed should be zero after full redemption");
        assertGt(token.balanceOf(buyer1), 0, "Buyer should have received LUMINA");
    }
}
