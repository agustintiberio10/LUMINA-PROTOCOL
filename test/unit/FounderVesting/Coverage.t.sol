// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVesting, IAaveV3PoolReader} from "../../../src/token/FounderVesting.sol";

/// @notice Mock oracle returning configurable ETH/BTC prices.
contract FVMockOracle {
    int256 public ethPrice;
    int256 public btcPrice;

    function setPrices(int256 _eth, int256 _btc) external {
        ethPrice = _eth;
        btcPrice = _btc;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (asset == bytes32("ETH")) return ethPrice;
        if (asset == bytes32("BTC")) return btcPrice;
        return 0;
    }
}

/// @notice Mock Aave V3 pool returning configurable borrow rate.
contract FVMockAavePool {
    uint128 public borrowRate;

    function setBorrowRate(uint128 r) external {
        borrowRate = r;
    }

    function getReserveData(address) external view returns (IAaveV3PoolReader.ReserveData memory data) {
        data.currentVariableBorrowRate = borrowRate;
    }
}

contract FounderVestingCoverage is Test {
    address oracle = makeAddr("oracle");
    address aavePool = makeAddr("aavePool");
    address lumina = makeAddr("lumina");
    address usdc = makeAddr("usdc");
    address recipient = makeAddr("recipient");

    // ─────────────── Constructor zero-address reverts (5) ───────────────

    function test_Constructor_RevertIf_ZeroOracle() public {
        vm.expectRevert(bytes("Zero oracle"));
        new FounderVesting(address(0), aavePool, lumina, usdc, recipient);
    }

    function test_Constructor_RevertIf_ZeroAavePool() public {
        vm.expectRevert(bytes("Zero aavePool"));
        new FounderVesting(oracle, address(0), lumina, usdc, recipient);
    }

    function test_Constructor_RevertIf_ZeroLuminaToken() public {
        vm.expectRevert(bytes("Zero token"));
        new FounderVesting(oracle, aavePool, address(0), usdc, recipient);
    }

    function test_Constructor_RevertIf_ZeroUSDC() public {
        vm.expectRevert(bytes("Zero usdc"));
        new FounderVesting(oracle, aavePool, lumina, address(0), recipient);
    }

    function test_Constructor_RevertIf_ZeroRecipient() public {
        vm.expectRevert(bytes("Zero recipient"));
        new FounderVesting(oracle, aavePool, lumina, usdc, address(0));
    }

    // ─────────────── Constructor happy path ───────────────

    function test_Constructor_HappyPath_StoresArgs() public {
        FounderVesting fv = new FounderVesting(oracle, aavePool, lumina, usdc, recipient);
        assertEq(address(fv.oracle()), oracle);
        assertEq(fv.aavePool(), aavePool);
        assertEq(address(fv.luminaToken()), lumina);
        assertEq(fv.usdc(), usdc);
        assertEq(fv.recipient(), recipient);
        assertEq(fv.deployedAt(), block.timestamp);
    }

    // ═══════ getConditions() coverage (covers L159-160 + _evaluateConditions branches) ═══════

    function _deployWithMocks() internal returns (FounderVesting fv, FVMockOracle o, FVMockAavePool a) {
        o = new FVMockOracle();
        a = new FVMockAavePool();
        fv = new FounderVesting(address(o), address(a), lumina, usdc, recipient);
    }

    function test_GetConditions_AllFalse() public {
        (FounderVesting fv,,) = _deployWithMocks();
        (bool condA, bool condB, bool condC) = fv.getConditions();
        assertFalse(condA, "condA expected false");
        assertFalse(condB, "condB expected false");
        assertFalse(condC, "condC expected false");
    }

    function test_GetConditions_OnlyCondA_True() public {
        // condA: ETH/BTC > 0.050 (50e15 in 18-dec); condB requires ethPrice > 4_000e8.
        // Pick ETH = 3000e8 (below $4000 → condB false) and BTC = 50000e8 so ratio = 3000/50000 = 0.06 > 0.05.
        (FounderVesting fv, FVMockOracle o,) = _deployWithMocks();
        o.setPrices(3_000_00000000, 50_000_00000000);
        (bool condA, bool condB, bool condC) = fv.getConditions();
        assertTrue(condA, "condA expected true");
        assertFalse(condB, "condB expected false");
        assertFalse(condC, "condC expected false");
    }

    function test_GetConditions_OnlyCondB_True() public {
        // condB: ETH > $4000 (4_000e8); condA must be false → ETH/BTC < 0.050.
        // ETH = 5000e8, BTC = 200_000e8 → ratio = 5000/200000 = 0.025 < 0.05. condB true.
        (FounderVesting fv, FVMockOracle o,) = _deployWithMocks();
        o.setPrices(5_000_00000000, 200_000_00000000);
        (bool condA, bool condB, bool condC) = fv.getConditions();
        assertFalse(condA, "condA expected false");
        assertTrue(condB, "condB expected true");
        assertFalse(condC, "condC expected false");
    }

    function test_GetConditions_OnlyCondC_True() public {
        // condC: Aave borrow rate > 7e25 (7% in RAY). Set both ETH/BTC to 0 to skip A/B.
        (FounderVesting fv,, FVMockAavePool a) = _deployWithMocks();
        a.setBorrowRate(uint128(8e25)); // 8% APY
        (bool condA, bool condB, bool condC) = fv.getConditions();
        assertFalse(condA);
        assertFalse(condB);
        assertTrue(condC, "condC expected true");
    }

    function test_GetConditions_TwoConditions_True_AC() public {
        (FounderVesting fv, FVMockOracle o, FVMockAavePool a) = _deployWithMocks();
        o.setPrices(3_000_00000000, 50_000_00000000); // condA true, condB false
        a.setBorrowRate(uint128(8e25)); // condC true
        (bool condA, bool condB, bool condC) = fv.getConditions();
        assertTrue(condA);
        assertFalse(condB);
        assertTrue(condC);
    }

    function test_GetConditions_AllTrue() public {
        (FounderVesting fv, FVMockOracle o, FVMockAavePool a) = _deployWithMocks();
        // ETH = 5000e8, BTC = 50000e8 → ratio = 0.1 > 0.05 (A); ETH > 4000 (B).
        o.setPrices(5_000_00000000, 50_000_00000000);
        a.setBorrowRate(uint128(8e25));
        (bool condA, bool condB, bool condC) = fv.getConditions();
        assertTrue(condA);
        assertTrue(condB);
        assertTrue(condC);
    }

    // ═══════ getStatus() coverage (covers L163, L176-183) ═══════

    function test_GetStatus_BeforeAnyCondition() public {
        (FounderVesting fv,,) = _deployWithMocks();
        (
            bool triggered,
            uint256 ts,
            uint256 trReleased,
            uint256 totalRel,
            uint256 metSince,
            uint256 nextReleaseAt,
            uint256 fallbackAt
        ) = fv.getStatus();
        assertFalse(triggered);
        assertEq(ts, 0);
        assertEq(trReleased, 0);
        assertEq(totalRel, 0);
        assertEq(metSince, 0);
        assertEq(nextReleaseAt, 0, "nextReleaseAt should be 0 before trigger");
        assertEq(fallbackAt, fv.deployedAt() + fv.FALLBACK_DURATION());
    }

    function test_GetStatus_DuringSustainedPeriod() public {
        (FounderVesting fv, FVMockOracle o, FVMockAavePool a) = _deployWithMocks();
        // Activate 2-of-3 then call checkAltSeason once to set conditionsMetSince.
        o.setPrices(5_000_00000000, 50_000_00000000);
        a.setBorrowRate(uint128(8e25));
        fv.checkAltSeason();
        (bool triggered,,,, uint256 metSince, uint256 nextReleaseAt, uint256 fallbackAt) = fv.getStatus();
        assertFalse(triggered, "still in sustained window");
        assertGt(metSince, 0, "conditionsMetSince should be set");
        assertEq(nextReleaseAt, 0, "nextReleaseAt 0 pre-trigger");
        assertGt(fallbackAt, 0);
    }

    function test_GetStatus_AfterUnlock() public {
        (FounderVesting fv, FVMockOracle o, FVMockAavePool a) = _deployWithMocks();
        o.setPrices(5_000_00000000, 50_000_00000000);
        a.setBorrowRate(uint128(8e25));
        // First call: start sustained period.
        fv.checkAltSeason();
        // Warp past SUSTAINED_DURATION + call again to flip altSeasonTriggered.
        vm.warp(block.timestamp + fv.SUSTAINED_DURATION() + 1);
        fv.checkAltSeason();
        (bool triggered, uint256 ts, uint256 trReleased,,, uint256 nextReleaseAt, uint256 fallbackAt) = fv.getStatus();
        assertTrue(triggered, "altSeasonTriggered must be true after sustained period");
        assertEq(ts, block.timestamp, "triggerTimestamp = now");
        assertEq(trReleased, 0, "no tranches released yet");
        // tranchesReleased(0) < TOTAL_TRANCHES(3) → nextReleaseAt = ts + 0 * 31d.
        assertEq(nextReleaseAt, ts);
        assertGt(fallbackAt, ts);
    }

    function test_GetStatus_4YearFallback() public {
        (FounderVesting fv,,) = _deployWithMocks();
        // Warp past fallback window.
        vm.warp(fv.deployedAt() + fv.FALLBACK_DURATION() + 1);
        fv.triggerFallback();
        (bool triggered,,,,, uint256 nextReleaseAt, uint256 fallbackAt) = fv.getStatus();
        assertTrue(triggered, "fallback triggered");
        assertGt(nextReleaseAt, 0, "nextReleaseAt should be set post-trigger");
        assertEq(fallbackAt, fv.deployedAt() + fv.FALLBACK_DURATION());
    }
}
