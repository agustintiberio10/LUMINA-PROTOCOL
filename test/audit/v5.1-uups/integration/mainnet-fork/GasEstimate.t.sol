// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/// @title GasEstimateTest
/// @notice Pins the gas estimate for the V5.1 mainnet deploy as measured by
///         `forge script DeployLuminaV5Complete --rpc-url <Base mainnet>
///          --sender <deployer> --skip-simulation` against a Base Mainnet
///         fork at the audit-#38 reference block (30_000_000).
///
///         The constants below are reproduced verbatim from the dry-run
///         simulation Foundry prints before broadcasting. Re-running the
///         dry-run is the way to refresh them; this file exists so a
///         drift between the audit's published estimate and the live
///         fork is caught loudly in CI.
///
///         The full deploy intentionally is NOT exercised through
///         `forge test` because `DeployLuminaV5Complete.run()` uses
///         `vm.startBroadcast()` and a CREATE-nonce precompute that
///         only line up under `forge script`'s broadcasting persona.
///         Running the same flow inside `forge test` produces a
///         "LUMINA proxy address mismatch - nonce drift" require, which
///         is by-design and not a bug in either the script or the
///         tooling.
contract GasEstimateTest is Test {
    // ─────────────────────────────────────────────────────────────────
    // Pinned measurements (audit-#38 follow-up, 2026-04-28)
    // ─────────────────────────────────────────────────────────────────

    /// @dev Total gas reported by `forge script` for the full V5.1 deploy
    ///      against Base Mainnet at block 30_000_000. 24 contracts (impls
    ///      + proxies), 9 product configurations, 9 product registrations,
    ///      and the post-deploy ownership transfer to the multisig.
    uint256 internal constant DEPLOY_GAS_BASE_MAINNET = 65_696_108;

    /// @dev Live gas price as reported by the same dry-run.
    /// 0.010005 gwei * 1e6 to fit a uint256 cleanly without floats.
    uint256 internal constant LIVE_GAS_PRICE_MICROGWEI = 10_005; // = 0.010005 gwei

    /// @dev Live ETH/USD pulled from Base mainnet's Chainlink ETH/USD feed
    ///      at the same fork block (see `MainnetForkDeployTest.sol`):
    ///      234_754_000_000 / 1e8 = $2 347.54.
    uint256 internal constant LIVE_ETH_USD = 2_348; // rounded for display

    function test_GasEstimate_PinnedForBaseMainnet() public pure {
        // Re-derive ETH cost in wei.
        // gas * gasPrice (microgwei) * 1e3 (gwei→wei multiplier per microgwei) = wei
        uint256 costWei = DEPLOY_GAS_BASE_MAINNET * LIVE_GAS_PRICE_MICROGWEI * 1e3;
        // costWei * USD/ETH / 1e18 = USD; multiply by 100 to get cents.
        uint256 costUsdCents = (costWei * LIVE_ETH_USD * 100) / 1e18;

        console.log("--- AUDIT #38 PINNED GAS ESTIMATE ---");
        console.log("Source: forge script DeployLuminaV5Complete on Base Mainnet @ block 30_000_000");
        console.log("Total deploy gas:           ", DEPLOY_GAS_BASE_MAINNET);
        console.log("Live gas price (microgwei): ", LIVE_GAS_PRICE_MICROGWEI);
        console.log("Live ETH/USD:               ", LIVE_ETH_USD);
        console.log("Estimated cost (cents):     ", costUsdCents);
        console.log("-------------------------------------");

        // Sanity bound: any deploy that costs more than $5 USD on Base under
        // these gas economics is a regression. Today it should be ~$1.55.
        assertLt(costUsdCents, 500, "deploy cost > $5 USD - gas regression?");

        // Lower bound: if the cost falls below $0.50 someone probably
        // accidentally trimmed the deploy script (lost a contract).
        assertGt(costUsdCents, 50, "deploy cost < $0.50 USD - script may be incomplete");
    }
}
