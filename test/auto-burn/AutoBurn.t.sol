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

// [legacy-migration] pattern #3 (F-19): TWAPBurner._swapAndBurn now derives the
// protective `minOut` exclusively from the capacity oracle and REVERTS with
// "TWAPBurner: oracle unset" if it is not wired. executeBurn() therefore needs a
// capacity oracle in place. Minimal IPriceOracle mock with a settable price.
contract MockCapacityOracle {
    uint256 public price;

    function setPrice(uint256 p) external {
        price = p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

contract AutoBurnTest is Test {
    using SafeERC20 for IERC20;

    MockUSDC internal usdc;
    MockLumina internal lumina;
    MockDex internal dex;
    MockCapacityOracle internal capOracle;
    TWAPBurner internal burner;

    address internal constant ROUTER_CALLER = address(0xA0);
    address internal constant BUYER = address(0xB1);
    address internal constant TREASURY = address(0xCAFE);
    address internal constant NON_OWNER = address(0xBAD);

    uint256 internal constant MAX_PURCHASES = 50;
    uint256 internal constant MAX_USDC = 500e6; // $500
    uint256 internal constant REFUND_CAP = 0.001 ether;

    // [legacy-migration] Oracle price of $1/LUMINA keeps the derived minOut small
    // enough that the mock DEX's fixed swapOutput clears the slippage floor.
    uint256 internal constant ORACLE_PRICE = 1e18;

    function setUp() public {
        vm.chainId(8453);
        // [legacy-migration] autoBurnReady()/executeBurn() are cooldown-gated
        // (block.timestamp >= lastBurnTimestamp + burnCooldown). With the Foundry
        // default block.timestamp == 1 and burnCooldown == 900, the cooldown would
        // never be satisfied. Warp well past it so the async burn path is reachable.
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        lumina = new MockLumina();
        dex = new MockDex(address(usdc), address(lumina));
        // Pre-fund the DEX with LUMINA so it can deliver swap output.
        lumina.mint(address(dex), 1_000_000e18);
        // Generous fixed output that beats the oracle-derived minOut for the
        // burn sizes exercised here (<= 500e6 USDC at $1/LUMINA ~ <= 500e18 out).
        dex.setSwapOutput(1_000e18);

        // Deploy TWAPBurner V1 then run initializeV2 on the same proxy.
        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(dex));
        burner.initializeV2(MAX_PURCHASES, MAX_USDC, true, REFUND_CAP, TREASURY);

        // [legacy-migration] pattern #3: wire the capacity oracle so executeBurn()'s
        // _swapAndBurn can derive a non-zero minOut instead of reverting.
        capOracle = new MockCapacityOracle();
        capOracle.setPrice(ORACLE_PRICE);
        burner.setCapacityOracle(address(capOracle));

        // Mint USDC for the router-style caller and approve once.
        usdc.mint(ROUTER_CALLER, 10_000_000e6);
        vm.prank(ROUTER_CALLER);
        usdc.approve(address(burner), type(uint256).max);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _send(uint256 amount) internal {
        // [legacy-migration] tx.origin is no longer consulted on the burn path
        // (F-22), but the two-arg prank is harmless and preserves caller intent.
        vm.prank(ROUTER_CALLER, BUYER); // tx.origin = BUYER, msg.sender = ROUTER_CALLER
        burner.receivePremium(amount);
    }

    function _send49ThenCheck() internal {
        for (uint256 i = 0; i < 49; i++) {
            _send(1e6);
        }
        assertEq(burner.purchaseCounter(), 49, "counter pre-50");
        assertEq(burner.totalUSDCBurned(), 0, "no burn yet");
        assertFalse(burner.autoBurnReady(), "not ready before threshold");
    }

    // ───────────────────────────── tests ───────────────────────────────

    /// 1. [legacy-migration] pattern #3/#10 (F-13/F-22/F-24): the burn is no longer
    ///    performed synchronously inside the 50th receivePremium. Instead the 50th
    ///    receipt flips autoBurnReady() true and a permissionless executeBurn()
    ///    performs the burn and resets the accrual counters. The old test asserted
    ///    an AutoBurnTriggered event emitted from receivePremium — that event is no
    ///    longer emitted by any code path (the synchronous in-purchase burn was
    ///    removed), so we assert the new async flow instead.
    function test_burn_after_50_purchases() external {
        _send49ThenCheck();

        // 50th receipt: accrues, does NOT burn in-tx, but arms autoBurnReady().
        _send(1e6);
        assertEq(burner.purchaseCounter(), 50, "counter accrued to threshold");
        assertEq(burner.totalUSDCBurned(), 0, "no synchronous burn in receivePremium");
        assertTrue(burner.autoBurnReady(), "auto-burn armed after 50th purchase");

        // Permissionless settlement performs the actual burn.
        burner.executeBurn();

        assertEq(burner.purchaseCounter(), 0, "counter reset");
        assertEq(burner.accumulatedUSDCSinceBurn(), 0, "USDC accumulator reset");
        assertGt(burner.totalUSDCBurned(), 0, "burn happened");
        assertEq(burner.lastBurnTimestamp(), block.timestamp, "lastBurnTimestamp updated");
        assertFalse(burner.autoBurnReady(), "disarmed after burn");
    }

    /// 2. [legacy-migration] pattern #3/#10: the USDC accumulator threshold arms
    ///    autoBurnReady() on the first large receipt; executeBurn() settles it.
    function test_burn_after_500_USDC_accumulated() external {
        _send(600e6);
        assertEq(burner.accumulatedUSDCSinceBurn(), 600e6, "accumulator tracks receipt");
        assertEq(burner.totalUSDCBurned(), 0, "no synchronous burn");
        assertTrue(burner.autoBurnReady(), "armed once accumulator passes 500 USDC");

        burner.executeBurn();

        assertEq(burner.purchaseCounter(), 0, "counter reset");
        assertEq(burner.accumulatedUSDCSinceBurn(), 0, "USDC accumulator reset");
        assertGt(burner.totalUSDCBurned(), 0, "burn happened");
    }

    /// 3. [legacy-migration] pattern #10: receivePremium always just accrues and
    ///    never reverts regardless of DEX health (no swap in the buyer's tx). When
    ///    the DEX swap reverts, the async executeBurn() reverts and the USDC is
    ///    retained for a later retry; the accrual counters are NOT reset because no
    ///    burn occurred. (Old behavior reset counters even on burn failure inside
    ///    receivePremium — that synchronous path no longer exists.)
    function test_purchase_succeeds_when_burn_fails() external {
        _send49ThenCheck();
        _send(1e6); // 50th — accrues, never reverts
        assertEq(burner.purchaseCounter(), 50, "accrued without reverting");

        dex.setRevertOnSwap(true);

        vm.expectRevert(bytes("swap reverted"));
        burner.executeBurn();

        // Failed settlement: nothing burned, USDC retained, counters intact.
        assertEq(burner.totalUSDCBurned(), 0, "no burn recorded");
        assertGt(usdc.balanceOf(address(burner)), 0, "USDC retained for retry");
        assertEq(burner.purchaseCounter(), 50, "counters untouched on failed burn");
    }

    /// 4. [legacy-migration] removed: gas-refund-to-buyer path. The F-13/F-22 fix
    ///    deleted the synchronous in-purchase auto-burn AND its tx.origin-derived
    ///    gas refund. The gasRefund* storage vars are now DORMANT — no code path
    ///    pays a refund (see TWAPBurner receive()/initializeV2 NatSpec). This test
    ///    asserted a refund was delivered to BUYER, which can no longer happen.

    /// 5. [legacy-migration] removed: "gas refund disabled" companion to test 4.
    ///    With the refund path removed entirely, the enabled/disabled distinction
    ///    no longer exists, so the assertion is obsolete.

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
