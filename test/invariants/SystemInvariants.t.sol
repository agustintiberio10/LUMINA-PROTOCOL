// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {MockSolvencyOracle} from "../mocks/MockSolvencyOracle.sol";
import {SystemHandler} from "../handlers/SystemHandler.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ Inline mock oracle for BondVault price feed ═══════

contract SystemMockPriceOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }


    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title SystemInvariants
/// @notice System-wide invariant test suite using SystemHandler.
///         Tests 6 invariants across LuminaTokenV2, BondVault, and AdaptiveFeeDistributor.
contract SystemInvariants is Test {
    // ═══════ Contracts ═══════
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    SystemMockPriceOracle oracle;
    AdaptiveFeeDistributor distributor;
    MockSolvencyOracle mockSolvencyOracle;
    SystemHandler handler;

    uint256 initialSupply;

    function setUp() public {
        // Warp to valid time (Jan 1 2026 + 60 days)
        vm.warp(1767225600 + 60 days);

        // ── Deploy mock oracles ──
        oracle = new SystemMockPriceOracle();
        mockSolvencyOracle = new MockSolvencyOracle();

        // ── Deploy AdaptiveFeeDistributor with mock solvency oracle ──
        distributor = ProxyDeployer.deployAdaptiveFeeDistributor(address(mockSolvencyOracle));

        // ── Deploy ClaimBond ──
        claimBond = ProxyDeployer.deployClaimBond();

        // ── Deploy LuminaTokenV2 (needs 5 unique non-zero addresses) ──
        // Use placeholder addresses for non-BondVault buckets
        address cexReserve = address(0xCE01);
        address founderVesting = address(0xF001);
        address lbpDeposit = address(0x1B01);
        address treasuryVesting = address(0x7001);

        // We need to know the BondVault address for token distribution.
        // First deploy token with a temporary bondVault address, then deploy vault.
        // Actually, the token mints to bondVault in constructor, so we use a placeholder
        // and then deal tokens to the real vault.
        address tempBondVault = address(0xBB01);

        token =
            ProxyDeployer.deployLuminaTokenV2(tempBondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);

        // ── Deploy handler first (we need its address as policyManager) ──
        // Temporary handler to get address -- we'll redeploy after vault is ready.
        // Instead, predict handler's role: handler will be the policyManager AND
        // an authorized caller on the vault.

        // Deploy vault with address(this) as policyManager temporarily
        vault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(this));
        claimBond.setBondVault(address(vault));

        // Fund vault with 70M LUMINA (matching the token distribution)
        deal(address(token), address(vault), 70_000_000 * 1e18);

        // Deploy the real handler
        handler = new SystemHandler(token, vault, claimBond, address(oracle));

        // Now redeploy vault+claimBond with handler as policyManager
        claimBond = ProxyDeployer.deployClaimBond();
        vault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(handler));
        claimBond.setBondVault(address(vault));

        // Fund the new vault
        deal(address(token), address(vault), 70_000_000 * 1e18);

        // Authorize handler as an authorized caller for burnFromReserves / decreaseObligations
        vault.setAuthorizedCaller(address(handler), true);

        // Rebuild handler with the correct vault reference
        handler = new SystemHandler(token, vault, claimBond, address(oracle));

        // Need to redeploy vault AGAIN so policyManager == handler
        claimBond = ProxyDeployer.deployClaimBond();
        vault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(handler));
        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);
        vault.setAuthorizedCaller(address(handler), true);

        // Record initial supply
        initialSupply = token.totalSupply();

        // Target only the handler for invariant calls
        targetContract(address(handler));
    }

    // ═══════ INVARIANT 1: Total supply never exceeds 100M ═══════

    function invariant_LuminaSupplyNeverExceedsMax() public view {
        assertTrue(token.totalSupply() <= 100_000_000 * 1e18, "INV-1: LUMINA total supply exceeds 100M MAX_SUPPLY");
    }

    // ═══════ INVARIANT 2: Supply only decreases (no mint exists) ═══════

    function invariant_LuminaSupplyOnlyDecreases() public view {
        assertTrue(
            token.totalSupply() <= initialSupply, "INV-2: LUMINA supply increased -- impossible (no mint function)"
        );
    }

    // ═══════ INVARIANT 3: BondVault solvency -- committed <= 50% of reserve value ═══════

    function invariant_BondVaultSolvency() public view {
        uint256 reserveBalance = token.balanceOf(address(vault));
        uint256 price = oracle.getLuminaPrice();
        uint256 reserveValueUSD = (reserveBalance * price) / 1e18;
        uint256 maxCommit = (reserveValueUSD * 5000) / 10000; // 50%
        uint256 committed = vault.totalCommittedUSD();

        assertTrue(committed <= maxCommit, "INV-3: BondVault insolvent -- committed > 50% of reserve value");
    }

    // ═══════ INVARIANT 4: Adaptive distribution always sums to 10000 BPS ═══════

    function invariant_AdaptiveDistributionSumsTo10000() public view {
        // Check all 16 quadrants (4 solvency x 4 momentum)
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (uint256 burn, uint256 buyback, uint256 ops, uint256 maintenance) = distributor.lookupDistribution(s, m);
                uint256 total = burn + buyback + ops + maintenance;
                assertTrue(total == 10000, "INV-4: Distribution does not sum to 10000 BPS");
            }
        }
    }

    // ═══════ INVARIANT 5: Maintenance floor >= 200 BPS in all quadrants ═══════

    function invariant_MaintenanceFloorAlways2Percent() public view {
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (,,, uint256 maintenance) = distributor.lookupDistribution(s, m);
                assertTrue(maintenance >= 200, "INV-5: Maintenance below 200 BPS floor");
            }
        }
    }

    // ═══════ INVARIANT 6: All burns within 5% per-tx cap ═══════

    function invariant_AllBurnsWithin5PercentCap() public view {
        assertTrue(handler.allBurnsWithinCap(), "INV-6: A burn exceeded the 5% per-tx cap");
    }

    // ═══════ INFORMATIONAL: Call summary ═══════

    function invariant_callSummary() public view {
        // Informational -- no assertion. Use -vvvv to see via console.log.
        // issueCalls, redeemCalls, burnCalls, decreaseCalls, advanceCalls
    }
}
