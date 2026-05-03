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
    address public constant UNISWAP_V3_SWAPROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;

    /// @dev [Audit fix H-13] Chainlink Sequencer Uptime Feed on Base
    ///      mainnet. Used by `ChainlinkGraceOracle.getSequencerDowntime`
    ///      to extend trigger windows when the sequencer is offline.
    address public constant SEQUENCER_UPTIME_FEED_BASE = 0xBca61D6e7f4f4bb6cf77aEc5a1AB6D7e6Ccf13b6;

    /// @dev The shared chainlinkOracle slot on the deploy expects a single
    ///      address. The shields each independently read the relevant feed.
    ///      For now we wire `CHAINLINK_BTC_USD` as the default; once the
    ///      protocol grows per-shield oracle wiring (post-V5.1), this can
    ///      change. The fork test does not depend on this choice.
    address public constant DEFAULT_CHAINLINK_ORACLE = CHAINLINK_BTC_USD;

    function run() external {
        // Inject mainnet dependency addresses as env vars so the shared
        // `DeployLuminaV5Complete` flow picks them up via `vm.envAddress`.
        vm.setEnv("USDC_ADDRESS", vm.toString(USDC_BASE_MAINNET));
        vm.setEnv("SWAP_ROUTER", vm.toString(UNISWAP_V3_SWAPROUTER02));
        vm.setEnv("CHAINLINK_ORACLE", vm.toString(DEFAULT_CHAINLINK_ORACLE));
        vm.setEnv("AAVE_POOL", vm.toString(AAVE_V3_POOL));

        // [Audit fix H-13 follow-up] Per-asset Chainlink feed addresses +
        // Base Sequencer Uptime Feed. Read by `Complete.run()` STEP 10b
        // when configuring the new ChainlinkGraceOracle. Heartbeats are
        // hard-coded inside Complete (1200s for crypto majors, 86400s
        // for stablecoin pegs).
        vm.setEnv("CHAINLINK_BTC_USD_FEED", vm.toString(CHAINLINK_BTC_USD));
        vm.setEnv("CHAINLINK_ETH_USD_FEED", vm.toString(CHAINLINK_ETH_USD));
        vm.setEnv("CHAINLINK_USDC_USD_FEED", vm.toString(CHAINLINK_USDC_USD));
        vm.setEnv("SEQUENCER_UPTIME_FEED", vm.toString(SEQUENCER_UPTIME_FEED_BASE));

        // Operator-supplied values still come from their environment.
        // We do not override these so that a misconfiguration surfaces as a
        // missing-env-var error at boot, not as a silent default.
        require(_envIsSet("MULTISIG"), "MULTISIG env var required");
        require(_envIsSet("LBP_DEPOSIT"), "LBP_DEPOSIT env var required");
        require(_envIsSet("OPS_WALLET"), "OPS_WALLET env var required");
        require(_envIsSet("FOUNDER_RECIPIENT"), "FOUNDER_RECIPIENT env var required");

        // ─── Audit V5.1 fix C-1: LBP_DEPOSIT must be a contract on mainnet ───
        // The 5M LUMINA LBP allocation is minted directly to LBP_DEPOSIT
        // during `LuminaTokenV2.initialize`. If that address is an EOA the
        // tokens are stranded with no recovery path. The founder commits to
        // a Gnosis Safe; this check makes a misconfiguration impossible to
        // broadcast. FOUNDER_RECIPIENT is intentionally an EOA (see
        // docs/audit/v5.1-uups/39-mainnet-dry-run/REPORT.md) and is not
        // checked here.
        address lbpDeposit = vm.envAddress("LBP_DEPOSIT");
        require(
            lbpDeposit.code.length > 0,
            "LBP_DEPOSIT must be a contract (multisig), not an EOA. Deploy your Gnosis Safe first and set LBP_DEPOSIT to its address."
        );

        console.log("===== DEPLOY LUMINA V5.1 - BASE MAINNET =====");
        console.log("USDC:               ", USDC_BASE_MAINNET);
        console.log("Uniswap V3 Router:  ", UNISWAP_V3_SWAPROUTER02);
        console.log("Aave V3 Pool:       ", AAVE_V3_POOL);
        console.log("Chainlink BTC/USD:  ", CHAINLINK_BTC_USD);
        console.log("Chainlink ETH/USD:  ", CHAINLINK_ETH_USD);
        console.log("Chainlink USDC/USD: ", CHAINLINK_USDC_USD);
        console.log("Multisig:           ", vm.envAddress("MULTISIG"));
        console.log("=============================================");

        // [Audit fix H-12 follow-up] Operator wiring — including BOTH
        //   claimBond.setAuthorizedOperator(marketplace, true)
        //   claimBond.setAuthorizedOperator(buybackEngine, true)
        //   claimBond.setMarketplaceEscape(marketplace)
        // — is performed atomically inside `DeployLuminaV5Complete.run()`
        // below (see lines around the "Marketplace + BuybackEngine
        // authorized as ClaimBond operators" log). This means the
        // operator does NOT have to remember a separate post-deploy
        // wiring step; a single `forge script DeployLuminaV5Mainnet`
        // produces a fully-wired protocol on Base Mainnet, including the
        // H-12 emergency-cancel escape hatch.
        //
        // Tests pinning this behaviour:
        //   - test/marketplace/EmergencyCancelBonds.t.sol
        //       :: test_DeployScriptSetsMarketplaceEscape
        //   - test/audit/v5.1-uups/integration/deploy/DeployScripts.t.sol
        //       :: test_DeployScriptSetsMarketplaceEscape (Sepolia path
        //         goes through the same wiring)
        //   - test/audit/v5.1-uups/integration/deploy/DeployScripts.t.sol
        //       :: test_PostDeployEmergencyCancelWorks (E2E)
        //
        // Why no defensive duplicate call here: the addresses produced by
        // `Complete.run()` are not exposed back to this wrapper, so a
        // local re-call would have to re-read them from the deployments
        // JSON file Complete writes. That indirection is more error-prone
        // than relying on the audited Complete flow + the pinned tests
        // above. If a future refactor of Complete drops `setMarketplaceEscape`,
        // those tests will catch the regression at CI time before any
        // mainnet broadcast.
        DeployLuminaV5Complete completeRunner = new DeployLuminaV5Complete();
        completeRunner.run();

        console.log("===== MAINNET DEPLOY DONE =====");
        console.log(
            "Operator wiring (setAuthorizedOperator + setMarketplaceEscape) handled inside Complete.run() above."
        );
    }

    /// @dev `vm.envOr` with a sentinel zero-address - a true zero is a
    ///      configuration error here regardless, so the indirection still
    ///      catches the unset case.
    function _envIsSet(string memory name) internal view returns (bool) {
        return vm.envOr(name, address(0)) != address(0);
    }
}
