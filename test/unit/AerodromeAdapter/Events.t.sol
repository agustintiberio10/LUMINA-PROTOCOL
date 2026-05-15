// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AerodromeAdapter, IAerodromeRouter} from "../../../src/dex/AerodromeAdapter.sol";

contract AAERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract AAMockRouter is IAerodromeRouter {
    uint256 public rate = 30;

    function swapExactTokensForTokens(uint256 amountIn, uint256 minOut, Route[] calldata routes, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        AAERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate;
        require(out >= minOut, "minOut");
        AAERC20(routes[0].to).mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function getAmountsOut(uint256 amountIn, Route[] memory) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * rate;
    }
}

contract AerodromeAdapterEvents is Test {
    event SwapExecuted(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event StableUpdated(bool oldStable, bool newStable);

    AerodromeAdapter adapter;
    AAMockRouter router;
    AAERC20 tokenIn;
    AAERC20 tokenOut;
    address user = makeAddr("user");
    address factory = makeAddr("factory");

    function setUp() public {
        vm.chainId(8453);
        router = new AAMockRouter();
        tokenIn = new AAERC20("IN", "IN");
        tokenOut = new AAERC20("OUT", "OUT");
        adapter = new AerodromeAdapter(address(router), factory, false);
    }

    function test_Event_SwapExecuted_Emitted() public {
        tokenIn.mint(user, 1000e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1000e18);
        vm.expectEmit(true, true, true, true);
        emit SwapExecuted(user, address(tokenIn), address(tokenOut), 1000e18, 30_000e18);
        adapter.swap(address(tokenIn), address(tokenOut), 1000e18, 25_000e18);
        vm.stopPrank();
    }

    function test_Event_FactoryUpdated_Emitted() public {
        address newFactory = makeAddr("newFactory");
        vm.expectEmit(true, true, false, false);
        emit FactoryUpdated(factory, newFactory);
        adapter.setFactory(newFactory);
    }

    function test_Event_StableUpdated_Emitted() public {
        vm.expectEmit(false, false, false, true);
        emit StableUpdated(false, true);
        adapter.setStable(true);
    }
}
