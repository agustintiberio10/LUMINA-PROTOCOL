// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockAavePool} from "src/mocks/MockAavePool.sol";

/// @title MockAavePoolTest
/// @notice Sprint H Phase 1.2 — unit tests for the testnet `MockAavePool`.
///         Covers admin setters, BPS→RAY conversion, multi-asset isolation,
///         stale-mode, revert-mode, ownership.
contract MockAavePoolTest is Test {
    // Re-declared events for vm.expectEmit (solc 0.8.20 doesn't support
    // `emit ContractName.EventName` cross-contract syntax — that's >=0.8.21).
    event BorrowRateUpdated(address indexed asset, uint256 oldRayRate, uint256 newRayRate);
    event LiquidityRateUpdated(address indexed asset, uint256 oldRayRate, uint256 newRayRate);
    event StaleStateChanged(bool stale);

    MockAavePool internal pool;

    address internal owner = address(this);
    address internal stranger = makeAddr("stranger");
    address internal usdc = makeAddr("usdc");
    address internal weth = makeAddr("weth");

    /// @dev BPS to RAY (1e23) helper for test expectations.
    function _bpsToRay(uint256 bps) internal pure returns (uint256) {
        return bps * 1e23;
    }

    function setUp() public {
        // Warp far enough in the future so `block.timestamp - 1 days` doesn't underflow.
        vm.warp(1_700_000_000);
        pool = new MockAavePool();
    }

    // ─────────────────── constructor + ownership ───────────────────

    function test_constructor_setsOwnerToDeployer() public view {
        assertEq(pool.owner(), owner);
    }

    function test_initialBorrowRate_zero() public view {
        // No setter called → rate defaults to zero, struct zero-initialized.
        assertEq(pool.variableBorrowRateOf(usdc), 0);
    }

    function test_transferOwnership_changesOwner() public {
        pool.transferOwnership(stranger);
        assertEq(pool.owner(), stranger);
    }

    function test_transferOwnership_zeroAddressReverts() public {
        vm.expectRevert("Zero address");
        pool.transferOwnership(address(0));
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAavePool.NotOwner.selector);
        pool.transferOwnership(stranger);
    }

    // ─────────────────── setBorrowRate ───────────────────

    function test_setBorrowRate_updatesData() public {
        pool.setBorrowRate(usdc, 700); // 7% APY
        MockAavePool.ReserveData memory data = pool.getReserveData(usdc);
        assertEq(uint256(data.currentVariableBorrowRate), _bpsToRay(700));
    }

    function test_setBorrowRate_convertsBPSToRay_700bps_equals_7percent() public {
        // 700 BPS == 7% APY == 7e25 in RAY.
        pool.setBorrowRate(usdc, 700);
        assertEq(pool.variableBorrowRateOf(usdc), 7e25);
    }

    function test_setBorrowRate_convertsBPSToRay_1000bps_equals_TRIGGER_RATE() public {
        // 1000 BPS == 10% APY == 10e25, the RateShockShield trigger threshold.
        pool.setBorrowRate(usdc, 1000);
        assertEq(pool.variableBorrowRateOf(usdc), 10e25);
    }

    function test_setBorrowRate_emitsEvent() public {
        // Match indexed asset; data field has oldRate=0 newRate=...
        vm.expectEmit(true, false, false, true, address(pool));
        emit BorrowRateUpdated(usdc, 0, _bpsToRay(500));
        pool.setBorrowRate(usdc, 500);
    }

    function test_setBorrowRate_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAavePool.NotOwner.selector);
        pool.setBorrowRate(usdc, 500);
    }

    function test_setBorrowRate_refreshesTimestamp_whenNotStale() public {
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        pool.setBorrowRate(usdc, 500);
        MockAavePool.ReserveData memory data = pool.getReserveData(usdc);
        assertEq(uint256(data.lastUpdateTimestamp), t0 + 1 hours);
    }

    function test_setBorrowRate_overflow_reverts() public {
        // 2^128 / 1e23 ≈ 3.4e15. Picking 1e16 BPS causes RAY > uint128.max.
        vm.expectRevert("rate overflow uint128");
        pool.setBorrowRate(usdc, 1e16);
    }

    // ─────────────────── setLiquidityRate ───────────────────

    function test_setLiquidityRate_updatesData() public {
        pool.setLiquidityRate(usdc, 300); // 3% APY
        MockAavePool.ReserveData memory data = pool.getReserveData(usdc);
        assertEq(uint256(data.currentLiquidityRate), _bpsToRay(300));
    }

    function test_setLiquidityRate_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit LiquidityRateUpdated(usdc, 0, _bpsToRay(300));
        pool.setLiquidityRate(usdc, 300);
    }

    function test_setLiquidityRate_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAavePool.NotOwner.selector);
        pool.setLiquidityRate(usdc, 300);
    }

    // ─────────────────── multi-asset ───────────────────

    function test_multipleAssets_independent() public {
        pool.setBorrowRate(usdc, 500); // 5%
        pool.setBorrowRate(weth, 1500); // 15%
        assertEq(pool.variableBorrowRateOf(usdc), _bpsToRay(500));
        assertEq(pool.variableBorrowRateOf(weth), _bpsToRay(1500));
        // Independence: setting USDC doesn't affect WETH.
        pool.setBorrowRate(usdc, 600);
        assertEq(pool.variableBorrowRateOf(usdc), _bpsToRay(600));
        assertEq(pool.variableBorrowRateOf(weth), _bpsToRay(1500));
    }

    // ─────────────────── setStale ───────────────────

    function test_setStale_makesDataOld() public {
        pool.setBorrowRate(usdc, 500);
        pool.setStale(true);
        MockAavePool.ReserveData memory data = pool.getReserveData(usdc);
        assertEq(uint256(data.lastUpdateTimestamp), block.timestamp - 1 days);
    }

    function test_setStale_off_returnsToFresh() public {
        pool.setBorrowRate(usdc, 500);
        pool.setStale(true);
        pool.setStale(false);
        // Without subsequent setBorrowRate, lastUpdateTimestamp from the original
        // setBorrowRate (= block.timestamp at time of call) is what's returned.
        MockAavePool.ReserveData memory data = pool.getReserveData(usdc);
        assertEq(uint256(data.lastUpdateTimestamp), block.timestamp);
    }

    function test_setStale_setBorrowRateUnderStale_keepsStaleWindow() public {
        pool.setStale(true);
        pool.setBorrowRate(usdc, 700);
        // setBorrowRate respected the `stale` flag and did NOT refresh lastUpdateTimestamp
        // (left it at zero — its initial value from a fresh struct).
        MockAavePool.ReserveData memory data = pool.getReserveData(usdc);
        // getReserveData applies the stale window, so result is block.timestamp - 1 days.
        assertEq(uint256(data.lastUpdateTimestamp), block.timestamp - 1 days);
    }

    function test_setStale_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(pool));
        emit StaleStateChanged(true);
        pool.setStale(true);
    }

    function test_setStale_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAavePool.NotOwner.selector);
        pool.setStale(true);
    }

    // ─────────────────── setRevert ───────────────────

    function test_setRevert_revertsOnGetReserveData() public {
        pool.setBorrowRate(usdc, 500);
        pool.setRevert(true);
        vm.expectRevert(MockAavePool.RevertSimulated.selector);
        pool.getReserveData(usdc);
    }

    function test_setRevert_revertsOnVariableBorrowRateOf() public {
        pool.setRevert(true);
        vm.expectRevert(MockAavePool.RevertSimulated.selector);
        pool.variableBorrowRateOf(usdc);
    }

    function test_setRevert_off_returnsNormally() public {
        pool.setBorrowRate(usdc, 500);
        pool.setRevert(true);
        pool.setRevert(false);
        MockAavePool.ReserveData memory data = pool.getReserveData(usdc);
        assertEq(uint256(data.currentVariableBorrowRate), _bpsToRay(500));
    }

    function test_setRevert_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAavePool.NotOwner.selector);
        pool.setRevert(true);
    }

    // ─────────────────── setReserveData ───────────────────

    function test_setReserveData_replacesFullStruct() public {
        MockAavePool.ReserveData memory custom;
        custom.currentVariableBorrowRate = uint128(_bpsToRay(800));
        custom.currentLiquidityRate = uint128(_bpsToRay(400));
        custom.id = 7;
        custom.aTokenAddress = address(0xabcd);
        pool.setReserveData(usdc, custom);
        MockAavePool.ReserveData memory got = pool.getReserveData(usdc);
        assertEq(uint256(got.currentVariableBorrowRate), _bpsToRay(800));
        assertEq(uint256(got.currentLiquidityRate), _bpsToRay(400));
        assertEq(got.id, 7);
        assertEq(got.aTokenAddress, address(0xabcd));
    }

    function test_setReserveData_onlyOwner() public {
        MockAavePool.ReserveData memory custom;
        vm.prank(stranger);
        vm.expectRevert(MockAavePool.NotOwner.selector);
        pool.setReserveData(usdc, custom);
    }
}
