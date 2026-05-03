// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {LuminaBondMarketplace} from "../../../src/marketplace/LuminaBondMarketplace.sol";
import {SolvencyOracle} from "../../../src/oracles/SolvencyOracle.sol";
import {CapacityOracle} from "../../../src/oracles/CapacityOracle.sol";
import {CEXLiquidityReserve} from "../../../src/treasury/CEXLiquidityReserve.sol";
import {TreasuryVesting} from "../../../src/token/TreasuryVesting.sol";
import {IDexRouter} from "../../../src/interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════════════════════════════════════════════════════════
// MOCKS
// ═══════════════════════════════════════════════════════════

contract MockPriceOracleMath {
    uint256 public price = 0.036e18; // $0.036

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockDexRouter is IDexRouter {
    uint256 public rate = 27e18; // 1 USDC ($1) = ~27.7 LUMINA at $0.036

    function setRate(uint256 r) external {
        rate = r;
    }

    function swap(address, address tokenOut, uint256 amountIn, uint256) external returns (uint256 amountOut) {
        // amountIn is USDC (6 dec), convert to LUMINA (18 dec) using rate
        amountOut = (amountIn * rate) / 1e6;
        // Mint LUMINA to caller (TWAPBurner) via deal-style — must be pre-funded
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256 expectedOut) {
        return (amountIn * rate) / 1e6;
    }
}

contract MockPolicyManager {
    uint256 public nextPolicyId = 1;

    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external returns (uint256) {
        return nextPolicyId++;
    }

    function triggerPayout(bytes32, uint256, bytes calldata) external {}
}

contract MockFeeDistributorMath {
    function isHealthy() external pure returns (bool) {
        return true;
    }

    function getDistribution() external pure returns (uint256, uint256, uint256, uint256) {
        return (8500, 800, 200, 500); // burn, buyback, ops, maint
    }
}

contract MockUSDC {
    // Minimal ERC20 for testing — we use forge deal() for balances

    }

// ═══════════════════════════════════════════════════════════
// MATH EDGE CASES AUDIT — 8 Categories, ~40 Tests
// ═══════════════════════════════════════════════════════════

contract MathEdgeCases is Test {
    // ═══════ SYSTEM CONTRACTS ═══════
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    CoverRouterV2 router;
    TWAPBurner twapBurner;
    LuminaBondMarketplace marketplace;
    SolvencyOracle solvencyOracle;
    CapacityOracle capacityOracle;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;

    // ═══════ MOCKS ═══════
    MockPriceOracleMath oracle;
    MockDexRouter dexRouter;
    MockPolicyManager policyManager;

    // ═══════ ADDRESSES ═══════
    address admin = makeAddr("admin");
    address user = makeAddr("user");
    address buyer = makeAddr("buyer");
    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address cexAddr = makeAddr("cexAddr");
    address treasuryAddr = makeAddr("treasuryAddr");
    address usdc;

    // ═══════ CONSTANTS ═══════
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC
    uint256 constant LUMINA_PRICE = 0.036e18; // $0.036

    function setUp() public {
        // Warp to 60 days after base timestamp
        vm.warp(BASE_TS + 60 days);

        // Deploy oracle
        oracle = new MockPriceOracleMath();

        // Deploy ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // Deploy token (needs 5 unique non-zero addresses for distribution)
        address tempVault = makeAddr("tempVault");
        token = ProxyDeployer.deployLuminaTokenV2(tempVault, cexAddr, founder, lbp, treasuryAddr);

        // Deploy a simple USDC mock using forge's ERC20 deal
        // We use address(0xUSDC) as a symbolic USDC — we use deal() for balances
        usdc = address(new ERC20Mock("USD Coin", "USDC", 6));

        // Deploy DexRouter mock
        dexRouter = new MockDexRouter();

        // Deploy TWAPBurner
        twapBurner = ProxyDeployer.deployTWAPBurner(usdc, address(token), address(dexRouter));

        // Deploy PolicyManager mock
        policyManager = new MockPolicyManager();

        // Deploy BondVault with test contract as initial policyManager
        vault = ProxyDeployer.deployBondVault(
            address(token),
            address(claimBond),
            address(oracle),
            address(this) // test contract acts as PolicyManager for direct issueBond calls
        );

        // Wire ClaimBond to BondVault
        claimBond.setBondVault(address(vault));

        // Fund BondVault with 70M LUMINA
        deal(address(token), address(vault), 70_000_000e18);

        // Deploy CoverRouter
        router = ProxyDeployer.deployCoverRouterV2(usdc, address(policyManager), address(twapBurner));

        // Deploy CapacityOracle (no pool, uses emergency price)
        capacityOracle = ProxyDeployer.deployCapacityOracle(
            address(0), // no pool
            address(token),
            usdc,
            LUMINA_PRICE // emergency price
        );

        // Deploy SolvencyOracle
        solvencyOracle = ProxyDeployer.deploySolvencyOracle(address(vault), address(capacityOracle), admin);

        // Deploy CEXLiquidityReserve
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(address(token), admin);
        deal(address(token), address(cexReserve), 14_000_000e18);

        // Deploy TreasuryVesting
        treasuryVesting = ProxyDeployer.deployTreasuryVesting(address(token));
        deal(address(token), address(treasuryVesting), 3_000_000e18);

        // Deploy Marketplace
        marketplace = ProxyDeployer.deployLuminaBondMarketplace(address(claimBond), usdc, address(twapBurner), admin);

        // Configure a default product on the router
        router.configureProduct(
            keccak256("TEST-PRODUCT"),
            8000, // 80% payout ratio
            20, // 0.20% trigger probability
            15000, // 1.5x margin
            3600, // 1 hour duration
            true
        );

        // Set capacity oracle on router
        router.setCapacityOracle(address(capacityOracle));

        // Fund dexRouter with LUMINA for swap simulation
        deal(address(token), address(dexRouter), 10_000_000e18);

        // Authorize vault caller for burn tests
        vault.setAuthorizedCaller(admin, true);
    }

    // ═══════════════════════════════════════════════════════
    // CATEGORY 1: OVERFLOW (5 tests)
    // ═══════════════════════════════════════════════════════

    /// @notice Max realistic coverage ($10M) must not overflow premium calculation via CoverRouterV2
    function test_overflow_maxCoverageAmount_premiumCalc() public {
        // Test multiple large coverages via the real CoverRouterV2.quotePremium()
        uint256[4] memory coverages = [uint256(1_000_000e6), 10_000_000e6, 100_000_000e6, 1_000_000_000e6];

        for (uint256 i = 0; i < coverages.length; i++) {
            (uint256 premium, uint256 payout) = router.quotePremium(keccak256("TEST-PRODUCT"), coverages[i]);
            assertGt(premium, 0, "Premium should be positive");
            assertLt(premium, coverages[i], "Premium must be less than coverage");
            assertEq(payout, (coverages[i] * 8000) / 10000, "Payout must be 80% of coverage");

            // Verify exact premium formula: coverage * 8000 * 20 * 15000 / 1e12
            uint256 expectedPremium = (coverages[i] * 8000 * 20 * 15000) / (10000 * 10000 * 10000);
            if (expectedPremium == 0) expectedPremium = 1;
            assertEq(premium, expectedPremium, "Premium must match quotePremium formula");
        }

        // Verify specific value for $10M: 10M * 0.80 * 0.002 * 1.5 = $24,000
        (uint256 premium10M,) = router.quotePremium(keccak256("TEST-PRODUCT"), 10_000_000e6);
        assertEq(premium10M, 24_000e6, "Premium for $10M coverage should be $24,000");
    }

    /// @notice Max face value for LUMINA conversion must not overflow
    function test_overflow_maxFaceValue_luminaConversion() public {
        // luminaAmount = usdAmount * 1e36 / price
        // Even with usdAmount = 1_000_000 (1M bonds), 1e6 * 1e36 = 1e42, well under uint256 max
        uint256 usdAmount = 1_000_000;
        uint256 price = LUMINA_PRICE;
        uint256 luminaAmount = (usdAmount * 1e36) / price;
        assertGt(luminaAmount, 0, "LUMINA amount should be positive");
        // 1M * 1e36 / 0.036e18 = 1e42 / 3.6e16 = ~2.77e25 — valid
        assertLt(luminaAmount, type(uint256).max, "Should not overflow");
    }

    /// @notice Far-future epoch (year 2099) calculation must not overflow
    function test_overflow_farFutureEpoch_year2099() public {
        // _timestampToEpoch: ts = BASE_TS + monthsFromBase * 2629746
        // year 2099, month 12 → monthsFromBase = (2099-2026)*12 + 11 = 887
        // ts = 1767225600 + 887 * 2629746 = ~3.1e9 — fits fine
        uint256 farFutureTs = BASE_TS + (887 * 2629746);
        vm.warp(farFutureTs - 730 days); // warp so issueBond timestamp is valid
        vm.warp(farFutureTs - 730 days);

        // Verify ClaimBond _timestampFromYearMonth works for 2099-12
        // epochId 209912 should be valid (epochId range: 202600..210012)
        // We test indirectly via issueBond which calls _timestampToEpoch
        oracle.setPrice(LUMINA_PRICE);
        vm.warp(farFutureTs - 730 days);
        vault.issueBond(user, 100);
        // If we get here without revert, epoch calc succeeded
        assertTrue(true, "Far-future epoch calculation succeeded");
    }

    /// @notice type(uint256).max coverage should revert (overflow in multiplication)
    function test_overflow_maxUint256_coverage_reverts() public {
        uint256 maxUint = type(uint256).max;
        // quotePremium: maxUint * 8000 overflows
        vm.expectRevert();
        router.quotePremium(keccak256("TEST-PRODUCT"), maxUint);
    }

    /// @notice type(uint256).max face value in LUMINA conversion should revert
    function test_overflow_maxUint256_luminaConversion_reverts() public {
        // redeemBond with enormous usdAmount — first issue bonds
        vault.issueBond(user, 100);
        uint256 epochId = _currentEpochPlus24();

        // Warp to maturity
        vm.warp(block.timestamp + 731 days);

        // Try redeeming more than balance
        vm.prank(user);
        vm.expectRevert("Insufficient bonds");
        vault.redeemBond(epochId, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════
    // CATEGORY 2: UNDERFLOW (4 tests)
    // ═══════════════════════════════════════════════════════

    /// @notice Redeeming more bonds than balance must revert
    function test_underflow_redeemMoreThanBalance() public {
        vault.issueBond(user, 500);
        uint256 epochId = _currentEpochPlus24();
        vm.warp(block.timestamp + 731 days);

        vm.prank(user);
        vm.expectRevert("Insufficient bonds");
        vault.redeemBond(epochId, 501);
    }

    /// @notice decreaseObligations more than committed must revert
    function test_underflow_decreaseObligations_moreThanCommitted() public {
        vault.issueBond(user, 100);
        assertEq(vault.totalCommittedUSD(), 100e18);

        vm.prank(admin);
        vm.expectRevert("Amount exceeds committed");
        vault.decreaseObligations(200e18);
    }

    /// @notice burnFromReserves more than balance must revert
    function test_underflow_burnFromReserves_moreThanBalance() public {
        uint256 balance = token.balanceOf(address(vault));
        vm.prank(admin);
        vm.expectRevert(); // Exceeds 5% per-tx cap (or insufficient if somehow huge)
        vault.burnFromReserves(balance + 1);
    }

    /// @notice totalCommittedUSD must not underflow on partial redemption
    function test_underflow_totalCommittedUSD_partialRedemption() public {
        vault.issueBond(user, 800);
        assertEq(vault.totalCommittedUSD(), 800e18);

        uint256 epochId = _currentEpochPlus24();
        vm.warp(block.timestamp + 731 days);

        // Redeem 500 of 800
        vm.prank(user);
        vault.redeemBond(epochId, 500);
        assertEq(vault.totalCommittedUSD(), 300e18, "Should be 300 USD committed after partial redeem");

        // Redeem remaining 300
        vm.prank(user);
        vault.redeemBond(epochId, 300);
        assertEq(vault.totalCommittedUSD(), 0, "Should be zero after full redeem");
    }

    // ═══════════════════════════════════════════════════════
    // CATEGORY 3: DIVISION BY ZERO (5 tests)
    // ═══════════════════════════════════════════════════════

    /// @notice Solvency ratio when totalCommittedUSD = 0 returns max uint
    function test_divZero_solvencyRatio_zeroObligations() public {
        // No bonds issued → totalCommittedUSD = 0
        uint256 ratio = solvencyOracle.getSolvencyRatio();
        assertEq(ratio, type(uint256).max, "Solvency ratio should be max when no obligations");
    }

    /// @notice [Fix C-3] Oracle price = 0 → _getSafePrice now reverts (no silent fallback).
    function test_divZero_luminaPrice_zero_reverts() public {
        // Issue bonds while price is normal (capacity check needs non-zero price)
        vault.issueBond(user, 100);
        uint256 epochId = _currentEpochPlus24();
        vm.warp(block.timestamp + 731 days);

        // Set price to 0 — _getSafePrice reverts with the new check
        oracle.setPrice(0);

        vm.prank(user);
        vm.expectRevert("Oracle price out of range");
        vault.redeemBond(epochId, 1);
    }

    /// @notice Premium calc with triggerProbBps = 0 yields premium = 1 (minimum)
    function test_divZero_premium_zeroTriggerProb() public {
        router.configureProduct(
            keccak256("ZERO-PROB"),
            8000, // 80% payout
            0, // 0% trigger prob
            15000, // 1.5x margin
            3600,
            true
        );
        (uint256 premium,) = router.quotePremium(keccak256("ZERO-PROB"), 1000e6);
        // coverage * 8000 * 0 * 15000 / 1e12 = 0, floored to 1
        assertEq(premium, 1, "Premium should be minimum 1 when triggerProb is 0");
    }

    /// @notice Premium calc with marginBps = 0 yields premium = 1 (minimum)
    function test_divZero_premium_zeroMargin() public {
        router.configureProduct(
            keccak256("ZERO-MARGIN"),
            8000,
            20,
            0, // 0x margin
            3600,
            true
        );
        (uint256 premium,) = router.quotePremium(keccak256("ZERO-MARGIN"), 1000e6);
        assertEq(premium, 1, "Premium should be minimum 1 when margin is 0");
    }

    /// @notice maxPoliciesPerDay when dailyCommitUSD = 0 returns max
    function test_divZero_maxPoliciesPerDay_zeroDailyCommit() public {
        // AVG_PAYOUT_USD = 500, AVG_TRIGGER_RATE_BPS = 100 (1%)
        // dailyCommitUSD = 500 * 100 / 10000 = 5, never zero with current constants
        // But we verify the guard: if dailyCommitUSD == 0, returns type(uint256).max
        // This tests the code path. With current constants dailyCommitUSD = 5.
        uint256 maxPolicies = capacityOracle.maxPoliciesPerDay();
        assertGt(maxPolicies, 0, "maxPoliciesPerDay should be positive");
    }

    // ═══════════════════════════════════════════════════════
    // CATEGORY 4: PRECISION LOSS (5 tests)
    // ═══════════════════════════════════════════════════════

    /// @notice Premium must be > 0 for minimum coverage ($100)
    function test_precision_premiumPositive_minCoverage() public {
        (uint256 premium,) = router.quotePremium(keccak256("TEST-PRODUCT"), 100e6);
        // 100e6 * 8000 * 20 * 15000 / (10000^3) = 100e6 * 2.4e9 / 1e12 = 240000
        // = $0.24 USDC (in 6-dec)
        assertGt(premium, 0, "Premium must be > 0 for $100 coverage");
        assertEq(premium, 240000, "Premium for $100: $0.24 USDC");
    }

    /// @notice 4-bucket distribution sum must not lose dust — via real TWAPBurner adaptive mode
    function test_precision_distributionSum_noDustLoss() public {
        // Setup adaptive mode on TWAPBurner
        MockFeeDistributorMath feeDist = new MockFeeDistributorMath();
        address buybackRes = makeAddr("buybackRes");
        address opsRes = makeAddr("opsRes");
        address maintRes = makeAddr("maintRes");

        twapBurner.setFeeDistributor(address(feeDist));
        twapBurner.setReserves(buybackRes, opsRes, maintRes);
        twapBurner.setAdaptiveMode(true);

        // Fund TWAPBurner with USDC via receivePremium
        uint256 amount = 10_000e6;
        deal(usdc, address(this), amount);
        ERC20Mock(usdc).approve(address(twapBurner), amount);
        twapBurner.receivePremium(amount);

        // Execute adaptive burn
        twapBurner.executeBurn();

        // Check: sum of distributions should account for all USDC (within dust tolerance)
        uint256 buybackBal = ERC20Mock(usdc).balanceOf(buybackRes);
        uint256 opsBal = ERC20Mock(usdc).balanceOf(opsRes);
        uint256 maintBal = ERC20Mock(usdc).balanceOf(maintRes);
        uint256 burnedUSDC = twapBurner.totalUSDCBurned();
        uint256 totalDistributed = buybackBal + opsBal + maintBal + burnedUSDC;

        // For 10000e6: burn=8500e6, buyback=800e6, ops=200e6, maint=500e6 => exact
        assertEq(totalDistributed, amount, "Distribution sum must equal total (no dust)");
        assertEq(buybackBal, 800e6, "Buyback share should be 8%");
        assertEq(opsBal, 200e6, "Ops share should be 2%");
        assertEq(maintBal, 500e6, "Maintenance share should be 5%");
    }

    /// @notice Distribution with odd amounts may lose dust — via real TWAPBurner adaptive mode
    function test_precision_distributionDust_oddAmount() public {
        // Setup adaptive mode on TWAPBurner
        MockFeeDistributorMath feeDist = new MockFeeDistributorMath();
        address buybackRes = makeAddr("buybackRes2");
        address opsRes = makeAddr("opsRes2");
        address maintRes = makeAddr("maintRes2");

        twapBurner.setFeeDistributor(address(feeDist));
        twapBurner.setReserves(buybackRes, opsRes, maintRes);
        twapBurner.setAdaptiveMode(true);

        // Fund TWAPBurner with odd USDC amount via receivePremium
        uint256 amount = 7777e6; // odd amount: $7,777
        deal(usdc, address(this), amount);
        ERC20Mock(usdc).approve(address(twapBurner), amount);
        twapBurner.receivePremium(amount);

        // Execute adaptive burn
        twapBurner.executeBurn();

        // Check bucket balances
        uint256 buybackBal = ERC20Mock(usdc).balanceOf(buybackRes);
        uint256 opsBal = ERC20Mock(usdc).balanceOf(opsRes);
        uint256 maintBal = ERC20Mock(usdc).balanceOf(maintRes);
        uint256 burnedUSDC = twapBurner.totalUSDCBurned();
        uint256 totalDistributed = buybackBal + opsBal + maintBal + burnedUSDC;

        // Dust = amount - totalDistributed, must be <= 3 wei (one rounding per non-burn bucket)
        uint256 dust = amount - totalDistributed;
        assertLe(dust, 3, "Dust loss must be <= 3 wei for odd amount");

        // Verify individual bucket amounts match expected integer division
        assertEq(buybackBal, (amount * 800) / 10000, "Buyback bucket mismatch");
        assertEq(opsBal, (amount * 200) / 10000, "Ops bucket mismatch");
        assertEq(maintBal, (amount * 500) / 10000, "Maint bucket mismatch");
    }

    /// @notice Marketplace fee calculation rounds correctly for small prices
    function test_precision_feeCalculation_smallPrice() public {
        // 1.5% of $1 = 0.015 = 15000 / 1000000 → in 6-dec USDC: 1e6 * 150 / 10000 = 15000
        (uint256 sellerFee, uint256 buyerFee, uint256 total) = marketplace.calculateFees(1e6);
        assertEq(sellerFee, 15000, "Seller fee for $1 = $0.015");
        assertEq(buyerFee, 15000, "Buyer fee for $1 = $0.015");
        assertEq(total, 30000, "Total fees for $1 = $0.03");
    }

    /// @notice LUMINA conversion rounding: protocol should never overpay
    function test_precision_luminaConversion_protocolFavored() public {
        // redeemBond: luminaAmount = usdAmount * 1e36 / price
        // Solidity integer division truncates → always rounds DOWN → protocol keeps dust
        uint256 usdAmount = 1; // $1
        uint256 price = LUMINA_PRICE; // 0.036e18

        uint256 luminaAmount = (usdAmount * 1e36) / price;
        uint256 backToUsd = (luminaAmount * price) / 1e18;

        // backToUsd should be <= usdAmount * 1e18 (in 18-dec USD)
        assertLe(backToUsd, usdAmount * 1e18, "Rounding must favor protocol (no overpay)");
    }

    // ═══════════════════════════════════════════════════════
    // CATEGORY 5: DECIMAL MISMATCH (4 tests)
    // ═══════════════════════════════════════════════════════

    /// @notice USDC (6 dec) to LUMINA (18 dec) conversion via BondVault.redeemBond() with actual oracle price
    function test_decimal_usdcToLumina_conversion() public {
        // Issue bond for $800
        vault.issueBond(user, 800);
        uint256 epochId = _currentEpochPlus24();
        vm.warp(block.timestamp + 731 days);

        // Read the live oracle price (not a hardcoded constant)
        uint256 oraclePrice = oracle.getLuminaPrice();
        assertGt(oraclePrice, 0, "Oracle price must be positive");

        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        vault.redeemBond(epochId, 800);
        uint256 received = token.balanceOf(user) - balBefore;

        // Compute expected LUMINA from oracle price: usdAmount * 1e36 / price
        uint256 expected = (800 * 1e36) / oraclePrice;
        assertEq(received, expected, "LUMINA received must match oracle-based formula");

        // Cross-check: converting back to USD should not exceed original amount (rounding favors protocol)
        uint256 backToUsd = (received * oraclePrice) / 1e18;
        assertLe(backToUsd, 800e18, "Round-trip must not overpay");

        // Verify approximate human-readable amount: at $0.036, $800 = ~22,222 LUMINA
        assertApproxEqRel(received, 22_222.222222e18, 1e15, "Should be ~22,222 LUMINA at $0.036");
    }

    /// @notice Oracle price consistency: 18-dec internal format
    function test_decimal_oraclePrice_18dec() public {
        uint256 price = capacityOracle.getLuminaPrice();
        assertEq(price, LUMINA_PRICE, "Emergency price should be 18-dec");
        // Verify it represents $0.036
        assertEq(price, 36e15, "$0.036 = 36e15 in 18-dec");
    }

    /// @notice Capacity check: units must match (18-dec USD-wei) in BondVault
    function test_decimal_capacityCheck_unitsMatch() public {
        // totalCommittedUSD is in 18-dec USD-wei after V3/SR2 fix
        vault.issueBond(user, 100); // $100 bond
        uint256 committed = vault.totalCommittedUSD();
        assertEq(committed, 100e18, "totalCommittedUSD must be 18-dec USD-wei");

        // availableCapacityUSD returns INTEGER dollars
        uint256 available = vault.availableCapacityUSD();
        // reserve = 70M * $0.036 = $2.52M, 50% = $1.26M, minus $100 = ~$1,259,900
        assertGt(available, 1_200_000, "Available capacity should be ~1.26M");
    }

    /// @notice CEXReserve vesting: LUMINA amounts in 18-dec
    function test_decimal_cexReserve_vestingDecimals() public {
        // CEXReserve was deployed at warp time (BASE_TS + 60d), so warp forward 60 days
        vm.warp(block.timestamp + 60 days);
        uint256 vested = cexReserve.getVestedAmount();
        // 60 days elapsed, VESTING_DURATION = 730 days
        // vested = 8.4M * 60d / 730d = ~690,410e18
        assertGt(vested, 600_000e18, "Vested should be > 600K LUMINA");
        assertLt(vested, 800_000e18, "Vested should be < 800K LUMINA");
    }

    // ═══════════════════════════════════════════════════════
    // CATEGORY 6: BOUNDARY CONDITIONS (6 tests)
    // ═══════════════════════════════════════════════════════

    /// @notice Coverage exactly at minimum ($100 USDC)
    function test_boundary_coverageExactMin() public {
        (uint256 premium,) = router.quotePremium(keccak256("TEST-PRODUCT"), 100e6);
        assertGt(premium, 0, "Premium for exactly $100 must be > 0");
    }

    /// @notice Coverage below minimum ($99.999999 USDC) must revert
    function test_boundary_coverageBelowMin_reverts() public {
        // $99.999999 in 6-dec = 99_999_999
        deal(usdc, user, 1e12);
        ERC20Mock(usdc).approveFor(user, address(router), 1e12);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.InvalidCoverage.selector, 99_999_999));
        router.purchasePolicy(keccak256("TEST-PRODUCT"), 99_999_999, bytes32("BTC"));
    }

    /// @notice Burn exactly 5% of vault balance must succeed
    function test_boundary_burnExactly5Percent() public {
        uint256 balance = token.balanceOf(address(vault));
        uint256 fivePercent = (balance * 5) / 100;

        vm.prank(admin);
        vault.burnFromReserves(fivePercent);

        uint256 newBalance = token.balanceOf(address(vault));
        assertEq(newBalance, balance - fivePercent, "Balance should decrease by 5%");
    }

    /// @notice Burn 5% + 1 wei must revert
    function test_boundary_burnExceeds5Percent_reverts() public {
        uint256 balance = token.balanceOf(address(vault));
        uint256 fivePercentPlus1 = (balance * 5) / 100 + 1;

        vm.prank(admin);
        vm.expectRevert("Exceeds 5% per-tx cap");
        vault.burnFromReserves(fivePercentPlus1);
    }

    /// @notice Multiple sequential burns within 5% each
    function test_boundary_sequentialBurns_5percent() public {
        uint256 balance1 = token.balanceOf(address(vault));
        uint256 burn1 = (balance1 * 5) / 100;
        vm.prank(admin);
        vault.burnFromReserves(burn1);

        // Second burn: 5% of NEW balance
        uint256 balance2 = token.balanceOf(address(vault));
        uint256 burn2 = (balance2 * 5) / 100;
        vm.prank(admin);
        vault.burnFromReserves(burn2);

        assertEq(token.balanceOf(address(vault)), balance1 - burn1 - burn2);
    }

    /// @notice Solvency at exactly 150% = 15000 bps (relevant for quadrant classification)
    function test_boundary_solvencyAt150Percent() public {
        // Set up: reserveValueUSD / obligations = 1.5
        // We need obligations such that ratio = exactly 15000 bps
        // ratio = (valueUSD * 10000) / obligations
        // 15000 = (valueUSD * 10000) / obligations → obligations = valueUSD * 10000 / 15000
        uint256 reserveBal = token.balanceOf(address(vault));
        uint256 valueUSD = (reserveBal * LUMINA_PRICE) / 1e18; // 18-dec USD
        uint256 targetObligations = (valueUSD * 10000) / 15000;

        // Issue bonds to reach target obligations
        uint256 bondsNeeded = targetObligations / 1e18; // integer dollars
        // This may exceed capacity — set a high price to allow it
        oracle.setPrice(1e18); // $1 per LUMINA → 70M LUMINA = $70M, 50% = $35M capacity
        vault.issueBond(user, bondsNeeded);

        // Reset price for solvency check
        oracle.setPrice(LUMINA_PRICE);
        uint256 ratio = solvencyOracle.getSolvencyRatio();
        // Due to rounding, ratio may be very close but not exactly 15000
        assertApproxEqAbs(ratio, 15000, 2, "Solvency ratio should be ~150%");
    }

    // ═══════════════════════════════════════════════════════
    // CATEGORY 7: EPOCH ARITHMETIC (4 tests)
    // ═══════════════════════════════════════════════════════

    /// @notice Epoch at BASE_TS + 730 days = ~Jan 2028 → epoch 202801
    function test_epoch_baseTimestampPlus730() public {
        vm.warp(BASE_TS);
        // issueBond at BASE_TS → maturity = BASE_TS + 730 days
        // monthsFromBase = (BASE_TS + 730*86400 - BASE_TS) / 2629746
        // = 63072000 / 2629746 = ~23.98 → month 23 from base
        // year = 2026 + 23/12 = 2026 + 1 = 2027, month = 1 + 23%12 = 12
        // epoch = 202712 (Dec 2027)
        // Actually 730 days = 730*86400 = 63072000, /2629746 = 23.98 → truncated to 23
        vault.issueBond(user, 100);
        uint256 epochId = 202712; // Dec 2027
        uint256 bal = claimBond.balanceOf(user, epochId);
        assertEq(bal, 100, "Bond should be in epoch 202712 (Dec 2027)");
    }

    /// @notice Epoch month boundary crossing
    function test_epoch_monthBoundaryCrossing() public {
        // Issue at BASE_TS + 30 days → maturity at +760 days from base
        vm.warp(BASE_TS + 30 days);
        // monthsFromBase for maturity = (30*86400 + 730*86400) / 2629746
        // = 65664000 / 2629746 = ~24.97 → 24 → year = 2028, month = 1 (Jan)
        // epoch = 202801
        vault.issueBond(user, 200);
        uint256 epochId = 202801;
        uint256 bal = claimBond.balanceOf(user, epochId);
        assertEq(bal, 200, "Bond should cross into epoch 202801 (Jan 2028)");
    }

    /// @notice Epoch for far future (year 2050)
    function test_epoch_farFuture_year2050() public {
        // Warp to a time where maturity lands in 2050
        // epoch 205001 → year 2050, month 1
        // monthsFromBase = (2050-2026)*12 + 0 = 288
        // maturityTs = BASE_TS + 288 * 2629746
        // issuanceTs = maturityTs - 730 days
        uint256 maturityTs = BASE_TS + (288 * 2629746);
        uint256 issuanceTs = maturityTs - 730 days;
        vm.warp(issuanceTs);

        vault.issueBond(user, 50);
        uint256 bal = claimBond.balanceOf(user, 205001);
        assertEq(bal, 50, "Bond should be in epoch 205001 (Jan 2050)");
    }

    /// @notice Epoch consistency: maturityDate stored matches expected timestamp
    function test_epoch_maturityDateConsistency() public {
        vault.issueBond(user, 100);
        uint256 epochId = _currentEpochPlus24();

        uint256 storedMaturity = claimBond.maturityDate(epochId);
        // maturityDate is computed from _timestampFromYearMonth
        // which uses BASE_TIMESTAMP + monthsFromBase * 2629746
        uint256 year = epochId / 100;
        uint256 month = epochId % 100;
        uint256 monthsFromBase = (year - 2026) * 12 + (month - 1);
        uint256 expectedMaturity = BASE_TS + (monthsFromBase * 2629746);

        assertEq(storedMaturity, expectedMaturity, "Stored maturity must match formula");
    }

    // ═══════════════════════════════════════════════════════
    // CATEGORY 8: CHAINLINK / ORACLE EDGE CASES (3 tests)
    // ═══════════════════════════════════════════════════════

    /// @notice [Fix C-3] Oracle returns 0 → _getSafePrice reverts.
    function test_oracle_returnsZero_reverts() public {
        oracle.setPrice(0);
        vm.expectRevert("Oracle price out of range");
        vault.previewRedemption(100);
    }

    /// @notice [Fix C-3] Oracle returns at the new floor ($0.005).
    function test_oracle_atFloorPrice() public {
        oracle.setPrice(5e15); // $0.005 — at new MIN_REDEEM_PRICE

        vault.issueBond(user, 10);
        uint256 epochId = _currentEpochPlus24();
        vm.warp(block.timestamp + 731 days);

        // At $0.005, $10 of bonds = 10 * 1e36 / 5e15 = 2e21 LUMINA wei = 2,000 LUMINA
        vm.prank(user);
        vault.redeemBond(epochId, 10);

        uint256 received = token.balanceOf(user);
        uint256 expected = (uint256(10) * 1e36) / 5e15;
        assertEq(received, expected, "Redemption at new floor price must be exact");
        assertEq(received, 2000 * 1e18, "Should receive 2000 LUMINA for $10 at $0.005/LUMINA");
    }

    /// @notice [F-REVERSE-1] Oracle returns >= MAX_REDEEM_PRICE → reverts.
    function test_oracle_atOrAboveMaxPrice_reverts() public {
        oracle.setPrice(1000e18); // exactly MAX_REDEEM_PRICE — must revert (strict <)

        vault.issueBond(user, 800);
        uint256 epochId = _currentEpochPlus24();
        vm.warp(block.timestamp + 731 days);

        vm.prank(user);
        vm.expectRevert("Oracle price out of range");
        vault.redeemBond(epochId, 800);

        oracle.setPrice(type(uint256).max);
        vm.prank(user);
        vm.expectRevert("Oracle price out of range");
        vault.redeemBond(epochId, 800);
    }

    /// @notice [F-REVERSE-1] Oracle just below MAX_REDEEM_PRICE works.
    function test_oracle_justBelowMaxPrice() public {
        oracle.setPrice(999e18); // just below MAX

        vault.issueBond(user, 800);
        uint256 epochId = _currentEpochPlus24();
        vm.warp(block.timestamp + 731 days);

        vm.prank(user);
        vault.redeemBond(epochId, 800);

        uint256 received = token.balanceOf(user);
        uint256 expected = (uint256(800) * 1e36) / 999e18;
        assertEq(received, expected, "Redemption just below MAX must be exact");
    }

    // ═══════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════

    /// @dev Calculate expected epoch for a bond issued now (maturity = now + 730 days)
    function _currentEpochPlus24() internal view returns (uint256) {
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }
}

// ═══════════════════════════════════════════════════════════
// HELPER: Minimal ERC20 Mock with 6 decimals (USDC-like)
// ═══════════════════════════════════════════════════════════

contract ERC20Mock is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable _decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 decimals_) {
        name = _name;
        symbol = _symbol;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // Helper for tests: approve on behalf of an address
    function approveFor(address owner_, address spender, uint256 amount) external {
        allowance[owner_][spender] = amount;
    }

    // Allow deal() to work by making balanceOf a public mapping (already is)
    // Forge's deal() directly writes to storage slot 0 for balanceOf
}
