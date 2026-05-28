// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PreFlightCheck} from "../script/PreFlightCheck.s.sol";

/**
 * @title  PreFlightCheckTest
 * @notice Asserts the gate ABORTS for each Phase-5.5 critical scenario and
 *         PASSES when everything is correct. All external calls are mocked
 *         via `vm.mockCall` so the test runs hermetically (no fork, no live
 *         RPC). Uses the pure-args `verify(...)` entrypoint instead of the
 *         env-based `run()` — `vm.setEnv` is process-global and races when
 *         Forge runs tests in parallel.
 */
contract PreFlightCheckTest is Test {
    PreFlightCheck internal check;

    // Test-only sentinel addresses.
    address internal constant LUMINA_TOKEN    = address(0x1111111111111111111111111111111111111111);
    address internal constant BOND_VAULT      = address(0x2222222222222222222222222222222222222222);
    address internal constant CAPACITY_ORACLE = address(0x3333333333333333333333333333333333333333);
    address internal constant COVER_ROUTER    = address(0x4444444444444444444444444444444444444444);
    address internal constant GNOSIS_SAFE     = address(0x5555555555555555555555555555555555555555);
    address internal constant DEPLOYER        = address(0x6666666666666666666666666666666666666666);

    // Constants the script enforces.
    address internal constant USDC_MAINNET      = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDC_MOCK_SEPOLIA = 0xD944d8e5D8329994D83950872Ec210891d3Ab6AE;
    address internal constant FOUNDER_EOA       = 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        check = new PreFlightCheck();
        vm.chainId(8453); // pretend we're on Base mainnet (the script also asserts this)
    }

    /// Mock every external call the check makes so it sees a HEALTHY mainnet.
    /// Individual tests override one mock at a time to exercise a single failure.
    function _mockHealthy() internal {
        vm.mockCall(CAPACITY_ORACLE, abi.encodeWithSignature("pool()"), abi.encode(address(0xDEAD)));
        vm.mockCall(COVER_ROUTER,    abi.encodeWithSignature("usdc()"), abi.encode(USDC_MAINNET));
        // hasRole(DEFAULT_ADMIN_ROLE, EOA) = false ; (..., Safe) = true on both contracts.
        vm.mockCall(LUMINA_TOKEN, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, FOUNDER_EOA), abi.encode(false));
        vm.mockCall(LUMINA_TOKEN, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, GNOSIS_SAFE), abi.encode(true));
        vm.mockCall(BOND_VAULT,   abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, FOUNDER_EOA), abi.encode(false));
        vm.mockCall(BOND_VAULT,   abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, GNOSIS_SAFE), abi.encode(true));
    }

    function _runHealthy() internal view {
        check.verify(LUMINA_TOKEN, BOND_VAULT, CAPACITY_ORACLE, COVER_ROUTER, GNOSIS_SAFE, DEPLOYER);
    }

    // ─── happy path ──────────────────────────────────────────────────────
    function test_passes_whenEverythingHealthy() public {
        _mockHealthy();
        _runHealthy(); // must not revert
    }

    // ─── CRITICAL 1 — FN-C1 ──────────────────────────────────────────────
    function test_aborts_FN_C1_poolUnset() public {
        _mockHealthy();
        vm.mockCall(CAPACITY_ORACLE, abi.encodeWithSignature("pool()"), abi.encode(address(0)));
        vm.expectRevert(bytes("FN-C1: pool not set"));
        _runHealthy();
    }

    // ─── CRITICAL 2 — FN-H1 ──────────────────────────────────────────────
    function test_aborts_FN_H1_usdcIsMock() public {
        _mockHealthy();
        vm.mockCall(COVER_ROUTER, abi.encodeWithSignature("usdc()"), abi.encode(USDC_MOCK_SEPOLIA));
        vm.expectRevert(bytes("FN-H1: USDC not mainnet"));
        _runHealthy();
    }

    // ─── CRITICAL 3 — RM-C1 (4 variants) ─────────────────────────────────
    function test_aborts_RM_C1_eoaStillHasTokenAdmin() public {
        _mockHealthy();
        vm.mockCall(LUMINA_TOKEN, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, FOUNDER_EOA), abi.encode(true));
        vm.expectRevert(bytes("RM-C1: EOA has token admin"));
        _runHealthy();
    }

    function test_aborts_RM_C1_safeMissingTokenAdmin() public {
        _mockHealthy();
        vm.mockCall(LUMINA_TOKEN, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, GNOSIS_SAFE), abi.encode(false));
        vm.expectRevert(bytes("RM-C1: Safe missing token admin"));
        _runHealthy();
    }

    function test_aborts_RM_C1_eoaStillHasVaultAdmin() public {
        _mockHealthy();
        vm.mockCall(BOND_VAULT, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, FOUNDER_EOA), abi.encode(true));
        vm.expectRevert(bytes("RM-C1: EOA has vault admin"));
        _runHealthy();
    }

    function test_aborts_RM_C1_safeMissingVaultAdmin() public {
        _mockHealthy();
        vm.mockCall(BOND_VAULT, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, GNOSIS_SAFE), abi.encode(false));
        vm.expectRevert(bytes("RM-C1: Safe missing vault admin"));
        _runHealthy();
    }

    // ─── BONUS — chainId + deployer hygiene ───────────────────────────────
    function test_aborts_BONUS_wrongChainId() public {
        _mockHealthy();
        vm.chainId(84532); // Base Sepolia by mistake
        vm.expectRevert(bytes("BONUS: wrong chainId"));
        _runHealthy();
    }

    function test_aborts_BONUS_deployerIsBurnedEoa() public {
        _mockHealthy();
        vm.expectRevert(bytes("BONUS: deployer is burned EOA"));
        // Pass FOUNDER_EOA as deployer explicitly.
        check.verify(LUMINA_TOKEN, BOND_VAULT, CAPACITY_ORACLE, COVER_ROUTER, GNOSIS_SAFE, FOUNDER_EOA);
    }
}
