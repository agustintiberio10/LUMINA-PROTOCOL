// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {DeployLuminaV5Complete} from "./DeployLuminaV5Complete.s.sol";

/// @title DeployLuminaV5Mainnet
/// @notice Production deploy entry point for Base Mainnet. Hard-codes the
///         addresses of every external dependency the protocol uses (USDC,
///         Chainlink price feeds, Aave V3 Pool, Uniswap V3 SwapRouter02)
///         and injects them as environment variables before invoking the
///         shared `DeployLuminaV5Complete` flow. Operator-supplied values
///         (multisig, LBP recipient, ops wallet, founder recipient) are
///         still read from the operator's environment so they cannot be
///         locked in at compile time.
///
/// @dev Run with:
///        forge script script/deploy/DeployLuminaV5Mainnet.s.sol:DeployLuminaV5Mainnet \
///          --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PK --broadcast --verify
///
///      The fork-rehearsal test in
///      `test/audit/v5.1-uups/integration/mainnet-fork/MainnetForkDeploy.t.sol`
///      exercises this same flow against a Base Mainnet fork without
///      broadcasting - it is the operator-grade pre-flight check before any
///      real `--broadcast` run.
contract DeployLuminaV5Mainnet is Script {
    // ─────────────────────────────────────────────────────────────────
    // Real Base Mainnet dependency addresses. Verified at audit #38
    // time (2026-04-28) via cast on https://mainnet.base.org. Any drift
    // from these MUST be flagged as a finding before broadcasting.
    // See docs/audit/v5.1-uups/38-mainnet-fork/01-MAINNET-DEPS.md.
    // ─────────────────────────────────────────────────────────────────
    address public constant USDC_BASE_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant CHAINLINK_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address public constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address public constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address public constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    // DEX surfaces — names MUST match what `DeployLuminaV5Complete` reads via
    // `vm.envAddress` (UNISWAP_V3_ROUTER / UNISWAP_V3_QUOTER / AERODROME_*),
    // otherwise the deploy reverts at boot. Aerodrome is the primary swap
    // venue on Base; Uniswap V3 is the fallback.
    address public constant UNISWAP_V3_SWAPROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address public constant UNISWAP_V3_QUOTER_V2    = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address public constant AERODROME_ROUTER        = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address public constant AERODROME_FACTORY       = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    function run() external {
        // Inject mainnet dependency addresses as env vars so the shared
        // `DeployLuminaV5Complete` flow picks them up via `vm.envAddress`.
        // KEY NAMES MUST MATCH `Complete.s.sol` exactly — a typo here makes
        // the setEnv a silent no-op (the Complete script then reverts with
        // "missing env" at runtime). Audited against `DeployLuminaV5Complete`
        // lines 106-118 on the same commit.
        vm.setEnv("USDC_ADDRESS",       vm.toString(USDC_BASE_MAINNET));
        vm.setEnv("AAVE_POOL",          vm.toString(AAVE_V3_POOL));
        vm.setEnv("UNISWAP_V3_ROUTER",  vm.toString(UNISWAP_V3_SWAPROUTER02));
        vm.setEnv("UNISWAP_V3_QUOTER",  vm.toString(UNISWAP_V3_QUOTER_V2));
        vm.setEnv("AERODROME_ROUTER",   vm.toString(AERODROME_ROUTER));
        vm.setEnv("AERODROME_FACTORY",  vm.toString(AERODROME_FACTORY));

        // Operator-supplied values still come from their environment.
        // We do not override these so that a misconfiguration surfaces as a
        // missing-env-var error at boot, not as a silent default.
        require(_envIsSet("MULTISIG"), "MULTISIG env var required");
        require(_envIsSet("LBP_DEPOSIT"), "LBP_DEPOSIT env var required");
        require(_envIsSet("OPS_WALLET"), "OPS_WALLET env var required");
        require(_envIsSet("FOUNDER_RECIPIENT"), "FOUNDER_RECIPIENT env var required");
        // ORACLE_KEY: EIP-712 signer EOA wired into LuminaOracleV2.
        // SEQUENCER_UPTIME_FEED: Chainlink L2 sequencer feed — on Base mainnet
        // MUST be 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433. Per OP-DEPLOY-4,
        // a missing/zero feed silently disables the L2-down guard.
        require(_envIsSet("ORACLE_KEY"), "ORACLE_KEY env var required");
        require(_envIsSet("SEQUENCER_UPTIME_FEED"), "SEQUENCER_UPTIME_FEED env var required");

        console.log("===== DEPLOY LUMINA V5.1 - BASE MAINNET =====");
        console.log("USDC:               ", USDC_BASE_MAINNET);
        console.log("Aave V3 Pool:       ", AAVE_V3_POOL);
        console.log("Uniswap V3 Router:  ", UNISWAP_V3_SWAPROUTER02);
        console.log("Uniswap V3 Quoter:  ", UNISWAP_V3_QUOTER_V2);
        console.log("Aerodrome Router:   ", AERODROME_ROUTER);
        console.log("Aerodrome Factory:  ", AERODROME_FACTORY);
        console.log("Chainlink BTC/USD:  ", CHAINLINK_BTC_USD);
        console.log("Chainlink ETH/USD:  ", CHAINLINK_ETH_USD);
        console.log("Chainlink USDC/USD: ", CHAINLINK_USDC_USD);
        console.log("Multisig:           ", vm.envAddress("MULTISIG"));
        console.log("=============================================");

        // Delegate the rest to the audited Complete flow.
        DeployLuminaV5Complete completeRunner = new DeployLuminaV5Complete();
        completeRunner.run();

        console.log("===== MAINNET DEPLOY DONE =====");
    }

    /// @dev `vm.envOr` with a sentinel zero-address - a true zero is a
    ///      configuration error here regardless, so the indirection still
    ///      catches the unset case.
    function _envIsSet(string memory name) internal view returns (bool) {
        return vm.envOr(name, address(0)) != address(0);
    }
}
