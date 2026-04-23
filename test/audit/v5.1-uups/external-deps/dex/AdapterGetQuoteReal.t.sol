// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {UniswapV3Adapter, IQuoterV2, ISwapRouter} from "../../../../../src/dex/UniswapV3Adapter.sol";
import {AerodromeAdapter, IAerodromeRouter} from "../../../../../src/dex/AerodromeAdapter.sol";

/// @notice Mock UniV3 QuoterV2 — configurable quote and revert.
contract MockQuoterV2 {
    uint256 public quoteReturn;
    bool public shouldRevert;

    function setQuote(uint256 q) external {
        quoteReturn = q;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory)
        external
        view
        returns (uint256, uint160, uint32, uint256)
    {
        require(!shouldRevert, "quoter down");
        return (quoteReturn, 0, 0, 0);
    }
}

/// @notice Mock Aerodrome router — configurable getAmountsOut.
contract MockAerodromeRouter {
    uint256 public lastOut;
    bool public shouldRevert;
    bool public returnEmpty;

    function setQuote(uint256 q) external {
        lastOut = q;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setReturnEmpty(bool v) external {
        returnEmpty = v;
    }

    function swapExactTokensForTokens(uint256, uint256, IAerodromeRouter.Route[] calldata, address, uint256)
        external
        view
        returns (uint256[] memory amounts)
    {
        require(!shouldRevert, "swap down");
        amounts = new uint256[](2);
        amounts[1] = lastOut;
    }

    function getAmountsOut(uint256, IAerodromeRouter.Route[] memory) external view returns (uint256[] memory amounts) {
        require(!shouldRevert, "quote down");
        if (returnEmpty) return new uint256[](0);
        amounts = new uint256[](2);
        amounts[1] = lastOut;
    }
}

/**
 * @title AdapterGetQuoteReal
 * @notice Verifies M-02 fix: UniswapV3Adapter and AerodromeAdapter now
 *         implement real getQuote via QuoterV2 / getAmountsOut, with
 *         try/catch returning 0 on any revert.
 */
contract AdapterGetQuoteReal is Test {
    address constant USDC = address(0x1);
    address constant LUMINA = address(0x2);

    // ─────────────────────────────────────────────────────────────
    // UniswapV3Adapter — getQuote via QuoterV2
    // ─────────────────────────────────────────────────────────────
    function _uniAdapter(address quoter) internal returns (UniswapV3Adapter) {
        address router = makeAddr("v3SwapRouter");
        return new UniswapV3Adapter(router, quoter, 3000);
    }

    function test_FixM02_UniV3_GetQuote_ReturnsNonZero() public {
        MockQuoterV2 q = new MockQuoterV2();
        q.setQuote(1_234e18);
        UniswapV3Adapter a = _uniAdapter(address(q));
        uint256 got = a.getQuote(USDC, LUMINA, 1000e6);
        assertEq(got, 1_234e18);
    }

    function test_FixM02_UniV3_GetQuote_ZeroAmount_ReturnsZero() public {
        MockQuoterV2 q = new MockQuoterV2();
        q.setQuote(1_234e18);
        UniswapV3Adapter a = _uniAdapter(address(q));
        assertEq(a.getQuote(USDC, LUMINA, 0), 0);
    }

    function test_FixM02_UniV3_GetQuote_OnQuoterRevert_ReturnsZero() public {
        MockQuoterV2 q = new MockQuoterV2();
        q.setShouldRevert(true);
        UniswapV3Adapter a = _uniAdapter(address(q));
        assertEq(a.getQuote(USDC, LUMINA, 1000e6), 0);
    }

    function test_FixM02_UniV3_GetQuote_LargeAmount_NoOverflow() public {
        MockQuoterV2 q = new MockQuoterV2();
        q.setQuote(type(uint128).max);
        UniswapV3Adapter a = _uniAdapter(address(q));
        uint256 got = a.getQuote(USDC, LUMINA, type(uint128).max);
        assertEq(got, type(uint128).max);
    }

    function test_FixM02_UniV3_Constructor_ZeroQuoter_Reverts() public {
        address router = makeAddr("v3SwapRouter");
        vm.expectRevert(bytes("Zero quoter"));
        new UniswapV3Adapter(router, address(0), 3000);
    }

    function test_FixM02_UniV3_Constructor_ZeroRouter_Reverts() public {
        MockQuoterV2 q = new MockQuoterV2();
        vm.expectRevert(bytes("Zero router"));
        new UniswapV3Adapter(address(0), address(q), 3000);
    }

    // ─────────────────────────────────────────────────────────────
    // AerodromeAdapter — getQuote via getAmountsOut
    // ─────────────────────────────────────────────────────────────
    function _aeroAdapter(address router) internal returns (AerodromeAdapter) {
        address factory = makeAddr("aeroFactory");
        return new AerodromeAdapter(router, factory, false);
    }

    function test_FixM02_Aero_GetQuote_ReturnsNonZero() public {
        MockAerodromeRouter r = new MockAerodromeRouter();
        r.setQuote(2_345e18);
        AerodromeAdapter a = _aeroAdapter(address(r));
        uint256 got = a.getQuote(USDC, LUMINA, 1000e6);
        assertEq(got, 2_345e18);
    }

    function test_FixM02_Aero_GetQuote_ZeroAmount_ReturnsZero() public {
        MockAerodromeRouter r = new MockAerodromeRouter();
        r.setQuote(2_345e18);
        AerodromeAdapter a = _aeroAdapter(address(r));
        assertEq(a.getQuote(USDC, LUMINA, 0), 0);
    }

    function test_FixM02_Aero_GetQuote_OnRouterRevert_ReturnsZero() public {
        MockAerodromeRouter r = new MockAerodromeRouter();
        r.setShouldRevert(true);
        AerodromeAdapter a = _aeroAdapter(address(r));
        assertEq(a.getQuote(USDC, LUMINA, 1000e6), 0);
    }

    function test_FixM02_Aero_GetQuote_OnEmptyResponse_ReturnsZero() public {
        MockAerodromeRouter r = new MockAerodromeRouter();
        r.setQuote(100e18);
        r.setReturnEmpty(true);
        AerodromeAdapter a = _aeroAdapter(address(r));
        assertEq(a.getQuote(USDC, LUMINA, 1000e6), 0);
    }

    function test_FixM02_Aero_GetQuote_LargeAmount_NoOverflow() public {
        MockAerodromeRouter r = new MockAerodromeRouter();
        r.setQuote(type(uint128).max);
        AerodromeAdapter a = _aeroAdapter(address(r));
        uint256 got = a.getQuote(USDC, LUMINA, type(uint128).max);
        assertEq(got, type(uint128).max);
    }

    // ─────────────────────────────────────────────────────────────
    // Interface mutability consistency
    // ─────────────────────────────────────────────────────────────
    function test_FixM02_Interface_IsNonView_AllowsQuoterCall() public {
        // A simple compile-time test: calling getQuote on UniV3 adapter
        // which is non-view proves the interface now accepts non-view
        // implementations.
        MockQuoterV2 q = new MockQuoterV2();
        q.setQuote(1e18);
        UniswapV3Adapter a = _uniAdapter(address(q));
        uint256 got = a.getQuote(USDC, LUMINA, 1000e6);
        assertEq(got, 1e18);
    }
}
