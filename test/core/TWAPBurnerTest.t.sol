// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/v2/core/TWAPBurner.sol";
import "../../src/v2/token/LuminaTokenV2.sol";

// Mock swap router that simulates Uniswap swap
contract MockSwapRouter {
    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC ($1) = 27.7 LUMINA at $0.036

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external returns (uint256 amountOut)
    {
        // Simulate: take USDC, give LUMINA
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        // Calculate LUMINA output: amountIn (6 dec) * rate * 1e12 (to 18 dec)
        amountOut = (params.amountIn * rate * 1e12);
        // Transfer LUMINA to recipient
        lumina.transfer(params.recipient, amountOut);
    }

    function setRate(uint256 r) external { rate = r; }
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
        // Deploy mock USDC
        MockERC20 mockUsdc = new MockERC20("USDC", "USDC", 6);
        usdc = address(mockUsdc);

        // Deploy token
        token = new LuminaTokenV2(bondVault, lbp, founder, treasury);

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
        (uint256 received, uint256 burned, uint256 luminaBurned,
         uint256 pending, uint256 lastBurn, bool canBurn_) = burner.getStats();
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
