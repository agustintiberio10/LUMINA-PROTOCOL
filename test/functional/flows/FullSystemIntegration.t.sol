// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {CapacityOracle} from "../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../../src/interfaces/IDexRouter.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════════════════════════════════════════════════════════════
//  INLINE MOCKS (external dependencies only)
// ═══════════════════════════════════════════════════════════════

contract MockUSDC_FSI {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockSwapRouter_FSI is IDexRouter {
    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC = 27 LUMINA (at ~$0.037/LUMINA)

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate * 1e12; // USDC 6-dec -> LUMINA 18-dec
        lumina.transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }
}

/// @dev Mock shield that always succeeds for integration testing
contract MockShieldV2_FSI {
    bytes32 public productId;
    uint256 private _nextPolicyId;

    struct PolicyData {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumPaid;
        uint256 maxPayout;
        uint256 expiresAt;
        uint8 status;
    }

    mapping(uint256 => PolicyData) public policyData;

    constructor(bytes32 _productId) {
        productId = _productId;
    }

    struct CreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        bytes extraData;
    }

    struct PayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }

    function createPolicy(CreatePolicyParams calldata params) external returns (uint256 policyId) {
        _nextPolicyId++;
        policyId = _nextPolicyId;
        uint256 maxPayout = (params.coverageAmount * 8000) / 10000;
        policyData[policyId] = PolicyData({
            buyer: params.buyer,
            coverageAmount: params.coverageAmount,
            premiumPaid: params.premiumAmount,
            maxPayout: maxPayout,
            expiresAt: block.timestamp + params.durationSeconds,
            status: 0
        });
    }

    function verifyAndCalculate(uint256 policyId, bytes calldata) external returns (PayoutResult memory result) {
        PolicyData storage pd = policyData[policyId];
        pd.status = 1;
        result =
            PayoutResult({triggered: true, payoutAmount: pd.maxPayout, recipient: pd.buyer, reason: "MOCK_TRIGGER"});
    }

    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (
            address insuredAgent,
            uint256 coverageAmount,
            uint256 premiumPaid,
            uint256 maxPayout,
            uint256 expiresAt,
            uint8 status
        )
    {
        PolicyData storage pd = policyData[policyId];
        return (pd.buyer, pd.coverageAmount, pd.premiumPaid, pd.maxPayout, pd.expiresAt, pd.status);
    }
}

/// @dev Mock CapacityOracle with controllable price for integration tests
contract MockCapacityOracle_FSI {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

// ═══════════════════════════════════════════════════════════════
//  FULL SYSTEM INTEGRATION TESTS — Phase 7.4
// ═══════════════════════════════════════════════════════════════

/// @title FullSystemIntegrationTest
/// @notice Deploys the full LUMINA V5.0 core system and validates
///         multi-contract interactions across bond issuance, premium
///         distribution, oracle chain, emergency fallback, and circuit
///         breaker flows.
contract FullSystemIntegrationTest is Test {
    // ═══════ CORE CONTRACTS (real) ═══════
    LuminaTokenV2 token;
    BondVault bondVault;
    ClaimBond claimBond;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;
    SolvencyOracle solvencyOracle;
    AdaptiveFeeDistributor feeDistributor;

    // ═══════ MOCKS (external deps only) ═══════
    MockUSDC_FSI usdc;
    MockSwapRouter_FSI swapRouter;
    MockShieldV2_FSI mockShield;
    MockCapacityOracle_FSI capacityOracle;

    // ═══════ ADDRESSES ═══════
    address admin = makeAddr("admin");
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");
    address buybackReserve = makeAddr("buybackReserve");
    address opsReserve = makeAddr("opsReserve");
    address maintenanceReserve = makeAddr("maintenanceReserve");
    address buyer1 = makeAddr("buyer1");
    address buyer2 = makeAddr("buyer2");

    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-INTEG");
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC
    uint256 constant EMERGENCY_PRICE = 0.036e18; // $0.036

    // ═══════ SETUP ═══════

    function setUp() public {
        // Warp to Feb 1 2026 — safely past BASE_TS for valid bond epochs
        vm.warp(BASE_TS + 31 days);

        // --- Phase 1: Deploy mocks ---
        usdc = new MockUSDC_FSI();
        capacityOracle = new MockCapacityOracle_FSI(EMERGENCY_PRICE);

        // --- Phase 2: Deploy ClaimBond (no deps) ---
        claimBond = ProxyDeployer.deployClaimBond();

        // --- Phase 3: Predict BondVault address and deploy in correct order ---
        // We need: token(bondVault), BondVault(token, claimBond, oracle, policyManager)
        // Strategy: deploy BondVault with policyManager=address(0), wire via setPolicyManager()

        // Predict LuminaTokenV2 address so BondVault can reference it
        uint64 currentNonce = vm.getNonce(address(this));
        // Deploy order from here: bondVault(+0), token(+1), swapRouter(+2), ...
        // Actually: bondVault needs lumina, lumina needs bondVault -> circular.
        // Solution: deploy BondVault first with predicted lumina address.

        // Deploy order: bondVault via proxy(+0,+1), token via proxy(+2 impl, +3 proxy)
        address predictedToken = vm.computeCreateAddress(address(this), currentNonce + 3);

        bondVault = ProxyDeployer.deployBondVault(
            predictedToken, // lumina (predicted)
            address(claimBond), // claimBond
            address(capacityOracle), // priceOracle
            address(0) // policyManager (set later via one-shot)
        );

        // Deploy token with real bondVault address
        token = ProxyDeployer.deployLuminaTokenV2(
            address(bondVault), cexReserve, founderVesting, lbpDeposit, treasuryVesting
        );
        require(address(token) == predictedToken, "Token address prediction failed");

        // --- Phase 4: Deploy SwapRouter mock ---
        swapRouter = new MockSwapRouter_FSI(address(token));
        deal(address(token), address(swapRouter), 5_000_000e18);

        // --- Phase 5: Wire ClaimBond -> BondVault ---
        claimBond.setBondVault(address(bondVault));

        // --- Phase 6: Deploy SolvencyOracle + AdaptiveFeeDistributor ---
        solvencyOracle = ProxyDeployer.deploySolvencyOracle(address(bondVault), address(capacityOracle), admin);
        feeDistributor = ProxyDeployer.deployAdaptiveFeeDistributor(address(solvencyOracle));

        // --- Phase 7: Deploy TWAPBurner ---
        twapBurner = ProxyDeployer.deployTWAPBurner(address(usdc), address(token), address(swapRouter));
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));

        // --- Phase 8: Deploy PolicyManagerV2 + CoverRouterV2 ---
        policyManager = ProxyDeployer.deployPolicyManagerV2(address(bondVault));
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));

        // Wire PolicyManager -> Router
        policyManager.setRouter(address(coverRouter));

        // Wire BondVault -> PolicyManager (one-shot)
        bondVault.setPolicyManager(address(policyManager));

        // --- Phase 9: Wire TWAPBurner adaptive mode ---
        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(buybackReserve, opsReserve, maintenanceReserve);
        twapBurner.setCapacityOracle(address(capacityOracle));
        twapBurner.setAuthorizedSender(address(coverRouter), true);
        twapBurner.setAdaptiveMode(true);

        // --- Phase 10: Deploy & register mock shield ---
        mockShield = new MockShieldV2_FSI(PRODUCT_ID);
        policyManager.registerProduct(PRODUCT_ID, address(mockShield));

        // --- Phase 11: Configure product in CoverRouter ---
        coverRouter.configureProduct(
            PRODUCT_ID,
            8000, // 80% payout ratio
            200, // 2% trigger probability
            15000, // 1.5x margin
            3600, // 1 hour duration
            true
        );

        // --- Phase 12: Fund buyers with USDC ---
        usdc.mint(buyer1, 10_000_000e6);
        usdc.mint(buyer2, 10_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 1: Full Day Operation Cycle
    //  Deploy -> Issue 10 bonds -> TWAPBurner burn -> SolvencyOracle
    //  evaluate -> Verify cross-contract state consistency
    // ═══════════════════════════════════════════════════════════════

    function test_Integration_FullDay_OperationCycle() public {
        // --- Verify initial state ---
        assertEq(token.balanceOf(address(bondVault)), 70_000_000e18, "BondVault should hold 70M LUMINA");
        assertEq(bondVault.totalCommittedUSD(), 0, "No commitments initially");
        assertEq(policyManager.totalPolicies(), 0, "No policies initially");

        // --- Issue 10 bonds via policy purchase + trigger ---
        uint256 coverageAmount = 1000e6; // $1,000 per policy
        uint256 expectedPremium = (coverageAmount * 8000 * 200 * 15000) / (10000 * 10000 * 10000);
        uint256 totalPremiums;

        for (uint256 i = 0; i < 10; i++) {
            address buyer = i % 2 == 0 ? buyer1 : buyer2;

            // Purchase policy
            vm.startPrank(buyer);
            usdc.approve(address(coverRouter), type(uint256).max);
            coverRouter.purchasePolicy(PRODUCT_ID, coverageAmount, "BTC");
            vm.stopPrank();
            totalPremiums += expectedPremium;

            // Trigger payout -> issues bond
            coverRouter.submitTrigger(PRODUCT_ID, i + 1, "");
        }

        // --- Verify bond state ---
        // Each policy: coverage $1000, payout 80% = $800
        uint256 expectedCommitment = 800 * 10 * 1e18; // 10 bonds x $800 in 18-dec
        assertEq(bondVault.totalCommittedUSD(), expectedCommitment, "Total committed should be $8,000");
        assertEq(policyManager.totalPolicies(), 10, "Should have 10 policies");
        assertEq(policyManager.totalTriggers(), 10, "Should have 10 triggers");

        // --- Verify premiums reached TWAPBurner ---
        assertEq(usdc.balanceOf(address(twapBurner)), totalPremiums, "TWAPBurner should hold all premiums");

        // --- Execute TWAPBurner burn (adaptive mode) ---
        uint256 supplyBefore = token.totalSupply();
        twapBurner.executeBurn();

        // Verify burn happened — supply decreased
        uint256 supplyAfter = token.totalSupply();
        assertTrue(supplyAfter < supplyBefore, "LUMINA supply should decrease after burn");
        assertGt(twapBurner.totalLUMINABurned(), 0, "Should have burned LUMINA");

        // Verify adaptive distribution sent funds to reserves
        // Default quadrant is (1,1) = Healthy/Stable = 8500/800/200/500 bps
        uint256 expectedBuyback = (totalPremiums * 800) / 10000;
        uint256 expectedOps = (totalPremiums * 200) / 10000;
        uint256 expectedMaint = (totalPremiums * 500) / 10000;

        assertEq(usdc.balanceOf(buybackReserve), expectedBuyback, "Buyback reserve should receive 8%");
        assertEq(usdc.balanceOf(opsReserve), expectedOps, "Ops reserve should receive 2%");
        assertEq(usdc.balanceOf(maintenanceReserve), expectedMaint, "Maintenance reserve should receive 5%");

        // --- Evaluate SolvencyOracle ---
        // Warp past evaluation interval (1 day)
        vm.warp(block.timestamp + 1 days + 1);
        solvencyOracle.evaluate();

        // SolvencyOracle should report healthy (massive reserves vs small obligations)
        assertTrue(solvencyOracle.isHealthy(), "Oracle should be healthy");
        (uint8 sLevel, uint8 mLevel) = solvencyOracle.getCurrentQuadrant();
        // With 70M LUMINA at $0.036 = $2.52M reserve vs $8K committed -> ultra or healthy
        // (3-day smoothing means level may be 0 or 1 depending on history initialization)
        assertLe(sLevel, 1, "Solvency should be Ultra or Healthy with massive reserves");

        // --- Cross-contract consistency ---
        // AdaptiveFeeDistributor reads from SolvencyOracle
        assertTrue(feeDistributor.isHealthy(), "FeeDistributor should be healthy");
        (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintBps) = feeDistributor.getDistribution();
        // Ultra/Stable (0,1) -> 9000/500/0/500
        assertEq(burnBps + buybackBps + opsBps + maintBps, 10000, "Distribution should sum to 100%");

        // BondVault capacity is consistent with oracle
        uint256 capacity = bondVault.availableCapacityUSD();
        assertGt(capacity, 0, "Should have remaining capacity");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 2: Oracle Chain — CapacityOracle -> SolvencyOracle
    //  -> AdaptiveFeeDistributor -> TWAPBurner
    // ═══════════════════════════════════════════════════════════════

    function test_Integration_OracleChain_CapacityToDistributor() public {
        // --- Step 1: CapacityOracle.getLuminaPrice() feeds into SolvencyOracle ---
        uint256 oraclePrice = capacityOracle.getLuminaPrice();
        assertEq(oraclePrice, EMERGENCY_PRICE, "CapacityOracle should return $0.036");

        // Issue a bond to create obligations (need non-zero for meaningful solvency)
        vm.startPrank(buyer1);
        usdc.approve(address(coverRouter), type(uint256).max);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();
        coverRouter.submitTrigger(PRODUCT_ID, 1, "");

        // --- Step 2: SolvencyOracle.evaluate() updates quadrant ---
        vm.warp(block.timestamp + 1 days + 1);
        solvencyOracle.evaluate();

        uint256 solvencyRatio = solvencyOracle.getSolvencyRatio();
        assertGt(solvencyRatio, 0, "Solvency ratio should be non-zero");
        // 70M LUMINA * $0.036 = $2.52M / $800 obligations -> massive solvency
        assertTrue(solvencyRatio > 20000, "Solvency ratio should be ultra (>200%)");

        (uint8 sLevel, uint8 mLevel) = solvencyOracle.getCurrentQuadrant();

        // --- Step 3: AdaptiveFeeDistributor returns correct values for quadrant ---
        (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintBps) = feeDistributor.getDistribution();
        // Verify against hardcoded matrix
        (uint256 expectedBurn, uint256 expectedBuyback, uint256 expectedOps, uint256 expectedMaint) =
            feeDistributor.lookupDistribution(sLevel, mLevel);
        assertEq(burnBps, expectedBurn, "Burn bps should match matrix");
        assertEq(buybackBps, expectedBuyback, "Buyback bps should match matrix");
        assertEq(opsBps, expectedOps, "Ops bps should match matrix");
        assertEq(maintBps, expectedMaint, "Maint bps should match matrix");
        assertEq(burnBps + buybackBps + opsBps + maintBps, 10000, "Distribution must sum to 10000");

        // --- Step 4: TWAPBurner uses the distribution ---
        usdc.mint(address(twapBurner), 10_000e6);

        uint256 buybackBefore = usdc.balanceOf(buybackReserve);
        uint256 opsBefore = usdc.balanceOf(opsReserve);
        uint256 maintBefore = usdc.balanceOf(maintenanceReserve);

        twapBurner.executeBurn();

        // Verify funds were split according to the distribution from the oracle chain
        uint256 totalDistributed = 10_000e6;
        uint256 buybackExpected = (totalDistributed * buybackBps) / 10000;
        uint256 opsExpected = (totalDistributed * opsBps) / 10000;
        uint256 maintExpected = (totalDistributed * maintBps) / 10000;

        assertEq(
            usdc.balanceOf(buybackReserve) - buybackBefore, buybackExpected, "Buyback reserve received incorrect amount"
        );
        assertEq(usdc.balanceOf(opsReserve) - opsBefore, opsExpected, "Ops reserve received incorrect amount");
        assertEq(
            usdc.balanceOf(maintenanceReserve) - maintBefore,
            maintExpected,
            "Maintenance reserve received incorrect amount"
        );

        // Verify LUMINA was burned (burn bucket > 0)
        assertGt(twapBurner.totalLUMINABurned(), 0, "LUMINA should have been burned");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 3: Emergency Fallback
    //  Pause SolvencyOracle -> isHealthy() false -> TWAPBurner
    //  uses fallback distribution 8500/800/200/500
    // ═══════════════════════════════════════════════════════════════

    function test_Integration_EmergencyFallback() public {
        // --- Verify healthy before pause ---
        assertTrue(feeDistributor.isHealthy(), "Should be healthy before pause");
        assertTrue(solvencyOracle.isHealthy(), "SolvencyOracle should be healthy");

        // --- Admin pauses SolvencyOracle ---
        vm.prank(admin);
        solvencyOracle.setEmergencyPause(true);

        // --- Verify isHealthy returns false throughout chain ---
        assertTrue(solvencyOracle.emergencyPaused(), "SolvencyOracle should be paused");
        assertFalse(solvencyOracle.isHealthy(), "SolvencyOracle.isHealthy should be false");
        assertFalse(feeDistributor.isHealthy(), "FeeDistributor.isHealthy should be false");

        // --- Fund TWAPBurner and execute burn ---
        usdc.mint(address(twapBurner), 10_000e6);

        uint256 buybackBefore = usdc.balanceOf(buybackReserve);
        uint256 opsBefore = usdc.balanceOf(opsReserve);
        uint256 maintBefore = usdc.balanceOf(maintenanceReserve);
        uint256 supplyBefore = token.totalSupply();

        twapBurner.executeBurn();

        // --- Verify fallback distribution 8500/800/200/500 ---
        uint256 totalAmount = 10_000e6;
        uint256 expectedBuyback = (totalAmount * 800) / 10000; // 800 USDC
        uint256 expectedOps = (totalAmount * 200) / 10000; // 200 USDC
        uint256 expectedMaint = (totalAmount * 500) / 10000; // 500 USDC
        // Burn portion = 8500 bps = 8500 USDC -> swapped to LUMINA and burned

        assertEq(
            usdc.balanceOf(buybackReserve) - buybackBefore,
            expectedBuyback,
            "Fallback: buyback should receive 800 USDC (8%)"
        );
        assertEq(usdc.balanceOf(opsReserve) - opsBefore, expectedOps, "Fallback: ops should receive 200 USDC (2%)");
        assertEq(
            usdc.balanceOf(maintenanceReserve) - maintBefore,
            expectedMaint,
            "Fallback: maintenance should receive 500 USDC (5%)"
        );

        // Verify LUMINA was burned (85% of premium -> swap -> burn)
        uint256 supplyAfter = token.totalSupply();
        assertTrue(supplyAfter < supplyBefore, "LUMINA supply should decrease from 85% burn");
        assertGt(twapBurner.totalLUMINABurned(), 0, "Should have burned LUMINA from fallback burn portion");

        // --- Unpause and verify recovery ---
        vm.prank(admin);
        solvencyOracle.setEmergencyPause(false);
        assertTrue(feeDistributor.isHealthy(), "Should be healthy after unpause");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 4: CoverRouterV2 Auto-Pause Full Cycle
    //  Set capacity oracle -> drop price -> auto-pause blocks new
    //  policies -> raise price -> policies work again
    // ═══════════════════════════════════════════════════════════════

    function test_Integration_AutoPause_FullCycle() public {
        // --- Step 1: Set capacity oracle on CoverRouter ---
        coverRouter.setCapacityOracle(address(capacityOracle));

        // --- Step 2: Issue a bond while system is healthy ---
        vm.startPrank(buyer1);
        usdc.approve(address(coverRouter), type(uint256).max);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();
        coverRouter.submitTrigger(PRODUCT_ID, 1, "");

        // Verify bond was issued: $800 committed (80% of $1000)
        assertEq(bondVault.totalCommittedUSD(), 800 * 1e18, "Should have $800 committed");

        // Find the epoch for the issued bond
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;
        assertEq(claimBond.balanceOf(buyer1, epochId), 800, "Buyer1 should hold 800 bond tokens");

        // --- Step 3: Drop price below MIN_PRICE_FOR_NEW_POLICIES ($0.005) ---
        capacityOracle.setPrice(0.004e18); // $0.004

        // Verify auto-pause is active
        assertTrue(coverRouter.isProtocolAutoPaused(), "Protocol should be auto-paused");

        // --- Step 4: Verify new policy purchase is blocked ---
        vm.startPrank(buyer2);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.expectRevert("Protocol auto-paused: LUMINA price below safety threshold");
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        // --- Step 5: Verify redemption still works ---
        vm.warp(block.timestamp + 731 days);
        capacityOracle.setPrice(EMERGENCY_PRICE); // restore to $0.036

        assertTrue(claimBond.isMatured(epochId), "Bonds should be matured");

        uint256 luminaBefore = token.balanceOf(buyer1);
        vm.prank(buyer1);
        bondVault.redeemBond(epochId, 400); // partial redeem: $400 worth

        uint256 luminaAfter = token.balanceOf(buyer1);
        assertGt(luminaAfter, luminaBefore, "Buyer should receive LUMINA");
        assertEq(claimBond.balanceOf(buyer1, epochId), 400, "Should have 400 bonds remaining");

        // Verify commitment tracking updated
        assertEq(bondVault.totalCommittedUSD(), 400 * 1e18, "Committed should be $400 after partial redeem");

        // --- Step 6: Verify policy purchase works again with healthy price ---
        assertFalse(coverRouter.isProtocolAutoPaused(), "Protocol should not be auto-paused");

        vm.startPrank(buyer2);
        usdc.approve(address(coverRouter), type(uint256).max);
        coverRouter.purchasePolicy(PRODUCT_ID, 500e6, "BTC");
        vm.stopPrank();

        // This should succeed now
        coverRouter.submitTrigger(PRODUCT_ID, 2, "");

        // New bond: $500 * 80% = $400
        assertEq(bondVault.totalCommittedUSD(), 800 * 1e18, "Committed should be $800 after new issuance");

        // Final: redeem remaining bonds from first bond
        vm.prank(buyer1);
        bondVault.redeemBond(epochId, 400);
        assertEq(claimBond.balanceOf(buyer1, epochId), 0, "All bonds redeemed");
        assertEq(bondVault.totalCommittedUSD(), 400 * 1e18, "Only new bond committed remains");
    }

    // ═══════ HELPER ═══════

    function _timestampToEpoch(uint256 ts) internal pure returns (uint256) {
        require(ts >= BASE_TS, "Before base");
        uint256 monthsFromBase = (ts - BASE_TS) / 2629746;
        uint256 yr = 2026 + monthsFromBase / 12;
        uint256 mo = 1 + monthsFromBase % 12;
        return yr * 100 + mo;
    }
}
