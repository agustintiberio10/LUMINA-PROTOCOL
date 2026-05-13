// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVesting} from "../../../src/token/FounderVesting.sol";

contract FounderVestingCoverage is Test {
    address oracle = makeAddr("oracle");
    address aavePool = makeAddr("aavePool");
    address lumina = makeAddr("lumina");
    address usdc = makeAddr("usdc");
    address recipient = makeAddr("recipient");

    // ─────────────── Constructor zero-address reverts (5) ───────────────

    function test_Constructor_RevertIf_ZeroOracle() public {
        vm.expectRevert(bytes("Zero oracle"));
        new FounderVesting(address(0), aavePool, lumina, usdc, recipient);
    }

    function test_Constructor_RevertIf_ZeroAavePool() public {
        vm.expectRevert(bytes("Zero aavePool"));
        new FounderVesting(oracle, address(0), lumina, usdc, recipient);
    }

    function test_Constructor_RevertIf_ZeroLuminaToken() public {
        vm.expectRevert(bytes("Zero token"));
        new FounderVesting(oracle, aavePool, address(0), usdc, recipient);
    }

    function test_Constructor_RevertIf_ZeroUSDC() public {
        vm.expectRevert(bytes("Zero usdc"));
        new FounderVesting(oracle, aavePool, lumina, address(0), recipient);
    }

    function test_Constructor_RevertIf_ZeroRecipient() public {
        vm.expectRevert(bytes("Zero recipient"));
        new FounderVesting(oracle, aavePool, lumina, usdc, address(0));
    }

    // ─────────────── Constructor happy path ───────────────

    function test_Constructor_HappyPath_StoresArgs() public {
        FounderVesting fv = new FounderVesting(oracle, aavePool, lumina, usdc, recipient);
        assertEq(address(fv.oracle()), oracle);
        assertEq(fv.aavePool(), aavePool);
        assertEq(address(fv.luminaToken()), lumina);
        assertEq(fv.usdc(), usdc);
        assertEq(fv.recipient(), recipient);
        assertEq(fv.deployedAt(), block.timestamp);
    }
}
