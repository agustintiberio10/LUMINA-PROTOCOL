// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/TWAPBurner.sol";
import "../../src/token/LuminaTokenV2.sol";
import {MockFeeDistributor} from "../mocks/MockFeeDistributor.sol";

// Mock swap router that simulates Uniswap swap
contract MockSwapRouter {
    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC ($1) = 27.7 LUMINA at $0.036

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        // Simulate: take USDC, give LUMINA
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        // Calculate LUMINA output: amountIn (6 dec) * rate * 1e12 (to 18 dec)
        amountOut = (params.amountIn * rate * 1e12);
        // Transfer LUMINA to recipient
        lumina.transfer(params.recipient, amountOut);
    }

    function setRate(uint256 r) external {
        rate = r;
    }
}

contract TWAPBurnerTest is Test {
    TWAPBurner burner;
    LuminaTokenV2 token;
    MockSwapRouter router;

    address bondVault = makeAddr("bondVault");
    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address usdc;
    address coverRouter = makeAddr("coverRouter");

    function setUp() public {
        // [SR3] Warp past initial cooldown (default burnCooldown=900s vs ts=1)
        vm.warp(1000);

        // Deploy mock USDC
        MockERC20 mockUsdc = new MockERC20("USDC", "USDC", 6);
        usdc = address(mockUsdc);

        // Deploy token
        token = new LuminaTokenV2(bondVault, makeAddr("cex"), founder, lbp, treasury);

        // Deploy mock router
        router = new MockSwapRouter(address(token));
        // Give router some LUMINA to simulate swaps
        deal(address(token), address(router), 1_000_000 * 1e18);

        // Deploy burner
        burner = new TWAPBurner(usdc, address(token), address(router));

        // Grant BURNER_ROLE to the burner
        token.grantRole(token.BURNER_ROLE(), address(burner));

        // Setup: give coverRouter some USDC
        deal(usdc, coverRouter, 100_000e6);
    }

    function test_receivePremium() public {
        vm.startPrank(coverRouter);
        IERC20(usdc).approve(address(burner), 100e6);
        burner.receivePremium(100e6);
        vm.stopPrank();

        assertEq(burner.totalUSDCReceived(), 100e6);
        assertEq(IERC20(usdc).balanceOf(address(burner)), 100e6);
    }

    function test_executeBurn() public {
        // Send USDC to burner
        vm.startPrank(coverRouter);
        IERC20(usdc).approve(address(burner), 10e6); // $10
        burner.receivePremium(10e6);
        vm.stopPrank();

        // Execute burn
        uint256 supplyBefore = token.totalSupply();
        burner.executeBurn();
        uint256 supplyAfter = token.totalSupply();

        assertTrue(supplyAfter < supplyBefore);
        assertGt(burner.totalLUMINABurned(), 0);
        assertEq(burner.totalUSDCBurned(), 10e6);
    }

    function test_cooldown_enforced() public {
        vm.startPrank(coverRouter);
        IERC20(usdc).approve(address(burner), 20e6);
        burner.receivePremium(20e6);
        vm.stopPrank();

        burner.executeBurn();

        // Try again immediately — should fail
        vm.expectRevert("Cooldown active");
        burner.executeBurn();

        // Wait cooldown
        vm.warp(block.timestamp + 901);
        // Need more USDC
        vm.startPrank(coverRouter);
        IERC20(usdc).approve(address(burner), 10e6);
        burner.receivePremium(10e6);
        vm.stopPrank();

        burner.executeBurn(); // should work now
    }

    function test_below_minimum_reverts() public {
        // Send tiny amount
        deal(usdc, address(burner), 0.5e6); // $0.50
        vm.expectRevert("Below minimum");
        burner.executeBurn();
    }

    function test_canBurn_view() public {
        assertFalse(burner.canBurn()); // no USDC

        vm.startPrank(coverRouter);
        IERC20(usdc).approve(address(burner), 5e6);
        burner.receivePremium(5e6);
        vm.stopPrank();

        assertTrue(burner.canBurn());
    }

    function test_getStats() public view {
        (uint256 received, uint256 burned, uint256 luminaBurned, uint256 pending, uint256 lastBurn, bool canBurn_) =
            burner.getStats();
        assertEq(received, 0);
        assertEq(burned, 0);
        assertEq(luminaBurned, 0);
        assertEq(pending, 0);
        assertEq(lastBurn, 0);
        assertFalse(canBurn_);
    }

    function test_cannot_recover_usdc() public {
        vm.expectRevert("Cannot recover USDC");
        burner.recoverToken(usdc, 100);
    }

    function test_cannot_recover_lumina() public {
        vm.expectRevert("Cannot recover LUMINA");
        burner.recoverToken(address(token), 100);
    }

    function test_onlyOwner_config() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        burner.setBurnCooldown(60);
    }

    // ═══════ V5.0 ADAPTIVE MODE TESTS (4-BUCKET) ═══════

    function _setupAdaptive(MockFeeDistributor mock)
        internal
        returns (address buybackRes, address opsRes, address maintRes)
    {
        buybackRes = makeAddr("buybackReserve");
        opsRes = makeAddr("opsReserve");
        maintRes = makeAddr("maintenanceReserve");

        burner.setFeeDistributor(address(mock));
        burner.setReserves(buybackRes, opsRes, maintRes);
        burner.setAdaptiveMode(true);
    }

    function test_LegacyMode_BurnsFullAmount() public {
        uint256 usdcAmount = 1000e6;
        deal(usdc, address(burner), usdcAmount);
        vm.warp(block.timestamp + 901);

        uint256 supplyBefore = token.totalSupply();
        burner.executeBurn();
        assertTrue(token.totalSupply() < supplyBefore, "LUMINA should decrease");
        assertEq(IERC20(usdc).balanceOf(address(burner)), 0, "USDC should be 0");
    }

    function test_RevertIf_AdaptiveModeWithoutDistributor() public {
        vm.expectRevert("FeeDistributor not set");
        burner.setAdaptiveMode(true);
    }

    function test_RevertIf_AdaptiveModeWithoutReserves() public {
        MockFeeDistributor mock = new MockFeeDistributor();
        burner.setFeeDistributor(address(mock));
        vm.expectRevert("Reserves not set");
        burner.setAdaptiveMode(true);
    }

    function test_AdaptiveMode_UnhealthyDistributorUsesFallback() public {
        MockFeeDistributor mock = new MockFeeDistributor();
        mock.setHealthy(false);
        (address buybackRes, address opsRes, address maintRes) = _setupAdaptive(mock);

        deal(usdc, address(burner), 10000e6);
        vm.warp(block.timestamp + 901);
        burner.executeBurn();

        // Fallback: 8500/800/200/500
        assertEq(IERC20(usdc).balanceOf(buybackRes), 800e6, "Buyback should get 8%");
        assertEq(IERC20(usdc).balanceOf(opsRes), 200e6, "Ops should get 2%");
        assertEq(IERC20(usdc).balanceOf(maintRes), 500e6, "Maintenance should get 5%");
    }

    function test_AdaptiveMode_HealthyDistributorUsesCustom() public {
        MockFeeDistributor mock = new MockFeeDistributor();
        mock.setHealthy(true);
        mock.setDistribution(7000, 2000, 500, 500);
        (address buybackRes, address opsRes, address maintRes) = _setupAdaptive(mock);

        deal(usdc, address(burner), 10000e6);
        vm.warp(block.timestamp + 901);
        burner.executeBurn();

        assertEq(IERC20(usdc).balanceOf(buybackRes), 2000e6, "Buyback should get 20%");
        assertEq(IERC20(usdc).balanceOf(opsRes), 500e6, "Ops should get 5%");
        assertEq(IERC20(usdc).balanceOf(maintRes), 500e6, "Maintenance should get 5%");
    }

    function test_AdaptiveMode_InvalidDistributionUsesFallback() public {
        MockFeeDistributor mock = new MockFeeDistributor();
        mock.setHealthy(true);
        mock.setDistribution(5000, 3000, 2000, 1000); // 110% invalid

        (address buybackRes, address opsRes, address maintRes) = _setupAdaptive(mock);

        deal(usdc, address(burner), 10000e6);
        vm.warp(block.timestamp + 901);
        burner.executeBurn();

        // Fallback: 8500/800/200/500
        assertEq(IERC20(usdc).balanceOf(buybackRes), 800e6, "Should use fallback 8%");
        assertEq(IERC20(usdc).balanceOf(opsRes), 200e6, "Should use fallback 2%");
        assertEq(IERC20(usdc).balanceOf(maintRes), 500e6, "Should use fallback 5%");
    }

    function test_AdaptiveMode_DistributorRevertsUsesFallback() public {
        MockFeeDistributor mock = new MockFeeDistributor();
        mock.setRevertOnHealthy(true);

        (address buybackRes, address opsRes, address maintRes) = _setupAdaptive(mock);

        deal(usdc, address(burner), 10000e6);
        vm.warp(block.timestamp + 901);
        burner.executeBurn();

        // Fallback: 8500/800/200/500
        assertEq(IERC20(usdc).balanceOf(buybackRes), 800e6, "Should use fallback 8%");
        assertEq(IERC20(usdc).balanceOf(opsRes), 200e6, "Should use fallback 2%");
        assertEq(IERC20(usdc).balanceOf(maintRes), 500e6, "Should use fallback 5%");
    }

    function test_AdaptiveMode_EmitsCorrectEvent() public {
        MockFeeDistributor mock = new MockFeeDistributor();
        mock.setHealthy(true);
        mock.setDistribution(7500, 1500, 500, 500);

        (address buybackRes, address opsRes, address maintRes) = _setupAdaptive(mock);

        deal(usdc, address(burner), 10000e6);
        vm.warp(block.timestamp + 901);

        burner.executeBurn();

        // Verify the distribution happened correctly
        assertEq(IERC20(usdc).balanceOf(buybackRes), 1500e6, "Buyback 15%");
        assertEq(IERC20(usdc).balanceOf(opsRes), 500e6, "Ops 5%");
        assertEq(IERC20(usdc).balanceOf(maintRes), 500e6, "Maintenance 5%");
    }

    function test_AdaptiveMode_GetDistributionRevertsUsesFallback() public {
        MockFeeDistributor mock = new MockFeeDistributor();
        mock.setHealthy(true);
        mock.setRevertOnGetDistribution(true);

        (address buybackRes, address opsRes, address maintRes) = _setupAdaptive(mock);

        deal(usdc, address(burner), 10000e6);
        vm.warp(block.timestamp + 901);
        burner.executeBurn();

        // Fallback: 8500/800/200/500
        assertEq(IERC20(usdc).balanceOf(buybackRes), 800e6, "Should use fallback 8%");
        assertEq(IERC20(usdc).balanceOf(opsRes), 200e6, "Should use fallback 2%");
        assertEq(IERC20(usdc).balanceOf(maintRes), 500e6, "Should use fallback 5%");
    }

    function test_AdaptiveMode_MaintenanceReceivesCorrectUSDC() public {
        MockFeeDistributor mock = new MockFeeDistributor();
        mock.setHealthy(true);
        // Use the default: 8500/800/200/500
        (,, address maintRes) = _setupAdaptive(mock);

        deal(usdc, address(burner), 10000e6);
        vm.warp(block.timestamp + 901);
        burner.executeBurn();

        assertEq(IERC20(usdc).balanceOf(maintRes), 500e6, "Maintenance should get exactly 5% of 10000 USDC");
    }

    function test_FallbackDistribution_IsNow_85_8_2_5() public {
        // Verify fallback constants
        assertEq(burner.FALLBACK_BURN_BPS(), 8500, "Fallback burn should be 85%");
        assertEq(burner.FALLBACK_BUYBACK_BPS(), 800, "Fallback buyback should be 8%");
        assertEq(burner.FALLBACK_OPS_BPS(), 200, "Fallback ops should be 2%");
        assertEq(burner.FALLBACK_MAINTENANCE_BPS(), 500, "Fallback maintenance should be 5%");

        // Also verify sum
        uint256 sum = burner.FALLBACK_BURN_BPS() + burner.FALLBACK_BUYBACK_BPS() + burner.FALLBACK_OPS_BPS()
            + burner.FALLBACK_MAINTENANCE_BPS();
        assertEq(sum, 10000, "Fallback must sum to 10000");

        // Verify actual distribution with unhealthy distributor
        MockFeeDistributor mock = new MockFeeDistributor();
        mock.setHealthy(false);
        (address buybackRes, address opsRes, address maintRes) = _setupAdaptive(mock);

        deal(usdc, address(burner), 10000e6);
        vm.warp(block.timestamp + 901);
        burner.executeBurn();

        assertEq(IERC20(usdc).balanceOf(buybackRes), 800e6, "Buyback fallback 8%");
        assertEq(IERC20(usdc).balanceOf(opsRes), 200e6, "Ops fallback 2%");
        assertEq(IERC20(usdc).balanceOf(maintRes), 500e6, "Maintenance fallback 5%");
    }
}

// Simple ERC20 mock for USDC
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _dec) {
        name = _name;
        symbol = _symbol;
        decimals = _dec;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
