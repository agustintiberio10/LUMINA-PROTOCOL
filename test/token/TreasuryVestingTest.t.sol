// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/token/TreasuryVesting.sol";

contract TreasuryVestingTest is Test {
    LuminaTokenV2 token;
    TreasuryVesting vesting;

    address bondVault = makeAddr("bondVault");
    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address multisig;

    function setUp() public {
        multisig = address(this); // deployer is owner (multisig in prod)
        token = new LuminaTokenV2(bondVault, makeAddr("cex"), founder, lbp, address(0xdead));
        vesting = new TreasuryVesting(address(token));
        deal(address(token), address(vesting), 3_000_000 * 1e18);
    }

    function test_locked_for_6_months() public view {
        assertTrue(vesting.isLocked());
        assertEq(vesting.available(), 0);
    }

    function test_cannot_release_during_lock() public {
        vm.expectRevert("Still locked");
        vesting.release(makeAddr("dest"), 100_000 * 1e18);
    }

    function test_release_after_lock() public {
        vm.warp(block.timestamp + 180 days);
        assertFalse(vesting.isLocked());

        address dest = makeAddr("liquidityPool");
        vesting.release(dest, 250_000 * 1e18);
        assertEq(token.balanceOf(dest), 250_000 * 1e18);
        assertEq(vesting.totalReleased(), 250_000 * 1e18);
    }

    function test_cannot_exceed_monthly_max() public {
        vm.warp(block.timestamp + 180 days);
        vm.expectRevert("Exceeds monthly max");
        vesting.release(makeAddr("dest"), 300_000 * 1e18);
    }

    function test_cannot_release_twice_same_month() public {
        vm.warp(block.timestamp + 180 days);
        vesting.release(makeAddr("dest"), 200_000 * 1e18);

        vm.expectRevert("Already released this month");
        vesting.release(makeAddr("dest"), 50_000 * 1e18);
    }

    /// @notice [V4/SR2] Regression: month-0 cap must prevent multi-release.
    function test_cannot_drain_month0() public {
        vm.warp(block.timestamp + 180 days + 1); // just after lock

        // First release OK
        vesting.release(makeAddr("dest"), 250_000 * 1e18);

        // Second release same month MUST REVERT (would previously drain 3M)
        vm.expectRevert("Already released this month");
        vesting.release(makeAddr("dest"), 250_000 * 1e18);

        // Only 250K released
        assertEq(vesting.totalReleased(), 250_000 * 1e18);
    }

    function test_can_release_next_month() public {
        vm.warp(block.timestamp + 180 days);
        vesting.release(makeAddr("dest"), 250_000 * 1e18);

        vm.warp(block.timestamp + 30 days);
        vesting.release(makeAddr("dest"), 250_000 * 1e18);
        assertEq(vesting.totalReleased(), 500_000 * 1e18);
    }

    function test_cannot_exceed_total() public {
        // [SR3] Use absolute warps anchored to deployedAt to avoid any Foundry
        // composition quirk with repeated `block.timestamp + X`.
        uint256 deployedAt = vesting.deployedAt();

        // Release all 12 months (3M / 250K = 12 months)
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(deployedAt + 180 days + (i * 30 days));
            vesting.release(makeAddr("dest"), 250_000 * 1e18);
        }
        assertEq(vesting.totalReleased(), 3_000_000 * 1e18);

        // No more room even in the next month
        vm.warp(deployedAt + 180 days + (12 * 30 days));
        vm.expectRevert("Exceeds total");
        vesting.release(makeAddr("dest"), 1);
    }

    function test_nonOwner_cannot_release() public {
        vm.warp(block.timestamp + 180 days);
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        vesting.release(makeAddr("dest"), 100_000 * 1e18);
    }

    function test_getStatus() public view {
        (uint256 total, uint256 released, uint256 remaining, bool locked,,) = vesting.getStatus();
        assertEq(total, 3_000_000 * 1e18);
        assertEq(released, 0);
        assertEq(remaining, 3_000_000 * 1e18);
        assertTrue(locked);
    }
}
