// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Minimal LUMINA mock — same shape as the one used in
///      CEXLiquidityReserveTest.t.sol so this suite stands alone.
contract MockLUMINA {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }
}

/// @title CEXReserveMutableCap
/// @notice Suite that exercises the storage-backed `monthlyCap` introduced
///         in feat/cex-reserve-mutable-cap. Covers default value, setter
///         access control + bounds, downstream effect on `allocate()` and
///         `getMonthlyCapRemaining()`, the `initializeV2` re-init path, and
///         the storage-layout invariant required for UUPS upgrade safety.
contract CEXReserveMutableCapTest is Test {
    using ProxyDeployer for *;

    CEXLiquidityReserve reserve;
    MockLUMINA lumina;

    address multisig = makeAddr("multisig");
    address recipient = makeAddr("recipient");
    address attacker = makeAddr("attacker");

    // Storage slot derived from `forge inspect storage-layout`. Hard-coded
    // so a future refactor that shifts slots fails this test loudly rather
    // than silently breaking proxy upgrade compatibility.
    uint256 internal constant MONTHLY_CAP_SLOT = 7;

    // Convenient aliases for the two new bounds.
    uint256 internal constant DEFAULT_CAP = 1_000_000e18;
    uint256 internal constant MAX_CAP = 14_000_000e18;

    // Same event signature as the contract — used with vm.expectEmit.
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap, address indexed updater, uint256 timestamp);

    function setUp() public {
        lumina = new MockLUMINA();
        reserve = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), multisig);
        lumina.mint(address(reserve), 14_000_000 * 1e18);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 1 — Default cap on a fresh deployment is exactly 1M LUMINA.
    //          Required so existing operational expectations survive the
    //          constant→storage migration without any post-deploy call.
    // ─────────────────────────────────────────────────────────────────
    function test_DefaultCapIs1M() public view {
        assertEq(reserve.monthlyCap(), DEFAULT_CAP, "default cap must be 1M");
        assertEq(reserve.DEFAULT_MONTHLY_CAP(), DEFAULT_CAP, "DEFAULT_MONTHLY_CAP constant must be 1M");
        assertEq(reserve.MAX_MONTHLY_CAP(), MAX_CAP, "MAX_MONTHLY_CAP must equal TOTAL_AMOUNT");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 2 — Admin can raise the cap and a single allocate up to the
    //          new cap clears.
    // ─────────────────────────────────────────────────────────────────
    function test_AdminCanIncreaseCap() public {
        vm.prank(multisig);
        reserve.setMonthlyCap(5_000_000e18);
        assertEq(reserve.monthlyCap(), 5_000_000e18);

        // Confirm allocate() honors the new ceiling: 2M would have failed
        // pre-change; now it passes (no sub-bucket gating in Tier-1 model).
        vm.prank(multisig);
        reserve.allocate(
            recipient, 2_000_000e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1, "post-increase allocate"
        );
        assertEq(lumina.balanceOf(recipient), 2_000_000e18);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 3 — Admin can lower the cap and subsequent allocate above the
    //          new ceiling reverts.
    // ─────────────────────────────────────────────────────────────────
    function test_AdminCanDecreaseCap() public {
        vm.prank(multisig);
        reserve.setMonthlyCap(500_000e18);
        assertEq(reserve.monthlyCap(), 500_000e18);

        vm.prank(multisig);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(recipient, 600_000e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "above lowered cap");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 4 — Anyone other than DEFAULT_ADMIN_ROLE is rejected by the
    //          AccessControl modifier.
    // ─────────────────────────────────────────────────────────────────
    function test_NonAdminCannotChangeCap() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0))
        );
        reserve.setMonthlyCap(2_000_000e18);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 5 — Setting cap = 0 reverts ("Cap zero"). Necessary because
    //          a zero cap would brick `allocate()` permanently.
    // ─────────────────────────────────────────────────────────────────
    function test_CapZeroReverts() public {
        vm.prank(multisig);
        vm.expectRevert("Cap zero");
        reserve.setMonthlyCap(0);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 6 — Setting cap above MAX_MONTHLY_CAP (= TOTAL_AMOUNT 14M)
    //          reverts ("Cap exceeds total reserve"). At-the-boundary
    //          (== MAX) is allowed; one wei above is not.
    // ─────────────────────────────────────────────────────────────────
    function test_CapAboveMaxReverts() public {
        // exactly at MAX — must succeed
        vm.prank(multisig);
        reserve.setMonthlyCap(MAX_CAP);
        assertEq(reserve.monthlyCap(), MAX_CAP);

        // one wei over MAX — must revert
        vm.prank(multisig);
        vm.expectRevert("Cap exceeds total reserve");
        reserve.setMonthlyCap(MAX_CAP + 1);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 7 — A cap change is honored by the very next allocate, even
    //          inside the same 30-day bucket. No epoch advance required.
    // ─────────────────────────────────────────────────────────────────
    function test_NewCapAppliesImmediately() public {
        // Pre-state: try 1.5M, fails because default cap is 1M.
        vm.prank(multisig);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(recipient, 1_500_000e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2, "pre-bump");

        // Bump cap, then retry the same allocate — must succeed in the
        // same block / same month.
        vm.prank(multisig);
        reserve.setMonthlyCap(2_000_000e18);

        vm.prank(multisig);
        reserve.allocate(recipient, 1_500_000e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2, "post-bump");
        assertEq(lumina.balanceOf(recipient), 1_500_000e18);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 8 — Mutating the cap does NOT touch `monthlyAllocations[curr]`.
    //          Spent in the current bucket persists across cap changes,
    //          which is the only way to keep the cap genuinely binding.
    // ─────────────────────────────────────────────────────────────────
    function test_CurrentMonthSpendingPersists() public {
        // Spend 800k in month 0.
        vm.prank(multisig);
        reserve.allocate(recipient, 800_000e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "fill 80%");
        uint256 month = reserve.getCurrentMonth();
        assertEq(reserve.monthlyAllocations(month), 800_000e18);

        // Raise cap to 5M — spent stays at 800k, NOT reset.
        vm.prank(multisig);
        reserve.setMonthlyCap(5_000_000e18);
        assertEq(reserve.monthlyAllocations(month), 800_000e18, "spent must persist after cap raise");

        // Lower cap to 1M — same: spent stays at 800k.
        vm.prank(multisig);
        reserve.setMonthlyCap(1_000_000e18);
        assertEq(reserve.monthlyAllocations(month), 800_000e18, "spent must persist after cap cut");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 9 — `MonthlyCapUpdated(oldCap, newCap, indexed updater, ts)`
    //          is emitted with exact field values when the admin updates
    //          the cap.
    // ─────────────────────────────────────────────────────────────────
    function test_EventEmittedOnCapUpdate() public {
        vm.expectEmit(true, false, false, true, address(reserve));
        emit MonthlyCapUpdated(DEFAULT_CAP, 3_000_000e18, multisig, block.timestamp);

        vm.prank(multisig);
        reserve.setMonthlyCap(3_000_000e18);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 10 — Storage layout invariant. `monthlyCap` MUST occupy
    //           slot MONTHLY_CAP_SLOT (= 7). If a refactor moves it,
    //           every existing V5.1 proxy on chain would suffer a
    //           collision after upgrade.
    // ─────────────────────────────────────────────────────────────────
    function test_StorageLayoutPreserved() public {
        // The setter writes the slot — confirm the slot we read back
        // matches both the value and the documented index.
        vm.prank(multisig);
        reserve.setMonthlyCap(7_777_777e18);

        bytes32 raw = vm.load(address(reserve), bytes32(MONTHLY_CAP_SLOT));
        assertEq(uint256(raw), 7_777_777e18, "slot 7 must hold monthlyCap");
        assertEq(reserve.monthlyCap(), 7_777_777e18);

        // Sanity check the slots immediately around it remain occupied
        // by the variables they were before this change.
        bytes32 luminaSlot = vm.load(address(reserve), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(luminaSlot))), address(lumina), "slot 0 must still be lumina");
        bytes32 deployTsSlot = vm.load(address(reserve), bytes32(uint256(1)));
        assertEq(uint256(deployTsSlot), reserve.deploymentTimestamp(), "slot 1 must still be deploymentTimestamp");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 11 — Cap dropped below already-spent amount: spent stays,
    //           further allocates of any non-zero amount revert.
    //           Defensive: validates underflow-free behaviour.
    // ─────────────────────────────────────────────────────────────────
    function test_DecreaseCapBelowSpent() public {
        vm.prank(multisig);
        reserve.allocate(recipient, 600_000e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "spend 600k");

        vm.prank(multisig);
        reserve.setMonthlyCap(500_000e18);
        // spent (600k) > cap (500k) → no further allocate possible.
        assertEq(reserve.getMonthlyCapRemaining(), 0, "remaining must be 0 when spent > cap");

        vm.prank(multisig);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(recipient, 1e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "any further wei");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 12 — `initializeV2` simulates the upgrade path: a proxy
    //           created with a "legacy" layout (cap slot = 0) gets
    //           bumped to DEFAULT_MONTHLY_CAP after the reinit call.
    // ─────────────────────────────────────────────────────────────────
    function test_ReinitV2RestoresDefault() public {
        // Force monthlyCap to 0 to mimic a legacy V5.1 proxy that has just
        // been upgraded but never had `monthlyCap` initialised.
        // OZ Initializable's version stays at 1 from the fresh setUp so
        // reinitializer(2) is callable as-is.
        vm.store(address(reserve), bytes32(MONTHLY_CAP_SLOT), bytes32(uint256(0)));
        assertEq(reserve.monthlyCap(), 0, "legacy state primed");

        vm.prank(multisig);
        reserve.initializeV2();
        assertEq(reserve.monthlyCap(), DEFAULT_CAP, "initializeV2 must restore 1M default");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 13 — `initializeV2` is idempotent: it can only run once per
    //           proxy. Required so a malicious or accidental second
    //           call cannot reset operator-set caps back to 1M.
    // ─────────────────────────────────────────────────────────────────
    function test_ReinitV2OnlyOnce() public {
        // The fresh deploy path already runs initializer(1). Try to call
        // initializeV2 — first call should pass (bumps version to 2).
        // Per OZ Initializable, calling reinitializer(N) when the contract
        // is already at version >= N reverts with InvalidInitialization.
        // The fresh deploy is at version 1, so the first call succeeds.
        vm.prank(multisig);
        reserve.initializeV2();

        // Second call must revert (version is now 2).
        vm.prank(multisig);
        vm.expectRevert();
        reserve.initializeV2();
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 14 — `getMonthlyCapRemaining()` reflects the current storage
    //           cap, not any compile-time constant. Important for
    //           off-chain dashboards that read this value.
    // ─────────────────────────────────────────────────────────────────
    function test_GetMonthlyCapRemainingReflectsNewCap() public {
        // Default: full 1M available.
        assertEq(reserve.getMonthlyCapRemaining(), DEFAULT_CAP);

        // Spend 200k — remaining = 800k.
        vm.prank(multisig);
        reserve.allocate(recipient, 200_000e18, CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3, "spend 200k");
        assertEq(reserve.getMonthlyCapRemaining(), 800_000e18);

        // Bump cap to 3M → remaining = 3M - 200k = 2.8M.
        vm.prank(multisig);
        reserve.setMonthlyCap(3_000_000e18);
        assertEq(reserve.getMonthlyCapRemaining(), 2_800_000e18);

        // Cut cap below spent → remaining = 0 (hard floor).
        vm.prank(multisig);
        reserve.setMonthlyCap(150_000e18);
        assertEq(reserve.getMonthlyCapRemaining(), 0);
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 15 — `initializeV2` is gated by `onlyRole(DEFAULT_ADMIN_ROLE)`.
    //           A caller without the role must be rejected with the
    //           OZ AccessControl error before any state change.
    // ─────────────────────────────────────────────────────────────────
    function test_InitializeV2OnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0))
        );
        reserve.initializeV2();
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 16 — When called by the holder of DEFAULT_ADMIN_ROLE, the
    //           function bumps the proxy version and writes
    //           `monthlyCap = DEFAULT_MONTHLY_CAP`.
    // ─────────────────────────────────────────────────────────────────
    function test_InitializeV2WithAdminWorks() public {
        // Prime legacy state so the post-call assertion is meaningful even
        // though setUp already initialised monthlyCap to DEFAULT_CAP.
        vm.store(address(reserve), bytes32(MONTHLY_CAP_SLOT), bytes32(uint256(0)));
        assertEq(reserve.monthlyCap(), 0, "legacy state primed");

        vm.prank(multisig);
        reserve.initializeV2();

        assertEq(reserve.monthlyCap(), DEFAULT_CAP, "admin call must restore DEFAULT_MONTHLY_CAP");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 17 — `reinitializer(2)` guard fires on a second admin call.
    //           Both calls come from the admin so we are exercising the
    //           OZ Initializable guard, NOT the AccessControl modifier
    //           (which runs first and would mask the reinit revert if the
    //           caller had no role).
    // ─────────────────────────────────────────────────────────────────
    function test_InitializeV2CannotBeCalledTwice() public {
        vm.prank(multisig);
        reserve.initializeV2();

        // Second admin call must revert because the contract is already
        // at version 2 — OZ Initializable throws InvalidInitialization.
        vm.prank(multisig);
        vm.expectRevert();
        reserve.initializeV2();
    }
}
