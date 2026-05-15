// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AerodromeAdapter, IAerodromeRouter} from "../../../src/dex/AerodromeAdapter.sol";

/// @notice Test ERC20 with mintable supply for transfer-from path coverage.
contract AeroTestERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Mock Aerodrome router with configurable swap output + revert mode.
contract MockAerodromeRouter is IAerodromeRouter {
    uint256 public swapRate = 30; // tokenIn:tokenOut = 1:30 (e.g. USDC -> LUM)
    bool public revertOnGetAmountsOut;
    bool public returnEmptyAmounts;
    address public tokenOutSink;

    function setSwapRate(uint256 r) external {
        swapRate = r;
    }

    function setRevertGetAmountsOut(bool r) external {
        revertOnGetAmountsOut = r;
    }

    function setReturnEmptyAmounts(bool e) external {
        returnEmptyAmounts = e;
    }

    function setTokenOutSink(address s) external {
        tokenOutSink = s;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 /*deadline*/
    ) external override returns (uint256[] memory amounts) {
        // Pull tokenIn from caller (the adapter approved us).
        AeroTestERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * swapRate;
        require(out >= amountOutMin, "Mock: minOut");
        // Mint output to recipient.
        AeroTestERC20(routes[0].to).mint(to, out);
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[amounts.length - 1] = out;
    }

    function getAmountsOut(uint256 amountIn, Route[] memory routes)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        if (revertOnGetAmountsOut) revert("Mock: quote revert");
        if (returnEmptyAmounts) {
            amounts = new uint256[](0);
            return amounts;
        }
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[amounts.length - 1] = amountIn * swapRate;
    }
}

contract AerodromeAdapterTest is Test {
    AerodromeAdapter adapter;
    MockAerodromeRouter router;
    AeroTestERC20 tokenIn;
    AeroTestERC20 tokenOut;
    address factory = makeAddr("factory");
    address user = makeAddr("user");

    function setUp() public {
        vm.chainId(8453);
        router = new MockAerodromeRouter();
        tokenIn = new AeroTestERC20("IN", "IN");
        tokenOut = new AeroTestERC20("OUT", "OUT");
        adapter = new AerodromeAdapter(address(router), factory, false);
    }

    // ─────────────── Constructor ───────────────

    function test_Constructor_Success_VolatilePool() public {
        AerodromeAdapter a = new AerodromeAdapter(address(router), factory, false);
        assertEq(address(a.router()), address(router));
        assertEq(a.factory(), factory);
        assertFalse(a.stable());
    }

    function test_Constructor_Success_StablePool() public {
        AerodromeAdapter a = new AerodromeAdapter(address(router), factory, true);
        assertTrue(a.stable());
    }

    function test_Constructor_RevertIf_ZeroRouter() public {
        vm.expectRevert(bytes("Zero router"));
        new AerodromeAdapter(address(0), factory, false);
    }

    function test_Constructor_RevertIf_ZeroFactory() public {
        vm.expectRevert(bytes("Zero factory"));
        new AerodromeAdapter(address(router), address(0), false);
    }

    // ─────────────── swap ───────────────

    function test_Swap_HappyPath_ReturnsAmount() public {
        tokenIn.mint(user, 1000e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1000e18);
        uint256 out = adapter.swap(address(tokenIn), address(tokenOut), 1000e18, 25_000e18);
        vm.stopPrank();
        assertEq(out, 1000e18 * 30, "swap output mismatch");
        assertEq(tokenOut.balanceOf(user), 30_000e18, "user did not receive tokenOut");
    }

    function test_Swap_RevertIf_BelowMinOut() public {
        tokenIn.mint(user, 1000e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1000e18);
        // minOut higher than rate → mock router reverts.
        vm.expectRevert(bytes("Mock: minOut"));
        adapter.swap(address(tokenIn), address(tokenOut), 1000e18, 100_000e18);
        vm.stopPrank();
    }

    // ─────────────── getQuote ───────────────

    function test_GetQuote_HappyPath() public view {
        uint256 q = adapter.getQuote(address(tokenIn), address(tokenOut), 1000e18);
        assertEq(q, 1000e18 * 30, "quote mismatch");
    }

    function test_GetQuote_AmountInZero_Returns0() public view {
        uint256 q = adapter.getQuote(address(tokenIn), address(tokenOut), 0);
        assertEq(q, 0, "expected 0 for amountIn=0");
    }

    function test_GetQuote_RouterReverts_Returns0() public {
        router.setRevertGetAmountsOut(true);
        uint256 q = adapter.getQuote(address(tokenIn), address(tokenOut), 1000e18);
        assertEq(q, 0, "expected 0 when router reverts");
    }

    function test_GetQuote_EmptyAmounts_Returns0() public {
        router.setReturnEmptyAmounts(true);
        uint256 q = adapter.getQuote(address(tokenIn), address(tokenOut), 1000e18);
        assertEq(q, 0, "expected 0 when router returns empty amounts array");
    }

    // ─────────────── setFactory ───────────────

    function test_SetFactory_Owner_Success() public {
        address newFactory = makeAddr("newFactory");
        adapter.setFactory(newFactory);
        assertEq(adapter.factory(), newFactory);
    }

    function test_SetFactory_RevertIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.setFactory(makeAddr("newFactory"));
    }

    function test_SetFactory_RevertIf_Zero() public {
        vm.expectRevert(bytes("Zero factory"));
        adapter.setFactory(address(0));
    }

    // ─────────────── setStable ───────────────

    function test_SetStable_Owner_Success() public {
        assertFalse(adapter.stable());
        adapter.setStable(true);
        assertTrue(adapter.stable());
        adapter.setStable(false);
        assertFalse(adapter.stable());
    }

    function test_SetStable_RevertIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.setStable(true);
    }
}
