// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DeployLuminaV5Complete} from "./DeployLuminaV5Complete.s.sol";
import {ShieldAdapterFactory} from "./DeployShieldsAndAdapters.s.sol";

import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";

interface ICoverRouterPause {
    function setPaused(bool state) external;
}

interface IPolicyManagerRegister {
    function registerProduct(bytes32 productId, address shield) external;
}

interface ICoverRouterConfigure {
    function configureProduct(
        bytes32 productId,
        uint256 payoutRatioBps,
        uint256 triggerProbBps,
        uint256 marginBps,
        uint32 durationSeconds,
        bool active
    ) external;
}

/// @title DeployLuminaV5Mainnet
/// @notice Production deploy entry point for Base Mainnet. Inherits the
///         audited `DeployLuminaV5Complete` flow and chains Phase C
///         (shields + product registration) + the deferred PolicyManagerV2 /
///         CoverRouterV2 ownership handoff in a SINGLE forge-script run.
///
/// @dev    History — the previous `new Complete() + completeRunner.run()`
///         pattern was structurally broken: inside `Complete.run()`, `msg.sender`
///         was the wrapper instance (not the broadcaster EOA), so
///         `vm.computeCreateAddress(deployer, currentNonce + 10)` precomputed
///         the LUMINA proxy from the wrapper's nonce while the actual broadcast
///         deployed it from the EOA's nonce. STEP 8 always reverted with
///         "LUMINA proxy address mismatch - nonce drift". Surfaced by the fork
///         dry-run on 2026-05-28. The fix is inheritance + `super.run()`, which
///         uses internal dispatch and preserves `msg.sender`.
///
///         Run with:
///           forge script script/deploy/DeployLuminaV5Mainnet.s.sol:DeployLuminaV5Mainnet \
///             --rpc-url $BASE_MAINNET_RPC --private-key $DEPLOYER_PRIVATE_KEY \
///             --broadcast --verify
///
/// @dev    The fork-rehearsal at
///         `test/audit/v5.1-uups/integration/mainnet-fork/MainnetForkDeploy.t.sol`
///         + the orchestrator at `script/dry-run/run.sh` are the operator-grade
///         pre-flight checks before any real `--broadcast` run.
contract DeployLuminaV5Mainnet is DeployLuminaV5Complete {
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
    address public constant CHAINLINK_L2_SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address public constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    // DEX surfaces — names MUST match what `DeployLuminaV5Complete` reads via
    // `vm.envAddress` (UNISWAP_V3_ROUTER / UNISWAP_V3_QUOTER / AERODROME_*),
    // otherwise the deploy reverts at boot. Aerodrome is the primary swap
    // venue on Base; Uniswap V3 is the fallback.
    address public constant UNISWAP_V3_SWAPROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address public constant UNISWAP_V3_QUOTER_V2    = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address public constant AERODROME_ROUTER        = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address public constant AERODROME_FACTORY       = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    // ─── Phase C product spec — locked at audit #181 time ──────────────
    uint256 internal constant PHASE_C_PAYOUT_RATIO_BPS = 8000;
    uint256 internal constant PHASE_C_MARGIN_BPS = 20000;

    function run() public override {
        // ───── 1. Inject mainnet dep addresses + DEFER flag for the parent ─────
        vm.setEnv("USDC_ADDRESS",      vm.toString(USDC_BASE_MAINNET));
        vm.setEnv("AAVE_POOL",         vm.toString(AAVE_V3_POOL));
        vm.setEnv("UNISWAP_V3_ROUTER", vm.toString(UNISWAP_V3_SWAPROUTER02));
        vm.setEnv("UNISWAP_V3_QUOTER", vm.toString(UNISWAP_V3_QUOTER_V2));
        vm.setEnv("AERODROME_ROUTER",  vm.toString(AERODROME_ROUTER));
        vm.setEnv("AERODROME_FACTORY", vm.toString(AERODROME_FACTORY));

        // [Post-dryrun ADR-027] Defer PM/CR ownership transfer so we still own
        // them when Phase C registers products + configures pricing.
        vm.setEnv("DEFER_PM_CR_OWNERSHIP", "true");

        // Operator-supplied values still come from their environment.
        // We do not override these so that a misconfiguration surfaces as a
        // missing-env-var error at boot, not as a silent default.
        require(_envIsSet("MULTISIG"), "MULTISIG env var required");
        require(_envIsSet("LBP_DEPOSIT"), "LBP_DEPOSIT env var required");
        require(_envIsSet("OPS_WALLET"), "OPS_WALLET env var required");
        require(_envIsSet("FOUNDER_RECIPIENT"), "FOUNDER_RECIPIENT env var required");
        require(_envIsSet("ORACLE_KEY"), "ORACLE_KEY env var required");
        require(_envIsSet("SEQUENCER_UPTIME_FEED"), "SEQUENCER_UPTIME_FEED env var required");
        require(_envIsSet("RELAYER"), "RELAYER env var required");

        console.log("===== DEPLOY LUMINA V5.1 - BASE MAINNET (chained: Complete + PhaseC + Handoff) =====");
        console.log("USDC:               ", USDC_BASE_MAINNET);
        console.log("Aave V3 Pool:       ", AAVE_V3_POOL);
        console.log("Uniswap V3 Router:  ", UNISWAP_V3_SWAPROUTER02);
        console.log("Uniswap V3 Quoter:  ", UNISWAP_V3_QUOTER_V2);
        console.log("Aerodrome Router:   ", AERODROME_ROUTER);
        console.log("Aerodrome Factory:  ", AERODROME_FACTORY);
        console.log("Chainlink BTC/USD:  ", CHAINLINK_BTC_USD);
        console.log("Chainlink ETH/USD:  ", CHAINLINK_ETH_USD);
        console.log("Chainlink USDC/USD: ", CHAINLINK_USDC_USD);
        console.log("L2 Sequencer Feed:  ", CHAINLINK_L2_SEQUENCER_FEED);
        console.log("Multisig:           ", vm.envAddress("MULTISIG"));
        console.log("Relayer:            ", vm.envAddress("RELAYER"));
        console.log("==================================================================================");

        // ───── 2. Run the audited Complete flow via `super` (internal dispatch) ─────
        // Internal dispatch preserves msg.sender — the broadcaster EOA stays
        // the deployer inside the parent's logic. Fixes the "LUMINA proxy
        // address mismatch - nonce drift" revert that the previous external
        // `completeRunner.run()` produced.
        super.run();

        // ───── 3. Phase C — register + configure 6 products as deployer ─────
        // Deployer is still owner of PM + CR (because of DEFER flag).
        address policyManager = vm.envAddress("DEPLOY_OUT_POLICY_MANAGER");
        address coverRouter   = vm.envAddress("DEPLOY_OUT_COVER_ROUTER");
        address multisig      = vm.envAddress("MULTISIG");
        address relayer       = vm.envAddress("RELAYER");

        _runPhaseCInline(policyManager, coverRouter, relayer, multisig);

        // ───── 4. setPaused(true) BEFORE handing off — bootstrap stays paused ─────
        // and ───── 5. PolicyManager + CoverRouter ownership → multisig ─────
        vm.startBroadcast();
        ICoverRouterPause(coverRouter).setPaused(true);
        OwnableUpgradeable(policyManager).transferOwnership(multisig);
        OwnableUpgradeable(coverRouter).transferOwnership(multisig);
        vm.stopBroadcast();

        console.log("===== MAINNET DEPLOY DONE =====");
        console.log("  state: paused=true, pool=0 (bootstrap), 6 products registered");
        console.log("  next : LBP -> setPool -> PreFlightCheck (full) -> setPaused(false)");
        console.log("  see  : script/PreFlightCheckBootstrap.s.sol (run NOW) +");
        console.log("         script/PreFlightCheck.s.sol (run pre-unpause)");
    }

    /// @dev Inline copy of `DeployPhaseC.deployPhaseC` body. Inlining is
    ///      structurally required: nested calls through another contract's
    ///      method would have `msg.sender == phaseCRunner` (not the broadcaster)
    ///      and PM.registerProduct would revert OwnableUnauthorizedAccount.
    ///      Script-level external calls under `vm.startBroadcast()` are
    ///      submitted as txs from the broadcaster — that's the EOA the parent
    ///      Complete script kept as owner of PM/CR (via DEFER_PM_CR_OWNERSHIP).
    function _runPhaseCInline(
        address policyManager,
        address coverRouter,
        address relayer,
        address finalOwner
    ) internal {
        vm.startBroadcast();

        ShieldAdapterFactory factory = new ShieldAdapterFactory();

        address[6] memory impls = [
            address(new FlashBTCShield1h()),
            address(new FlashBTCShield24h()),
            address(new FlashBTCShield48h()),
            address(new FlashETHShield1h()),
            address(new FlashETHShield24h()),
            address(new FlashETHShield48h())
        ];

        // Three parallel arrays instead of an array-of-tuple (Solidity doesn't
        // support tuple-typed array literals in calldata).
        bytes32[6] memory productIds = [
            keccak256("FLASHBTC1H-001"),
            keccak256("FLASHBTC24-001"),
            keccak256("FLASHBTC48-001"),
            keccak256("FLASHETH1H-001"),
            keccak256("FLASHETH24-001"),
            keccak256("FLASHETH48-001")
        ];
        uint256[6] memory triggerProbBps = [
            uint256(18),
            uint256(329),
            uint256(929),
            uint256(10),
            uint256(286),
            uint256(769)
        ];
        uint32[6] memory durations = [
            uint32(3600),
            uint32(86400),
            uint32(172800),
            uint32(3600),
            uint32(86400),
            uint32(172800)
        ];
        address[6] memory feeds = [
            CHAINLINK_BTC_USD, CHAINLINK_BTC_USD, CHAINLINK_BTC_USD,
            CHAINLINK_ETH_USD, CHAINLINK_ETH_USD, CHAINLINK_ETH_USD
        ];

        for (uint256 i = 0; i < 6; i++) {
            (, address adapterProxy) = factory.deployPair(
                impls[i],
                feeds[i],
                CHAINLINK_L2_SEQUENCER_FEED,
                productIds[i],
                policyManager,
                relayer,
                finalOwner
            );

            // Deployer is still PM owner (DEFER flag); broadcaster = deployer.
            IPolicyManagerRegister(policyManager).registerProduct(productIds[i], adapterProxy);

            ICoverRouterConfigure(coverRouter).configureProduct(
                productIds[i],
                PHASE_C_PAYOUT_RATIO_BPS,
                triggerProbBps[i],
                PHASE_C_MARGIN_BPS,
                durations[i],
                true
            );
        }

        vm.stopBroadcast();
        console.log("--- PHASE C ---");
        console.log("  6 shields + 6 adapters deployed, registered on PM, configured on CR");
    }

    /// @dev `vm.envOr` with a sentinel zero-address - a true zero is a
    ///      configuration error here regardless, so the indirection still
    ///      catches the unset case.
    function _envIsSet(string memory name) internal view returns (bool) {
        return vm.envOr(name, address(0)) != address(0);
    }
}
