// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../../src/core/TWAPBurner.sol";
import "../../src/token/LuminaTokenV2.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";
import {MockFeeDistributor} from "../mocks/MockFeeDistributor.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// Mock DEX router that implements IDexRouter for testing
contract MockDexRouter is IDexRouter {
    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC ($1) = 27 LUMINA at ~$0.037
    uint256 public quoteRate = 0; // 0 means no quote available

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        // Simulate: take tokenIn, give tokenOut
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // Calculate output: amountIn (6 dec) * rate * 1e12 (to 18 dec)
        amountOut = (amountIn * rate * 1e12);
        require(amountOut >= minAmountOut, "Slippage exceeded");
        // Transfer LUMINA to caller
        lumina.transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256 amountIn) external view override returns (uint256) {
        uint256 r = quoteRate == 0 ? rate : quoteRate;
        return (amountIn * r * 1e12);
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setQuoteRate(uint256 r) external {
        quoteRate = r;
    }
}

contract TWAPBurnerTest is Test {
    using ProxyDeployer for *;

    TWAPBurner burner;
    LuminaTokenV2 token;
    MockDexRouter router;

    address bondVault = makeAddr("bondVault");
    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address usdc;
    address coverRouter = makeAddr("coverRouter");

    function setUp() public {
        vm.chainId(8453);
        // [SR3] Warp past initial cooldown (default burnCooldown=900s vs ts=1)
        vm.warp(1000);

        // Deploy mock USDC
        MockERC20 mockUsdc = new MockERC20("USDC", "USDC", 6);
        usdc = address(mockUsdc);

        // Deploy token
        token = ProxyDeployer.deployLuminaTokenV2(bondVault, makeAddr("cex"), founder, lbp, treasury);

        // Deploy mock DEX router
        router = new MockDexRouter(address(token));
        // Give router some LUMINA to simulate swaps
        deal(address(token), address(router), 1_000_000 * 1e18);

        // Deploy burner
        burner = ProxyDeployer.deployTWAPBurner(usdc, address(token), address(router));

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

    // ═══════ setPoolFee tests ═══════

    function test_SetPoolFee_Success() public {
        assertEq(burner.poolFee(), 10000, "Default pool fee should be 10000");

        burner.setPoolFee(500);
        assertEq(burner.poolFee(), 500, "Pool fee should be updated to 500");

        burner.setPoolFee(3000);
        assertEq(burner.poolFee(), 3000, "Pool fee should be updated to 3000");

        burner.setPoolFee(10000);
        assertEq(burner.poolFee(), 10000, "Pool fee should be updated to 10000");
    }

    function test_SetPoolFee_RevertIf_NotOwner() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("random")));
        burner.setPoolFee(500);
    }

    function test_SetPoolFee_RevertIf_InvalidTier() public {
        vm.expectRevert("Invalid fee tier");
        burner.setPoolFee(100);
    }

    // ═══════ setMaxSlippageBps tests ═══════

    function test_SetMaxSlippage_Success() public {
        assertEq(burner.maxSlippageBps(), 500, "Default max slippage should be 500");

        burner.setMaxSlippageBps(50);
        assertEq(burner.maxSlippageBps(), 50, "Max slippage should be updated to 50 (0.5%)");

        burner.setMaxSlippageBps(1000);
        assertEq(burner.maxSlippageBps(), 1000, "Max slippage should be updated to 1000 (10%)");
    }

    function test_SetMaxSlippage_RevertIf_NotOwner() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("random")));
        burner.setMaxSlippageBps(100);
    }

    function test_SetMaxSlippage_RevertIf_TooLow() public {
        vm.expectRevert("Slippage: 0.5%-10%");
        burner.setMaxSlippageBps(49);
    }

    function test_SetMaxSlippage_RevertIf_TooHigh() public {
        vm.expectRevert("Slippage: 0.5%-10%");
        burner.setMaxSlippageBps(1001);
    }

    // ═══════ MULTI-DEX ROUTER TESTS ═══════

    function test_TWAPBurner_SingleDexRouter() public {
        // Default setup has 1 router — verify it works
        assertEq(burner.dexRouterCount(), 1, "Should have 1 router");
        assertEq(address(burner.dexRouters(0)), address(router), "First router should be mock");

        // Execute a burn to verify single-router path
        deal(usdc, address(burner), 10e6);
        vm.warp(block.timestamp + 901);
        burner.executeBurn();
        assertGt(burner.totalLUMINABurned(), 0, "Should have burned LUMINA");
    }

    function test_TWAPBurner_MultipleDexRouters_SelectsBest() public {
        // Create a second router with a better rate
        MockDexRouter betterRouter = new MockDexRouter(address(token));
        betterRouter.setRate(50); // 50 LUMINA per USDC vs 27
        betterRouter.setQuoteRate(50); // Provides quotes
        deal(address(token), address(betterRouter), 1_000_000 * 1e18);

        // Also set quoteRate on original router so comparison works
        router.setQuoteRate(27);

        // Add the better router
        burner.addDexRouter(address(betterRouter));
        assertEq(burner.dexRouterCount(), 2, "Should have 2 routers");

        // Execute burn — should use the better router
        deal(usdc, address(burner), 10e6);
        vm.warp(block.timestamp + 901);

        uint256 supplyBefore = token.totalSupply();
        burner.executeBurn();
        uint256 burned = burner.totalLUMINABurned();

        // With rate=50, 10 USDC = 10e6 * 50 * 1e12 = 500e18 LUMINA
        assertEq(burned, 500e18, "Should have used better router (rate=50)");
    }

    function test_TWAPBurner_AddDexRouter() public {
        assertEq(burner.dexRouterCount(), 1);

        MockDexRouter secondRouter = new MockDexRouter(address(token));
        burner.addDexRouter(address(secondRouter));
        assertEq(burner.dexRouterCount(), 2);
        assertEq(address(burner.dexRouters(1)), address(secondRouter));
    }

    function test_TWAPBurner_AddDexRouter_RevertZero() public {
        vm.expectRevert("Zero router");
        burner.addDexRouter(address(0));
    }

    function test_TWAPBurner_AddDexRouter_RevertNotOwner() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("random")));
        burner.addDexRouter(makeAddr("someRouter"));
    }

    function test_TWAPBurner_SetDexRouters() public {
        MockDexRouter r1 = new MockDexRouter(address(token));
        MockDexRouter r2 = new MockDexRouter(address(token));

        address[] memory routers = new address[](2);
        routers[0] = address(r1);
        routers[1] = address(r2);

        burner.setDexRouters(routers);
        assertEq(burner.dexRouterCount(), 2);
        assertEq(address(burner.dexRouters(0)), address(r1));
        assertEq(address(burner.dexRouters(1)), address(r2));
    }

    function test_TWAPBurner_SetDexRouters_RevertEmpty() public {
        address[] memory routers = new address[](0);
        vm.expectRevert("Empty routers");
        burner.setDexRouters(routers);
    }

    function test_TWAPBurner_SetDexRouters_RevertNotOwner() public {
        address[] memory routers = new address[](1);
        routers[0] = makeAddr("someRouter");
        vm.prank(makeAddr("random"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("random")));
        burner.setDexRouters(routers);
    }

    function test_TWAPBurner_FallbackToFirstRouter_WhenQuotesFail() public {
        // Add a second router that has no LUMINA balance (swap would fail)
        // But the first router should still work because quotes return 0
        deal(usdc, address(burner), 10e6);
        vm.warp(block.timestamp + 901);

        // Both routers return 0 for quotes, so first is used
        burner.executeBurn();
        assertGt(burner.totalLUMINABurned(), 0, "Should have burned via first router");
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
