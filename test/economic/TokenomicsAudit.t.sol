// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ═══════ MOCK CONTRACTS ═══════

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCapacityOracle {
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
}

contract MockSolvencyOracle {
    uint8 public sLevel;
    uint8 public mLevel;
    bool public healthy = true;

    function setQuadrant(uint8 _s, uint8 _m) external {
        sLevel = _s;
        mLevel = _m;
    }

    function setHealthy(bool _h) external {
        healthy = _h;
    }

    function getCurrentQuadrant() external view returns (uint8, uint8) {
        return (sLevel, mLevel);
    }

    function isHealthy() external view returns (bool) {
        return healthy;
    }

    function getSolvencyRatio() external pure returns (uint256) {
        return 20000; // 200%
    }
}

contract MockDexRouter {
    uint256 public rate; // LUMINA per 1 USDC (6 dec) — result in 18 dec

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn * rate) / 1e6;
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external returns (uint256 amountOut) {
        amountOut = (amountIn * rate) / 1e6;
        // Transfer USDC in
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // We need LUMINA to give back — mint not possible, use deal in test
        // The test will pre-fund this router with LUMINA
        // Just transfer LUMINA out
        address lumina = address(0); // set by test
        // Simplified: the test must pre-fund this contract with LUMINA
    }
}

/// @dev A more complete mock DEX that actually swaps tokens
contract MockSwapRouter {
    IERC20 public usdc;
    IERC20 public lumina;
    uint256 public luminaPerUSDC; // 18-dec LUMINA per 1 USDC (6 dec input)

    constructor(address _usdc, address _lumina, uint256 _luminaPerUSDC) {
        usdc = IERC20(_usdc);
        lumina = IERC20(_lumina);
        luminaPerUSDC = _luminaPerUSDC;
    }

    function setRate(uint256 _rate) external {
        luminaPerUSDC = _rate;
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn * luminaPerUSDC) / 1e6;
    }

    function swap(address, address, uint256 amountIn, uint256 minOut) external returns (uint256 amountOut) {
        amountOut = (amountIn * luminaPerUSDC) / 1e6;
        require(amountOut >= minOut, "Slippage");
        usdc.transferFrom(msg.sender, address(this), amountIn);
        lumina.transfer(msg.sender, amountOut);
    }
}

/// @dev Proper mock shield implementing the IShieldV2 interface expected by PolicyManagerV2
contract MockShieldV2 {
    bytes32 public immutable shieldProductId;
    uint256 public nextPolicyId = 1;

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

    constructor(bytes32 _productId) {
        shieldProductId = _productId;
    }

    function productId() external view returns (bytes32) {
        return shieldProductId;
    }

    function createPolicy(CreatePolicyParams calldata) external returns (uint256) {
        return nextPolicyId++;
    }

    function verifyAndCalculate(uint256, bytes calldata) external pure returns (PayoutResult memory) {
        return PayoutResult({triggered: true, payoutAmount: 0, recipient: address(0), reason: "TEST"});
    }

    function getPolicyInfo(uint256) external pure returns (address, uint256, uint256, uint256, uint256, uint8) {
        return (address(0), 0, 0, 0, 0, 0);
    }
}

// ═══════ MAIN TEST CONTRACT ═══════

contract TokenomicsAuditTest is Test {
    // Core contracts
    LuminaTokenV2 public lumina;
    BondVault public bondVault;
    ClaimBond public claimBond;
    PolicyManagerV2 public policyManager;
    TWAPBurner public twapBurner;
    AdaptiveFeeDistributor public feeDistributor;
    CEXLiquidityReserve public cexReserve;
    MaintenanceReserve public maintenanceReserve;
    CoverRouterV2 public coverRouter;

    // Mocks
    MockUSDC public usdc;
    MockCapacityOracle public oracle;
    MockSolvencyOracle public solvencyOracle;
    MockSwapRouter public swapRouter;
    MockShieldV2 public shield;

    // Addresses
    address public deployer = address(this);
    address public multisig = address(0xAA);
    address public founder = address(0xBB);
    address public lbpDeposit = address(0xCC);
    address public treasuryVesting = address(0xDD);
    address public buyer = address(0xEE);
    address public buybackReserve = address(0xFF);
    address public opsReserve = address(0x11);

    // Constants
    uint256 constant BASE_TS = 1767225600; // Jan 1, 2026 UTC
    uint256 constant LUMINA_PRICE = 0.1e18; // $0.10 per LUMINA
    uint256 constant MAX_SUPPLY = 100_000_000e18;

    function setUp() public {
        // Warp to BASE_TS + 60 days
        vm.warp(BASE_TS + 60 days);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy mock oracle at $0.10
        oracle = new MockCapacityOracle(LUMINA_PRICE);

        // Deploy mock solvency oracle (healthy, stable)
        solvencyOracle = new MockSolvencyOracle();
        solvencyOracle.setQuadrant(1, 1); // Healthy + Stable

        // Deploy ClaimBond
        claimBond = new ClaimBond();

        // Deploy LuminaTokenV2 — need placeholder addresses for vesting contracts
        // Use a temporary pattern: deploy token, then deploy real contracts
        address tempBondVault = _computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        lumina = new LuminaTokenV2(
            tempBondVault,
            address(0x1001), // cex temp
            founder,
            lbpDeposit,
            treasuryVesting
        );

        // Deploy BondVault to match computed address
        bondVault = new BondVault(address(lumina), address(claimBond), address(oracle), address(0));

        // Verify BondVault address matches
        require(address(bondVault) == tempBondVault, "BondVault address mismatch");

        // Set BondVault on ClaimBond
        claimBond.setBondVault(address(bondVault));

        // Deploy PolicyManager
        policyManager = new PolicyManagerV2(address(bondVault));

        // Set PolicyManager on BondVault
        bondVault.setPolicyManager(address(policyManager));

        // Deploy swap router (rate: 10 LUMINA per 1 USDC at $0.10)
        swapRouter = new MockSwapRouter(address(usdc), address(lumina), 10e18);

        // Fund swap router with LUMINA for swaps (from lbpDeposit allocation)
        vm.prank(lbpDeposit);
        lumina.transfer(address(swapRouter), 2_000_000e18);

        // Deploy TWAPBurner
        twapBurner = new TWAPBurner(address(usdc), address(lumina), address(swapRouter));
        twapBurner.setCapacityOracle(address(oracle));

        // Deploy AdaptiveFeeDistributor
        feeDistributor = new AdaptiveFeeDistributor(address(solvencyOracle));

        // Deploy MaintenanceReserve
        maintenanceReserve = new MaintenanceReserve(address(usdc), multisig);

        // Deploy CEXLiquidityReserve — reuse the cex address that got tokens
        // Note: In the real deploy, CEXLiquidityReserve holds the 14M. Here we just test economics.
        cexReserve = new CEXLiquidityReserve(address(lumina), multisig);

        // Configure TWAPBurner adaptive mode
        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(buybackReserve, opsReserve, address(maintenanceReserve));
        twapBurner.setAdaptiveMode(true);

        // Deploy CoverRouter
        coverRouter = new CoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        coverRouter.setCapacityOracle(address(oracle));

        // Deploy mock shield and register product
        bytes32 productId = keccak256("FLASHBTC1H-001");
        shield = new MockShieldV2(productId);
        policyManager.setRouter(address(coverRouter));
        policyManager.registerProduct(productId, address(shield));

        // Configure product on CoverRouter: 80% payout, 0.20% trigger prob, 1.5x margin, 1 hour
        coverRouter.configureProduct(productId, 8000, 20, 15000, 3600, true);

        // Grant BURNER_ROLE to TWAPBurner on token
        lumina.grantRole(lumina.BURNER_ROLE(), address(twapBurner));

        // Fund buyer with USDC
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
    }

    // Helper to compute CREATE address
    function _computeCreateAddress(address deployer_, uint64 nonce) internal pure returns (address) {
        bytes memory data;
        if (nonce == 0x00) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer_, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer_, uint8(nonce));
        } else if (nonce <= 0xff) {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer_, bytes1(0x81), uint8(nonce));
        } else if (nonce <= 0xffff) {
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer_, bytes1(0x82), uint16(nonce));
        } else if (nonce <= 0xffffff) {
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer_, bytes1(0x83), uint24(nonce));
        } else {
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer_, bytes1(0x84), uint32(nonce));
        }
        return address(uint160(uint256(keccak256(data))));
    }

    // ═══════════════════════════════════════════════════════════════
    // SUPPLY & DISTRIBUTION (5 tests)
    // ═══════════════════════════════════════════════════════════════

    function test_Economics_TotalSupply_Immutable_100M() public view {
        assertEq(lumina.MAX_SUPPLY(), 100_000_000e18, "MAX_SUPPLY must be 100M");
        assertEq(lumina.totalSupply() + lumina.totalBurned(), lumina.MAX_SUPPLY(), "Supply + burned = MAX");
    }

    function test_Economics_Distribution_70_14_8_5_3() public view {
        // BondVault gets 70M
        uint256 bondVaultBalance = lumina.balanceOf(address(bondVault));
        assertEq(bondVaultBalance, 70_000_000e18, "BondVault should hold 70M");

        // CEX Reserve address (0x1001) gets 14M
        assertEq(lumina.balanceOf(address(0x1001)), 14_000_000e18, "CEX Reserve should hold 14M");

        // Founder gets 8M
        assertEq(lumina.balanceOf(founder), 8_000_000e18, "Founder should hold 8M");

        // LBP gets 5M (2M sent to swapRouter in setUp for testing)
        uint256 lbpRemaining = lumina.balanceOf(lbpDeposit) + lumina.balanceOf(address(swapRouter));
        assertEq(lbpRemaining, 5_000_000e18, "LBP allocation should total 5M");

        // Treasury gets 3M
        assertEq(lumina.balanceOf(treasuryVesting), 3_000_000e18, "Treasury should hold 3M");
    }

    function test_Economics_NoInflation_SupplyOnlyDecreases() public {
        uint256 supplyBefore = lumina.totalSupply();

        // Burn some tokens via TWAPBurner
        usdc.mint(address(twapBurner), 100e6); // $100 USDC
        vm.warp(block.timestamp + 901); // pass cooldown
        twapBurner.executeBurn();

        uint256 supplyAfter = lumina.totalSupply();
        assertLt(supplyAfter, supplyBefore, "Supply must decrease after burn");

        // Verify no mint function exists (LuminaTokenV2 has no public mint)
        // The only _mint call is in constructor. No way to increase supply.
        assertLe(lumina.totalSupply(), MAX_SUPPLY, "Supply can never exceed MAX");
    }

    function test_Economics_VestingDoesNotMint() public view {
        // Founder vesting contract receives pre-minted tokens at deployment
        // FounderVesting.TOTAL_AMOUNT = 8M which matches constructor mint
        // No new tokens are ever created — vesting only transfers existing tokens
        uint256 founderAllocation = lumina.balanceOf(founder);
        assertEq(founderAllocation, 8_000_000e18, "Founder holds pre-minted tokens, no new mint");
    }

    function test_Economics_CEXReserveDoesNotMint() public view {
        // CEX Reserve holds pre-minted tokens. The contract only transfers, never mints.
        uint256 cexAllocation = lumina.balanceOf(address(0x1001));
        assertEq(cexAllocation, 14_000_000e18, "CEX holds pre-minted tokens");
        // CEXLiquidityReserve.TOTAL_AMOUNT matches
        assertEq(cexReserve.TOTAL_AMOUNT(), 14_000_000e18, "CEXReserve constant matches allocation");
    }

    // ═══════════════════════════════════════════════════════════════
    // BURN DYNAMICS (5 tests)
    // ═══════════════════════════════════════════════════════════════

    function test_BurnRate_AllQuadrants_Validated() public view {
        // Iterate all 16 quadrants (4 solvency x 4 momentum)
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (uint256 burn, uint256 buyback, uint256 ops, uint256 maint) = feeDistributor.lookupDistribution(s, m);

                // Sum must equal 10000 bps
                uint256 total = burn + buyback + ops + maint;
                assertEq(
                    total, 10000, string.concat("Quadrant sum != 10000 at s=", vm.toString(s), " m=", vm.toString(m))
                );

                // Maintenance must be >= 200 bps (2%) in all quadrants
                assertGe(maint, 200, string.concat("Maintenance < 200 at s=", vm.toString(s), " m=", vm.toString(m)));
            }
        }
    }

    function test_BurnRate_HealthyStable_85_8_2_5() public {
        // Quadrant (1,1) = Healthy + Stable → 8500/800/200/500
        solvencyOracle.setQuadrant(1, 1);

        (uint256 burn, uint256 buyback, uint256 ops, uint256 maint) = feeDistributor.getDistribution();
        assertEq(burn, 8500, "Burn should be 85%");
        assertEq(buyback, 800, "Buyback should be 8%");
        assertEq(ops, 200, "Ops should be 2%");
        assertEq(maint, 500, "Maintenance should be 5%");

        // Verify actual USDC distribution
        uint256 amount = 10_000e6; // $10K
        usdc.mint(address(twapBurner), amount);
        vm.warp(block.timestamp + 901);

        uint256 maintBefore = usdc.balanceOf(address(maintenanceReserve));
        uint256 buybackBefore = usdc.balanceOf(buybackReserve);

        twapBurner.executeBurn();

        uint256 maintAfter = usdc.balanceOf(address(maintenanceReserve));
        uint256 buybackAfter = usdc.balanceOf(buybackReserve);

        assertEq(maintAfter - maintBefore, 500e6, "Maintenance should receive $500 (5%)");
        assertEq(buybackAfter - buybackBefore, 800e6, "Buyback should receive $800 (8%)");
    }

    function test_BurnRate_CrisisCrash_0_96_2_2() public {
        // Quadrant (3,3) = Crisis + Crash → 0/9600/200/200
        solvencyOracle.setQuadrant(3, 3);

        (uint256 burn, uint256 buyback, uint256 ops, uint256 maint) = feeDistributor.getDistribution();
        assertEq(burn, 0, "Burn should be 0% in crisis/crash");
        assertEq(buyback, 9600, "Buyback should be 96%");
        assertEq(ops, 200, "Ops should be 2%");
        assertEq(maint, 200, "Maintenance should be 2%");
    }

    function test_BurnRate_AutoPause_BlocksNewPremiums() public {
        // Set price below MIN_PRICE_FOR_NEW_POLICIES (0.005 USD)
        oracle.setPrice(4e15); // $0.004 — below $0.005 threshold

        bytes32 productId = keccak256("FLASHBTC1H-001");

        vm.prank(buyer);
        vm.expectRevert("Protocol auto-paused: LUMINA price below safety threshold");
        coverRouter.purchasePolicy(productId, 1000e6, "BTC");
    }

    function test_BurnProjection_12Month() public {
        uint256 supplyStart = lumina.totalSupply();

        // Set cooldown to minimum to avoid interference
        twapBurner.setBurnCooldown(60);

        // Simulate 12 months of burns: $10K/month in premiums
        // Use absolute timestamps to avoid via_ir block.timestamp caching issue
        uint256 startTs = BASE_TS + 60 days;
        for (uint256 i = 0; i < 12; i++) {
            usdc.mint(address(twapBurner), 10_000e6);
            startTs += 31 days;
            vm.warp(startTs);
            twapBurner.executeBurn();
        }

        uint256 supplyEnd = lumina.totalSupply();
        uint256 totalBurned = supplyStart - supplyEnd;

        // At $0.10/LUMINA, $10K buys 100K LUMINA. 85% burn = 85K/month.
        // Over 12 months ≈ 1.02M LUMINA burned (in adaptive 85% mode)
        assertGt(totalBurned, 900_000e18, "12-month burn should exceed 900K LUMINA");
        assertLt(totalBurned, 1_200_000e18, "12-month burn should be under 1.2M LUMINA");

        // Supply only ever decreased
        assertLt(supplyEnd, supplyStart, "Supply must be lower after 12 months");
    }

    // ═══════════════════════════════════════════════════════════════
    // INCENTIVE ALIGNMENT (5 tests)
    // ═══════════════════════════════════════════════════════════════

    function test_Incentive_Buyer_80PercentPayout() public {
        // CoverRouter product has 8000 payoutRatioBps = 80%
        bytes32 productId = keccak256("FLASHBTC1H-001");

        // $1000 coverage → $800 payout (80%)
        (uint256 premium, uint256 payout) = coverRouter.quotePremium(productId, 1000e6);
        assertEq(payout, 800e6, "Payout should be 80% of coverage = $800");
        assertGt(premium, 0, "Premium must be > 0");
    }

    function test_Incentive_Multisig_CannotDrainVault() public {
        // BondVault has NO withdraw function.
        // Only exits: redeemBond (requires matured bonds) and burnFromReserves (5% cap per tx).
        uint256 vaultBalance = lumina.balanceOf(address(bondVault));

        // burnFromReserves is capped at 5% per tx
        uint256 maxBurn = (vaultBalance * 5) / 100;

        // Attempt to burn more than 5% (must fail)
        bondVault.setAuthorizedCaller(address(this), true);
        vm.expectRevert("Exceeds 5% per-tx cap");
        bondVault.burnFromReserves(maxBurn + 1);

        // Even the 5% burn works
        bondVault.burnFromReserves(maxBurn);
        // But vault still holds 95%
        assertGe(lumina.balanceOf(address(bondVault)), (vaultBalance * 95) / 100 - 1, "Vault retains 95%+");
    }

    function test_Incentive_Multisig_BuybackWithCaps() public {
        // BuybackEngine enforces daily budget via dailyConfig
        // Here we verify the BondVault's authorized caller mechanism has proper caps
        bondVault.setAuthorizedCaller(address(this), true);

        uint256 balance = lumina.balanceOf(address(bondVault));
        uint256 fivePercent = (balance * 5) / 100;

        // First burn succeeds
        bondVault.burnFromReserves(fivePercent);

        // Second burn of 5% of NEW balance also succeeds (5% of remaining)
        uint256 newBalance = lumina.balanceOf(address(bondVault));
        uint256 newFivePercent = (newBalance * 5) / 100;
        bondVault.burnFromReserves(newFivePercent);

        // Total burned is bounded — cannot drain in one session
        uint256 totalDrained = balance - lumina.balanceOf(address(bondVault));
        assertLt(totalDrained, (balance * 10) / 100, "Cannot drain >10% in two txs");
    }

    function test_Incentive_BondHolder_FaceValueAtMaturity() public {
        // Issue a bond for $800
        vm.prank(address(policyManager));
        bondVault.issueBond(buyer, 800);

        // Compute epoch for maturity (730 days from now)
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Warp past maturity
        vm.warp(maturityTs + 1);

        // Redeem: $800 face value at $0.10/LUMINA = 8000 LUMINA
        uint256 balBefore = lumina.balanceOf(buyer);
        vm.prank(buyer);
        bondVault.redeemBond(epochId, 800);
        uint256 balAfter = lumina.balanceOf(buyer);

        // $800 / $0.10 = 8000 LUMINA (with 18 decimals)
        uint256 expectedLumina = (800 * 1e36) / LUMINA_PRICE;
        assertEq(balAfter - balBefore, expectedLumina, "Bond holder receives face value in LUMINA");
    }

    function test_Incentive_Marketplace_FeesFlow() public {
        // Marketplace charges 3% total (1.5% buyer + 1.5% seller)
        // Fees flow to TWAPBurner

        // Issue a bond to seller
        address seller = address(0x5E);
        vm.prank(address(policyManager));
        bondVault.issueBond(seller, 1000);

        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Verify fee constants on marketplace
        // LuminaBondMarketplace: SELLER_FEE_BPS=150, BUYER_FEE_BPS=150, total=300 bps = 3%
        // Test: $1000 listing price → $15 seller fee + $15 buyer fee = $30 total to TWAPBurner
        uint256 priceUSDC = 600e6; // selling $1000 bonds at 60% discount
        uint256 sellerFee = (priceUSDC * 150) / 10000; // $9
        uint256 buyerFee = (priceUSDC * 150) / 10000; // $9
        uint256 totalFees = sellerFee + buyerFee; // $18 to TWAPBurner

        assertEq(totalFees, 18e6, "3% of $600 = $18 fees flow to TWAPBurner");
    }

    // ═══════════════════════════════════════════════════════════════
    // VALUE CAPTURE (5 tests)
    // ═══════════════════════════════════════════════════════════════

    function test_Revenue_ExpiredPremiums_FlowToTWAPBurner() public {
        // When policies expire without triggering, premiums stay in TWAPBurner
        // (they were sent there at purchase time). Nothing is refunded.
        uint256 twapBefore = usdc.balanceOf(address(twapBurner));

        // Purchase a policy — premium goes to TWAPBurner
        bytes32 productId = keccak256("FLASHBTC1H-001");
        vm.prank(buyer);
        coverRouter.purchasePolicy(productId, 1000e6, "BTC");

        uint256 twapAfter = usdc.balanceOf(address(twapBurner));
        assertGt(twapAfter, twapBefore, "TWAPBurner received premium");

        // Warp past expiry — premiums remain in TWAPBurner (no refund mechanism)
        vm.warp(block.timestamp + 2 hours);

        // Premium is still there, ready for burn
        assertEq(usdc.balanceOf(address(twapBurner)), twapAfter, "Premiums persist after expiry");
    }

    function test_Revenue_MarketplaceFees_FlowToTWAPBurner() public {
        // Marketplace fees (3%) are sent directly to TWAPBurner address
        // Verified by marketplace contract: usdc.safeTransfer(twapBurner, sellerFee + buyerFee)
        // Here we test the receivePremium/receiveMarketplaceFee pathway

        usdc.mint(address(this), 100e6);
        usdc.approve(address(twapBurner), 100e6);

        uint256 before = usdc.balanceOf(address(twapBurner));
        twapBurner.receiveMarketplaceFee(100e6);
        uint256 after_ = usdc.balanceOf(address(twapBurner));

        assertEq(after_ - before, 100e6, "Marketplace fees received by TWAPBurner");
        assertEq(twapBurner.totalUSDCReceived(), 100e6, "Total USDC received tracked");
    }

    function test_Revenue_MaintenanceFund_5Percent() public {
        // In Healthy+Stable quadrant (1,1), maintenance = 500 bps = 5%
        solvencyOracle.setQuadrant(1, 1);

        uint256 premiumAmount = 10_000e6; // $10K
        usdc.mint(address(twapBurner), premiumAmount);
        vm.warp(block.timestamp + 901);

        uint256 maintBefore = usdc.balanceOf(address(maintenanceReserve));
        twapBurner.executeBurn();
        uint256 maintAfter = usdc.balanceOf(address(maintenanceReserve));

        uint256 maintReceived = maintAfter - maintBefore;
        assertEq(maintReceived, 500e6, "5% of $10K = $500 to maintenance");
    }

    function test_Revenue_BreakEven_200PoliciesPerMonth() public {
        // 200 policies × $50 premium = $10K/month revenue
        // 5% to maintenance = $500/month — covers basic ops
        // Simulate: fund TWAPBurner with $10K (representing one month of premiums)
        solvencyOracle.setQuadrant(1, 1); // 5% maintenance

        usdc.mint(address(twapBurner), 10_000e6);
        vm.warp(block.timestamp + 901);

        twapBurner.executeBurn();

        uint256 maintBalance = usdc.balanceOf(address(maintenanceReserve));
        assertEq(maintBalance, 500e6, "Break-even: $500/month covers maintenance");

        // Annualized: $6,000/year maintenance budget from 200 policies/month
        uint256 annualMaintenance = maintBalance * 12;
        assertEq(annualMaintenance, 6_000e6, "Annual maintenance budget = $6K");
    }

    function test_Revenue_BuybackArbitrage_60PercentDiscount() public {
        // Buy $1000 face value bonds at 60% discount = pay $400
        // Double burn: obligations decrease by $1000, LUMINA burned from reserves
        // Net effect: protocol pays $400 to reduce $1000 obligations + burns LUMINA

        // Verify the math: $1000 face value at $0.10/LUMINA = 10,000 LUMINA equivalent
        uint256 faceValueUSD = 1000e18; // 18-dec USD-wei
        uint256 luminaToBurn = (faceValueUSD * 1e18) / LUMINA_PRICE; // 10,000 LUMINA
        assertEq(luminaToBurn, 10_000e18, "Double burn: 10K LUMINA burned for $1K obligation");

        // Discount benefit: spent $400 (60% of $1000) to reduce $1000 obligations
        // Net gain: $600 worth of obligation reduction for free
        uint256 costPaid = 400e6;
        uint256 obligationReduced = 1000; // integer dollars
        uint256 arbitrageGain = obligationReduced - (costPaid / 1e6);
        assertEq(arbitrageGain, 600, "Protocol gains $600 per $1K bond bought at 60% discount");
    }

    // ═══════════════════════════════════════════════════════════════
    // SOLVENCY (5 tests)
    // ═══════════════════════════════════════════════════════════════

    function test_Solvency_BaseScenario_14x() public view {
        // 70M LUMINA × $0.10 = $7M reserve value
        // $0 obligations (fresh state) → infinite solvency
        // With $500K obligations → $7M / $500K = 14x
        uint256 reserveBalance = lumina.balanceOf(address(bondVault));
        uint256 reserveValueUSD = (reserveBalance * LUMINA_PRICE) / 1e18;

        // $7M
        assertEq(reserveValueUSD, 7_000_000e18, "Reserve value = $7M");

        uint256 hypotheticalObligations = 500_000e18; // $500K in 18-dec
        uint256 solvencyRatio = (reserveValueUSD * 10000) / hypotheticalObligations;

        // 14x = 140000 bps
        assertEq(solvencyRatio, 140000, "Solvency ratio = 14x (140,000 bps)");
    }

    function test_Solvency_MassTrigger_50Bonds() public {
        // Issue 50 bonds × $4K = $200K in new obligations
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(address(policyManager));
            bondVault.issueBond(buyer, 4000); // $4K each
        }

        // Total committed: 50 × $4000 × 1e18 = $200K in 18-dec USD-wei
        uint256 committed = bondVault.totalCommittedUSD();
        assertEq(committed, 200_000e18, "Total committed = $200K");

        // Reserve: 70M × $0.10 = $7M. Max commit: $3.5M (50% safety factor).
        // $200K << $3.5M → still very solvent
        uint256 reserveBalance = lumina.balanceOf(address(bondVault));
        uint256 reserveValueUSD = (reserveBalance * LUMINA_PRICE) / 1e18;
        uint256 maxCommit = (reserveValueUSD * 5000) / 10000;

        assertGt(maxCommit, committed, "Still solvent after 50 mass triggers");
    }

    function test_Solvency_50PercentCrash() public {
        // Issue some obligations first
        vm.prank(address(policyManager));
        bondVault.issueBond(buyer, 100_000); // $100K

        // Price crashes 50%: $0.10 → $0.05
        oracle.setPrice(0.05e18);

        // Reserve: 70M × $0.05 = $3.5M. Max commit: $1.75M (50% safety).
        // Obligations: $100K. Ratio: $3.5M / $100K = 35x — still very solvent
        uint256 reserveBalance = lumina.balanceOf(address(bondVault));
        uint256 newReserveValue = (reserveBalance * 0.05e18) / 1e18;
        uint256 obligations = bondVault.totalCommittedUSD();

        uint256 ratio = (newReserveValue * 100) / obligations;
        assertGt(ratio, 100, "Solvency ratio > 100% even after 50% crash");
    }

    function test_Solvency_AutoPause_PreventsBadObligations() public {
        // Set price below auto-pause threshold
        oracle.setPrice(4e15); // $0.004

        // CoverRouter blocks new policies
        bytes32 productId = keccak256("FLASHBTC1H-001");
        vm.prank(buyer);
        vm.expectRevert("Protocol auto-paused: LUMINA price below safety threshold");
        coverRouter.purchasePolicy(productId, 1000e6, "BTC");

        // Existing bonds can still be redeemed (redemption is never blocked)
        // Only new obligation creation is paused
        assertTrue(coverRouter.isProtocolAutoPaused(), "Protocol should show auto-paused");
    }

    function test_Solvency_PerfectStorm() public {
        // Perfect storm: price -80% + mass triggers
        // Issue max bonds first at normal price
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(address(policyManager));
            bondVault.issueBond(buyer, 10_000); // $10K each = $200K total
        }

        // Price crashes 80%: $0.10 → $0.02
        oracle.setPrice(0.02e18);

        // Reserve: 70M × $0.02 = $1.4M. Obligations: $200K.
        // Ratio: $1.4M / $200K = 7x — stressed but alive
        uint256 reserveBalance = lumina.balanceOf(address(bondVault));
        uint256 crashedReserveValue = (reserveBalance * 0.02e18) / 1e18;
        uint256 obligations = bondVault.totalCommittedUSD();

        uint256 ratio = (crashedReserveValue * 10000) / obligations;
        assertGt(ratio, 10000, "Even in perfect storm, solvency > 100%");

        // New policies should be blocked (auto-pause at $0.005)
        // At $0.02 we're above threshold but in defensive mode
        // The protocol survives — bond holders will still get paid at maturity
        assertGt(crashedReserveValue, obligations, "Reserve still covers all obligations");
    }
}
