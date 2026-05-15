// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {LuminaTokenV2_RescueV1} from "../../../src/token/LuminaTokenV2_RescueV1.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title Upgrade_RescueV1
/// @notice Sprint Z.2 Phase B.3 — UUPS upgrade tests for the one-shot emergencyRecover.
contract Upgrade_RescueV1_Test is Test {
    LuminaTokenV2 token; // proxy, typed as V1
    LuminaTokenV2_RescueV1 tokenAsRescue; // same proxy address, typed as RescueV1

    address admin = address(this); // deployer == DEFAULT_ADMIN_ROLE
    address bondVault = makeAddr("bondVault");
    address cexReserve = makeAddr("cexReserve");
    address founderVestingOld = makeAddr("founderVestingOld");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");
    address founderVestingNew = makeAddr("founderVestingNew");
    address attacker = makeAddr("attacker");

    event EmergencyRescueExecuted(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        vm.chainId(8453);
        token = ProxyDeployer.deployLuminaTokenV2(bondVault, cexReserve, founderVestingOld, lbpDeposit, treasuryVesting);
        // Upgrade to RescueV1.
        LuminaTokenV2_RescueV1 impl = new LuminaTokenV2_RescueV1();
        token.upgradeToAndCall(address(impl), bytes(""));
        tokenAsRescue = LuminaTokenV2_RescueV1(address(token));
    }

    // ═══════ State preservation across upgrade ═══════

    function test_Upgrade_PreservesSupply() public view {
        assertEq(token.totalSupply(), 100_000_000 * 1e18, "totalSupply must equal MAX_SUPPLY");
    }

    function test_Upgrade_PreservesAllBalances() public view {
        assertEq(token.balanceOf(bondVault), 70_000_000 * 1e18);
        assertEq(token.balanceOf(cexReserve), 14_000_000 * 1e18);
        assertEq(token.balanceOf(founderVestingOld), 8_000_000 * 1e18);
        assertEq(token.balanceOf(lbpDeposit), 5_000_000 * 1e18);
        assertEq(token.balanceOf(treasuryVesting), 3_000_000 * 1e18);
    }

    function test_Upgrade_PreservesOwner() public view {
        // DEFAULT_ADMIN_ROLE was granted to msg.sender in initialize; setUp's `this` is admin.
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin), "admin role must persist");
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), attacker));
    }

    // ═══════ emergencyRecover function ═══════

    function test_EmergencyRecover_OnlyOwner_Reverts_NonOwner() public {
        // Cache the role BEFORE pranking — token.DEFAULT_ADMIN_ROLE() is a view call
        // to a non-vm address and would consume the one-shot vm.prank.
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role);
        vm.prank(attacker);
        vm.expectRevert(expected);
        tokenAsRescue.emergencyRecover(founderVestingOld, founderVestingNew, 8_000_000 * 1e18);
    }

    function test_EmergencyRecover_Success_TransfersAmount() public {
        uint256 amount = 8_000_000 * 1e18;
        vm.expectEmit(true, true, true, true);
        emit EmergencyRescueExecuted(founderVestingOld, founderVestingNew, amount);
        tokenAsRescue.emergencyRecover(founderVestingOld, founderVestingNew, amount);
        assertEq(token.balanceOf(founderVestingOld), 0, "FV old drained");
        assertEq(token.balanceOf(founderVestingNew), amount, "FV new credited");
        assertTrue(tokenAsRescue.emergencyRecoverUsed());
    }

    function test_EmergencyRecover_RevertsOnSecondCall() public {
        tokenAsRescue.emergencyRecover(founderVestingOld, founderVestingNew, 1);
        vm.expectRevert(bytes("Rescue already used"));
        tokenAsRescue.emergencyRecover(founderVestingOld, founderVestingNew, 1);
    }

    function test_EmergencyRecover_RevertsZeroFromOrTo() public {
        vm.expectRevert(bytes("Zero from"));
        tokenAsRescue.emergencyRecover(address(0), founderVestingNew, 1);
        vm.expectRevert(bytes("Zero to"));
        tokenAsRescue.emergencyRecover(founderVestingOld, address(0), 1);
    }
}
