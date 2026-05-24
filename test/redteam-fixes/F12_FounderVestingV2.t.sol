// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVestingV2} from "../../src/token/FounderVestingV2.sol";

contract MockOracleV2 {
    int256 public ethPrice = 3000_00000000; // $3,000 (8 dec)
    int256 public btcPrice = 60000_00000000; // $60,000 (8 dec)

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (asset == bytes32("ETH")) return ethPrice;
        if (asset == bytes32("BTC")) return btcPrice;
        return 0;
    }

    function setEthPrice(int256 p) external {
        ethPrice = p;
    }

    function setBtcPrice(int256 p) external {
        btcPrice = p;
    }
}

contract MockAaveV2 {
    uint128 public borrowRate = 5e25; // 5% (below threshold)

    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address) external view returns (ReserveData memory data) {
        data.currentVariableBorrowRate = borrowRate;
    }

    function setBorrowRate(uint128 r) external {
        borrowRate = r;
    }
}

contract F12_FounderVestingV2 is Test {
    FounderVestingV2 vesting;
    MockOracleV2 oracle;
    MockAaveV2 aave;

    address luminaToken = makeAddr("lumina");
    address usdc = makeAddr("usdc");
    address founder = makeAddr("founder");

    uint256 t0;

    function setUp() public {
        oracle = new MockOracleV2();
        aave = new MockAaveV2();
        // Clean deploy (no v1 carry).
        vesting = new FounderVestingV2(address(oracle), address(aave), luminaToken, usdc, founder, 0, 0, false, 0);
        t0 = block.timestamp;
    }

    /// F-12: a single big spike + one snapshot 24h later (the v1 bypass) must NOT unlock.
    function test_SingleBlockSpikeDoesNotUnlock() public {
        oracle.setEthPrice(6000_00000000); // > $5,000 override

        // First observation starts the window.
        vesting.checkAltSeason();
        // Jump 24h and snapshot once more (v1 would have triggered here with just 2 snapshots).
        vm.warp(t0 + 1 days + 1);
        vesting.checkAltSeason();

        assertFalse(vesting.altSeasonTriggered(), "two snapshots must NOT unlock");
        (, uint256 p1Since, uint256 p2Obs,) = vesting.getSustainProgress();
        assertLt(p2Obs, vesting.MIN_OBSERVATIONS(), "observation count below required");
    }

    /// F-12: triggering PATH 2 requires MIN_OBSERVATIONS spaced snapshots across >= 24h.
    function test_SustainedRequiresMultipleSnapshots() public {
        oracle.setEthPrice(6000_00000000); // override condition true

        uint256 n = vesting.MIN_OBSERVATIONS();
        // Feed exactly N hourly observations.
        for (uint256 i = 0; i < n; i++) {
            vm.warp(t0 + i * 1 hours);
            vesting.checkAltSeason();
        }
        // After N spaced obs the window is N-1 hours (< 24h) so still not triggered.
        assertFalse(vesting.altSeasonTriggered(), "not yet: window < 24h");

        // One more observation just past the 24h window mark trips the trigger.
        vm.warp(t0 + 1 days + 1 hours);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered(), "unlocks after sustained 24h + N obs");
    }

    /// F-12: a false observation in the middle resets the accumulator.
    function test_FalseObservationResetsAccumulator() public {
        oracle.setEthPrice(6000_00000000);
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(t0 + i * 1 hours);
            vesting.checkAltSeason();
        }
        (,, uint256 obsBefore,) = vesting.getSustainProgress();
        assertEq(obsBefore, 10, "10 observations accumulated");

        // Price drops below override -> reset.
        oracle.setEthPrice(3000_00000000);
        vm.warp(t0 + 11 hours);
        vesting.checkAltSeason();
        (,, uint256 obsAfter, uint256 sinceAfter) = vesting.getSustainProgress();
        assertEq(obsAfter, 0, "accumulator reset to 0");
        assertEq(sinceAfter, 0, "window start reset");
    }

    /// F-12: condB (ETH > $4,000) must be true even when the BTC feed is unavailable (returns 0).
    function test_CondBIndependentOfBtcFeed() public {
        oracle.setEthPrice(4500_00000000); // ETH $4,500 > $4,000 threshold
        oracle.setBtcPrice(0); // BTC feed down

        (bool condA, bool condB, bool condC,) = vesting.getConditions();
        assertTrue(condB, "condB must be independent of BTC feed");
        assertFalse(condA, "condA needs BTC feed, must be false when BTC=0");
        assertFalse(condC, "condC borrow rate below threshold");
    }

    /// Sanity: with BTC up and ETH/BTC high, condA also resolves true.
    function test_CondAStillNeedsBtcFeed() public {
        oracle.setEthPrice(4500_00000000);
        oracle.setBtcPrice(60000_00000000);
        (bool condA, bool condB,,) = vesting.getConditions();
        assertTrue(condB);
        assertTrue(condA, "ETH/BTC = 0.075 > 0.05 threshold");
    }

    /// Migration carry-over: V2 can be constructed reflecting an already-triggered v1.
    function test_MigrationCarryOver() public {
        FounderVestingV2 migrated = new FounderVestingV2(
            address(oracle), address(aave), luminaToken, usdc, founder, 1, 2_666_666 ether, true, block.timestamp
        );
        assertTrue(migrated.altSeasonTriggered());
        assertEq(migrated.tranchesReleased(), 1);
        assertEq(migrated.totalReleased(), 2_666_666 ether);
    }
}
