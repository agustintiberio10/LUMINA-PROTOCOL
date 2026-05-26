// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../src/token/LuminaTokenV2.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../../src/interfaces/IDexRouter.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract MockUSDC_PDF {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Mock DEX router that simulates a swap.
///      Returns `rate` LUMINA (in 18-dec wei) per 1 USDC (6-dec).
contract MockSwapRouter_PDF is IDexRouter {
    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC = 27 LUMINA

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate * 1e12;
        lumina.transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256 amountIn) external view override returns (uint256) {
        return amountIn * rate * 1e12;
    }
}

/// @dev Mock AdaptiveFeeDistributor that returns configurable distribution values.
contract MockFeeDistributor_PDF {
    uint256 public burnBps;
    uint256 public buybackBps;
    uint256 public opsBps;
    uint256 public maintenanceBps;
    bool public healthy;
    bool public shouldRevert;

    constructor(uint256 _burnBps, uint256 _buybackBps, uint256 _opsBps, uint256 _maintenanceBps) {
        burnBps = _burnBps;
        buybackBps = _buybackBps;
        opsBps = _opsBps;
        maintenanceBps = _maintenanceBps;
        healthy = true;
    }

    function setDistribution(uint256 _burnBps, uint256 _buybackBps, uint256 _opsBps, uint256 _maintenanceBps) external {
        burnBps = _burnBps;
        buybackBps = _buybackBps;
        opsBps = _opsBps;
        maintenanceBps = _maintenanceBps;
    }

    function setHealthy(bool _healthy) external {
        healthy = _healthy;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getDistribution() external view returns (uint256, uint256, uint256, uint256) {
        require(!shouldRevert, "MockFeeDistributor: forced revert");
        return (burnBps, buybackBps, opsBps, maintenanceBps);
    }

    function isHealthy() external view returns (bool) {
        require(!shouldRevert, "MockFeeDistributor: forced revert");
        return healthy;
    }
}

/// @dev [legacy-migration] pattern #3: TWAPBurner._swapAndBurn now REVERTS with
///      "TWAPBurner: oracle unset" unless a capacity oracle is wired, since minOut
///      is derived exclusively from the oracle price (F-19). This minimal mock
///      returns a fresh price so executeBurn's burn portion can settle.
contract MockCapacityOracle_PDF {
    uint256 public price = 0.036e18; // $0.036; aligns with the 27 LUMINA/USDC router rate

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

/// @title PremiumDistributionFlowTest
/// @notice Phase 7.4 functional flow tests for premium distribution through TWAPBurner.
///         Tests legacy mode (100% burn) and adaptive mode (4-bucket distribution).
contract PremiumDistributionFlowTest is Test {
    // ═══════ CORE CONTRACTS ═══════
    LuminaTokenV2 token;
    TWAPBurner twapBurner;

    // ═══════ MOCKS ═══════
    MockUSDC_PDF usdc;
    MockSwapRouter_PDF swapRouter;
    MockFeeDistributor_PDF feeDistributor;
    MockCapacityOracle_PDF capacityOracle; // [legacy-migration] pattern #3

    // ═══════ ADDRESSES ═══════
    address bondVaultAddr = makeAddr("bondVault");
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");

    address buybackReserve = makeAddr("buybackReserve");
    address opsReserve = makeAddr("opsReserve");
    address maintenanceReserve = makeAddr("maintenanceReserve");

    address premiumPayer = makeAddr("premiumPayer");

    uint256 constant BASE_TS = 1767225600;

    function setUp() public {
        vm.chainId(8453);
        vm.warp(BASE_TS + 60 days);

        // 1. Deploy USDC mock
        usdc = new MockUSDC_PDF();

        // 2. Deploy token with a placeholder bondVault
        token =
            ProxyDeployer.deployLuminaTokenV2(bondVaultAddr, cexReserve, founderVesting, lbpDeposit, treasuryVesting);

        // 3. Deploy swap router mock, fund it with LUMINA
        swapRouter = new MockSwapRouter_PDF(address(token));
        deal(address(token), address(swapRouter), 10_000_000e18);

        // 4. Deploy TWAPBurner
        twapBurner = ProxyDeployer.deployTWAPBurner(address(usdc), address(token), address(swapRouter));

        // 5. Grant BURNER_ROLE to TWAPBurner
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));

        // [legacy-migration] pattern #3: wire a capacity oracle so the burn
        // portion of executeBurn can derive minOut (otherwise _swapAndBurn reverts
        // "TWAPBurner: oracle unset"). Applies to both legacy and adaptive paths.
        capacityOracle = new MockCapacityOracle_PDF();
        twapBurner.setCapacityOracle(address(capacityOracle));

        // 6. Deploy fee distributor mock (Healthy/Stable quadrant: 8500/800/200/500)
        feeDistributor = new MockFeeDistributor_PDF(8500, 800, 200, 500);

        // 7. Fund premiumPayer with USDC and set up approval for TWAPBurner
        usdc.mint(premiumPayer, 100_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Send premium USDC to TWAPBurner via receivePremium.
    function _sendPremium(uint256 amount) internal {
        vm.startPrank(premiumPayer);
        usdc.approve(address(twapBurner), amount);
        twapBurner.receivePremium(amount);
        vm.stopPrank();
    }

    /// @dev Enable adaptive mode on TWAPBurner with the mock fee distributor.
    function _enableAdaptiveMode() internal {
        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(buybackReserve, opsReserve, maintenanceReserve);
        twapBurner.setAdaptiveMode(true);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 1: Legacy mode - no adaptive, 100% burn
    // ═══════════════════════════════════════════════════════════

    function test_Flow_Premium_LegacyMode_NoBuckets() public {
        uint256 premiumAmount = 10_000e6; // $10,000

        // Send premium to TWAPBurner
        _sendPremium(premiumAmount);

        // Verify USDC received
        assertEq(usdc.balanceOf(address(twapBurner)), premiumAmount, "TWAPBurner should hold premium");
        assertEq(twapBurner.totalUSDCReceived(), premiumAmount, "totalUSDCReceived should match");

        // Verify adaptive mode is OFF
        assertFalse(twapBurner.adaptiveModeEnabled(), "Adaptive mode should be off");

        // Execute burn (legacy mode: 100% goes to swap and burn)
        uint256 supplyBefore = token.totalSupply();
        twapBurner.executeBurn();
        uint256 supplyAfter = token.totalSupply();

        // Verify LUMINA was burned
        assertTrue(supplyAfter < supplyBefore, "LUMINA supply should decrease");
        assertGt(twapBurner.totalLUMINABurned(), 0, "Should have burned LUMINA");
        assertEq(twapBurner.totalUSDCBurned(), premiumAmount, "Should have used all USDC for burn");

        // Verify TWAPBurner has no remaining USDC
        assertEq(usdc.balanceOf(address(twapBurner)), 0, "TWAPBurner should have 0 USDC after burn");

        // Verify no USDC went to reserves
        assertEq(usdc.balanceOf(buybackReserve), 0, "buybackReserve should have 0");
        assertEq(usdc.balanceOf(opsReserve), 0, "opsReserve should have 0");
        assertEq(usdc.balanceOf(maintenanceReserve), 0, "maintenanceReserve should have 0");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 2: Adaptive mode with Healthy/Stable distribution
    // ═══════════════════════════════════════════════════════════

    function test_Flow_Premium_AdaptiveMode_HealthyStable() public {
        // Enable adaptive mode with 8500/800/200/500 distribution
        _enableAdaptiveMode();
        assertTrue(twapBurner.adaptiveModeEnabled(), "Adaptive mode should be on");

        uint256 premiumAmount = 10_000e6; // $10,000

        // Send premium
        _sendPremium(premiumAmount);

        // Record balances before
        uint256 supplyBefore = token.totalSupply();

        // Execute burn (adaptive mode)
        twapBurner.executeBurn();

        uint256 supplyAfter = token.totalSupply();

        // Expected distribution of $10,000:
        // Burn:        85.0% = $8,500 => 8500e6 USDC
        // Buyback:      8.0% = $800   => 800e6 USDC
        // Ops:          2.0% = $200   => 200e6 USDC
        // Maintenance:  5.0% = $500   => 500e6 USDC
        assertEq(usdc.balanceOf(buybackReserve), 800e6, "buybackReserve should receive $800");
        assertEq(usdc.balanceOf(opsReserve), 200e6, "opsReserve should receive $200");
        assertEq(usdc.balanceOf(maintenanceReserve), 500e6, "maintenanceReserve should receive $500");

        // Burn portion: $8,500 was swapped to LUMINA and burned
        assertTrue(supplyAfter < supplyBefore, "LUMINA supply should decrease from burn portion");
        assertEq(twapBurner.totalUSDCBurned(), 8500e6, "Only 8500 USDC should be counted as burned");

        // TWAPBurner should have no remaining USDC
        assertEq(usdc.balanceOf(address(twapBurner)), 0, "TWAPBurner should have 0 USDC remaining");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 3: Fallback when distributor fails
    // ═══════════════════════════════════════════════════════════

    function test_Flow_Premium_FallbackWhen_DistributorFails() public {
        // Enable adaptive mode
        _enableAdaptiveMode();

        // Make the fee distributor revert
        feeDistributor.setShouldRevert(true);

        uint256 premiumAmount = 10_000e6;
        _sendPremium(premiumAmount);

        // Execute burn — should use fallback constants: 8500/800/200/500
        twapBurner.executeBurn();

        // Fallback distribution is the same as the hardcoded constants:
        // FALLBACK_BURN_BPS = 8500
        // FALLBACK_BUYBACK_BPS = 800
        // FALLBACK_OPS_BPS = 200
        // FALLBACK_MAINTENANCE_BPS = 500
        assertEq(usdc.balanceOf(buybackReserve), 800e6, "Fallback: buybackReserve should get $800");
        assertEq(usdc.balanceOf(opsReserve), 200e6, "Fallback: opsReserve should get $200");
        assertEq(usdc.balanceOf(maintenanceReserve), 500e6, "Fallback: maintenanceReserve should get $500");
        assertEq(twapBurner.totalUSDCBurned(), 8500e6, "Fallback: 8500 USDC burned");
        assertEq(usdc.balanceOf(address(twapBurner)), 0, "TWAPBurner should have 0 USDC remaining");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 4: Quadrant change updates distribution
    // ═══════════════════════════════════════════════════════════

    function test_Flow_Premium_QuadrantChange() public {
        // Enable adaptive mode with initial Healthy/Stable: 8500/800/200/500
        _enableAdaptiveMode();

        uint256 premiumAmount = 10_000e6;

        // First premium with initial distribution
        _sendPremium(premiumAmount);
        twapBurner.executeBurn();

        // Verify initial distribution
        assertEq(usdc.balanceOf(buybackReserve), 800e6, "Initial: buybackReserve $800");
        assertEq(usdc.balanceOf(opsReserve), 200e6, "Initial: opsReserve $200");
        assertEq(usdc.balanceOf(maintenanceReserve), 500e6, "Initial: maintenanceReserve $500");

        // Change to Crisis/Crash distribution: 0/9600/200/200
        feeDistributor.setDistribution(0, 9600, 200, 200);

        // Wait for cooldown
        vm.warp(block.timestamp + twapBurner.burnCooldown() + 1);

        // Second premium with new distribution
        _sendPremium(premiumAmount);
        twapBurner.executeBurn();

        // Verify new distribution applied (additive to previous balances):
        // Buyback: 800 + 9600 = 10400e6 => (9600/10000 * 10000e6 = 9600e6 new)
        assertEq(usdc.balanceOf(buybackReserve), 800e6 + 9600e6, "Updated: buybackReserve $800 + $9600");
        // Ops: 200 + 200 = 400e6
        assertEq(usdc.balanceOf(opsReserve), 200e6 + 200e6, "Updated: opsReserve $200 + $200");
        // Maintenance: 500 + 200 = 700e6
        assertEq(usdc.balanceOf(maintenanceReserve), 500e6 + 200e6, "Updated: maintenanceReserve $500 + $200");

        // Burn portion: 0% of $10,000 = $0 new burn
        // totalUSDCBurned should remain at 8500 from first round (no new burn in crisis/crash)
        assertEq(twapBurner.totalUSDCBurned(), 8500e6, "No additional USDC burned in 0% burn quadrant");
    }
}
