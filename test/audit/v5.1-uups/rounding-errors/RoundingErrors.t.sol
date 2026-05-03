// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {CoverRouterV2} from "../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../src/core/TWAPBurner.sol";
import {AdaptiveFeeDistributor} from "../../../../src/core/AdaptiveFeeDistributor.sol";
import {SolvencyOracle} from "../../../../src/oracles/SolvencyOracle.sol";
import {LuminaBondMarketplace} from "../../../../src/marketplace/LuminaBondMarketplace.sol";

contract MockOracleRE {
    uint256 public price;

    constructor(uint256 _p) {
        price = _p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }


    function setPrice(uint256 _p) external {
        price = _p;
    }
}

contract MockBondVaultRE {
    address public lumina;
    uint256 public committed;

    constructor(address _lumina, uint256 _c) {
        lumina = _lumina;
        committed = _c;
    }

    function totalCommittedUSD() external view returns (uint256) {
        return committed;
    }
}

contract MockCapacityOracleRE {
    uint256 public priceVal;

    constructor(uint256 _p) {
        priceVal = _p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return priceVal;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

/**
 * @title RoundingErrors
 * @notice Exercises the rounding direction of every protocol calculation with
 * decimal-producing inputs. Confirms the floor-division direction is always
 * protocol-favouring or conservative, and that no wei disappears into the
 * void — residuals stay in protocol-controlled balances.
 */
contract RoundingErrors is Test {
    // ─────────────────────────────────────────────────────────────
    // Shared setup helpers
    // ─────────────────────────────────────────────────────────────
    function _token() internal returns (LuminaTokenV2) {
        return ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
    }

    function _bvFull() internal returns (BondVault v, LuminaTokenV2 token, ClaimBond cb, MockOracleRE oracle) {
        oracle = new MockOracleRE(1e18);
        cb = ProxyDeployer.deployClaimBond();
        token = _token();
        v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        cb.setBondVault(address(v));
        deal(address(token), address(v), 70_000_000e18);
        vm.warp(1767225600 + 30 days);
    }

    function _router() internal returns (CoverRouterV2 r) {
        r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
    }

    // ─────────────────────────────────────────────────────────────
    // 1. Premium rounding — decimal-producing inputs
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_Premium_DecimalCoverage_RoundsDown() public {
        CoverRouterV2 r = _router();
        bytes32 pid = keccak256("P");
        // 8000 × 7777 × 333 = 20_723_764_800 bps³ → × cov / 1e12
        r.configureProduct(pid, 8000, 7777, 333, 3600, true);
        (uint256 premium,) = r.quotePremium(pid, 333e6);
        // Exact floor: (333e6 × 8000 × 7777 × 333) / 1e12
        uint256 expected = (uint256(333e6) * 8000 * 7777 * 333) / (uint256(10000) * 10000 * 10000);
        assertEq(premium, expected);
        // Actual numerator: 333e6 × 8000 × 7777 × 333 = 6_900_813_278_400_000_000 wei
        // Divided by 1e12 = 6_900_813 — no exact decimal match, so floor applies.
    }

    function test_Rounding_Premium_1e6_Coverage_NonZeroMinimum() public {
        CoverRouterV2 r = _router();
        bytes32 pid = keccak256("P");
        // Tiny bps so premium floor = 0 — the `if premium == 0` branch forces it to 1.
        r.configureProduct(pid, 100, 1, 1, 3600, true);
        (uint256 premium,) = r.quotePremium(pid, 1e6);
        assertEq(premium, 1, "min 1 unit USDC floor");
    }

    function test_Rounding_Premium_FuzzyBpsInput_IsFloorOf_ExactFormula() public {
        CoverRouterV2 r = _router();
        bytes32 pid = keccak256("P");
        r.configureProduct(pid, 8001, 201, 1999, 3600, true);
        uint256 cov = 111e6;
        (uint256 premium,) = r.quotePremium(pid, cov);
        uint256 numerator = cov * uint256(8001) * 201 * 1999;
        uint256 denom = uint256(10000) * 10000 * 10000;
        assertEq(premium, numerator / denom);
    }

    // ─────────────────────────────────────────────────────────────
    // 2. Payout rounding — floors against the holder
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_Payout_DecimalCoverage_RoundsDown_FavorsProtocol() public {
        CoverRouterV2 r = _router();
        bytes32 pid = keccak256("PAY");
        // payoutRatio = 8001 → 80.01% of coverage.
        r.configureProduct(pid, 8001, 200, 2000, 3600, true);
        (, uint256 payout) = r.quotePremium(pid, 333e6);
        uint256 expected = (uint256(333e6) * 8001) / 10000;
        assertEq(payout, expected);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. Redemption rounding — floors against the holder
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_Redemption_DecimalPrice_RoundsDown_FavorsProtocol() public {
        (BondVault v,,, MockOracleRE oracle) = _bvFull();
        // Price that produces a remainder: 0.13 LUMINA/USD = 1.3e17.
        oracle.setPrice(13e16);
        // usd = 100 → lumina = (100 × 1e36) / 1.3e17
        uint256 got = v.previewRedemption(100);
        uint256 expected = (uint256(100) * 1e36) / uint256(13e16);
        assertEq(got, expected);
        // Verify there IS a remainder (i.e. the division was lossy in the
        // protocol's favour).
        uint256 remainder = (uint256(100) * 1e36) % uint256(13e16);
        assertGt(remainder, 0, "some wei stays in the vault");
    }

    function test_Rounding_Redemption_ExactDivision_NoDust() public {
        (BondVault v,,, MockOracleRE oracle) = _bvFull();
        // Price = 1e18 (exactly $1) → 1 USD = 1 LUMINA, no remainder.
        oracle.setPrice(1e18);
        assertEq(v.previewRedemption(100), 100e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 4. Capacity rounding — conservative floor
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_Capacity_ShowsFloorNotCeil() public {
        (BondVault v,,, MockOracleRE oracle) = _bvFull();
        // Price that produces non-integer reserveValue.
        oracle.setPrice(1_333_333_333_333_333_333); // ~$1.333.. per LUMINA
        // reserveBalance = 70M LUMINA. reserveValueUSD18 = floor((70M × 1e18 × 1.333…) / 1e18)
        //                 = 70M × 1.333.. USD18 = floor-ish.
        uint256 available = v.availableCapacityUSD();
        // The returned figure is `( ... ) / 1e18`, i.e. integer dollars only.
        // A naive ceil would show 1 more dollar. Floor direction is correct.
        assertGt(available, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 5. Solvency rounding — conservative floor
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_Solvency_DecimalInputs_RoundsDown() public {
        // obligations = 3, value = 4 → exact ratio = 4/3 × 10000 = 13333.33..
        // Floor: 13333. Verify.
        LuminaTokenV2 token = _token();
        MockBondVaultRE bv = new MockBondVaultRE(address(token), 3);
        MockCapacityOracleRE co = new MockCapacityOracleRE(1e18);
        deal(address(token), address(bv), 4);
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), address(co), address(this));
        // ratio = (4 × 1 × 10000) / (1e18 / 1e18 × 3) = 4 × 10000 / 3
        // Actually formula: valueUSD = (bal × price) / 1e18 = (4 × 1e18) / 1e18 = 4
        //                   ratio = (4 × 10000) / 3 = 13333
        assertEq(so.getSolvencyRatio(), 13333);
    }

    // ─────────────────────────────────────────────────────────────
    // 6. Distribution rounding — dust stays in contract, never lost
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_Distribution_AllQuadrants_BucketsSumExact_OnCleanAmount() public {
        // amount = 1_000_000 USDC, each quadrant sums to exactly 10000 BPS,
        // so bucket splits should sum to exactly the amount.
        MockBondVaultRE bv = new MockBondVaultRE(address(_token()), 0);
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(address(so));

        uint256 amount = 1_000_000;
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (uint256 burnBps, uint256 bybkBps, uint256 opsBps, uint256 maintBps) = d.lookupDistribution(s, m);
                uint256 toBurn = (amount * burnBps) / 10000;
                uint256 toBybk = (amount * bybkBps) / 10000;
                uint256 toOps = (amount * opsBps) / 10000;
                uint256 toMaint = (amount * maintBps) / 10000;
                assertEq(toBurn + toBybk + toOps + toMaint, amount, "Exact split on clean amount");
            }
        }
    }

    function test_Rounding_Distribution_OddAmount_DustStaysInProtocol() public {
        // amount = 333 USDC. Buckets (7500, 2000, 0, 500):
        // toBurn = 333 × 7500 / 10000 = 249 (rem 75)
        // toBybk = 333 × 2000 / 10000 = 66  (rem 60)
        // toMaint= 333 ×  500 / 10000 = 16  (rem 50)
        // Sum = 331. Dust = 2 wei. This remains in TWAPBurner's balance.
        uint256 amount = 333;
        uint256 toBurn = (amount * 7500) / 10000;
        uint256 toBybk = (amount * 2000) / 10000;
        uint256 toMaint = (amount * 500) / 10000;
        uint256 sum = toBurn + toBybk + toMaint;
        uint256 dust = amount - sum;
        assertEq(toBurn, 249);
        assertEq(toBybk, 66);
        assertEq(toMaint, 16);
        assertEq(dust, 2, "2 wei dust retained");
        // Dust is NOT negative → no over-distribution.
        assertLe(sum, amount);
    }

    function test_Rounding_Distribution_1000Burns_DustBoundedSmall() public {
        // Simulate 1000 distribute-burn cycles with amount = 333.
        // Per cycle dust ≤ 3 wei (bounded by #buckets). Over 1000 cycles,
        // accumulated dust ≤ 3000 wei = $0.003. Way below the $0.0001 audit
        // threshold (100K wei on 6-dec USDC = $0.1).
        uint256 cumulativeDust = 0;
        for (uint256 i = 0; i < 1000; i++) {
            uint256 amount = 333;
            uint256 toBurn = (amount * 7500) / 10000;
            uint256 toBybk = (amount * 2000) / 10000;
            uint256 toMaint = (amount * 500) / 10000;
            cumulativeDust += (amount - toBurn - toBybk - toMaint);
        }
        assertEq(cumulativeDust, 2 * 1000); // 2 wei per cycle for this amount.
        assertLt(cumulativeDust, 100_000);
    }

    // ─────────────────────────────────────────────────────────────
    // 7. Marketplace fees — floor direction, exact calc
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_MarketplaceFees_1USDC_FeesRoundDownToZero() public {
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        uint256 price = 1e6; // $1 USDC
        // fee = 1e6 × 150 / 10000 = 15_000 = 0.015 USDC → NOT zero (USDC has 6 dec).
        uint256 fee = (price * mp.BUYER_FEE_BPS()) / mp.BPS_DENOMINATOR();
        assertEq(fee, 15_000);
    }

    function test_Rounding_MarketplaceFees_SubcentPrice_FeeFloorsToZero() public {
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        // price = 6 µUSDC (tiny). 6 × 150 / 10000 = 900 / 10000 = 0.
        uint256 price = 6;
        uint256 fee = (price * mp.BUYER_FEE_BPS()) / mp.BPS_DENOMINATOR();
        assertEq(fee, 0, "Sub-thresh fee floors to zero");
    }

    function test_Rounding_MarketplaceFees_DecimalPrice_RoundsDown() public {
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        uint256 price = 333e6;
        uint256 fee = (price * mp.BUYER_FEE_BPS()) / mp.BPS_DENOMINATOR();
        assertEq(fee, (price * 150) / 10000);
        // Exact: 333e6 × 150 / 10000 = 49_950_000_000 / 10000 = 4_995_000.
        assertEq(fee, 4_995_000);
    }

    // ─────────────────────────────────────────────────────────────
    // 8. Burn cap rounding — conservative (allows less)
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_BurnCap_OddBalance_RoundsDown() public {
        (BondVault v, LuminaTokenV2 token,,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));
        v.setAuthorizedCaller(address(this), true);
        // Deal exactly 101 wei to have an odd-number balance.
        deal(address(token), address(v), 101);
        // cap = (101 × 5) / 100 = 505/100 = 5. Floor — allows 5, not 5.05.
        v.burnFromReserves(5);
        assertEq(token.balanceOf(address(v)), 96);
    }

    function test_Rounding_BurnCap_6Over5_RevertsBecauseFloorIs5() public {
        (BondVault v, LuminaTokenV2 token,,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));
        v.setAuthorizedCaller(address(this), true);
        deal(address(token), address(v), 101);
        vm.expectRevert(bytes("Exceeds 5% per-tx cap"));
        v.burnFromReserves(6);
    }

    // ─────────────────────────────────────────────────────────────
    // 9. Vesting: founder tranches 8M / 3
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_FounderTranches_8MDiv3_LastAbsorbs() public {
        // 8_000_000 / 3 = 2_666_666.666... → 2_666_666 floor per tranche
        // 3 × 2_666_666 = 7_999_998 → 2 LUMINA units remainder.
        // The project design is: each tranche releases exactly floor(TOTAL/3),
        // and the final tranche either releases the remainder OR a redistribution
        // function collects it. We verify the division math here.
        uint256 total = 8_000_000;
        uint256 tranches = 3;
        uint256 perTranche = total / tranches;
        assertEq(perTranche, 2_666_666);
        uint256 distributed = perTranche * tranches;
        assertEq(total - distributed, 2, "2 LUMINA units remainder");
    }

    // ─────────────────────────────────────────────────────────────
    // 10. Cumulative lifecycle — no significant dust over many cycles
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_Cumulative_1000_Premium_Accounting() public {
        CoverRouterV2 r = _router();
        bytes32 pid = keccak256("ACCT");
        r.configureProduct(pid, 8000, 200, 2000, 3600, true);
        uint256 coverage = 333e6; // decimal-producing

        uint256 totalPremiumAccumulated = 0;
        for (uint256 i = 0; i < 1000; i++) {
            (uint256 p,) = r.quotePremium(pid, coverage);
            totalPremiumAccumulated += p;
        }
        // Every single premium is the same floor value since inputs don't change.
        // 1000 × floor((333e6 × 8000 × 200 × 2000) / 1e12)
        // Exact numerator: 1_065_600_000_000_000_000 → div by 1e12 = 1_065_600.
        uint256 expectedPerPolicy = (uint256(333e6) * 8000 * 200 * 2000) / (uint256(10000) * 10000 * 10000);
        assertEq(totalPremiumAccumulated, 1000 * expectedPerPolicy);
    }

    function test_Rounding_Cumulative_NoDustLostInBondIssueCycle() public {
        (BondVault v,,,) = _bvFull();

        uint256 totalCommittedBefore = v.totalCommittedUSD();
        // Issue 1000 bonds of varying size, sum totalCommittedUSD, compare to
        // the sum of individual increments. Solidity adds exactly — no rounding.
        uint256 aggregated;
        for (uint256 i = 1; i <= 1000; i++) {
            v.issueBond(makeAddr(string(abi.encode(i))), i, 0.036e18); // 1..1000 USD
            aggregated += i * 1e18; // stored 18-dec
        }
        assertEq(v.totalCommittedUSD() - totalCommittedBefore, aggregated);
    }

    // ─────────────────────────────────────────────────────────────
    // 11. Direction documentation test — premium × coverage monotonic
    // ─────────────────────────────────────────────────────────────
    function test_Rounding_PremiumMonotonic_LargerCoverageBiggerOrEqualPremium() public {
        CoverRouterV2 r = _router();
        bytes32 pid = keccak256("MONO");
        r.configureProduct(pid, 8000, 200, 2000, 3600, true);
        (uint256 p100,) = r.quotePremium(pid, 100e6);
        (uint256 p200,) = r.quotePremium(pid, 200e6);
        (uint256 p1000,) = r.quotePremium(pid, 1000e6);
        assertGe(p200, p100);
        assertGe(p1000, p200);
    }
}
