// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";
import "../../src/treasury/CEXLiquidityReserve.sol";

/// @notice Sprint Fix Audit Economic — Phase B (R1).
/// @dev Covers:
///   - injectToVault access control (only BondVault).
///   - Auto-injection trigger when available-capacity ratio dips at-or-below 50%.
///   - Floor-price pause + hysteresis recovery (120% of floor).
///   - Permissionless `pokeCheckAndInject` re-evaluation entry point.
contract MockOracleR1 {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract BondVaultAutoInjectionTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    CEXLiquidityReserve cexReserve;
    MockOracleR1 oracle;

    address founder = makeAddr("founder");
    address lbp = makeAddr("lbp");
    address treasury = makeAddr("treasury");
    address user = address(0xBEEF);
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);

        oracle = new MockOracleR1();

        ClaimBond cbImpl = new ClaimBond();
        ERC1967Proxy cbProxy = new ERC1967Proxy(address(cbImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(cbProxy));

        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, makeAddr("tmpVault"), makeAddr("cex"), founder, lbp, treasury
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        BondVault vImpl = new BondVault();
        ERC1967Proxy vProxy = new ERC1967Proxy(
            address(vImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(this)
            )
        );
        vault = BondVault(address(vProxy));

        CEXLiquidityReserve crImpl = new CEXLiquidityReserve();
        ERC1967Proxy crProxy = new ERC1967Proxy(
            address(crImpl),
            abi.encodeWithSelector(CEXLiquidityReserve.initialize.selector, address(token), address(this))
        );
        cexReserve = CEXLiquidityReserve(address(crProxy));

        // Wire both sides.
        cexReserve.setBondVault(address(vault));
        vault.setCexReserve(address(cexReserve));

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);
        deal(address(token), address(cexReserve), 14_000_000 * 1e18);

        vault.setBondMaturitySeconds(60);
    }

    // ─── injectToVault access control ───

    function test_OnlyBondVaultCanInject() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("Not BondVault"));
        cexReserve.injectToVault(1 ether);
    }

    function test_InjectRevertsOnZeroAmount() public {
        vm.prank(address(vault));
        vm.expectRevert(bytes("Zero injection"));
        cexReserve.injectToVault(0);
    }

    function test_InjectRevertsWhenInsufficientReserve() public {
        // Drain the CEX reserve fully so any positive injection request reverts.
        deal(address(token), address(cexReserve), 0);
        vm.prank(address(vault));
        vm.expectRevert(bytes("Insufficient reserve"));
        cexReserve.injectToVault(1 ether);
    }

    function test_InjectHappyPath_VaultBalanceIncreases() public {
        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 reserveBefore = token.balanceOf(address(cexReserve));

        vm.prank(address(vault));
        cexReserve.injectToVault(1_000_000 ether);

        assertEq(token.balanceOf(address(vault)), vaultBefore + 1_000_000 ether);
        assertEq(token.balanceOf(address(cexReserve)), reserveBefore - 1_000_000 ether);
        assertEq(cexReserve.totalInjected(), 1_000_000 ether);
    }

    // ─── Capacity-threshold auto-injection ───

    function test_CapacityAtThresholdTriggersInjection() public {
        // Push capacity ratio at-or-under 50% by committing ~50% of maxCapacity.
        // maxCommit at $0.036 over 70M LUMINA = 70M * 0.036 * 0.5 = $1.26M.
        // Committing $700k puts available capacity at ~$560k → ratio ≈ 44%.
        // Capture BEFORE issueBond — its hook runs the (first) injection.
        uint256 reserveBalBefore = token.balanceOf(address(cexReserve));
        uint256 vaultBalBefore = token.balanceOf(address(vault));

        vault.issueBond(user, 700_000);

        // [F-07] The first injection fires (lastInjectionTimestamp == 0, so the
        // 1-day cooldown is satisfied). A subsequent pokeCheckAndInject within
        // the cooldown is now correctly a NO-OP, so we assert the single
        // injection's cumulative effect rather than a repeat.
        vault.pokeCheckAndInject(); // no-op under INJECTION_COOLDOWN

        assertGt(vault.totalInjectedFromCex(), 0, "Injection did not fire");
        assertLt(token.balanceOf(address(cexReserve)), reserveBalBefore, "CEX reserve did not decrease");
        assertGt(token.balanceOf(address(vault)), vaultBalBefore, "Vault did not receive injection");
    }

    function test_CapacityWellAboveThreshold_NoInjection() public {
        // Tiny commitment (~$100) leaves capacity ratio ~100%.
        vault.issueBond(user, 100);
        assertEq(vault.totalInjectedFromCex(), 0, "Injection fired above threshold");
    }

    // ─── Floor-price pause + hysteresis ───

    function test_PriceBelowFloorPausesPolicies() public {
        oracle.setPrice(0.004 ether); // below $0.005 floor
        vault.pokeCheckAndInject();
        assertTrue(vault.policiesPaused(), "Should be paused after floor breach");
    }

    function test_RecoveryUnpausesPoliciesWithHysteresis() public {
        oracle.setPrice(0.004 ether);
        vault.pokeCheckAndInject();
        assertTrue(vault.policiesPaused(), "Should be paused");

        // Above floor but under 120% threshold (= $0.006).
        oracle.setPrice(0.0055 ether);
        vault.pokeCheckAndInject();
        assertTrue(vault.policiesPaused(), "Should still be paused (within hysteresis band)");

        // Above hysteresis threshold.
        oracle.setPrice(0.006 ether);
        vault.pokeCheckAndInject();
        assertFalse(vault.policiesPaused(), "Should be unpaused above hysteresis");
    }

    function test_PriceExactlyAtFloor_PausesPolicies() public {
        oracle.setPrice(5e15); // exactly at floor
        vault.pokeCheckAndInject();
        assertTrue(vault.policiesPaused(), "Should pause at floor (boundary)");
    }

    // ─── Robustness: CEX Reserve unset → injection no-op, floor still works ───

    function test_NoCexReserveWired_FloorBranchStillWorks() public {
        vault.setCexReserve(address(0));

        // Capacity-triggering scenario should NOT inject (no reserve).
        vault.issueBond(user, 700_000);
        assertEq(vault.totalInjectedFromCex(), 0, "Should not inject without reserve");

        // But floor breach still pauses.
        oracle.setPrice(0.004 ether);
        vault.pokeCheckAndInject();
        assertTrue(vault.policiesPaused(), "Floor branch should be independent");
    }
}
