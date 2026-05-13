// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TreasuryVesting} from "../../../src/token/TreasuryVesting.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract TreasuryVestingCoverage is Test {
    address token = makeAddr("lumina");

    function test_Initialize_RevertIf_ZeroToken() public {
        TreasuryVesting impl = new TreasuryVesting();
        bytes memory initData = abi.encodeWithSelector(TreasuryVesting.initialize.selector, address(0));
        vm.expectRevert(bytes("Zero token"));
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_HappyPath_StoresToken() public {
        TreasuryVesting v = ProxyDeployer.deployTreasuryVesting(token);
        assertEq(address(v.luminaToken()), token);
    }

    // ─── available() coverage (covers L74-75 — unlocked path) ───

    function test_Available_ReturnsZero_WhenLocked() public {
        TreasuryVesting v = ProxyDeployer.deployTreasuryVesting(token);
        // Still in LOCK_DURATION → L73 returns 0.
        assertEq(v.available(), 0);
    }

    function test_Available_ReturnsMaxMonthly_WhenUnlocked() public {
        TreasuryVesting v = ProxyDeployer.deployTreasuryVesting(token);
        // Warp past LOCK_DURATION so L74-75 execute.
        vm.warp(v.deployedAt() + v.LOCK_DURATION() + 1);
        uint256 avail = v.available();
        // remaining (3M) > MAX_MONTHLY_RELEASE (250K) → returns MAX_MONTHLY_RELEASE.
        assertEq(avail, v.MAX_MONTHLY_RELEASE());
    }
}
