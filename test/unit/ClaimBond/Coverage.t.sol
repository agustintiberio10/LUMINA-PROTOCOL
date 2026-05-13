// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

contract ClaimBondCoverage is Test {
    ClaimBond bond;
    address vault = makeAddr("vault");
    address user = makeAddr("user");
    uint256 constant EPOCH = 202712; // Dec 2027

    function setUp() public {
        bond = ProxyDeployer.deployClaimBond();
        bond.setBondVault(vault);
    }

    // ─────────────── reinitializeURI ───────────────

    function test_ReinitializeURI_BumpsVersion() public {
        // Initial _baseURI is set to canonical default during initialize.
        // Calling reinitializeURI(2) re-seeds the same default (idempotent).
        bond.reinitializeURI(2);
        // baseURI is private; observe via uri(epoch).
        // Without mints epochExists is false, but uri() concatenates regardless.
        string memory u = bond.uri(EPOCH);
        // Expect the canonical HTTPS prefix.
        assertEq(bytes(u)[0], "h", "uri does not start with h");
    }

    function test_ReinitializeURI_RevertIf_VersionReused() public {
        bond.reinitializeURI(2);
        // Reinitializer with the same version reverts (OZ Initializable).
        vm.expectRevert();
        bond.reinitializeURI(2);
    }

    // ─────────────── burnByHolder ───────────────

    function test_BurnByHolder_RevertIf_InsufficientBalance() public {
        vm.prank(vault);
        bond.mint(user, EPOCH, 10);
        vm.prank(user);
        vm.expectRevert(bytes("Insufficient balance"));
        bond.burnByHolder(user, EPOCH, 11);
    }

    function test_BurnByHolder_HappyPath_HolderBurnsOwn() public {
        vm.prank(vault);
        bond.mint(user, EPOCH, 10);
        vm.prank(user);
        bond.burnByHolder(user, EPOCH, 4);
        assertEq(bond.balanceOf(user, EPOCH), 6);
    }

    function test_BurnByHolder_RevertIf_NotHolderNorApproved() public {
        vm.prank(vault);
        bond.mint(user, EPOCH, 10);
        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(bytes("Not holder or approved"));
        bond.burnByHolder(user, EPOCH, 5);
    }

    // ─────────────── getFaceValue ───────────────

    function test_GetFaceValue_RevertIf_EpochDoesNotExist() public {
        vm.expectRevert(bytes("Epoch does not exist"));
        bond.getFaceValue(EPOCH);
    }

    function test_GetFaceValue_Returns1e18() public {
        vm.prank(vault);
        bond.mint(user, EPOCH, 1);
        assertEq(bond.getFaceValue(EPOCH), 1e18);
    }

    // ─────────────── getHolderFaceValue ───────────────

    function test_GetHolderFaceValue_ReturnsBalanceTimes1e18() public {
        vm.prank(vault);
        bond.mint(user, EPOCH, 5);
        assertEq(bond.getHolderFaceValue(user, EPOCH), 5e18);
    }

    // ─────────────── isMatured ───────────────

    function test_IsMatured_ReturnsFalse_WhenEpochNotExist() public view {
        assertFalse(bond.isMatured(202812));
    }

    function test_IsMatured_ReturnsFalse_BeforeMaturity() public {
        vm.prank(vault);
        bond.mint(user, EPOCH, 1);
        // Block time before Dec 2027 → not matured.
        assertFalse(bond.isMatured(EPOCH));
    }

    function test_IsMatured_ReturnsTrue_AfterMaturity() public {
        vm.prank(vault);
        bond.mint(user, EPOCH, 1);
        vm.warp(bond.maturityDate(EPOCH) + 1);
        assertTrue(bond.isMatured(EPOCH));
    }

    // ─────────────── getEpochInfo ───────────────

    function test_GetEpochInfo_NonExistent_ZeroValues() public view {
        (bool exists, uint256 maturity, uint256 supply, bool matured) = bond.getEpochInfo(EPOCH);
        assertFalse(exists);
        assertEq(maturity, 0);
        assertEq(supply, 0);
        assertFalse(matured);
    }

    function test_GetEpochInfo_AfterMint_ReturnsState() public {
        vm.prank(vault);
        bond.mint(user, EPOCH, 7);
        (bool exists, uint256 maturity, uint256 supply, bool matured) = bond.getEpochInfo(EPOCH);
        assertTrue(exists);
        assertGt(maturity, 0);
        assertEq(supply, 7);
        // block.timestamp is well before Dec 2027 maturity.
        assertFalse(matured);
    }

    // ─────────────── uri / name / symbol ───────────────

    function test_Uri_ConcatenatesBaseAndEpochAndJson() public view {
        string memory u = bond.uri(EPOCH);
        // Expect "...202712.json" suffix.
        bytes memory ub = bytes(u);
        bytes memory tail = ".json";
        bool ok = true;
        for (uint256 i = 0; i < tail.length; i++) {
            if (ub[ub.length - tail.length + i] != tail[i]) {
                ok = false;
                break;
            }
        }
        assertTrue(ok, "uri does not end with .json");
    }

    function test_Name_Returns_LuminaBonds() public view {
        assertEq(bond.name(), "LUMINA Bonds");
    }

    function test_Symbol_Returns_LBOND() public view {
        assertEq(bond.symbol(), "LBOND");
    }

    // ─────────────── setBaseURI ───────────────

    function test_SetBaseURI_Owner_Success() public {
        bond.setBaseURI("https://new.lumina-org.com/m/");
        // Test via uri() suffix change.
        string memory u = bond.uri(202712);
        bytes memory ub = bytes(u);
        // Confirm new prefix prefix length matches.
        bytes memory prefix = "https://new.lumina-org.com/m/";
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(ub[i], prefix[i], "baseURI prefix mismatch");
        }
    }

    function test_SetBaseURI_RevertIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bond.setBaseURI("x");
    }

    // ─────────────── setAuthorizedOperator ───────────────

    function test_SetAuthorizedOperator_Owner_Success() public {
        address op = makeAddr("operator");
        bond.setAuthorizedOperator(op, true);
        assertTrue(bond.authorizedOperators(op));
        bond.setAuthorizedOperator(op, false);
        assertFalse(bond.authorizedOperators(op));
    }

    function test_SetAuthorizedOperator_RevertIf_ZeroAddress() public {
        vm.expectRevert(bytes("ClaimBond: zero address"));
        bond.setAuthorizedOperator(address(0), true);
    }

    function test_SetAuthorizedOperator_RevertIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bond.setAuthorizedOperator(makeAddr("op"), true);
    }
}
