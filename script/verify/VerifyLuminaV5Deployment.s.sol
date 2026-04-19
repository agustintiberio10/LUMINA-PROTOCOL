// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

// ═══════════════════════════════════════════════════════════════════════
// Minimal interfaces — avoids import conflicts across src/ contracts
// ═══════════════════════════════════════════════════════════════════════

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

interface IAccessControlMinimal {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IOwnableMinimal {
    function owner() external view returns (address);
}

interface ITWAPBurnerMinimal {
    function feeDistributor() external view returns (address);
    function adaptiveModeEnabled() external view returns (bool);
    function buybackReserve() external view returns (address);
    function maintenanceReserve() external view returns (address);
}

interface ICoverRouterV2Minimal {
    function policyManager() external view returns (address);
    function twapBurner() external view returns (address);
}

interface IPolicyManagerV2Minimal {
    function router() external view returns (address);
    function bondVault() external view returns (address);
    function getProductCount() external view returns (uint256);
}

interface IBondVaultMinimal {
    function policyManager() external view returns (address);
    function authorizedCallers(address caller) external view returns (bool);
}

interface IClaimBondMinimal {
    function bondVault() external view returns (address);
}

interface ICapacityOracleMinimal {
    function getLuminaPrice() external view returns (uint256);
}

/// @title VerifyLuminaV5Deployment
/// @notice Post-deployment verification script for LUMINA Protocol V5.0.
/// @dev Reads all contract addresses from environment variables.
///      Each check emits a console2.log with PASS/FAIL. Reverts at the end if any check fails.
///
///      Run: forge script script/verify/VerifyLuminaV5Deployment.s.sol --rpc-url $RPC
contract VerifyLuminaV5Deployment is Script {
    uint256 private _failures;

    function run() external view {
        // ═══════ LOAD ADDRESSES FROM ENV ═══════
        address luminaToken = vm.envAddress("LUMINA_TOKEN");
        address bondVault = vm.envAddress("BOND_VAULT");
        address cexLiquidityReserve = vm.envAddress("CEX_LIQUIDITY_RESERVE");
        address founderVesting = vm.envAddress("FOUNDER_VESTING");
        address lbpDeposit = vm.envAddress("LBP_DEPOSIT");
        address treasuryVesting = vm.envAddress("TREASURY_VESTING");
        address twapBurner = vm.envAddress("TWAP_BURNER");
        address adaptiveFeeDistributor = vm.envAddress("ADAPTIVE_FEE_DISTRIBUTOR");
        address coverRouter = vm.envAddress("COVER_ROUTER");
        address policyManager = vm.envAddress("POLICY_MANAGER");
        address claimBond = vm.envAddress("CLAIM_BOND");
        address buybackEngine = vm.envAddress("BUYBACK_ENGINE");
        address maintenanceReserve = vm.envAddress("MAINTENANCE_RESERVE");
        address capacityOracle = vm.envAddress("CAPACITY_ORACLE");
        address multisig = vm.envAddress("MULTISIG");

        console2.log("=== LUMINA V5.0 Deployment Verification ===");
        console2.log("");

        uint256 failures = 0;

        // ═══════════════════════════════════════════
        // 1. BALANCE CHECKS
        // ═══════════════════════════════════════════
        console2.log("--- 1. Balance Checks ---");

        failures += _checkBalance(luminaToken, bondVault, 70_000_000e18, "BondVault");
        failures += _checkBalance(luminaToken, cexLiquidityReserve, 14_000_000e18, "CEXLiquidityReserve");
        failures += _checkBalance(luminaToken, founderVesting, 8_000_000e18, "FounderVesting");
        failures += _checkBalance(luminaToken, lbpDeposit, 5_000_000e18, "LBP deposit");
        failures += _checkBalance(luminaToken, treasuryVesting, 3_000_000e18, "TreasuryVesting");

        // ═══════════════════════════════════════════
        // 2. ROLE CHECKS
        // ═══════════════════════════════════════════
        console2.log("");
        console2.log("--- 2. Role Checks ---");

        // LuminaTokenV2: BURNER_ROLE granted to TWAPBurner
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");
        failures += _checkRole(luminaToken, BURNER_ROLE, twapBurner, "LuminaTokenV2.BURNER_ROLE -> TWAPBurner");

        // BondVault: authorizedCallers[buybackEngine] == true
        {
            bool authorized = IBondVaultMinimal(bondVault).authorizedCallers(buybackEngine);
            if (authorized) {
                console2.log("[PASS] BondVault.authorizedCallers[buybackEngine] == true");
            } else {
                console2.log("[FAIL] BondVault.authorizedCallers[buybackEngine] != true");
                failures++;
            }
        }

        // CEXLiquidityReserve: ALLOCATOR_ROLE for multisig
        bytes32 ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
        failures += _checkRole(
            cexLiquidityReserve, ALLOCATOR_ROLE, multisig, "CEXLiquidityReserve.ALLOCATOR_ROLE -> multisig"
        );

        // MaintenanceReserve: SPENDER_ROLE for multisig
        bytes32 SPENDER_ROLE = keccak256("SPENDER_ROLE");
        failures += _checkRole(
            maintenanceReserve, SPENDER_ROLE, multisig, "MaintenanceReserve.SPENDER_ROLE -> multisig"
        );

        // BuybackEngine: BUYBACK_OPERATOR_ROLE for multisig
        bytes32 BUYBACK_OPERATOR_ROLE = keccak256("BUYBACK_OPERATOR_ROLE");
        failures += _checkRole(
            buybackEngine, BUYBACK_OPERATOR_ROLE, multisig, "BuybackEngine.BUYBACK_OPERATOR_ROLE -> multisig"
        );

        // ═══════════════════════════════════════════
        // 3. WIRING CHECKS
        // ═══════════════════════════════════════════
        console2.log("");
        console2.log("--- 3. Wiring Checks ---");

        // TWAPBurner
        failures += _checkAddress(
            ITWAPBurnerMinimal(twapBurner).feeDistributor(),
            adaptiveFeeDistributor,
            "TWAPBurner.feeDistributor == adaptiveFeeDistributor"
        );

        {
            bool adaptiveEnabled = ITWAPBurnerMinimal(twapBurner).adaptiveModeEnabled();
            if (adaptiveEnabled) {
                console2.log("[PASS] TWAPBurner.adaptiveModeEnabled == true");
            } else {
                console2.log("[FAIL] TWAPBurner.adaptiveModeEnabled != true");
                failures++;
            }
        }

        {
            address bbReserve = ITWAPBurnerMinimal(twapBurner).buybackReserve();
            if (bbReserve != address(0)) {
                console2.log("[PASS] TWAPBurner.buybackReserve != address(0)");
            } else {
                console2.log("[FAIL] TWAPBurner.buybackReserve == address(0)");
                failures++;
            }
        }

        failures += _checkAddress(
            ITWAPBurnerMinimal(twapBurner).maintenanceReserve(),
            maintenanceReserve,
            "TWAPBurner.maintenanceReserve == maintenanceReserve"
        );

        // CoverRouterV2
        failures += _checkAddress(
            address(ICoverRouterV2Minimal(coverRouter).policyManager()),
            policyManager,
            "CoverRouterV2.policyManager == policyManager"
        );

        failures += _checkAddress(
            address(ICoverRouterV2Minimal(coverRouter).twapBurner()),
            twapBurner,
            "CoverRouterV2.twapBurner == twapBurner"
        );

        // PolicyManagerV2
        failures += _checkAddress(
            IPolicyManagerV2Minimal(policyManager).router(), coverRouter, "PolicyManagerV2.router == coverRouter"
        );

        failures += _checkAddress(
            address(IPolicyManagerV2Minimal(policyManager).bondVault()),
            bondVault,
            "PolicyManagerV2.bondVault == bondVault"
        );

        // BondVault
        failures += _checkAddress(
            IBondVaultMinimal(bondVault).policyManager(), policyManager, "BondVault.policyManager == policyManager"
        );

        // ClaimBond
        failures += _checkAddress(
            IClaimBondMinimal(claimBond).bondVault(), bondVault, "ClaimBond.bondVault == bondVault"
        );

        // ═══════════════════════════════════════════
        // 4. OWNERSHIP CHECKS
        // ═══════════════════════════════════════════
        console2.log("");
        console2.log("--- 4. Ownership Checks ---");

        failures += _checkOwner(twapBurner, multisig, "TWAPBurner");
        failures += _checkOwner(coverRouter, multisig, "CoverRouterV2");
        failures += _checkOwner(policyManager, multisig, "PolicyManagerV2");
        failures += _checkOwner(capacityOracle, multisig, "CapacityOracle");
        failures += _checkOwner(claimBond, multisig, "ClaimBond");

        // ═══════════════════════════════════════════
        // 5. ORACLE CHECKS
        // ═══════════════════════════════════════════
        console2.log("");
        console2.log("--- 5. Oracle Checks ---");

        {
            uint256 luminaPrice = ICapacityOracleMinimal(capacityOracle).getLuminaPrice();
            if (luminaPrice > 0) {
                console2.log("[PASS] CapacityOracle.getLuminaPrice() > 0 (price:", luminaPrice, ")");
            } else {
                console2.log("[FAIL] CapacityOracle.getLuminaPrice() == 0");
                failures++;
            }
        }

        // ═══════════════════════════════════════════
        // 6. SHIELD REGISTRATION
        // ═══════════════════════════════════════════
        console2.log("");
        console2.log("--- 6. Shield Registration ---");

        {
            uint256 productCount = IPolicyManagerV2Minimal(policyManager).getProductCount();
            if (productCount == 9) {
                console2.log("[PASS] PolicyManagerV2 has 9 shields registered");
            } else {
                console2.log("[FAIL] PolicyManagerV2 shield count:", productCount, "(expected 9)");
                failures++;
            }
        }

        // ═══════════════════════════════════════════
        // SUMMARY
        // ═══════════════════════════════════════════
        console2.log("");
        console2.log("=== Verification Complete ===");

        if (failures > 0) {
            console2.log("FAILURES:", failures);
            revert("Deployment verification failed. See logs above.");
        } else {
            console2.log("ALL CHECKS PASSED");
        }
    }

    // ═══════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════

    function _checkBalance(address token, address holder, uint256 expected, string memory label)
        internal
        view
        returns (uint256 fail)
    {
        uint256 actual = IERC20Minimal(token).balanceOf(holder);
        if (actual == expected) {
            console2.log("[PASS]", label, "balance correct");
        } else {
            console2.log("[FAIL]", label, "balance mismatch. Actual:", actual);
            fail = 1;
        }
    }

    function _checkRole(address target, bytes32 role, address account, string memory label)
        internal
        view
        returns (uint256 fail)
    {
        bool has = IAccessControlMinimal(target).hasRole(role, account);
        if (has) {
            console2.log("[PASS]", label);
        } else {
            console2.log("[FAIL]", label);
            fail = 1;
        }
    }

    function _checkAddress(address actual, address expected, string memory label) internal view returns (uint256 fail) {
        if (actual == expected) {
            console2.log("[PASS]", label);
        } else {
            console2.log("[FAIL]", label);
            console2.log("  actual:", actual);
            console2.log("  expected:", expected);
            fail = 1;
        }
    }

    function _checkOwner(address target, address expectedOwner, string memory label)
        internal
        view
        returns (uint256 fail)
    {
        address actual = IOwnableMinimal(target).owner();
        if (actual == expectedOwner) {
            console2.log("[PASS]", label, "owner == multisig");
        } else {
            console2.log("[FAIL]", label, "owner mismatch:", actual);
            fail = 1;
        }
    }
}
