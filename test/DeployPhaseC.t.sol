// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {DeployPhaseC} from "../script/deploy/DeployPhaseC.s.sol";

/**
 * @notice Hermetic test for the Phase C deploy script. Uses lightweight
 *         mocks for PolicyManagerV2.registerProduct + CoverRouterV2.configureProduct
 *         (the only two external calls Phase C makes outside the factory).
 *         The shields and adapters are deployed for REAL (their init only
 *         stores addresses; no chain state required), so this exercises the
 *         full wiring path without a fork.
 */

/// Mock PolicyManagerV2 — records registerProduct calls so we can assert.
contract MockPolicyManager {
    mapping(bytes32 => address) public productShield;
    event Registered(bytes32 indexed productId, address indexed shield);

    function registerProduct(bytes32 productId, address shield) external {
        productShield[productId] = shield;
        emit Registered(productId, shield);
    }
}

/// Mock CoverRouterV2 — records configureProduct calls and enforces the same
/// payoutRatioBps==8000 check the real contract has (so a regression in the
/// script gets caught here too).
contract MockCoverRouter {
    struct ProductConfig {
        bytes32 productId;
        uint256 payoutRatioBps;
        uint256 triggerProbBps;
        uint256 marginBps;
        uint32 durationSeconds;
        bool active;
    }

    mapping(bytes32 => ProductConfig) public products;

    function configureProduct(
        bytes32 productId,
        uint256 payoutRatioBps,
        uint256 triggerProbBps,
        uint256 marginBps,
        uint32 durationSeconds,
        bool active
    ) external {
        require(payoutRatioBps == 8000, "payoutRatioBps must be 8000");
        require(durationSeconds > 0, "Duration must be > 0");
        products[productId] = ProductConfig(productId, payoutRatioBps, triggerProbBps, marginBps, durationSeconds, active);
    }
}

contract DeployPhaseCTest is Test {
    DeployPhaseC internal script;
    MockPolicyManager internal pm;
    MockCoverRouter internal cr;

    address internal constant RELAYER = address(0x9999);
    address internal constant MULTISIG = address(0x5555);
    // Mainnet Base feed addresses (asserted by inspection in the spec).
    address internal constant BTC_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address internal constant ETH_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQ_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Canonical productIds — must match the script's spec table (also tested via _expected()).
    bytes32 internal constant PID_BTC_1H  = keccak256("FLASHBTC1H-001");
    bytes32 internal constant PID_BTC_24H = keccak256("FLASHBTC24-001");
    bytes32 internal constant PID_BTC_48H = keccak256("FLASHBTC48-001");
    bytes32 internal constant PID_ETH_1H  = keccak256("FLASHETH1H-001");
    bytes32 internal constant PID_ETH_24H = keccak256("FLASHETH24-001");
    bytes32 internal constant PID_ETH_48H = keccak256("FLASHETH48-001");

    function setUp() public {
        script = new DeployPhaseC();
        pm = new MockPolicyManager();
        cr = new MockCoverRouter();
    }

    function _run() internal returns (DeployPhaseC.Deployed[6] memory) {
        return script.deployPhaseC(address(pm), address(cr), RELAYER, MULTISIG, BTC_FEED, ETH_FEED, SEQ_FEED);
    }

    // ── happy path ─────────────────────────────────────────────────────
    function test_deploysSixShieldsAndAdapters() public {
        DeployPhaseC.Deployed[6] memory out = _run();
        for (uint256 i = 0; i < 6; i++) {
            assertTrue(out[i].shield != address(0), "shield zero");
            assertTrue(out[i].adapter != address(0), "adapter zero");
            assertTrue(out[i].shield != out[i].adapter, "shield == adapter");
            assertTrue(out[i].shield.code.length > 0, "shield no code");
            assertTrue(out[i].adapter.code.length > 0, "adapter no code");
        }
    }

    function test_registersSixProductsOnPolicyManager() public {
        DeployPhaseC.Deployed[6] memory out = _run();
        for (uint256 i = 0; i < 6; i++) {
            assertEq(pm.productShield(out[i].productId), out[i].adapter, "productShield mismatch");
        }
    }

    function test_configuresSixProductsOnCoverRouter_withCorrectParams() public {
        _run();
        // Expected configs (matches the spec table in the instrucciones) —
        // three parallel arrays because Solidity has no tuple-array literal.
        bytes32[6] memory pids = [PID_BTC_1H, PID_BTC_24H, PID_BTC_48H, PID_ETH_1H, PID_ETH_24H, PID_ETH_48H];
        uint256[6] memory trigs = [uint256(18), 329, 929, 10, 286, 769];
        uint32[6] memory durs = [uint32(3600), 86400, 172800, 3600, 86400, 172800];

        for (uint256 i = 0; i < 6; i++) {
            (bytes32 pidStored, uint256 payout, uint256 trigStored, uint256 margin, uint32 durStored, bool active) =
                cr.products(pids[i]);
            assertEq(pidStored, pids[i], "stored productId");
            assertEq(payout, 8000, "payoutRatioBps");
            assertEq(trigStored, trigs[i], "triggerProbBps");
            assertEq(margin, 20000, "marginBps");
            assertEq(durStored, durs[i], "duration");
            assertTrue(active, "not active");
        }
    }

    function test_ownerOfEveryShieldAndAdapterIsMultisig() public {
        DeployPhaseC.Deployed[6] memory out = _run();
        for (uint256 i = 0; i < 6; i++) {
            assertEq(OwnableUpgradeable(out[i].shield).owner(), MULTISIG, "shield owner != multisig");
            assertEq(OwnableUpgradeable(out[i].adapter).owner(), MULTISIG, "adapter owner != multisig");
        }
    }

    function test_productIdsAreSixDistinctKeccaks() public {
        DeployPhaseC.Deployed[6] memory out = _run();
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = i + 1; j < 6; j++) {
                assertTrue(out[i].productId != out[j].productId, "duplicate productId");
            }
            // each is the keccak of its label
            assertEq(out[i].productId, keccak256(bytes(out[i].label)), "productId != keccak(label)");
        }
    }

    function test_relayerWiredOnEveryAdapter() public {
        DeployPhaseC.Deployed[6] memory out = _run();
        // Smoke check that the factory called adapter.setRelayer(RELAYER) — the
        // adapter exposes `relayer()` (Sprint Shields-UUPS). Reading via low
        // level so we don't need to import FlashShieldAdapter here.
        for (uint256 i = 0; i < 6; i++) {
            (bool ok, bytes memory ret) = out[i].adapter.staticcall(abi.encodeWithSignature("relayer()"));
            require(ok && ret.length == 32, "relayer() missing");
            address wired = abi.decode(ret, (address));
            assertEq(wired, RELAYER, "adapter relayer != RELAYER");
        }
    }
}
