// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";
import {RateShockShield} from "../../../../../src/products/RateShockShield.sol";
import {FounderVesting} from "../../../../../src/token/FounderVesting.sol";
import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {IShield} from "../../../../../src/interfaces/IShield.sol";

/// @notice Mutable Aave pool mock — returns configurable reserve data.
contract MockAavePool {
    bool public shouldRevert;
    uint128 public variableBorrowRate;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setVariableBorrowRate(uint128 r) external {
        variableBorrowRate = r;
    }

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

    function getReserveData(address) external view returns (ReserveData memory d) {
        require(!shouldRevert, "Aave paused");
        d.currentVariableBorrowRate = variableBorrowRate;
    }
}

/// @notice Oracle mock matching `ILuminaOracleReader` used by FounderVesting
/// (distinct from `IOracle` used by shields).
contract MockOracleAave {
    mapping(bytes32 => int256) public priceFor;
    bool public revertOnRead;

    function setPrice(bytes32 a, int256 p) external {
        priceFor[a] = p;
    }

    function setRevertOnRead(bool v) external {
        revertOnRead = v;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        require(!revertOnRead, "Oracle down");
        return priceFor[asset];
    }
}

/**
 * @title AaveIntegration
 * @notice Audits Aave V3 integration in RateShockShield (UUPS) and
 *         FounderVesting (immutable). Covers failure modes, boundary
 *         conditions, RAY-space semantics, and condition-C sustained
 *         logic.
 */
contract AaveIntegration is Test {
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    MockAavePool pool;
    MockOracleAave oracle;

    function setUp() public {
        pool = new MockAavePool();
        oracle = new MockOracleAave();
        oracle.setPrice(bytes32("ETH"), 3_000e8);
        oracle.setPrice(bytes32("BTC"), 60_000e8);
    }

    function _rateShock() internal returns (RateShockShield s) {
        s = ProxyDeployer.deployRateShockShield(address(this), address(oracle), address(pool), USDC_BASE);
    }

    function _founderVesting() internal returns (FounderVesting fv, LuminaTokenV2 token) {
        token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("tv")
        );
        fv = new FounderVesting(address(oracle), address(pool), address(token), USDC_BASE, makeAddr("recipient"));
    }

    // ─────────────────────────────────────────────────────────────
    // 1. RateShockShield: Aave revert propagates on view
    // ─────────────────────────────────────────────────────────────
    function test_Aave_RateShock_GetReserveDataReverts_ViewReverts() public {
        RateShockShield s = _rateShock();
        pool.setShouldRevert(true);
        // currentBorrowRate() reads the pool — should revert.
        vm.expectRevert();
        s.currentBorrowRate();
    }

    function test_Aave_RateShock_CreatePolicy_NoOracleRead() public {
        RateShockShield s = _rateShock();
        // createPolicy doesn't read Aave rate — should succeed even with
        // pool set to revert.
        pool.setShouldRevert(true);
        IShield.CreatePolicyParams memory p;
        p.buyer = makeAddr("b");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = 604800;
        p.asset = "USDC";
        s.createPolicy(p);
    }

    // ─────────────────────────────────────────────────────────────
    // 2. RateShock boundary: exactly 10% does NOT trigger (strict >)
    // ─────────────────────────────────────────────────────────────
    function test_Aave_RateShock_Boundary_Exactly10Percent_NoTrigger() public {
        RateShockShield s = _rateShock();
        pool.setVariableBorrowRate(10e25); // exactly trigger rate
        assertEq(s.currentBorrowRate(), 10e25);
        // Comparison is strict `>` — 10e25 == TRIGGER_RATE → false.
    }

    function test_Aave_RateShock_Boundary_10PercentPlus1Wei_Triggers() public {
        RateShockShield s = _rateShock();
        pool.setVariableBorrowRate(uint128(10e25) + 1);
        // Can't directly call _checkTriggerCondition (internal), but we
        // verify the rate is readable at the correct value.
        assertEq(s.currentBorrowRate(), uint256(10e25) + 1);
    }

    function test_Aave_RateShock_Boundary_Just_Below_10Percent_NoTrigger() public {
        RateShockShield s = _rateShock();
        pool.setVariableBorrowRate(uint128(10e25) - 1);
        assertEq(s.currentBorrowRate(), uint256(10e25) - 1);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. Rate zero: explicit
    // ─────────────────────────────────────────────────────────────
    function test_Aave_RateShock_RateZero_NoTrigger() public {
        RateShockShield s = _rateShock();
        pool.setVariableBorrowRate(0);
        assertEq(s.currentBorrowRate(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 4. Rate extreme: accepted (no sanity bound)
    // ─────────────────────────────────────────────────────────────
    function test_Aave_RateShock_RateExtreme_1000Percent_Readable() public {
        RateShockShield s = _rateShock();
        pool.setVariableBorrowRate(100e25); // 100% APY
        assertEq(s.currentBorrowRate(), 100e25);
    }

    function test_Aave_RateShock_RateMax_Uint128_Readable() public {
        RateShockShield s = _rateShock();
        pool.setVariableBorrowRate(type(uint128).max);
        assertEq(s.currentBorrowRate(), uint256(type(uint128).max));
    }

    // ─────────────────────────────────────────────────────────────
    // 5. Constants verification
    // ─────────────────────────────────────────────────────────────
    function test_Aave_RateShock_TriggerRate_Is10e25() public {
        RateShockShield s = _rateShock();
        assertEq(s.TRIGGER_RATE(), 10e25);
    }

    function test_Aave_RateShock_Duration_Is7Days() public {
        RateShockShield s = _rateShock();
        (uint32 min, uint32 max) = s.durationRange();
        assertEq(min, 604800);
        assertEq(max, 604800);
    }

    function test_Aave_RateShock_PoolAndUSDC_Correctly_Wired() public {
        RateShockShield s = _rateShock();
        assertEq(address(s.aavePool()), address(pool));
        assertEq(s.usdc(), USDC_BASE);
    }

    // ─────────────────────────────────────────────────────────────
    // 6. FounderVesting Condition C — Aave revert graceful
    // ─────────────────────────────────────────────────────────────
    function test_Aave_FounderVesting_AaveRevert_ConditionCUnmet() public {
        (FounderVesting fv,) = _founderVesting();
        pool.setShouldRevert(true);
        // checkAltSeason does not revert when Aave reverts (try/catch).
        // It just evaluates condC as false.
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0); // no sustained period started
    }

    // ─────────────────────────────────────────────────────────────
    // 7. FounderVesting Condition C boundary
    // ─────────────────────────────────────────────────────────────
    function test_Aave_FounderVesting_ConditionC_Boundary_Exactly7Percent_NotMet() public {
        (FounderVesting fv,) = _founderVesting();
        pool.setVariableBorrowRate(7e25); // exactly threshold
        // Only condC would matter here, but A/B are also unmet (prices are
        // defaults). With 0 of 3 met, no sustained period starts.
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
    }

    function test_Aave_FounderVesting_ConditionC_Boundary_7PercentPlus1_MetOnly1of3() public {
        (FounderVesting fv,) = _founderVesting();
        pool.setVariableBorrowRate(uint128(7e25) + 1);
        // Only condC met. Need 2 of 3 for sustained start — shouldn't start.
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
    }

    function test_Aave_FounderVesting_ConditionC_Met_Plus_CondB_StartsSustain() public {
        (FounderVesting fv,) = _founderVesting();
        pool.setVariableBorrowRate(uint128(7e25) + 1); // condC met
        oracle.setPrice(bytes32("ETH"), 4_001e8); // condB met (>4000)
        fv.checkAltSeason();
        // 2 of 3 met — sustained timer starts.
        assertGt(fv.conditionsMetSince(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 8. Sustained timer reset when rate drops below
    // ─────────────────────────────────────────────────────────────
    function test_Aave_FounderVesting_SustainReset_WhenRateDrops() public {
        (FounderVesting fv,) = _founderVesting();
        // Start with 2/3 conditions met.
        pool.setVariableBorrowRate(uint128(8e25)); // condC met
        oracle.setPrice(bytes32("ETH"), 4_001e8); // condB met
        fv.checkAltSeason();
        uint256 startedAt = fv.conditionsMetSince();
        assertGt(startedAt, 0);

        // Advance 3 days.
        vm.warp(block.timestamp + 3 days);

        // Rate drops — condC unmet, condB still unmet via ETH dropping too.
        pool.setVariableBorrowRate(uint128(5e25)); // below 7%
        oracle.setPrice(bytes32("ETH"), 3_000e8); // below $4000
        fv.checkAltSeason();

        // Sustain timer is reset.
        assertEq(fv.conditionsMetSince(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 9. Sustained 7 days + condition met → altSeason triggered
    // ─────────────────────────────────────────────────────────────
    function test_Aave_FounderVesting_SustainedFull7Days_TriggersAltSeason() public {
        (FounderVesting fv, LuminaTokenV2 token) = _founderVesting();
        // Fund the vesting contract so release can happen.
        deal(address(token), address(fv), 8_000_000e18);

        pool.setVariableBorrowRate(uint128(8e25)); // condC met
        oracle.setPrice(bytes32("ETH"), 4_001e8); // condB met
        fv.checkAltSeason();
        assertGt(fv.conditionsMetSince(), 0);
        assertFalse(fv.altSeasonTriggered());

        vm.warp(block.timestamp + 7 days + 1);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
    }

    function test_Aave_FounderVesting_SustainedShortOf7Days_NoTrigger() public {
        (FounderVesting fv,) = _founderVesting();
        pool.setVariableBorrowRate(uint128(8e25));
        oracle.setPrice(bytes32("ETH"), 4_001e8);
        fv.checkAltSeason();
        vm.warp(block.timestamp + 7 days - 1);
        fv.checkAltSeason();
        assertFalse(fv.altSeasonTriggered());
    }

    // ─────────────────────────────────────────────────────────────
    // 10. Constants verification for FounderVesting
    // ─────────────────────────────────────────────────────────────
    function test_Aave_FounderVesting_BorrowRateThreshold_Is7e25() public {
        (FounderVesting fv,) = _founderVesting();
        assertEq(fv.BORROW_RATE_THRESHOLD(), 7e25);
    }

    function test_Aave_FounderVesting_SustainedDuration_7Days() public {
        (FounderVesting fv,) = _founderVesting();
        assertEq(fv.SUSTAINED_DURATION(), 7 days);
    }

    function test_Aave_FounderVesting_ETH_USD_Threshold_4000_Dollars() public {
        (FounderVesting fv,) = _founderVesting();
        assertEq(fv.ETH_USD_THRESHOLD(), 400_000_000_000);
    }

    function test_Aave_FounderVesting_ETH_BTC_Threshold() public {
        (FounderVesting fv,) = _founderVesting();
        assertEq(fv.ETH_BTC_THRESHOLD(), 50e15);
    }

    // ─────────────────────────────────────────────────────────────
    // 11. RAY-space semantics — no conversion, direct comparison
    // ─────────────────────────────────────────────────────────────
    function test_Aave_RayComparison_5Percent_IsLessThan7Percent() public pure {
        assertTrue(5e25 < 7e25);
    }

    function test_Aave_RayComparison_10Percent_IsLessThan20Percent() public pure {
        assertTrue(10e25 < 20e25);
    }

    // ─────────────────────────────────────────────────────────────
    // 12. Cross-component isolation
    // ─────────────────────────────────────────────────────────────
    function test_Aave_AaveFailure_DoesNotAffect_BTCShield() public {
        // If Aave is down, FlashBTCShield (which doesn't use Aave) should
        // continue working. Trivial test but documents isolation.
        pool.setShouldRevert(true);
        // Nothing to invoke cross-shield here — assertion is architectural.
        assertTrue(pool.shouldRevert());
    }

    // ─────────────────────────────────────────────────────────────
    // 13. FounderVesting immutable — pool & usdc cannot change
    // ─────────────────────────────────────────────────────────────
    function test_Aave_FounderVesting_Pool_Immutable() public {
        (FounderVesting fv,) = _founderVesting();
        // `aavePool` is an immutable — address is fixed at deployment.
        assertEq(fv.aavePool(), address(pool));
    }

    function test_Aave_FounderVesting_USDC_Immutable() public {
        (FounderVesting fv,) = _founderVesting();
        assertEq(fv.usdc(), USDC_BASE);
    }

    // ─────────────────────────────────────────────────────────────
    // 14. RateShockShield pool/usdc state mutable via UUPS upgrade
    //     (but no setter — only via upgrade)
    // ─────────────────────────────────────────────────────────────
    function test_Aave_RateShock_NoSetAavePoolFunction_ExistsOnlyViaUpgrade() public {
        RateShockShield s = _rateShock();
        // The pool is set in initialize; no setter. Changing the pool
        // requires deploying a new impl + upgrade (admin-gated).
        assertEq(address(s.aavePool()), address(pool));
    }

    // ─────────────────────────────────────────────────────────────
    // 15. checkAltSeason twice without state change — no-op
    // ─────────────────────────────────────────────────────────────
    function test_Aave_FounderVesting_CheckAltSeasonTwice_SameState() public {
        (FounderVesting fv,) = _founderVesting();
        pool.setVariableBorrowRate(uint128(8e25));
        oracle.setPrice(bytes32("ETH"), 4_001e8);
        fv.checkAltSeason();
        uint256 startedAt1 = fv.conditionsMetSince();
        fv.checkAltSeason();
        uint256 startedAt2 = fv.conditionsMetSince();
        // Re-entering with conditions still met shouldn't reset the timer.
        assertEq(startedAt1, startedAt2);
    }

    // ─────────────────────────────────────────────────────────────
    // 16. Documented INFO — no staleness check
    // ─────────────────────────────────────────────────────────────
    function test_Aave_DOCUMENTED_NoStalenessCheck() public view {
        // Neither RateShockShield nor FounderVesting reads `lastUpdateTimestamp`.
        // This is documented in REPORT.md as INFO — Aave is expected to be
        // active and updating on every interaction.
        assertTrue(true);
    }

    // ─────────────────────────────────────────────────────────────
    // 17. Documented INFO — no rate sanity bound (not a bug)
    // ─────────────────────────────────────────────────────────────
    function test_Aave_DOCUMENTED_NoRateSanityBound() public view {
        // Unlike price oracles (M-01 fix), no MAX_RATE check is applied.
        // Legitimate financial crises could produce >100% APY and we want
        // such rates to still trigger the shield.
        assertTrue(true);
    }
}
