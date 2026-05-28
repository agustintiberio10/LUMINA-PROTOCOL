// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @title  PreFlightCheck — last safety gate before Base-mainnet deploy
 *
 * @notice MUST run and pass against the **production RPC** with the production
 *         contract addresses populated in env BEFORE running the real deploy.
 *         A failed check reverts with a specific message and the deploy script
 *         must abort. Pass = log "ALL PRE-FLIGHT CHECKS PASSED — safe to deploy".
 *
 * Verifies the three CRITICAL findings that Phase 5.5 (audits 7.5 / 7.4 / 7.2-7.3 /
 * 7.6) flagged as mainnet-blockers:
 *
 *   - CRIT 1 (FN-C1) — CapacityOracle.pool() != 0.  If 0, getLuminaPrice()
 *     returns an owner-set, unguarded emergencyPrice — the codebase itself
 *     says "MUST NOT SHIP TO MAINNET".
 *   - CRIT 2 (FN-H1) — coverRouter.usdc() == Circle USDC on Base mainnet
 *     (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913). NOT the testnet MockUSDC.
 *   - CRIT 3 (RM-C1) — DEFAULT_ADMIN_ROLE on both LuminaTokenV2 AND BondVault
 *     is held by the Gnosis Safe, NOT the founder EOA (which is burned on
 *     testnet and exposed in chat history).
 *
 * Plus bonus checks the audits also called out:
 *   - block.chainid == 8453 (Base mainnet, not Sepolia).
 *   - Deployer != the burned Sepolia EOA — must be a fresh hardware wallet.
 *
 * Required env vars (every check that depends on the address aborts if 0x0):
 *   LUMINA_TOKEN, BOND_VAULT, CAPACITY_ORACLE, COVER_ROUTER, GNOSIS_SAFE
 * Optional but recommended:
 *   DEPLOYER   (defaults to msg.sender if unset — but env is preferred so the
 *               check can run before any tx is broadcast).
 *
 * Usage:
 *   forge script script/PreFlightCheck.s.sol --rpc-url $BASE_MAINNET_RPC
 *
 * No state changes; this is a pure read-and-revert verifier.
 */

interface ICapacityOracleSlim { function pool() external view returns (address); }
interface ICoverRouterSlim    { function usdc() external view returns (address); }
interface IAccessControlSlim  { function hasRole(bytes32, address) external view returns (bool); }

contract PreFlightCheck is Script {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // Base mainnet canonical addresses.
    address public constant USDC_BASE_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 public constant BASE_MAINNET_CHAINID = 8453;

    // The Sepolia founder EOA that is already burned (private key exposed in
    // operational chat history, address public across every manifest/runbook).
    // MUST NOT hold any admin role on mainnet AND MUST NOT be the deployer.
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
        console2.log("=== Pre-flight check started ===");
        console2.log("chainId:", block.chainid);
        console2.log("contracts:");
        console2.log("  luminaToken   :", luminaToken);
        console2.log("  bondVault     :", bondVault);
        console2.log("  capacityOracle:", capacityOracle);
        console2.log("  coverRouter   :", coverRouter);
        console2.log("  gnosisSafe    :", gnosisSafe);
        console2.log("  deployer      :", deployer);

        // ─── CRITICAL 1 — FN-C1 (CapacityOracle.pool != 0) ──────────────────
        address pool = ICapacityOracleSlim(capacityOracle).pool();
        require(pool != address(0), "FN-C1: pool not set");
        console2.log("[PASS] CRITICAL 1 (FN-C1) pool =", pool);

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
        console2.log("ALL PRE-FLIGHT CHECKS PASSED - safe to deploy");
    }

    /**
     * @dev `vm.envOr` overload for address with default — Forge has
     *      `envOr(string,address)` but its availability depends on the version;
     *      this small wrapper is unambiguous across forge-std builds.
     */
    function _envOr(string memory key, address dflt) internal view returns (address) {
        try vm.envAddress(key) returns (address v) { return v; }
        catch { return dflt; }
    }
}
