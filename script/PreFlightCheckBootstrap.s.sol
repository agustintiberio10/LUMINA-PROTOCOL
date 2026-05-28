// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @title  PreFlightCheckBootstrap — pre-LBP / bootstrap safety gate
 *
 * @notice **USE THIS BEFORE LBP** — when the LUMINA/USDC pool does not exist
 *         yet. Once the LBP has created the pool and the Safe has called
 *         `capacityOracle.setPool(real)`, **DO NOT USE THIS — switch to
 *         `PreFlightCheck.s.sol` (the full check, PR #181)** before unpausing.
 *
 *         The full check requires `capacityOracle.pool() != 0` (FN-C1). That
 *         cannot be satisfied during bootstrap because the pool only exists
 *         post-LBP. The relaxed bootstrap variant accepts `pool == 0` BUT
 *         requires `coverRouter.paused() == true` as the compensating safety
 *         net: with the router paused, no `_purchase` can run, so nobody
 *         consumes the (manipulable) `emergencyPrice` that `getLuminaPrice()`
 *         returns while pool is unset. **The paused==true requirement is the
 *         safety net that compensates for pool==0.**
 *
 *         Every OTHER assertion is identical to PR #181:
 *           - FN-H1  : coverRouter.usdc() == Circle Base mainnet USDC
 *           - RM-C1  : DEFAULT_ADMIN_ROLE on LuminaTokenV2 + BondVault held by
 *                      the Gnosis Safe, NOT the burned founder EOA
 *           - BONUS  : chainId == 8453; deployer != burned EOA
 *
 *         Two entrypoints: `run()` reads env vars (for CLI / runbook use) and
 *         `verify(...)` takes explicit args (for tests — avoids the
 *         `vm.setEnv` race under Forge's parallel test runner).
 */

interface ICapacityOracleSlim { function pool() external view returns (address); }
interface ICoverRouterSlim    { function usdc() external view returns (address); function paused() external view returns (bool); }
interface IAccessControlSlim  { function hasRole(bytes32, address) external view returns (bool); }

contract PreFlightCheckBootstrap is Script {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // Base mainnet canonical values (identical to PreFlightCheck for parity).
    address public constant USDC_BASE_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 public constant BASE_MAINNET_CHAINID = 8453;

    // The burned Sepolia founder EOA. MUST hold no admin role on mainnet AND
    // MUST NOT be the mainnet deployer.
    address public constant FOUNDER_EOA_BURNED = 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8;

    /// Forge-script entrypoint — reads env vars and delegates to `verify()`.
    function run() external view {
        verify(
            vm.envAddress("LUMINA_TOKEN"),
            vm.envAddress("BOND_VAULT"),
            vm.envAddress("CAPACITY_ORACLE"),
            vm.envAddress("COVER_ROUTER"),
            vm.envAddress("GNOSIS_SAFE"),
            _envOr("DEPLOYER", FOUNDER_EOA_BURNED) // sentinel fails the deployer check explicitly
        );
    }

    /**
     * @notice Pure-args entrypoint — explicit addresses, no env. Tests call
     *         this directly to avoid the `vm.setEnv` race when Forge runs
     *         tests in parallel (env is process-global, not per-test).
     */
    function verify(
        address luminaToken,
        address bondVault,
        address capacityOracle,
        address coverRouter,
        address gnosisSafe,
        address deployer
    ) public view {
        console2.log("=== Pre-flight BOOTSTRAP check started (pre-LBP variant) ===");
        console2.log("chainId:", block.chainid);
        console2.log("contracts:");
        console2.log("  luminaToken   :", luminaToken);
        console2.log("  bondVault     :", bondVault);
        console2.log("  capacityOracle:", capacityOracle);
        console2.log("  coverRouter   :", coverRouter);
        console2.log("  gnosisSafe    :", gnosisSafe);
        console2.log("  deployer      :", deployer);

        // ─── BOOTSTRAP — coverRouter.paused() MUST be true ──────────────────
        // This is the compensating safety net. We do NOT check `pool != 0`
        // (it can legitimately be 0 during bootstrap; FN-C1 only ships if the
        // protocol is also UNPAUSED, which the next line forbids). Once the
        // LBP completes and the Safe sets the pool, switch to PreFlightCheck.
        require(ICoverRouterSlim(coverRouter).paused(), "BOOTSTRAP: coverRouter must be paused");
        console2.log(
            "[PASS] BOOTSTRAP coverRouter.paused() = true  (pool =",
            ICapacityOracleSlim(capacityOracle).pool(),
            "- informational; not enforced in bootstrap)"
        );

        // ─── CRITICAL 2 — FN-H1 (USDC = Circle Base mainnet) ────────────────
        address usdc = ICoverRouterSlim(coverRouter).usdc();
        require(usdc == USDC_BASE_MAINNET, "FN-H1: USDC not mainnet");
        console2.log("[PASS] CRITICAL 2 (FN-H1) usdc =", usdc);

        // ─── CRITICAL 3 — RM-C1 (admin = Safe on Token AND Vault) ───────────
        require(
            !IAccessControlSlim(luminaToken).hasRole(DEFAULT_ADMIN_ROLE, FOUNDER_EOA_BURNED),
            "RM-C1: EOA has token admin"
        );
        require(
            IAccessControlSlim(luminaToken).hasRole(DEFAULT_ADMIN_ROLE, gnosisSafe),
            "RM-C1: Safe missing token admin"
        );
        require(
            !IAccessControlSlim(bondVault).hasRole(DEFAULT_ADMIN_ROLE, FOUNDER_EOA_BURNED),
            "RM-C1: EOA has vault admin"
        );
        require(
            IAccessControlSlim(bondVault).hasRole(DEFAULT_ADMIN_ROLE, gnosisSafe),
            "RM-C1: Safe missing vault admin"
        );
        console2.log("[PASS] CRITICAL 3 (RM-C1) admin = Safe");

        // ─── BONUS — chainId + deployer hygiene ─────────────────────────────
        require(block.chainid == BASE_MAINNET_CHAINID, "BONUS: wrong chainId");
        console2.log("[PASS] BONUS-1 chainId = 8453 (Base mainnet)");

        require(deployer != FOUNDER_EOA_BURNED, "BONUS: deployer is burned EOA");
        console2.log("[PASS] BONUS-2 deployer != burned EOA");

        console2.log("");
        console2.log("BOOTSTRAP PRE-FLIGHT PASSED - safe to proceed to LBP");
        console2.log("REMEMBER: after setPool, run script/PreFlightCheck.s.sol (full) before unpausing.");
    }

    function _envOr(string memory key, address dflt) internal view returns (address) {
        try vm.envAddress(key) returns (address v) { return v; }
        catch { return dflt; }
    }
}
