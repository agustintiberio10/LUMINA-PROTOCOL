// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";

// Reuse the audited atomic shield+adapter factory from the Sepolia deploy.
import {ShieldAdapterFactory} from "./DeployShieldsAndAdapters.s.sol";

interface IPolicyManagerRegister {
    function registerProduct(bytes32 productId, address shield) external;
    function productShield(bytes32) external view returns (address);
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

/**
 * @title  DeployPhaseC
 * @notice Phase C of the mainnet deploy: deploys the 6 Flash shields + 6
 *         adapters and wires them into PolicyManagerV2 (registerProduct) and
 *         CoverRouterV2 (configureProduct). Without this, `DeployLuminaV5Complete`
 *         leaves the protocol non-functional (no products → no purchases).
 *
 *         Factored as a standalone script so it can run AFTER the core deploy,
 *         either by the operator (single command) or composed by the Mainnet
 *         wrapper. The pure-args entrypoint `deployPhaseC(...)` lets tests
 *         exercise the full wiring without env / broadcast.
 *
 * Required env (run() path):
 *   POLICY_MANAGER     PolicyManagerV2 proxy from the core deploy
 *   COVER_ROUTER       CoverRouterV2 proxy from the core deploy
 *   RELAYER            EOA wired into each FlashShieldAdapter
 *   MULTISIG           final owner of every shield + adapter proxy
 *   BTC_FEED           Chainlink BTC/USD feed (mainnet: 0x64c9...)
 *   ETH_FEED           Chainlink ETH/USD feed (mainnet: 0x7104...)
 *   SEQUENCER_FEED     Chainlink L2 sequencer uptime feed (mainnet:
 *                      0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; on Sepolia
 *                      the operator may pass `address(0)` consciously)
 *   DEPLOYER_PRIVATE_KEY  signer for the broadcast
 *
 * Required env (tests use the `deployPhaseC` pure-args entrypoint and skip env).
 */
contract DeployPhaseC is Script {
    // Phase C is purely additive — payoutRatioBps is locked at 8000 in
    // CoverRouterV2.configureProduct (require), 20000 marginBps = 2.0x agreed
    // pricing per the economic audit, and the 6 (triggerProbBps,duration)
    // pairs come straight from the product spec.
    uint256 internal constant PAYOUT_RATIO_BPS = 8000;
    uint256 internal constant MARGIN_BPS = 20000;

    struct ProductSpec {
        string label;            // canonical name; keccak256 → productId
        bytes32 productId;       // pre-computed for verifiability
        address feed;            // Chainlink BTC or ETH feed
        uint256 triggerProbBps;  // priced into the premium math
        uint32 durationSeconds;  // shield validity window
    }

    struct Deployed {
        string label;
        bytes32 productId;
        address shield;
        address adapter;
    }

    /// Forge-script entrypoint: reads env vars and broadcasts.
    function run() external returns (Deployed[6] memory out) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address policyManager = vm.envAddress("POLICY_MANAGER");
        address coverRouter = vm.envAddress("COVER_ROUTER");
        address relayer = vm.envAddress("RELAYER");
        address multisig = vm.envAddress("MULTISIG");
        address btcFeed = vm.envAddress("BTC_FEED");
        address ethFeed = vm.envAddress("ETH_FEED");
        address sequencerFeed = vm.envAddress("SEQUENCER_FEED");

        vm.startBroadcast(pk);
        out = deployPhaseC(policyManager, coverRouter, relayer, multisig, btcFeed, ethFeed, sequencerFeed);
        vm.stopBroadcast();

        for (uint256 i = 0; i < 6; i++) {
            console.log(out[i].label);
            console.log("  productId:", vm.toString(out[i].productId));
            console.log("  shield   :", out[i].shield);
            console.log("  adapter  :", out[i].adapter);
        }
        console.log("Phase C complete: 6 products registered + configured.");
    }

    /**
     * @notice Pure-args entrypoint. Deploys the 6 shield/adapter pairs (via
     *         the audited `ShieldAdapterFactory`), registers each on the
     *         PolicyManager, and configures pricing on the CoverRouter.
     *         Used by both `run()` (env-driven) and the unit tests.
     */
    function deployPhaseC(
        address policyManager,
        address coverRouter,
        address relayer,
        address finalOwner,
        address btcFeed,
        address ethFeed,
        address sequencerFeed
    ) public returns (Deployed[6] memory out) {
        ShieldAdapterFactory factory = new ShieldAdapterFactory();

        // Shield implementations — each variant is its own contract (different
        // window length / barrier behaviour); they share the BaseFlashShield
        // init signature `initialize(address router, address priceFeed, address sequencer)`.
        address[6] memory impls = [
            address(new FlashBTCShield1h()),
            address(new FlashBTCShield24h()),
            address(new FlashBTCShield48h()),
            address(new FlashETHShield1h()),
            address(new FlashETHShield24h()),
            address(new FlashETHShield48h())
        ];

        ProductSpec[6] memory specs = _specs(btcFeed, ethFeed);

        for (uint256 i = 0; i < 6; i++) {
            (address shieldProxy, address adapterProxy) = factory.deployPair(
                impls[i],
                specs[i].feed,
                sequencerFeed,
                specs[i].productId,
                policyManager,
                relayer,
                finalOwner
            );

            // PolicyManager registry — the adapter is what triggerPayout calls.
            IPolicyManagerRegister(policyManager).registerProduct(specs[i].productId, adapterProxy);

            // CoverRouter pricing — payoutRatio MUST be 8000 (require in the
            // contract). marginBps + triggerProbBps + duration straight from spec.
            ICoverRouterConfigure(coverRouter).configureProduct(
                specs[i].productId,
                PAYOUT_RATIO_BPS,
                specs[i].triggerProbBps,
                MARGIN_BPS,
                specs[i].durationSeconds,
                true // active
            );

            out[i] = Deployed({
                label: specs[i].label,
                productId: specs[i].productId,
                shield: shieldProxy,
                adapter: adapterProxy
            });
        }
    }

    /// Spec table — single source of truth, computed (label → productId).
    function _specs(address btcFeed, address ethFeed) internal pure returns (ProductSpec[6] memory s) {
        s[0] = ProductSpec({
            label: "FLASHBTC1H-001",
            productId: keccak256("FLASHBTC1H-001"),
            feed: btcFeed,
            triggerProbBps: 18,
            durationSeconds: 3600
        });
        s[1] = ProductSpec({
            label: "FLASHBTC24-001",
            productId: keccak256("FLASHBTC24-001"),
            feed: btcFeed,
            triggerProbBps: 329,
            durationSeconds: 86400
        });
        s[2] = ProductSpec({
            label: "FLASHBTC48-001",
            productId: keccak256("FLASHBTC48-001"),
            feed: btcFeed,
            triggerProbBps: 929,
            durationSeconds: 172800
        });
        s[3] = ProductSpec({
            label: "FLASHETH1H-001",
            productId: keccak256("FLASHETH1H-001"),
            feed: ethFeed,
            triggerProbBps: 10,
            durationSeconds: 3600
        });
        s[4] = ProductSpec({
            label: "FLASHETH24-001",
            productId: keccak256("FLASHETH24-001"),
            feed: ethFeed,
            triggerProbBps: 286,
            durationSeconds: 86400
        });
        s[5] = ProductSpec({
            label: "FLASHETH48-001",
            productId: keccak256("FLASHETH48-001"),
            feed: ethFeed,
            triggerProbBps: 769,
            durationSeconds: 172800
        });
    }
}
