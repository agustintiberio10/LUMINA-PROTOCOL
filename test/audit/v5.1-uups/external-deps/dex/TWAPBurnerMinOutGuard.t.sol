// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

contract MockDexRouterGuard is IDexRouter {
    using SafeERC20 for IERC20;

    uint256 public quoteReturn;
    uint256 public swapOutput;
    bool public revertOnSwap;
    bool public revertOnQuote;
    uint256 public callCount;

    function setQuote(uint256 q) external {
        quoteReturn = q;
    }

    function setSwapOutput(uint256 o) external {
        swapOutput = o;
    }

    function setRevertOnSwap(bool v) external {
        revertOnSwap = v;
    }

    function setRevertOnQuote(bool v) external {
        revertOnQuote = v;
    }

    function getQuote(address, address, uint256) external view returns (uint256) {
        require(!revertOnQuote, "quote reverted");
        return quoteReturn;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        require(!revertOnSwap, "swap reverted");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = swapOutput;
        require(amountOut >= minAmountOut, "slippage");
        if (amountOut > 0 && IERC20(tokenOut).balanceOf(address(this)) >= amountOut) {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
        callCount++;
    }
}

contract MockUSDCGuard {
    mapping(address => uint256) public balance;
    mapping(address => mapping(address => uint256)) public allowed;
    string public name = "USDC";
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external {
        balance[to] += amount;
    }

    function balanceOf(address who) external view returns (uint256) {
        return balance[who];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowed[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowed[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balance[msg.sender] -= amount;
        balance[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowed[from][msg.sender] != type(uint256).max) {
            allowed[from][msg.sender] -= amount;
        }
        balance[from] -= amount;
        balance[to] += amount;
        return true;
    }
}

contract MockCapacityOracleGuard {
    uint256 public priceVal;
    bool public shouldRevert;

    function setPrice(uint256 p) external {
        priceVal = p;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function getLuminaPrice() external view returns (uint256) {
        require(!shouldRevert, "oracle down");
        return priceVal;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

/**
 * @title TWAPBurnerMinOutGuard
 * @notice Verifies M-02 fix: TWAPBurner now refuses to swap if minOut
 *         ends up at 0 (both adapter quotes AND capacity oracle fail).
 */
contract TWAPBurnerMinOutGuard is Test {
    LuminaTokenV2 lumina;
    MockUSDCGuard usdc;
    MockDexRouterGuard router1;
    MockDexRouterGuard router2;
    MockCapacityOracleGuard capOracle;
    TWAPBurner burner;

    function setUp() public {
        lumina = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        usdc = new MockUSDCGuard();
        router1 = new MockDexRouterGuard();
        router2 = new MockDexRouterGuard();
        capOracle = new MockCapacityOracleGuard();

        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(router1));
        lumina.grantRole(lumina.BURNER_ROLE(), address(burner));

        burner.setMaxSlippageBps(500);
        burner.setMinBurnAmount(1e6);
        burner.setMaxBurnAmount(100_000e6);
        vm.warp(block.timestamp + 901);
    }

    function _fund(uint256 amt) internal {
        usdc.mint(address(burner), amt);
    }

    // ─────────────────────────────────────────────────────────────
    // All quotes revert AND oracle unset → minOut = 0 → guard reverts
    // ─────────────────────────────────────────────────────────────
    function test_FixM02_Guard_AllQuotesZero_NoOracle_Reverts() public {
        _fund(10e6);
        router1.setRevertOnQuote(true); // quote = 0 via try/catch
        // capacityOracle not set → minOut stays 0
        deal(address(lumina), address(router1), 100e18);
        router1.setSwapOutput(100e18);

        vm.expectRevert(bytes("TWAPBurner: minOut must be > 0"));
        burner.executeBurn();
    }

    // ─────────────────────────────────────────────────────────────
    // Quotes zero, oracle reverts → still minOut = 0 → guard reverts
    // ─────────────────────────────────────────────────────────────
    function test_FixM02_Guard_AllQuotesZero_OracleReverts_Reverts() public {
        _fund(10e6);
        router1.setRevertOnQuote(true);
        capOracle.setShouldRevert(true);
        burner.setCapacityOracle(address(capOracle));
        deal(address(lumina), address(router1), 100e18);
        router1.setSwapOutput(100e18);

        vm.expectRevert(bytes("TWAPBurner: minOut must be > 0"));
        burner.executeBurn();
    }

    // ─────────────────────────────────────────────────────────────
    // Quote non-zero → minOut derives from quote → guard passes
    // ─────────────────────────────────────────────────────────────
    function test_FixM02_Guard_QuoteNonZero_Succeeds() public {
        _fund(10e6);
        router1.setQuote(100e18);
        router1.setSwapOutput(100e18);
        deal(address(lumina), address(router1), 100e18);
        burner.executeBurn();
        assertEq(router1.callCount(), 1);
    }

    // ─────────────────────────────────────────────────────────────
    // Oracle provides minOut backstop → guard passes
    // ─────────────────────────────────────────────────────────────
    function test_FixM02_Guard_OracleOnly_Succeeds() public {
        _fund(10e6);
        router1.setRevertOnQuote(true);
        capOracle.setPrice(0.036e18);
        burner.setCapacityOracle(address(capOracle));
        // Oracle-derived expected ≈ (10e6 × 1e12 × 1e18) / 0.036e18 ≈ 2.78e20
        uint256 expected = (uint256(10e6) * 1e12 * 1e18) / 0.036e18;
        uint256 minOut = (expected * 9500) / 10000;
        deal(address(lumina), address(router1), expected);
        router1.setSwapOutput(minOut);
        burner.executeBurn();
        assertEq(router1.callCount(), 1);
    }

    // ─────────────────────────────────────────────────────────────
    // Best-router selection still picks higher quote
    // ─────────────────────────────────────────────────────────────
    function test_FixM02_Guard_BestQuote_StillPickedWhenBothNonZero() public {
        _fund(10e6);
        router1.setQuote(1000e18);
        router2.setQuote(1200e18); // best
        // router2's swap must return at least 1200 × 0.95 = 1140
        router2.setSwapOutput(1200e18);
        deal(address(lumina), address(router2), 1200e18);

        address[] memory rs = new address[](2);
        rs[0] = address(router1);
        rs[1] = address(router2);
        burner.setDexRouters(rs);

        burner.executeBurn();
        assertEq(router2.callCount(), 1);
        assertEq(router1.callCount(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // Combined M-01 + M-02: both fixes coexist on unrelated contracts
    // ─────────────────────────────────────────────────────────────
    function test_FixM02_CombinedWithM01_NoRegression() public {
        // This contract doesn't use shields, but we assert that running a
        // TWAPBurner cycle with the new guard doesn't interact with the
        // shield sanity-bounds fix (completely independent code paths).
        _fund(10e6);
        router1.setQuote(100e18);
        router1.setSwapOutput(100e18);
        deal(address(lumina), address(router1), 100e18);
        burner.executeBurn();
        assertEq(burner.totalLUMINABurned(), 100e18);
    }
}
