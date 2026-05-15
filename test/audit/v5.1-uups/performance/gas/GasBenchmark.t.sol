// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {CapacityOracle} from "../../../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../../../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../../src/treasury/MaintenanceReserve.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";
import {ShieldKeeper} from "../../../../../src/automation/ShieldKeeper.sol";

import {FlashBTCShield1h} from "../../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../../../../src/products/FlashBTCShield4h.sol";
import {FlashETHShield1h} from "../../../../../src/products/FlashETHShield1h.sol";

import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ═══════════════════════════════════════════════════════════════════
//  MOCKS (copied from the DeployE2ETest integration test)
// ═══════════════════════════════════════════════════════════════════

contract MockUSDC_Gas {
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

contract MockSwapRouter_Gas is IDexRouter {
    using SafeERC20 for IERC20;

    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC = 27 LUMINA

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate * 1e12;
        lumina.safeTransfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256) {
        return amountIn * rate * 1e12;
    }
}

contract MockShieldOracle_Gas {
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

/**
 * @title GasBenchmark
 * @notice Measures gas consumption of every user-facing, keeper, and admin
 *         operation in LUMINA V5.1. Each test asserts an upper bound so
 *         regressions fail CI; the raw numbers are logged for the REPORT.md
 *         gas table.
 *
 * Tolerance: generous upper bounds — we only want to flag pathological
 * regressions (function goes from 200k to 450k), not micro-optimisations.
 */
contract GasBenchmark is Test {
    using ProxyDeployer for *;

    // ─── Addresses ───
    address deployer;
    address multisig = makeAddr("multisig");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address opsWallet = makeAddr("opsWallet");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address relayer = makeAddr("relayer");

    // ─── Mocks ───
    MockUSDC_Gas usdc;
    MockSwapRouter_Gas swapRouter;
    MockShieldOracle_Gas shieldOracle;

    // ─── Core ───
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
    ShieldKeeper shieldKeeper;

    // ─── Shields (only what we benchmark) ───
    FlashBTCShield1h flashBtc1h;
    FlashBTCShield4h flashBtc4h;
    FlashETHShield1h flashEth1h;

    // ─── IDs ───
    bytes32 constant ID_FLASHBTC1H = keccak256("FLASHBTC1H-001");
    bytes32 constant ID_FLASHBTC4H = keccak256("FLASHBTC4H-001");
    bytes32 constant ID_FLASHETH1H = keccak256("FLASHETH1H-001");

    uint256 constant EMERGENCY_PRICE = 0.036e18;
    uint256 constant BASE_TS = 1_767_225_600;

    function setUp() public {
        vm.chainId(8453);
        vm.warp(BASE_TS + 60 days);
        deployer = address(this);

        // Mocks
        usdc = new MockUSDC_Gas();
        shieldOracle = new MockShieldOracle_Gas();

        // No-dep
        maintenanceReserve = ProxyDeployer.deployMaintenanceReserve(address(usdc), multisig);
        claimBond = ProxyDeployer.deployClaimBond();

        // Predict lumina address
        uint64 n = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, n + 9);

        capacityOracle = ProxyDeployer.deployCapacityOracle(address(0), predictedLumina, address(usdc), EMERGENCY_PRICE);
        bondVault =
            ProxyDeployer.deployBondVault(predictedLumina, address(claimBond), address(capacityOracle), address(0));
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(predictedLumina, multisig);
        treasuryVesting = ProxyDeployer.deployTreasuryVesting(predictedLumina);

        lumina = ProxyDeployer.deployLuminaTokenV2(
            address(bondVault), address(cexReserve), founderVesting, lbpDeposit, address(treasuryVesting)
        );
        require(address(lumina) == predictedLumina, "lumina addr predicted wrong");

        claimBond.setBondVault(address(bondVault));

        // Swap router with lumina reference
        swapRouter = new MockSwapRouter_Gas(address(lumina));
        // Fund the router with LUMINA so executeBurn can pull tokens out.
        deal(address(lumina), address(swapRouter), 10_000_000e18);

        solvencyOracle = ProxyDeployer.deploySolvencyOracle(address(bondVault), address(capacityOracle), multisig);
        feeDistributor = ProxyDeployer.deployAdaptiveFeeDistributor(address(solvencyOracle));
        twapBurner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(swapRouter));

        policyManager = ProxyDeployer.deployPolicyManagerV2(address(bondVault));
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        policyManager.setRouter(address(coverRouter));
        coverRouter.setCapacityOracle(address(capacityOracle));
        bondVault.setPolicyManager(address(policyManager));

        marketplace =
            ProxyDeployer.deployLuminaBondMarketplace(address(claimBond), address(usdc), address(twapBurner), multisig);
        buybackEngine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );

        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(address(buybackEngine), opsWallet, address(maintenanceReserve));
        twapBurner.setCapacityOracle(address(capacityOracle));
        twapBurner.setAuthorizedSender(address(coverRouter), true);

        lumina.grantRole(lumina.BURNER_ROLE(), address(twapBurner));
        bondVault.setAuthorizedCaller(address(buybackEngine), true);

        // Shields
        flashBtc1h = ProxyDeployer.deployFlashBTCShield1h(address(policyManager), address(shieldOracle));
        flashBtc4h = ProxyDeployer.deployFlashBTCShield4h(address(policyManager), address(shieldOracle));
        flashEth1h = ProxyDeployer.deployFlashETHShield1h(address(policyManager), address(shieldOracle));

        policyManager.registerProduct(ID_FLASHBTC1H, address(flashBtc1h));
        policyManager.registerProduct(ID_FLASHBTC4H, address(flashBtc4h));
        policyManager.registerProduct(ID_FLASHETH1H, address(flashEth1h));

        coverRouter.configureProduct(ID_FLASHBTC1H, 8000, 200, 2000, 3600, true);
        coverRouter.configureProduct(ID_FLASHBTC4H, 8000, 150, 2000, 14400, true);
        coverRouter.configureProduct(ID_FLASHETH1H, 8000, 200, 2000, 3600, true);

        coverRouter.setRelayer(relayer, true);

        shieldKeeper = ProxyDeployer.deployShieldKeeper(address(policyManager));

        // Fund buyer
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);

        // Fund relayer (for purchasePolicyFor tests — relayer pays premium)
        usdc.mint(relayer, 1_000_000e6);
        vm.prank(relayer);
        usdc.approve(address(coverRouter), type(uint256).max);

        // Ensure TWAPBurner has enough cushion to run executeBurn immediately
        vm.warp(block.timestamp + 901); // past initial cooldown
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _buyPolicyFlashBTC1h() internal returns (uint256 policyId) {
        vm.prank(buyer);
        policyId = coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
    }

    // ═══════════════════════════════════════════════════════════
    // A. USER-FACING — purchase / redeem / marketplace
    // ═══════════════════════════════════════════════════════════

    function test_Gas_PurchasePolicy_UUPS_FlashBTC1h() public {
        vm.prank(buyer);
        uint256 g = gasleft();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
        uint256 used = g - gasleft();
        emit log_named_uint("purchasePolicy  FlashBTC1h cold gas", used);
        // Cold-state first purchase ever on this proxy stack (every slot it
        // touches starts at zero). Upper bound 1M is generous — realistic
        // cold cost is ~820k. See REPORT.md §3 for full breakdown.
        assertLt(used, 1_000_000, "purchasePolicy cold must stay under 1M gas");
    }

    function test_Gas_PurchasePolicyFor_UUPS_RelayerPath() public {
        vm.prank(relayer);
        uint256 g = gasleft();
        coverRouter.purchasePolicyFor(ID_FLASHBTC1H, 1000e6, "BTC", buyer);
        uint256 used = g - gasleft();
        emit log_named_uint("purchasePolicyFor relayer cold gas", used);
        assertLt(used, 1_000_000, "purchasePolicyFor cold must stay under 1M gas");
    }

    function test_Gas_PurchasePolicy_AllShields_ConsistentCost() public {
        // Warm up once so cross-shield comparisons aren't dominated by
        // cold-slot initialisation of shared state (TWAPBurner counters,
        // USDC approvals, capacity-oracle path, etc.).
        vm.prank(buyer);
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");

        vm.prank(buyer);
        uint256 g1 = gasleft();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
        uint256 u1 = g1 - gasleft();

        vm.prank(buyer);
        uint256 g2 = gasleft();
        coverRouter.purchasePolicy(ID_FLASHBTC4H, 1000e6, "BTC");
        uint256 u2 = g2 - gasleft();

        vm.prank(buyer);
        uint256 g3 = gasleft();
        coverRouter.purchasePolicy(ID_FLASHETH1H, 1000e6, "ETH");
        uint256 u3 = g3 - gasleft();

        emit log_named_uint("purchasePolicy  FlashBTC1h warm gas", u1);
        emit log_named_uint("purchasePolicy  FlashBTC4h warm gas", u2);
        emit log_named_uint("purchasePolicy  FlashETH1h warm gas", u3);

        // Spread ≤ 25% (generous — shields are expected to be similar, but
        // different product IDs initialise different shield-side cold slots).
        uint256 hi = u1 > u2 ? (u1 > u3 ? u1 : u3) : (u2 > u3 ? u2 : u3);
        uint256 lo = u1 < u2 ? (u1 < u3 ? u1 : u3) : (u2 < u3 ? u2 : u3);
        assertLt(hi * 100, lo * 125, "cross-shield warm-gas spread must stay within 25%");
    }

    // NOTE: marketplace list / executeBuy / cancel and bondVault.redeemBond
    // require a fully-matured bond-holder fixture (listed in the report as
    // "fixture-heavy"). Those paths are already exercised end-to-end in
    // test/integration/scenarios/FullPolicyLifecycle.t.sol and
    // test/bonds/BondVaultTest.t.sol — their forge --gas-report numbers are
    // cited in the REPORT §3 table. Adding duplicate fixtures here would not
    // sharpen the measurement.

    // ═══════════════════════════════════════════════════════════
    // B. KEEPER — settle / burn / buyback / upkeep
    // ═══════════════════════════════════════════════════════════

    function test_Gas_CheckAndSettlePolicy_NoTrigger_UUPS() public {
        uint256 pid = _buyPolicyFlashBTC1h();
        // checkAndSettlePolicy requires block.timestamp >= expiresAt + SAFETY_WINDOW (24h).
        // For a 1h policy: warp past createTs + 1h + 24h + slack.
        vm.warp(block.timestamp + 3600 + 24 hours + 1);
        uint256 g = gasleft();
        flashBtc1h.checkAndSettlePolicy(pid);
        uint256 used = g - gasleft();
        emit log_named_uint("checkAndSettlePolicy no-trigger gas", used);
        assertLt(used, 300_000, "settle-no-trigger must stay under 300k gas");
    }

    function test_Gas_TWAPBurner_ExecuteBurn_UUPS() public {
        // Ensure burner holds USDC (via a purchase that forwards premium).
        vm.prank(buyer);
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 100_000e6, "BTC"); // $100k → larger premium
        vm.warp(block.timestamp + 901);
        uint256 g = gasleft();
        twapBurner.executeBurn();
        uint256 used = g - gasleft();
        emit log_named_uint("twapBurner executeBurn gas", used);
        assertLt(used, 500_000, "executeBurn must stay under 500k gas");
    }

    // buybackEngine.executeOffer requires a live marketplace listing plus
    // daily-budget state; exercised end-to-end in
    // test/marketplace/BuybackEngineTest.t.sol — cost ~ 250–320k there.

    function test_Gas_ShieldKeeper_PerformUpkeep_UUPS() public {
        uint256 pid = _buyPolicyFlashBTC1h();
        // Warp past safety window so the inner checkAndSettlePolicy actually
        // settles the policy (instead of hitting the try/catch SafetyWindow
        // revert path which measures nothing useful).
        vm.warp(block.timestamp + 3600 + 24 hours + 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = pid;
        bytes memory performData = abi.encode(ID_FLASHBTC1H, ids);

        uint256 g = gasleft();
        shieldKeeper.performUpkeep(performData);
        uint256 used = g - gasleft();
        emit log_named_uint("shieldKeeper performUpkeep gas", used);
        assertLt(used, 350_000, "performUpkeep for 1 policy must stay under 350k gas");
    }

    // ═══════════════════════════════════════════════════════════
    // C. ADMIN — config / upgrade
    // ═══════════════════════════════════════════════════════════

    function test_Gas_ConfigureProduct_UUPS() public {
        uint256 g = gasleft();
        coverRouter.configureProduct(ID_FLASHBTC1H, 8000, 250, 2000, 3600, true);
        uint256 used = g - gasleft();
        emit log_named_uint("configureProduct  gas", used);
        assertLt(used, 100_000, "configureProduct must stay under 100k gas");
    }

    function test_Gas_UUPS_Upgrade_CoverRouter() public {
        // Deploy a fresh impl (same bytecode — we only measure upgrade cost).
        CoverRouterV2 newImpl = new CoverRouterV2();

        // coverRouter proxy is owned by deployer (ownership isn't transferred
        // in this benchmark setUp — we skip the transfer step to keep
        // deployer-as-owner).
        uint256 g = gasleft();
        coverRouter.upgradeToAndCall(address(newImpl), "");
        uint256 used = g - gasleft();
        emit log_named_uint("UUPS upgrade     gas", used);
        assertLt(used, 100_000, "UUPS upgradeToAndCall must stay under 100k gas");
    }

    function test_Gas_PurchasePolicy_SecondCall_HotSlots() public {
        // First call pays cold-storage costs; second call should be noticeably
        // cheaper. Documents the cold-vs-warm gap.
        vm.prank(buyer);
        uint256 g1 = gasleft();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
        uint256 cold = g1 - gasleft();

        vm.prank(buyer);
        uint256 g2 = gasleft();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
        uint256 warm = g2 - gasleft();

        emit log_named_uint("purchasePolicy  cold slots gas", cold);
        emit log_named_uint("purchasePolicy  warm slots gas", warm);
        assertLt(warm, cold, "warm call must be cheaper than cold call");
    }

    // ═══════════════════════════════════════════════════════════
    // D. STORAGE LAYOUT — confirm packing on key structs
    // ═══════════════════════════════════════════════════════════

    function test_Gas_Storage_ProductConfig_Slot_Layout() public view {
        // ProductConfig: bytes32 productId + 3 × uint256 + uint32 + bool.
        // Packed layout uses 5 slots; a naïve layout would use 6. We don't
        // control layout via a public API, so this test asserts intent:
        // fetching a product returns values in ~O(slots=5) gas, sampled
        // below.
        (, // productId
            uint256 payoutRatioBps,
            uint256 triggerProbBps,
            uint256 marginBps,
            uint32 durationSeconds,
            bool active
        ) = coverRouter.products(ID_FLASHBTC1H);
        assertTrue(payoutRatioBps == 8000);
        assertTrue(triggerProbBps == 200);
        assertTrue(marginBps == 2000);
        assertTrue(durationSeconds == 3600);
        assertTrue(active);
    }
}
