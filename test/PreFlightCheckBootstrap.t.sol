// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PreFlightCheckBootstrap} from "../script/PreFlightCheckBootstrap.s.sol";

/**
 * @title  PreFlightCheckBootstrapTest
 * @notice Hermetic tests for the BOOTSTRAP (pre-LBP) variant of the pre-flight
 *         check. Uses `vm.mockCall` so the test runs without a fork or live
 *         RPC. Uses the pure-args `verify(...)` entrypoint to avoid the
 *         `vm.setEnv` race under Forge's parallel test runner.
 *
 *         Difference from the FULL PreFlightCheck (PR #181):
 *           - no `pool != 0` requirement (pool CAN be 0 during bootstrap);
 *           - new requirement: `coverRouter.paused() == true` (the safety net
 *             that compensates for pool==0).
 *         Everything else (FN-H1, RM-C1, BONUS) is identical.
 */
contract PreFlightCheckBootstrapTest is Test {
    PreFlightCheckBootstrap internal check;

    // Test-only sentinel addresses.
    address internal constant LUMINA_TOKEN    = address(0x1111111111111111111111111111111111111111);
    address internal constant BOND_VAULT      = address(0x2222222222222222222222222222222222222222);
    address internal constant CAPACITY_ORACLE = address(0x3333333333333333333333333333333333333333);
    address internal constant COVER_ROUTER    = address(0x4444444444444444444444444444444444444444);
    address internal constant GNOSIS_SAFE     = address(0x5555555555555555555555555555555555555555);
    address internal constant DEPLOYER        = address(0x6666666666666666666666666666666666666666);

    // Constants the script enforces.
    address internal constant USDC_MAINNET       = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDC_MOCK_SEPOLIA  = 0xD944d8e5D8329994D83950872Ec210891d3Ab6AE;
    address internal constant FOUNDER_EOA        = 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        check = new PreFlightCheckBootstrap();
        vm.chainId(8453);
    }

    /// HEALTHY bootstrap = pool=0, paused=true, USDC=Circle, admin=Safe.
    /// Individual tests override ONE mock to exercise a single failure.
    function _mockHealthyBootstrap() internal {
        vm.mockCall(CAPACITY_ORACLE, abi.encodeWithSignature("pool()"), abi.encode(address(0)));      // pool=0 OK in bootstrap
        vm.mockCall(COVER_ROUTER,    abi.encodeWithSignature("paused()"), abi.encode(true));          // the safety net
        vm.mockCall(COVER_ROUTER,    abi.encodeWithSignature("usdc()"), abi.encode(USDC_MAINNET));
        vm.mockCall(LUMINA_TOKEN, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, FOUNDER_EOA), abi.encode(false));
        vm.mockCall(LUMINA_TOKEN, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, GNOSIS_SAFE), abi.encode(true));
        vm.mockCall(BOND_VAULT,   abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, FOUNDER_EOA), abi.encode(false));
        vm.mockCall(BOND_VAULT,   abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, GNOSIS_SAFE), abi.encode(true));
    }

    function _run() internal view {
        check.verify(LUMINA_TOKEN, BOND_VAULT, CAPACITY_ORACLE, COVER_ROUTER, GNOSIS_SAFE, DEPLOYER);
    }

    // ─── happy path ─────────────────────────────────────────────────────
    function test_passes_whenBootstrapStateHealthy() public {
        _mockHealthyBootstrap();
        _run(); // pool=0 + paused=true is the legitimate bootstrap state — must pass
    }

    // ─── new requirement — paused must be true ──────────────────────────
    function test_aborts_whenPausedFalse() public {
        _mockHealthyBootstrap();
        vm.mockCall(COVER_ROUTER, abi.encodeWithSignature("paused()"), abi.encode(false));
        vm.expectRevert(bytes("BOOTSTRAP: coverRouter must be paused"));
        _run();
    }

    // ─── FN-H1 ──────────────────────────────────────────────────────────
    function test_aborts_whenUsdcIsMock() public {
        _mockHealthyBootstrap();
        vm.mockCall(COVER_ROUTER, abi.encodeWithSignature("usdc()"), abi.encode(USDC_MOCK_SEPOLIA));
        vm.expectRevert(bytes("FN-H1: USDC not mainnet"));
        _run();
    }

    // ─── RM-C1 ──────────────────────────────────────────────────────────
    function test_aborts_whenEoaHasTokenAdmin() public {
        _mockHealthyBootstrap();
        vm.mockCall(LUMINA_TOKEN, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, FOUNDER_EOA), abi.encode(true));
        vm.expectRevert(bytes("RM-C1: EOA has token admin"));
        _run();
    }

    function test_aborts_whenEoaHasVaultAdmin() public {
        _mockHealthyBootstrap();
        vm.mockCall(BOND_VAULT, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, FOUNDER_EOA), abi.encode(true));
        vm.expectRevert(bytes("RM-C1: EOA has vault admin"));
        _run();
    }

    function test_aborts_whenSafeMissingTokenAdmin() public {
        _mockHealthyBootstrap();
        vm.mockCall(LUMINA_TOKEN, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, GNOSIS_SAFE), abi.encode(false));
        vm.expectRevert(bytes("RM-C1: Safe missing token admin"));
        _run();
    }

    function test_aborts_whenSafeMissingVaultAdmin() public {
        _mockHealthyBootstrap();
        vm.mockCall(BOND_VAULT, abi.encodeWithSignature("hasRole(bytes32,address)", DEFAULT_ADMIN_ROLE, GNOSIS_SAFE), abi.encode(false));
        vm.expectRevert(bytes("RM-C1: Safe missing vault admin"));
        _run();
    }

    // ─── BONUS ──────────────────────────────────────────────────────────
    function test_aborts_whenWrongChainId() public {
        _mockHealthyBootstrap();
        vm.chainId(84532); // Base Sepolia by mistake
        vm.expectRevert(bytes("BONUS: wrong chainId"));
        _run();
    }

    function test_aborts_whenDeployerIsBurnedEoa() public {
        _mockHealthyBootstrap();
        vm.expectRevert(bytes("BONUS: deployer is burned EOA"));
        check.verify(LUMINA_TOKEN, BOND_VAULT, CAPACITY_ORACLE, COVER_ROUTER, GNOSIS_SAFE, FOUNDER_EOA);
    }
}
