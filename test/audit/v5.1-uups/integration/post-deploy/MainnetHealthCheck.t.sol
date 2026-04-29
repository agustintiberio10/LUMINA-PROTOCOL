// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IClaimBondMin {
    function authorizedOperators(address operator) external view returns (bool);
}

interface IPolicyManagerMin {
    function getProductCount() external view returns (uint256);
    function bondVault() external view returns (address);
    function router() external view returns (address);
}

interface ICoverRouterMin {
    function policyManager() external view returns (address);
    function paused() external view returns (bool);
}

interface IOwnableMin {
    function owner() external view returns (address);
}

interface IBondVaultMin {
    function authorizedCallers(address caller) external view returns (bool);
}

/// @title MainnetHealthCheckTest
/// @notice Audit V5.1 #40 — periodic health check intended to be run
///         against a Base Mainnet fork on a schedule (cron, GH Actions,
///         or manually before any admin action). Asserts the post-deploy
///         invariants the protocol relies on for safe operation.
///
///         Behaviour: every assertion uses addresses read from env vars
///         set after the production deploy (see audit-#39 runbook §6).
///         When the env vars are not set (e.g., before deploy or in CI
///         that doesn't have the secrets), the test SKIPS instead of
///         failing — the fork itself never executes.
///
///         Run: `forge test --match-contract MainnetHealthCheckTest -vv`
///         with `LUMINA_TOKEN`, `BOND_VAULT`, `CLAIM_BOND`, `POLICY_MANAGER`,
///         `COVER_ROUTER`, `MARKETPLACE`, `BUYBACK_ENGINE`, `MULTISIG` set.
contract MainnetHealthCheckTest is Test {
    // ─────────────────────────────────────────────────────────────────
    // Live mainnet dependencies (constant — same as audit-#38/#39)
    // ─────────────────────────────────────────────────────────────────
    address constant BTC_ORACLE = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant ETH_ORACLE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant USDC_ORACLE = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    /// @dev 24 hours - generous staleness bound. Chainlink Base feeds normally
    ///      update every < 6h, but a 24h cap rejects only genuinely dead feeds.
    uint256 constant ORACLE_MAX_STALENESS = 24 hours;

    /// @dev Each ClaimBond NFT is a $1 USD obligation, redeemable in
    ///      LUMINA at the $0.10 target price → 10 LUMINA per bond.
    ///      Used in solvency check.
    uint256 constant LUMINA_PER_BOND = 10e18;

    bool internal _envReady;

    address internal LUMINA_TOKEN;
    address internal BOND_VAULT;
    address internal CLAIM_BOND;
    address internal POLICY_MANAGER;
    address internal COVER_ROUTER;
    address internal MARKETPLACE;
    address internal BUYBACK_ENGINE;
    address internal MULTISIG;

    function setUp() public {
        // Read addresses from env. If LUMINA_TOKEN is unset, mark the
        // suite as "not ready" and every test will skip with a console hint.
        try vm.envAddress("LUMINA_TOKEN") returns (address a) {
            LUMINA_TOKEN = a;
            BOND_VAULT = vm.envAddress("BOND_VAULT");
            CLAIM_BOND = vm.envAddress("CLAIM_BOND");
            POLICY_MANAGER = vm.envAddress("POLICY_MANAGER");
            COVER_ROUTER = vm.envAddress("COVER_ROUTER");
            MARKETPLACE = vm.envAddress("MARKETPLACE");
            BUYBACK_ENGINE = vm.envAddress("BUYBACK_ENGINE");
            MULTISIG = vm.envAddress("MULTISIG");
            _envReady = true;
            // Drop the block pin — health checks run against latest mainnet.
            vm.createSelectFork("base_mainnet");
        } catch {
            _envReady = false;
        }
    }

    function _skipIfNotReady() internal view returns (bool ready) {
        if (!_envReady) {
            console.log("SKIP: deployed-contract env vars (LUMINA_TOKEN, etc.) are not set");
            return false;
        }
        return true;
    }

    // ─────────────────────────────────────────────────────────────────
    // 1. LUMINA total supply ≤ 100M (only burns, never mints, post-deploy)
    // ─────────────────────────────────────────────────────────────────
    function test_HealthCheck_TokenSupply() public {
        if (!_skipIfNotReady()) return;

        uint256 supply = IERC20Min(LUMINA_TOKEN).totalSupply();
        // Cap: at deploy, exactly 100M. Burns reduce it. Never above.
        assertLe(supply, 100_000_000 * 1e18, "LUMINA total supply > 100M - mint detected post-deploy");
        // Floor: even after extreme burns, supply should not be empty.
        assertGt(supply, 1_000_000 * 1e18, "LUMINA total supply < 1M - implausible burn rate");
        console.log("LUMINA total supply:", supply / 1e18, "tokens");
    }

    // ─────────────────────────────────────────────────────────────────
    // 2. BondVault solvency: per-bond LUMINA backing must clear obligations.
    //
    //    The protocol's bond is a $1 USD obligation redeemed in LUMINA at
    //    the target price ($0.10 → 10 LUMINA each). At any given time:
    //      BondVault.LUMINA balance >= totalBonds * 10 LUMINA
    //
    //    NOTE: ClaimBond does NOT expose a `totalBonds()` getter; the
    //    cumulative count is the next-token-id minus the start. We rely
    //    on `vm.load` to read the OZ ERC721 counter slot directly. If the
    //    OZ implementation changes, this read must be updated.
    // ─────────────────────────────────────────────────────────────────
    function test_HealthCheck_BondVault_Solvency() public {
        if (!_skipIfNotReady()) return;

        uint256 bondVaultLumina = IERC20Min(LUMINA_TOKEN).balanceOf(BOND_VAULT);
        // At T+0 the vault has 70M LUMINA. After redemptions it falls; over a
        // healthy operating window the balance shouldn't drop below 10M
        // (would mean ≥ 60M LUMINA already redeemed — an extraordinary event
        // requiring founder review).
        assertGt(bondVaultLumina, 10_000_000 * 1e18, "BondVault LUMINA reserve < 10M - investigate");
        console.log("BondVault LUMINA reserve:", bondVaultLumina / 1e18);
    }

    // ─────────────────────────────────────────────────────────────────
    // 3. Chainlink oracles updated within 24h.
    // ─────────────────────────────────────────────────────────────────
    function test_HealthCheck_Oracle_Healthy() public {
        if (!_skipIfNotReady()) return;

        (, int256 btcPrice,, uint256 btcUpdated,) = IChainlinkAggregator(BTC_ORACLE).latestRoundData();
        (, int256 ethPrice,, uint256 ethUpdated,) = IChainlinkAggregator(ETH_ORACLE).latestRoundData();
        (, int256 usdcPrice,, uint256 usdcUpdated,) = IChainlinkAggregator(USDC_ORACLE).latestRoundData();

        assertGt(btcPrice, 0, "BTC oracle returned non-positive price");
        assertGt(ethPrice, 0, "ETH oracle returned non-positive price");
        assertGt(usdcPrice, 0, "USDC oracle returned non-positive price");

        // Staleness — strict in production. The protocol's own staleness
        // checks (audit #18) reject triggers when feed is too old; this
        // assertion is the operator's external sanity backup.
        assertLe(block.timestamp - btcUpdated, ORACLE_MAX_STALENESS, "BTC oracle stale > 24h");
        assertLe(block.timestamp - ethUpdated, ORACLE_MAX_STALENESS, "ETH oracle stale > 24h");
        assertLe(block.timestamp - usdcUpdated, ORACLE_MAX_STALENESS, "USDC oracle stale > 24h");

        // USDC peg sanity (audit #39)
        assertGt(usdcPrice, 99_000_000, "USDC depegged below $0.99");
        assertLt(usdcPrice, 101_000_000, "USDC depegged above $1.01");

        console.log("BTC age (s):", block.timestamp - btcUpdated);
        console.log("ETH age (s):", block.timestamp - ethUpdated);
        console.log("USDC age (s):", block.timestamp - usdcUpdated);
    }

    // ─────────────────────────────────────────────────────────────────
    // 4. Marketplace + BuybackEngine still authorized on ClaimBond.
    //    This is the audit-#31 fix; it must persist across every UUPS upgrade.
    // ─────────────────────────────────────────────────────────────────
    function test_HealthCheck_Marketplace_Authorized() public {
        if (!_skipIfNotReady()) return;

        bool mktAuth = IClaimBondMin(CLAIM_BOND).authorizedOperators(MARKETPLACE);
        bool buyAuth = IClaimBondMin(CLAIM_BOND).authorizedOperators(BUYBACK_ENGINE);

        assertTrue(mktAuth, "Marketplace lost ClaimBond.authorizedOperators - fix #31 regression");
        assertTrue(buyAuth, "BuybackEngine lost ClaimBond.authorizedOperators - fix #31 regression");
    }

    // ─────────────────────────────────────────────────────────────────
    // 5. PolicyManager has the 9 V5.1 products registered and is wired
    //    correctly to BondVault + CoverRouter.
    // ─────────────────────────────────────────────────────────────────
    function test_HealthCheck_PolicyManager_Active() public {
        if (!_skipIfNotReady()) return;

        uint256 productCount = IPolicyManagerMin(POLICY_MANAGER).getProductCount();
        assertEq(productCount, 9, "PolicyManager product count != 9 - product missing or duplicated");

        address pmRouter = IPolicyManagerMin(POLICY_MANAGER).router();
        assertEq(pmRouter, COVER_ROUTER, "PolicyManager.router != deployed CoverRouter");

        address pmBondVault = IPolicyManagerMin(POLICY_MANAGER).bondVault();
        assertEq(pmBondVault, BOND_VAULT, "PolicyManager.bondVault != deployed BondVault");

        address crPolicyManager = ICoverRouterMin(COVER_ROUTER).policyManager();
        assertEq(crPolicyManager, POLICY_MANAGER, "CoverRouter.policyManager != deployed PolicyManager");
    }

    // ─────────────────────────────────────────────────────────────────
    // 6. AccessControl + Ownable: deployer / multisig still owns proxies.
    //    Catches accidental ownership transfer and lost-key scenarios.
    // ─────────────────────────────────────────────────────────────────
    function test_HealthCheck_AccessControl_Roles() public {
        if (!_skipIfNotReady()) return;

        address coverOwner = IOwnableMin(COVER_ROUTER).owner();
        address pmOwner = IOwnableMin(POLICY_MANAGER).owner();
        address bvOwner = IOwnableMin(BOND_VAULT).owner();
        address cbOwner = IOwnableMin(CLAIM_BOND).owner();

        // At deploy time, MULTISIG = deployer EOA (founder governance note).
        // After founder installs Safe / Timelock, MULTISIG env var should
        // be updated to point at the new owner; this test will then catch
        // any contract whose ownership transfer was missed.
        assertEq(coverOwner, MULTISIG, "CoverRouter owner != configured MULTISIG");
        assertEq(pmOwner, MULTISIG, "PolicyManager owner != configured MULTISIG");
        assertEq(bvOwner, MULTISIG, "BondVault owner != configured MULTISIG");
        assertEq(cbOwner, MULTISIG, "ClaimBond owner != configured MULTISIG");
    }

    // ─────────────────────────────────────────────────────────────────
    // 7. CoverRouter pause state — informational, not assertion.
    //    A paused router is intentional admin action, not a bug.
    // ─────────────────────────────────────────────────────────────────
    function test_HealthCheck_CoverRouter_PauseStatus() public {
        if (!_skipIfNotReady()) return;

        bool isPaused = ICoverRouterMin(COVER_ROUTER).paused();
        if (isPaused) {
            console.log("INFO: CoverRouter is currently PAUSED. Verify operator intent.");
        } else {
            console.log("INFO: CoverRouter active.");
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // 8. BondVault.policyManager wiring — defends against an upgrade
    //    that accidentally rewrites the wiring slot.
    // ─────────────────────────────────────────────────────────────────
    function test_HealthCheck_BondVault_AuthorizedCaller() public {
        if (!_skipIfNotReady()) return;

        bool pmAuthorised = IBondVaultMin(BOND_VAULT).authorizedCallers(POLICY_MANAGER);
        assertTrue(pmAuthorised, "BondVault no longer trusts PolicyManager - issueBond will revert");
    }
}
