// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {UniswapV3Adapter} from "../../src/dex/UniswapV3Adapter.sol";
import {AerodromeAdapter} from "../../src/dex/AerodromeAdapter.sol";

/// @title MRM06_DexMinOutFloor
/// @notice [MR-M06 fix] Each adapter's `swap` must reject a zero minOut floor.
///         A caller passing minOut=0 has no slippage protection and is
///         trivially sandwiched; the adapter now requires `minOut > 0`.
contract MRM06_DexMinOutFloorTest is Test {
    MockToken internal tokenIn;
    MockToken internal tokenOut;

    UniswapV3Adapter internal uniAdapter;
    AerodromeAdapter internal aeroAdapter;

    MockSwapRouter internal uniRouter;
    MockQuoter internal uniQuoter;
    MockAerodromeRouter internal aeroRouter;

    address internal constant FACTORY = address(0xFAC);

    function setUp() public {
        tokenIn = new MockToken("IN", "IN");
        tokenOut = new MockToken("OUT", "OUT");

        uniRouter = new MockSwapRouter();
        uniQuoter = new MockQuoter();
        uniAdapter = new UniswapV3Adapter(address(uniRouter), address(uniQuoter), 3000);

        aeroRouter = new MockAerodromeRouter();
        aeroAdapter = new AerodromeAdapter(address(aeroRouter), FACTORY, false);

        // Fund + approve the caller (this test contract) for both adapters.
        tokenIn.mint(address(this), 1_000_000e18);
        tokenIn.approve(address(uniAdapter), type(uint256).max);
        tokenIn.approve(address(aeroAdapter), type(uint256).max);
    }

    // ───────────────────────── Uniswap V3 adapter ─────────────────────────

    function test_Uniswap_swap_revertsOnZeroMinOut() public {
        vm.expectRevert(bytes("DexAdapter: minOut=0"));
        uniAdapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 0);
    }

    function test_Uniswap_swap_succeedsWithPositiveMinOut() public {
        // Non-zero minOut passes the new floor and reaches the (mock) router.
        uint256 out = uniAdapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 1);
        assertEq(out, 999e18, "uni mock output");
    }

    // ───────────────────────── Aerodrome adapter ──────────────────────────

    function test_Aerodrome_swap_revertsOnZeroMinOut() public {
        vm.expectRevert(bytes("DexAdapter: minOut=0"));
        aeroAdapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 0);
    }

    function test_Aerodrome_swap_succeedsWithPositiveMinOut() public {
        uint256 out = aeroAdapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 1);
        assertEq(out, 999e18, "aero mock output");
    }
}

// ─────────────────────────────── Mocks ────────────────────────────────

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mirrors UniswapV3Adapter.ISwapRouter.exactInputSingle.
contract MockSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256) {
        // Pull the input the adapter approved, simulate ~0.1% output.
        ERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        return 999e18;
    }
}

/// @dev Mirrors UniswapV3Adapter.IQuoterV2.quoteExactInputSingle.
contract MockQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory)
        external
        pure
        returns (uint256, uint160, uint32, uint256)
    {
        return (999e18, 0, 0, 0);
    }
}

/// @dev Mirrors AerodromeAdapter.IAerodromeRouter.swapExactTokensForTokens.
contract MockAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        Route[] calldata routes,
        address,
        uint256
    ) external returns (uint256[] memory amounts) {
        ERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = 999e18;
    }

    function getAmountsOut(uint256 amountIn, Route[] memory) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = 999e18;
    }
}
