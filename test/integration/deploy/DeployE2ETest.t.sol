// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// ─── Core contracts ───
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {CapacityOracle} from "../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {CEXLiquidityReserve} from "../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../src/treasury/MaintenanceReserve.sol";
import {LuminaBondMarketplace} from "../../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../../src/marketplace/BuybackEngine.sol";

// ─── Shields (real contracts) ───
import {FlashBTCShield1h} from "../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../src/products/FlashETHShield48h.sol";
import {MicroDepegShield} from "../../../src/products/MicroDepegShield.sol";
import {RateShockShield} from "../../../src/products/RateShockShield.sol";

// ═══════════════════════════════════════════════════════════════
//  INLINE MOCKS
// ═══════════════════════════════════════════════════════════════

contract MockUSDC_E2E {
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

contract MockSwapRouter_E2E {
    function swap(address, address, uint256, uint256) external pure returns (uint256) {
        return 1000e18;
    }

    function getQuote(address, address, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Mock oracle implementing IOracle for shield constructor.
contract MockShieldOracle_E2E {
    mapping(bytes32 => int256) public prices;

    constructor() {
        prices[bytes32("BTC")] = 65_000e8;
        prices[bytes32("ETH")] = 3_200e8;
        prices[bytes32("USDT")] = 1e8;
        prices[bytes32("DAI")] = 1e8;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        int256 p = prices[asset];
        return p > 0 ? p : int256(1e8);
    }

    function getSequencerDowntime(uint256) external pure returns (uint256) {
        return 0;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0xdead);
    }

    function oracleKey() external pure returns (address) {
        return address(0xdead);
    }
}

/// @dev Mock Aave V3 Pool for RateShockShield.
contract MockAavePool_E2E {
    function getReserveData(address)
        external
        pure
        returns (
            uint256,
            uint128,
            uint128,
            uint128,
            uint128,
            uint128,
            uint40,
            uint16,
            address,
            address,
            address,
            address,
            uint128,
            uint128,
            uint128
        )
    {
        // currentVariableBorrowRate = 5% APY in RAY
        return (0, 0, 0, 0, 5e25, 0, 0, 0, address(0), address(0), address(0), address(0), 0, 0, 0);
    }
}

// ═══════════════════════════════════════════════════════════════
//  DEPLOY E2E TEST — Comprehensive deployment validation
// ═══════════════════════════════════════════════════════════════

contract DeployE2ETest is Test {
    // ─── Addresses ───
    address deployer;
    address multisig;
    address founderVesting;
    address lbpDeposit;
    address opsWallet;

    // ─── Mocks ───
    MockUSDC_E2E usdc;
    MockSwapRouter_E2E swapRouter;
    MockShieldOracle_E2E shieldOracle;
    MockAavePool_E2E aavePool;

    // ─── Core protocol ───
    MaintenanceReserve maintenanceReserve;
    ClaimBond claimBond;
    CapacityOracle capacityOracle;
    BondVault bondVault;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;
    LuminaTokenV2 lumina;
    SolvencyOracle solvencyOracle;
    AdaptiveFeeDistributor feeDistributor;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;
    LuminaBondMarketplace marketplace;
    BuybackEngine buybackEngine;

    // ─── Real Shields (all 9) ───
    FlashBTCShield1h flashBtc1h;
    FlashBTCShield4h flashBtc4h;
    FlashBTCShield24h flashBtc24h;
    FlashBTCShield48h flashBtc48h;
    FlashETHShield1h flashEth1h;
    FlashETHShield24h flashEth24h;
    FlashETHShield48h flashEth48h;
    MicroDepegShield microDepeg;
    RateShockShield rateShock;

    // ─── Correct Product IDs (from shield contracts) ───
    bytes32 constant ID_FLASHBTC1H = keccak256("FLASHBTC1H-001");
    bytes32 constant ID_FLASHBTC4H = keccak256("FLASHBTC4H-001");
    bytes32 constant ID_FLASHBTC24 = keccak256("FLASHBTC24-001");
    bytes32 constant ID_FLASHBTC48 = keccak256("FLASHBTC48-001");
    bytes32 constant ID_FLASHETH1H = keccak256("FLASHETH1H-001");
    bytes32 constant ID_FLASHETH24 = keccak256("FLASHETH24-001");
    bytes32 constant ID_FLASHETH48 = keccak256("FLASHETH48-001");
    bytes32 constant ID_MICRODEPEG = keccak256("MICRODEPEG-001");
    bytes32 constant ID_RATESHOCK = keccak256("RATESHOCK-001");

    // ─── Constants ───
    uint256 constant EMERGENCY_PRICE = 0.036e18;
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC

    function setUp() public {
        vm.warp(BASE_TS + 60 days);

        deployer = address(this);
        multisig = makeAddr("multisig");
        founderVesting = makeAddr("founderVesting");
        lbpDeposit = makeAddr("lbpDeposit");
        opsWallet = makeAddr("opsWallet");

        // ── Phase 1: Mocks ──
        usdc = new MockUSDC_E2E();
        swapRouter = new MockSwapRouter_E2E();
        shieldOracle = new MockShieldOracle_E2E();
        aavePool = new MockAavePool_E2E();

        // ── Phase 2: No-dep contracts ──
        maintenanceReserve = new MaintenanceReserve(address(usdc), multisig);
        claimBond = new ClaimBond();

        // ── Phase 3: Predict lumina address ──
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, currentNonce + 4);

        capacityOracle = new CapacityOracle(address(0), predictedLumina, address(usdc), EMERGENCY_PRICE);
        bondVault = new BondVault(predictedLumina, address(claimBond), address(capacityOracle), address(0));
        cexReserve = new CEXLiquidityReserve(predictedLumina, multisig);
        treasuryVesting = new TreasuryVesting(predictedLumina);

        // ── Phase 4: Token ──
        lumina = new LuminaTokenV2(
            address(bondVault), address(cexReserve), founderVesting, lbpDeposit, address(treasuryVesting)
        );
        require(address(lumina) == predictedLumina, "Lumina address prediction failed");

        // ── Phase 5: Wire ClaimBond ──
        claimBond.setBondVault(address(bondVault));

        // ── Phase 6: SolvencyOracle + FeeDistributor ──
        solvencyOracle = new SolvencyOracle(address(bondVault), address(capacityOracle), multisig);
        feeDistributor = new AdaptiveFeeDistributor(address(solvencyOracle));

        // ── Phase 7: TWAPBurner ──
        twapBurner = new TWAPBurner(address(usdc), address(lumina), address(swapRouter));

        // ── Phase 8: PolicyManager + CoverRouter ──
        policyManager = new PolicyManagerV2(address(bondVault));
        coverRouter = new CoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        policyManager.setRouter(address(coverRouter));
        coverRouter.setCapacityOracle(address(capacityOracle));
        bondVault.setPolicyManager(address(policyManager));

        // ── Phase 9: Marketplace + BuybackEngine ──
        marketplace = new LuminaBondMarketplace(address(claimBond), address(usdc), address(twapBurner), multisig);
        buybackEngine = new BuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );

        // ── Phase 10: Wire TWAPBurner ──
        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(address(buybackEngine), opsWallet, address(maintenanceReserve));
        twapBurner.setCapacityOracle(address(capacityOracle));
        twapBurner.setAuthorizedSender(address(coverRouter), true);
        twapBurner.setAdaptiveMode(true);

        // ── Phase 11: Roles ──
        lumina.grantRole(lumina.BURNER_ROLE(), address(twapBurner));
        bondVault.setAuthorizedCaller(address(buybackEngine), true);

        // ── Phase 12: Deploy 9 REAL shields ──
        flashBtc1h = new FlashBTCShield1h(address(policyManager), address(shieldOracle));
        flashBtc4h = new FlashBTCShield4h(address(policyManager), address(shieldOracle));
        flashBtc24h = new FlashBTCShield24h(address(policyManager), address(shieldOracle));
        flashBtc48h = new FlashBTCShield48h(address(policyManager), address(shieldOracle));
        flashEth1h = new FlashETHShield1h(address(policyManager), address(shieldOracle));
        flashEth24h = new FlashETHShield24h(address(policyManager), address(shieldOracle));
        flashEth48h = new FlashETHShield48h(address(policyManager), address(shieldOracle));
        microDepeg = new MicroDepegShield(address(policyManager), address(shieldOracle));
        rateShock = new RateShockShield(address(policyManager), address(shieldOracle), address(aavePool), address(usdc));

        // ── Phase 13: Register shields in PolicyManager (correct IDs!) ──
        policyManager.registerProduct(ID_FLASHBTC1H, address(flashBtc1h));
        policyManager.registerProduct(ID_FLASHBTC4H, address(flashBtc4h));
        policyManager.registerProduct(ID_FLASHBTC24, address(flashBtc24h));
        policyManager.registerProduct(ID_FLASHBTC48, address(flashBtc48h));
        policyManager.registerProduct(ID_FLASHETH1H, address(flashEth1h));
        policyManager.registerProduct(ID_FLASHETH24, address(flashEth24h));
        policyManager.registerProduct(ID_FLASHETH48, address(flashEth48h));
        policyManager.registerProduct(ID_MICRODEPEG, address(microDepeg));
        policyManager.registerProduct(ID_RATESHOCK, address(rateShock));

        // ── Phase 14: Configure shields in CoverRouter (correct IDs + 8000 payout!) ──
        coverRouter.configureProduct(ID_FLASHBTC1H, 8000, 200, 2000, 3600, true);
        coverRouter.configureProduct(ID_FLASHBTC4H, 8000, 150, 2000, 14400, true);
        coverRouter.configureProduct(ID_FLASHBTC24, 8000, 100, 2000, 86400, true);
        coverRouter.configureProduct(ID_FLASHBTC48, 8000, 80, 2000, 172800, true);
        coverRouter.configureProduct(ID_FLASHETH1H, 8000, 200, 2000, 3600, true);
        coverRouter.configureProduct(ID_FLASHETH24, 8000, 100, 2000, 86400, true);
        coverRouter.configureProduct(ID_FLASHETH48, 8000, 80, 2000, 172800, true);
        coverRouter.configureProduct(ID_MICRODEPEG, 8000, 50, 2500, 604800, true);
        coverRouter.configureProduct(ID_RATESHOCK, 8000, 30, 3000, 604800, true);

        // ── Phase 15: Ownership transfer ──
        capacityOracle.transferOwnership(multisig);
        twapBurner.transferOwnership(multisig);
        policyManager.transferOwnership(multisig);
        coverRouter.transferOwnership(multisig);
        treasuryVesting.transferOwnership(multisig);
        claimBond.transferOwnership(multisig);

        lumina.grantRole(lumina.DEFAULT_ADMIN_ROLE(), multisig);
        lumina.revokeRole(lumina.DEFAULT_ADMIN_ROLE(), deployer);

        bondVault.grantRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), multisig);
        bondVault.grantRole(bondVault.DEFAULT_ADMIN_ROLE(), multisig);
        bondVault.revokeRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), deployer);
        bondVault.revokeRole(bondVault.DEFAULT_ADMIN_ROLE(), deployer);
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION A: All contracts deployed (non-zero addresses)
    // ═══════════════════════════════════════════════════════════════

    function test_SectionA_AllContracts_NonZero() public view {
        assertTrue(address(lumina) != address(0), "LuminaTokenV2 zero");
        assertTrue(address(bondVault) != address(0), "BondVault zero");
        assertTrue(address(claimBond) != address(0), "ClaimBond zero");
        assertTrue(address(capacityOracle) != address(0), "CapacityOracle zero");
        assertTrue(address(solvencyOracle) != address(0), "SolvencyOracle zero");
        assertTrue(address(feeDistributor) != address(0), "FeeDistributor zero");
        assertTrue(address(twapBurner) != address(0), "TWAPBurner zero");
        assertTrue(address(policyManager) != address(0), "PolicyManagerV2 zero");
        assertTrue(address(coverRouter) != address(0), "CoverRouterV2 zero");
        assertTrue(address(cexReserve) != address(0), "CEXLiquidityReserve zero");
        assertTrue(address(maintenanceReserve) != address(0), "MaintenanceReserve zero");
        assertTrue(address(treasuryVesting) != address(0), "TreasuryVesting zero");
        assertTrue(address(marketplace) != address(0), "Marketplace zero");
        assertTrue(address(buybackEngine) != address(0), "BuybackEngine zero");
        assertTrue(address(flashBtc1h) != address(0), "FlashBTCShield1h zero");
        assertTrue(address(flashBtc4h) != address(0), "FlashBTCShield4h zero");
        assertTrue(address(flashBtc24h) != address(0), "FlashBTCShield24h zero");
        assertTrue(address(flashBtc48h) != address(0), "FlashBTCShield48h zero");
        assertTrue(address(flashEth1h) != address(0), "FlashETHShield1h zero");
        assertTrue(address(flashEth24h) != address(0), "FlashETHShield24h zero");
        assertTrue(address(flashEth48h) != address(0), "FlashETHShield48h zero");
        assertTrue(address(microDepeg) != address(0), "MicroDepegShield zero");
        assertTrue(address(rateShock) != address(0), "RateShockShield zero");
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION B: Token distribution (70/14/8/5/3)
    // ═══════════════════════════════════════════════════════════════

    function test_SectionB_TokenDistribution() public view {
        assertEq(lumina.totalSupply(), 100_000_000e18, "Total supply must be 100M");
        assertEq(lumina.balanceOf(address(bondVault)), 70_000_000e18, "BondVault must hold 70M (70%)");
        assertEq(lumina.balanceOf(address(cexReserve)), 14_000_000e18, "CEX Reserve must hold 14M (14%)");
        assertEq(lumina.balanceOf(founderVesting), 8_000_000e18, "Founder must hold 8M (8%)");
        assertEq(lumina.balanceOf(lbpDeposit), 5_000_000e18, "LBP must hold 5M (5%)");
        assertEq(lumina.balanceOf(address(treasuryVesting)), 3_000_000e18, "Treasury must hold 3M (3%)");
    }

    function test_SectionB_NoTokensElsewhere() public view {
        // Deployer should hold 0
        assertEq(lumina.balanceOf(deployer), 0, "Deployer should hold 0 tokens");
        // Multisig should hold 0
        assertEq(lumina.balanceOf(multisig), 0, "Multisig should hold 0 tokens");
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION C: Wiring (all cross-contract references)
    // ═══════════════════════════════════════════════════════════════

    function test_SectionC_TWAPBurner_Wiring() public view {
        assertEq(twapBurner.feeDistributor(), address(feeDistributor), "TWAPBurner.feeDistributor wrong");
        assertTrue(twapBurner.adaptiveModeEnabled(), "Adaptive mode must be enabled");
        assertEq(twapBurner.capacityOracle(), address(capacityOracle), "TWAPBurner.capacityOracle wrong");
        assertEq(twapBurner.buybackReserve(), address(buybackEngine), "buybackReserve wrong");
        assertEq(twapBurner.opsReserve(), opsWallet, "opsReserve wrong");
        assertEq(twapBurner.maintenanceReserve(), address(maintenanceReserve), "maintenanceReserve wrong");
        assertTrue(twapBurner.authorizedSenders(address(coverRouter)), "CoverRouter not authorized in TWAPBurner");
    }

    function test_SectionC_PolicyManager_Wiring() public view {
        assertEq(policyManager.router(), address(coverRouter), "PolicyManager.router wrong");
        assertEq(address(policyManager.bondVault()), address(bondVault), "PolicyManager.bondVault wrong");
    }

    function test_SectionC_BondVault_Wiring() public view {
        assertEq(bondVault.policyManager(), address(policyManager), "BondVault.policyManager wrong");
        assertEq(address(bondVault.priceOracle()), address(capacityOracle), "BondVault.priceOracle wrong");
    }

    function test_SectionC_ClaimBond_Wiring() public view {
        assertEq(claimBond.bondVault(), address(bondVault), "ClaimBond.bondVault wrong");
    }

    function test_SectionC_CoverRouter_Wiring() public view {
        assertEq(address(coverRouter.usdc()), address(usdc), "CoverRouter.usdc wrong");
        assertEq(address(coverRouter.policyManager()), address(policyManager), "CoverRouter.policyManager wrong");
        assertEq(address(coverRouter.twapBurner()), address(twapBurner), "CoverRouter.twapBurner wrong");
        assertEq(address(coverRouter.capacityOracle()), address(capacityOracle), "CoverRouter.capacityOracle wrong");
    }

    function test_SectionC_SolvencyOracle_Wiring() public view {
        assertEq(address(solvencyOracle.bondVault()), address(bondVault), "SolvencyOracle.bondVault wrong");
        assertEq(
            address(solvencyOracle.capacityOracle()), address(capacityOracle), "SolvencyOracle.capacityOracle wrong"
        );
        assertEq(address(solvencyOracle.lumina()), address(lumina), "SolvencyOracle.lumina wrong");
    }

    function test_SectionC_FeeDistributor_Wiring() public view {
        assertEq(
            address(feeDistributor.solvencyOracle()), address(solvencyOracle), "FeeDistributor.solvencyOracle wrong"
        );
    }

    function test_SectionC_Marketplace_Wiring() public view {
        assertEq(marketplace.twapBurner(), address(twapBurner), "Marketplace.twapBurner wrong");
    }

    function test_SectionC_OneShot_BondVault_PolicyManager() public {
        vm.expectRevert("PolicyManager already set");
        bondVault.setPolicyManager(makeAddr("another"));
    }

    function test_SectionC_OneShot_ClaimBond_BondVault() public {
        // Ownership transferred to multisig, so call as multisig
        vm.prank(multisig);
        vm.expectRevert("Already set");
        claimBond.setBondVault(makeAddr("another"));
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION D: All 9 shields registered AND configured
    // ═══════════════════════════════════════════════════════════════

    function test_SectionD_All9Shields_RegisteredInPolicyManager() public view {
        assertEq(policyManager.productShield(ID_FLASHBTC1H), address(flashBtc1h), "PM: FlashBTC1H not registered");
        assertEq(policyManager.productShield(ID_FLASHBTC4H), address(flashBtc4h), "PM: FlashBTC4H not registered");
        assertEq(policyManager.productShield(ID_FLASHBTC24), address(flashBtc24h), "PM: FlashBTC24H not registered");
        assertEq(policyManager.productShield(ID_FLASHBTC48), address(flashBtc48h), "PM: FlashBTC48H not registered");
        assertEq(policyManager.productShield(ID_FLASHETH1H), address(flashEth1h), "PM: FlashETH1H not registered");
        assertEq(policyManager.productShield(ID_FLASHETH24), address(flashEth24h), "PM: FlashETH24H not registered");
        assertEq(policyManager.productShield(ID_FLASHETH48), address(flashEth48h), "PM: FlashETH48H not registered");
        assertEq(policyManager.productShield(ID_MICRODEPEG), address(microDepeg), "PM: MicroDepeg not registered");
        assertEq(policyManager.productShield(ID_RATESHOCK), address(rateShock), "PM: RateShock not registered");

        // All active
        assertTrue(policyManager.productActive(ID_FLASHBTC1H), "FlashBTC1H not active");
        assertTrue(policyManager.productActive(ID_FLASHBTC4H), "FlashBTC4H not active");
        assertTrue(policyManager.productActive(ID_FLASHBTC24), "FlashBTC24H not active");
        assertTrue(policyManager.productActive(ID_FLASHBTC48), "FlashBTC48H not active");
        assertTrue(policyManager.productActive(ID_FLASHETH1H), "FlashETH1H not active");
        assertTrue(policyManager.productActive(ID_FLASHETH24), "FlashETH24H not active");
        assertTrue(policyManager.productActive(ID_FLASHETH48), "FlashETH48H not active");
        assertTrue(policyManager.productActive(ID_MICRODEPEG), "MicroDepeg not active");
        assertTrue(policyManager.productActive(ID_RATESHOCK), "RateShock not active");

        // Product count
        assertEq(policyManager.getProductCount(), 9, "Should have exactly 9 products");
    }

    /// @notice KEY TEST: Catches missing configureProduct() calls (Bug #2)
    function test_E2E_All9Shields_ConfiguredInCoverRouter() public view {
        // Each product must have durationSeconds > 0 (indicates configured)
        _assertProductConfigured(ID_FLASHBTC1H, 8000, 3600, "FlashBTC1H");
        _assertProductConfigured(ID_FLASHBTC4H, 8000, 14400, "FlashBTC4H");
        _assertProductConfigured(ID_FLASHBTC24, 8000, 86400, "FlashBTC24H");
        _assertProductConfigured(ID_FLASHBTC48, 8000, 172800, "FlashBTC48H");
        _assertProductConfigured(ID_FLASHETH1H, 8000, 3600, "FlashETH1H");
        _assertProductConfigured(ID_FLASHETH24, 8000, 86400, "FlashETH24H");
        _assertProductConfigured(ID_FLASHETH48, 8000, 172800, "FlashETH48H");
        _assertProductConfigured(ID_MICRODEPEG, 8000, 604800, "MicroDepeg");
        _assertProductConfigured(ID_RATESHOCK, 8000, 604800, "RateShock");
    }

    function _assertProductConfigured(bytes32 pid, uint256 expectedPayout, uint32 expectedDuration, string memory label)
        internal
        view
    {
        (
            ,
            uint256 payoutRatioBps,, // triggerProbBps
            , // marginBps
            uint32 durationSeconds,
            bool active
        ) = coverRouter.products(pid);
        assertTrue(durationSeconds > 0, string.concat(label, ": not configured in CoverRouter (duration=0)"));
        assertEq(durationSeconds, expectedDuration, string.concat(label, ": wrong duration"));
        assertEq(payoutRatioBps, expectedPayout, string.concat(label, ": wrong payoutRatioBps"));
        assertTrue(active, string.concat(label, ": not active"));
    }

    /// @notice KEY TEST: Catches product ID mismatch between shield constants, PolicyManager, and CoverRouter (Bug #1)
    function test_E2E_ShieldIds_MatchAcross_Shield_PM_Router() public view {
        // Verify each shield's PRODUCT_ID matches what's registered in PolicyManager and CoverRouter
        assertEq(flashBtc1h.PRODUCT_ID(), ID_FLASHBTC1H, "FlashBTC1H: PRODUCT_ID mismatch");
        assertEq(flashBtc4h.PRODUCT_ID(), ID_FLASHBTC4H, "FlashBTC4H: PRODUCT_ID mismatch");
        assertEq(flashBtc24h.PRODUCT_ID(), ID_FLASHBTC24, "FlashBTC24H: PRODUCT_ID mismatch");
        assertEq(flashBtc48h.PRODUCT_ID(), ID_FLASHBTC48, "FlashBTC48H: PRODUCT_ID mismatch");
        assertEq(flashEth1h.PRODUCT_ID(), ID_FLASHETH1H, "FlashETH1H: PRODUCT_ID mismatch");
        assertEq(flashEth24h.PRODUCT_ID(), ID_FLASHETH24, "FlashETH24H: PRODUCT_ID mismatch");
        assertEq(flashEth48h.PRODUCT_ID(), ID_FLASHETH48, "FlashETH48H: PRODUCT_ID mismatch");
        assertEq(microDepeg.PRODUCT_ID(), ID_MICRODEPEG, "MicroDepeg: PRODUCT_ID mismatch");
        assertEq(rateShock.PRODUCT_ID(), ID_RATESHOCK, "RateShock: PRODUCT_ID mismatch");

        // Verify the shield registered in PolicyManager matches the actual shield contract
        assertEq(
            policyManager.productShield(flashBtc1h.PRODUCT_ID()),
            address(flashBtc1h),
            "PM lookup by shield.PRODUCT_ID != shield address for FlashBTC1H"
        );
        assertEq(
            policyManager.productShield(flashEth1h.PRODUCT_ID()),
            address(flashEth1h),
            "PM lookup by shield.PRODUCT_ID != shield address for FlashETH1H"
        );
        assertEq(
            policyManager.productShield(rateShock.PRODUCT_ID()),
            address(rateShock),
            "PM lookup by shield.PRODUCT_ID != shield address for RateShock"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION E: Roles assigned correctly
    // ═══════════════════════════════════════════════════════════════

    function test_SectionE_Roles() public view {
        // BURNER_ROLE granted to TWAPBurner
        assertTrue(lumina.hasRole(lumina.BURNER_ROLE(), address(twapBurner)), "TWAPBurner must have BURNER_ROLE");

        // BuybackEngine authorized in BondVault
        assertTrue(bondVault.authorizedCallers(address(buybackEngine)), "BuybackEngine must be authorized in BondVault");

        // Multisig has DEFAULT_ADMIN_ROLE on lumina
        assertTrue(
            lumina.hasRole(lumina.DEFAULT_ADMIN_ROLE(), multisig), "Multisig must have DEFAULT_ADMIN_ROLE on lumina"
        );

        // Deployer no longer has admin roles
        assertFalse(
            lumina.hasRole(lumina.DEFAULT_ADMIN_ROLE(), deployer), "Deployer must NOT have DEFAULT_ADMIN_ROLE on lumina"
        );
        assertFalse(
            bondVault.hasRole(bondVault.DEFAULT_ADMIN_ROLE(), deployer),
            "Deployer must NOT have DEFAULT_ADMIN_ROLE on BondVault"
        );
        assertFalse(
            bondVault.hasRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), deployer),
            "Deployer must NOT have AUTHORIZED_CALLER_ADMIN_ROLE on BondVault"
        );

        // BondVault: multisig has admin roles
        assertTrue(
            bondVault.hasRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), multisig),
            "Multisig must have AUTHORIZED_CALLER_ADMIN_ROLE on BondVault"
        );
        assertTrue(
            bondVault.hasRole(bondVault.DEFAULT_ADMIN_ROLE(), multisig),
            "Multisig must have DEFAULT_ADMIN_ROLE on BondVault"
        );

        // BuybackEngine: multisig has BUYBACK_OPERATOR_ROLE
        assertTrue(
            buybackEngine.hasRole(buybackEngine.BUYBACK_OPERATOR_ROLE(), multisig),
            "Multisig must have BUYBACK_OPERATOR_ROLE on BuybackEngine"
        );
    }

    function test_SectionE_OwnershipTransferred() public view {
        assertEq(capacityOracle.owner(), multisig, "CapacityOracle owner must be multisig");
        assertEq(twapBurner.owner(), multisig, "TWAPBurner owner must be multisig");
        assertEq(policyManager.owner(), multisig, "PolicyManager owner must be multisig");
        assertEq(coverRouter.owner(), multisig, "CoverRouter owner must be multisig");
        assertEq(treasuryVesting.owner(), multisig, "TreasuryVesting owner must be multisig");
        assertEq(claimBond.owner(), multisig, "ClaimBond owner must be multisig");
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION F: Can buy each of 9 shields immediately after deploy
    //  KEY TEST: Catches BOTH bugs (wrong IDs + missing configureProduct)
    // ═══════════════════════════════════════════════════════════════

    /// @notice KEY TEST: End-to-end purchase of all 9 shields
    function test_E2E_CanBuyEach9Shields() public {
        address buyer = makeAddr("buyer");
        uint256 coverage = 1000e6; // $1000
        usdc.mint(buyer, 100_000e6); // plenty of USDC

        // Transfer ownership back to deployer temporarily for policy purchases
        // (policyManager ownership was transferred to multisig in setUp)
        // Actually, purchasing doesn't need ownership - it goes through coverRouter.
        // We just need the buyer to approve USDC to coverRouter.
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);

        // BTC shields
        coverRouter.purchasePolicy(ID_FLASHBTC1H, coverage, bytes32("BTC"));
        coverRouter.purchasePolicy(ID_FLASHBTC4H, coverage, bytes32("BTC"));
        coverRouter.purchasePolicy(ID_FLASHBTC24, coverage, bytes32("BTC"));
        coverRouter.purchasePolicy(ID_FLASHBTC48, coverage, bytes32("BTC"));

        // ETH shields
        coverRouter.purchasePolicy(ID_FLASHETH1H, coverage, bytes32("ETH"));
        coverRouter.purchasePolicy(ID_FLASHETH24, coverage, bytes32("ETH"));
        coverRouter.purchasePolicy(ID_FLASHETH48, coverage, bytes32("ETH"));

        // MicroDepeg (asset = USDT for depeg coverage)
        coverRouter.purchasePolicy(ID_MICRODEPEG, coverage, bytes32("USDT"));

        // RateShock (asset = USDC reference)
        coverRouter.purchasePolicy(ID_RATESHOCK, coverage, bytes32("USDC"));

        vm.stopPrank();

        // Verify policies were created
        assertEq(policyManager.totalPolicies(), 9, "Should have 9 policies total");
        assertEq(policyManager.activePolicies(), 9, "Should have 9 active policies");
    }

    function test_E2E_CanBuy_FlashBTC1H() public {
        _buyShield(ID_FLASHBTC1H, bytes32("BTC"), 1000e6);
    }

    function test_E2E_CanBuy_FlashBTC4H() public {
        _buyShield(ID_FLASHBTC4H, bytes32("BTC"), 1000e6);
    }

    function test_E2E_CanBuy_FlashBTC24H() public {
        _buyShield(ID_FLASHBTC24, bytes32("BTC"), 1000e6);
    }

    function test_E2E_CanBuy_FlashBTC48H() public {
        _buyShield(ID_FLASHBTC48, bytes32("BTC"), 1000e6);
    }

    function test_E2E_CanBuy_FlashETH1H() public {
        _buyShield(ID_FLASHETH1H, bytes32("ETH"), 1000e6);
    }

    function test_E2E_CanBuy_FlashETH24H() public {
        _buyShield(ID_FLASHETH24, bytes32("ETH"), 1000e6);
    }

    function test_E2E_CanBuy_FlashETH48H() public {
        _buyShield(ID_FLASHETH48, bytes32("ETH"), 1000e6);
    }

    function test_E2E_CanBuy_MicroDepeg() public {
        _buyShield(ID_MICRODEPEG, bytes32("USDT"), 1000e6);
    }

    function test_E2E_CanBuy_RateShock() public {
        _buyShield(ID_RATESHOCK, bytes32("USDC"), 1000e6);
    }

    function _buyShield(bytes32 productId, bytes32 asset, uint256 coverage) internal {
        address buyer = makeAddr("singleBuyer");
        usdc.mint(buyer, 100_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
        uint256 policyId = coverRouter.purchasePolicy(productId, coverage, asset);
        vm.stopPrank();
        assertTrue(policyId > 0, "Policy ID should be > 0");
        assertEq(policyManager.totalPolicies(), 1, "Should have 1 policy");
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION G: Admin operations work
    // ═══════════════════════════════════════════════════════════════

    function test_SectionG_MultisigCanPause() public {
        vm.prank(multisig);
        coverRouter.setPaused(true);
        assertTrue(coverRouter.paused(), "Should be paused");

        // Buying should revert
        address buyer = makeAddr("buyer");
        usdc.mint(buyer, 100_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.expectRevert();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, bytes32("BTC"));
        vm.stopPrank();

        // Unpause
        vm.prank(multisig);
        coverRouter.setPaused(false);
        assertFalse(coverRouter.paused(), "Should be unpaused");
    }

    function test_SectionG_MultisigCanDeactivateProduct() public {
        vm.prank(multisig);
        policyManager.deactivateProduct(ID_FLASHBTC1H);
        assertFalse(policyManager.productActive(ID_FLASHBTC1H), "Product should be deactivated");
    }

    function test_SectionG_MultisigCanAddRelayer() public {
        address relayer = makeAddr("relayer");
        vm.prank(multisig);
        coverRouter.setRelayer(relayer, true);
        assertTrue(coverRouter.authorizedRelayers(relayer), "Relayer should be authorized");
    }

    function test_SectionG_DeployerCannotAdmin() public {
        // Deployer lost ownership, so admin calls should revert
        vm.startPrank(deployer);

        vm.expectRevert();
        coverRouter.setPaused(true);

        vm.expectRevert();
        policyManager.deactivateProduct(ID_FLASHBTC1H);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION: CapacityOracle emergency price
    // ═══════════════════════════════════════════════════════════════

    function test_CapacityOracle_EmergencyPrice() public view {
        uint256 price = capacityOracle.getLuminaPrice();
        assertEq(price, EMERGENCY_PRICE, "Should return emergency price when pool is address(0)");
    }

    // ═══════════════════════════════════════════════════════════════
    //  REGRESSION: Wrong product IDs should fail
    // ═══════════════════════════════════════════════════════════════

    function test_Regression_WrongProductIds_NotRegistered() public view {
        // These are the OLD (wrong) IDs from the buggy mainnet script
        bytes32 wrongBtc1h = keccak256("FLASH_BTC_1H");
        bytes32 wrongEth1h = keccak256("FLASH_ETH_1H");
        bytes32 wrongDepeg = keccak256("MICRO_DEPEG");
        bytes32 wrongRate = keccak256("RATE_SHOCK");

        // None of these should be registered
        assertEq(policyManager.productShield(wrongBtc1h), address(0), "Wrong BTC1H ID should not be registered");
        assertEq(policyManager.productShield(wrongEth1h), address(0), "Wrong ETH1H ID should not be registered");
        assertEq(policyManager.productShield(wrongDepeg), address(0), "Wrong Depeg ID should not be registered");
        assertEq(policyManager.productShield(wrongRate), address(0), "Wrong Rate ID should not be registered");
    }

    function test_Regression_WrongProductIds_CannotBuy() public {
        bytes32 wrongBtc1h = keccak256("FLASH_BTC_1H");

        address buyer = makeAddr("buyer");
        usdc.mint(buyer, 100_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);

        // Should revert because the wrong ID is not configured in CoverRouter
        vm.expectRevert();
        coverRouter.purchasePolicy(wrongBtc1h, 1000e6, bytes32("BTC"));
        vm.stopPrank();
    }
}
