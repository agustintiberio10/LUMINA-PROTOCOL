// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockLumina is ERC20 {
    constructor() ERC20("LUMINA", "LUMINA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract MockDex is IDexRouter {
    using SafeERC20 for IERC20;

    address public usdc;
    address public lumina;
    bool public revertOnSwap;
    uint256 public swapOutput;

    constructor(address _usdc, address _lumina) {
        usdc = _usdc;
        lumina = _lumina;
        swapOutput = 1e18;
    }

    function setRevertOnSwap(bool v) external {
        revertOnSwap = v;
    }

    function setSwapOutput(uint256 v) external {
        swapOutput = v;
    }

    function getQuote(address, address, uint256) external view returns (uint256) {
        return swapOutput;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut)
    {
        require(!revertOnSwap, "swap reverted");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = swapOutput;
        require(amountOut >= minOut, "slippage");
        if (IERC20(tokenOut).balanceOf(address(this)) >= amountOut) {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
    }
}

contract AutoBurnTest is Test {
    using SafeERC20 for IERC20;

    MockUSDC internal usdc;
    MockLumina internal lumina;
    MockDex internal dex;
    TWAPBurner internal burner;

    address internal constant ROUTER_CALLER = address(0xA0);
    address internal constant BUYER = address(0xB1);
    address internal constant TREASURY = address(0xCAFE);
    address internal constant NON_OWNER = address(0xBAD);

    uint256 internal constant MAX_PURCHASES = 50;
    uint256 internal constant MAX_USDC = 500e6; // $500
    uint256 internal constant REFUND_CAP = 0.001 ether;

    event AutoBurnTriggered(uint256 amount, address indexed router, address indexed gasRecipient);
    event AutoBurnFailed(uint256 amount, bytes reason);
    event GasRefunded(address indexed recipient, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();
        lumina = new MockLumina();
        dex = new MockDex(address(usdc), address(lumina));
        // Pre-fund the DEX with LUMINA so it can deliver swap output.
        lumina.mint(address(dex), 1_000_000e18);

        // Deploy TWAPBurner V1 then run initializeV2 on the same proxy.
        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(dex));
        burner.initializeV2(MAX_PURCHASES, MAX_USDC, true, REFUND_CAP, TREASURY);

        // Mint USDC for the router-style caller and approve once.
        usdc.mint(ROUTER_CALLER, 10_000_000e6);
        vm.prank(ROUTER_CALLER);
        usdc.approve(address(burner), type(uint256).max);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _send(uint256 amount) internal {
        vm.prank(ROUTER_CALLER, BUYER); // tx.origin = BUYER, msg.sender = ROUTER_CALLER
        burner.receivePremium(amount);
    }

    function _send49ThenCheck() internal {
        for (uint256 i = 0; i < 49; i++) {
            _send(1e6);
        }
        assertEq(burner.purchaseCounter(), 49, "counter pre-50");
        assertEq(burner.totalUSDCBurned(), 0, "no burn yet");
    }

    // ───────────────────────────── tests ───────────────────────────────

    /// 1. Burn fires on the 50th purchase.
    function test_burn_after_50_purchases() external {
        _send49ThenCheck();

        // 50th
        vm.expectEmit(true, true, false, false, address(burner));
        emit AutoBurnTriggered(50e6, ROUTER_CALLER, BUYER);
        _send(1e6);

        assertEq(burner.purchaseCounter(), 0, "counter reset");
        assertEq(burner.accumulatedUSDCSinceBurn(), 0, "USDC accumulator reset");
        assertGt(burner.totalUSDCBurned(), 0, "burn happened");
        assertEq(burner.lastBurnTimestamp(), block.timestamp, "lastBurnTimestamp updated");
    }

    /// 2. Burn fires on first purchase if it exceeds the USDC threshold.
    function test_burn_after_500_USDC_accumulated() external {
        vm.expectEmit(true, true, false, false, address(burner));
        emit AutoBurnTriggered(600e6, ROUTER_CALLER, BUYER);
        _send(600e6);

        assertEq(burner.purchaseCounter(), 0, "counter reset");
        assertEq(burner.accumulatedUSDCSinceBurn(), 0, "USDC accumulator reset");
        assertGt(burner.totalUSDCBurned(), 0, "burn happened");
    }

    /// 3. Purchase succeeds even when the DEX swap reverts; counters still reset.
    function test_purchase_succeeds_when_burn_fails() external {
        _send49ThenCheck();
        dex.setRevertOnSwap(true);

        vm.expectEmit(true, true, false, false, address(burner));
        emit AutoBurnTriggered(50e6, ROUTER_CALLER, BUYER);
        // Don't assert exact AutoBurnFailed payload; just ensure tx does not revert.
        _send(1e6);

        assertEq(burner.purchaseCounter(), 0, "counter reset even on burn failure");
        assertEq(burner.totalUSDCBurned(), 0, "no burn recorded");
        assertGt(usdc.balanceOf(address(burner)), 0, "USDC retained for retry");
    }

    /// 4. Gas refund delivered to recipient and capped.
    function test_gas_refund_within_cap() external {
        // Pre-fund the burner with ETH so refund can be paid.
        vm.deal(address(burner), 1 ether);
        uint256 buyerEthBefore = BUYER.balance;

        // Use a non-zero gas price so refund > 0.
        vm.txGasPrice(50 gwei);

        for (uint256 i = 0; i < 50; i++) {
            _send(1e6);
        }

        uint256 received = BUYER.balance - buyerEthBefore;
        assertGt(received, 0, "refund delivered");
        assertLe(received, REFUND_CAP, "refund within cap");
    }

    /// 5. Gas refund disabled → no ETH transferred.
    function test_gas_refund_disabled() external {
        burner.setGasRefundConfig(false, REFUND_CAP, TREASURY);
        vm.deal(address(burner), 1 ether);
        uint256 buyerEthBefore = BUYER.balance;
        vm.txGasPrice(50 gwei);

        for (uint256 i = 0; i < 50; i++) {
            _send(1e6);
        }

        assertEq(BUYER.balance, buyerEthBefore, "no refund");
        assertEq(address(burner).balance, 1 ether, "balance untouched");
    }

    /// 6. Storage layout: pre-existing getters keep their initial values after initializeV2.
    function test_storage_layout_preserved() external view {
        assertEq(address(burner.usdc()), address(usdc));
        assertEq(address(burner.lumina()), address(lumina));
        assertEq(burner.minBurnAmount(), 1e6);
        assertEq(burner.maxBurnAmount(), 10_000e6);
        assertEq(burner.burnCooldown(), 900);
        assertEq(burner.poolFee(), 10_000);
        assertEq(burner.maxSlippageBps(), 500);
    }

    /// 7. Only owner can change auto-burn / refund config.
    function test_only_owner_can_change_config() external {
        vm.startPrank(NON_OWNER);
        vm.expectRevert();
        burner.setAutoBurnConfig(10, 100e6);
        vm.expectRevert();
        burner.setGasRefundConfig(false, 0, address(0));
        vm.stopPrank();

        // Owner path works.
        burner.setAutoBurnConfig(10, 100e6);
        assertEq(burner.maxPurchasesBeforeBurn(), 10);
        assertEq(burner.maxAccumulatedUSDCBeforeBurn(), 100e6);
    }

    /// 8. initializeV2 cannot be called twice.
    function test_initializeV2_only_once() external {
        vm.expectRevert();
        burner.initializeV2(100, 1000e6, false, 0, address(0));
    }
}
