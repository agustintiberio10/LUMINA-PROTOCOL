// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AerodromeAdapter} from "../../../src/dex/AerodromeAdapter.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title EchidnaAerodromeAdapter
/// @notice Sprint Z.1 — Echidna property fuzzing for AerodromeAdapter immutable.
contract EchidnaAerodromeAdapter {
    AerodromeAdapter adapter;
    MockAerodromeRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    address factory = address(0xFAC10);

    uint256 totalSwaps;

    constructor() {
        router = new MockAerodromeRouter();
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        adapter = new AerodromeAdapter(address(router), factory, false);
        // Pre-fund this contract so swap calls can pull from us.
        tokenIn.mint(address(this), 1_000_000 * 1e18);
    }

    // ═══════ Echidna-fuzzed mutators ═══════

    function setRate(uint256 r) external {
        router.setRate(r);
    }

    function trySwap(uint256 amountIn, uint256 minOut) external {
        if (amountIn == 0) return;
        if (amountIn > tokenIn.balanceOf(address(this))) return;
        try adapter.swap(address(tokenIn), address(tokenOut), amountIn, minOut) {
            totalSwaps++;
        } catch {}
    }

    // ═══════ Properties ═══════

    /// @notice P1: AdapterAdapter holds zero balance of tokenIn after every swap (no fund trap).
    function echidna_adapter_no_token_in_residue() public view returns (bool) {
        return tokenIn.balanceOf(address(adapter)) == 0;
    }

    /// @notice P2: AdapterAdapter holds zero balance of tokenOut (forwarded to msg.sender).
    function echidna_adapter_no_token_out_residue() public view returns (bool) {
        return tokenOut.balanceOf(address(adapter)) == 0;
    }

    /// @notice P3: router immutable address never changes.
    function echidna_router_immutable() public view returns (bool) {
        return address(adapter.router()) == address(router);
    }
}
