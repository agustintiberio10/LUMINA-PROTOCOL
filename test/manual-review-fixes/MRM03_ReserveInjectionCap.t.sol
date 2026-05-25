// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

/// @notice Minimal LUMINA mock (mirrors test/treasury/CEXLiquidityReserveTest.t.sol).
contract MockLUMINA {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }
}

/// @title MRM03_ReserveInjectionCap
/// @notice [MR-M03 fix] CEXLiquidityReserve.injectToVault now enforces its OWN
///         per-window cap (MAX_INJECTION_BPS = 10% of balance) and cooldown
///         (INJECTION_COOLDOWN = 1 day), independent of the (upgradeable) BondVault
///         caller. Defense-in-depth: a second injection within the cooldown reverts,
///         and an over-cap amount reverts.
contract MRM03_ReserveInjectionCapTest is Test {
    CEXLiquidityReserve reserve;
    MockLUMINA lumina;

    address multisig = makeAddr("multisig");
    address bondVault = makeAddr("bondVault");

    function setUp() public {
        vm.chainId(8453);
        // Realistic wall-clock so the first injection clears the cooldown gate
        // (lastInjectionTimestamp starts at 0; on-chain block.timestamp ~1.7e9 ≫
        // INJECTION_COOLDOWN, so the first pull is always allowed — only the
        // default test timestamp of 1 would spuriously trip it).
        vm.warp(1_700_000_000);
        lumina = new MockLUMINA();
        reserve = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), multisig);
        lumina.mint(address(reserve), 14_000_000 * 1e18);

        // Wire the BondVault that is allowed to pull emergency liquidity.
        vm.prank(multisig);
        reserve.setBondVault(bondVault);
    }

    // ─────────────────────────── cap ───────────────────────────

    function test_injectToVault_revertsWhenOverPerWindowCap() public {
        // Balance is 14M; 10% cap = 1.4M. Asking for 1.4M + 1 wei must revert.
        uint256 cap = (lumina.balanceOf(address(reserve)) * reserve.MAX_INJECTION_BPS()) / 10000;
        vm.prank(bondVault);
        vm.expectRevert(bytes("CLR: exceeds per-window cap"));
        reserve.injectToVault(cap + 1);
    }

    function test_injectToVault_succeedsAtExactlyCap() public {
        uint256 cap = (lumina.balanceOf(address(reserve)) * reserve.MAX_INJECTION_BPS()) / 10000;
        vm.prank(bondVault);
        reserve.injectToVault(cap);
        assertEq(reserve.totalInjected(), cap, "totalInjected should equal cap");
        assertEq(reserve.lastInjectionTimestamp(), block.timestamp, "timestamp recorded");
    }

    // ─────────────────────────── cooldown ───────────────────────────

    function test_injectToVault_revertsWhenWithinCooldown() public {
        uint256 t0 = block.timestamp;

        vm.prank(bondVault);
        reserve.injectToVault(1_000 * 1e18);

        // Advance LESS than the cooldown window: second injection must revert.
        vm.warp(t0 + reserve.INJECTION_COOLDOWN() - 1);
        vm.prank(bondVault);
        vm.expectRevert(bytes("CLR: injection cooldown"));
        reserve.injectToVault(1_000 * 1e18);
    }

    function test_injectToVault_succeedsAfterCooldown() public {
        uint256 t0 = block.timestamp;

        vm.prank(bondVault);
        reserve.injectToVault(1_000 * 1e18);

        // Advance PAST the cooldown window: second injection succeeds.
        vm.warp(t0 + reserve.INJECTION_COOLDOWN());
        vm.prank(bondVault);
        reserve.injectToVault(1_000 * 1e18);
        assertEq(reserve.totalInjected(), 2_000 * 1e18, "two injections accounted");
    }

    function test_injectToVault_revertsForNonBondVault() public {
        vm.expectRevert(bytes("Not BondVault"));
        reserve.injectToVault(1);
    }
}
