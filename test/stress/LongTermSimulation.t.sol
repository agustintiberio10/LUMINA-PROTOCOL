// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract SimMockOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }


    function setPrice(uint256 _price) external {
        price = _price;
    }
}

/// @title LongTermSimulation
/// @notice Economic simulation tests for LUMINA BondVault under extended time horizons
///         and extreme market conditions. Runs locally — no fork required.
contract LongTermSimulation is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    SimMockOracle oracle;

    address user = makeAddr("user");

    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC

    function setUp() public {
        vm.warp(BASE_TS + 60 days);

        oracle = new SimMockOracle();
        claimBond = ProxyDeployer.deployClaimBond();
        token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("tempVault"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        vault = ProxyDeployer.deployBondVault(
            address(token),
            address(claimBond),
            address(oracle),
            address(this) // test contract acts as PolicyManager
        );

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);
    }

    // ═══════ 12-MONTH PROTOCOL HEALTH ═══════

    /// @notice Simulate 12 months of bond issuance with varying prices, then redeem after maturity.
    function test_Simulation_12MonthProtocolHealth() public {
        uint256 bondsPerMonth = 50;
        uint256 bondAmountUSD = 500; // $500 per bond
        uint256 totalBondsIssued = 0;
        uint256 expectedCommittedUSD = 0;

        // Deterministic prices cycling between $0.02 and $0.10
        uint256[12] memory monthlyPrices = [
            uint256(0.036e18), // Month 1
            uint256(0.042e18), // Month 2
            uint256(0.028e18), // Month 3
            uint256(0.055e18), // Month 4
            uint256(0.02e18), // Month 5
            uint256(0.07e18), // Month 6
            uint256(0.033e18), // Month 7
            uint256(0.1e18), // Month 8
            uint256(0.045e18), // Month 9
            uint256(0.06e18), // Month 10
            uint256(0.025e18), // Month 11
            uint256(0.08e18) // Month 12
        ];

        for (uint256 month = 0; month < 12; month++) {
            // Set price for this month
            oracle.setPrice(monthlyPrices[month]);

            // Warp to the start of each month (30 days apart)
            vm.warp(BASE_TS + 60 days + (month * 30 days));

            // Issue bonds for this month
            for (uint256 i = 0; i < bondsPerMonth; i++) {
                vault.issueBond(user, bondAmountUSD, 0.036e18);
                totalBondsIssued++;
                expectedCommittedUSD += bondAmountUSD * 1e18;
            }
        }

        // Verify total bonds issued
        assertEq(totalBondsIssued, 600, "Should have issued 600 bonds total");

        // Verify totalCommittedUSD tracks correctly (18-dec USD-wei)
        assertEq(vault.totalCommittedUSD(), expectedCommittedUSD, "totalCommittedUSD should match");

        // Vault should still have tokens (never ran out during issuance)
        uint256 vaultBalance = token.balanceOf(address(vault));
        assertGt(vaultBalance, 0, "Vault should still hold LUMINA tokens");
        assertEq(vaultBalance, 70_000_000 * 1e18, "No tokens should have left vault during issuance");

        // ═══════ REDEMPTION PHASE (month 24+) ═══════
        // Warp to month 26 (well past 24-month maturity for earliest bonds)
        vm.warp(BASE_TS + 60 days + (26 * 30 days));
        oracle.setPrice(0.05e18);

        // Find a matured epoch and redeem some bonds
        uint256 maturityTs = BASE_TS + 60 days + 730 days; // first bond's maturity
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 monthNum = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + monthNum;

        uint256 userBondBalance = claimBond.balanceOf(user, epochId);
        if (userBondBalance > 0 && claimBond.isMatured(epochId)) {
            uint256 balanceBefore = token.balanceOf(address(vault));
            vm.prank(user);
            vault.redeemBond(epochId, userBondBalance);

            uint256 balanceAfter = token.balanceOf(address(vault));
            assertLt(balanceAfter, balanceBefore, "Vault balance should decrease after redemption");
            assertGt(token.balanceOf(user), 0, "User should have received LUMINA");
        }
    }

    // ═══════ MARKET CRASH SCENARIO ═══════

    /// @notice Simulate a market crash: issue bonds, price crashes, verify capacity
    ///         check still guards against over-issuance, then recover.
    function test_Simulation_MarketCrashScenario() public {
        // Phase 1: Issue 100 bonds at $0.036
        oracle.setPrice(0.036e18);
        for (uint256 i = 0; i < 100; i++) {
            vault.issueBond(user, 800, 0.036e18);
        }
        assertEq(vault.totalCommittedUSD(), 100 * 800 * 1e18, "Should have 100 bonds committed");

        // Phase 2: Price crashes to $0.004
        // Capacity decreases dramatically, so large issuance should fail
        oracle.setPrice(0.004e18);
        uint256 cap = vault.availableCapacityUSD();

        // At $0.004 capacity is much lower. Try to issue beyond capacity.
        if (cap < 800) {
            vm.expectRevert("Exceeds capacity");
            vault.issueBond(user, 800, 0.036e18);
        }

        // Phase 3: Price recovers to $0.036
        oracle.setPrice(0.036e18);

        // Phase 4: Confirm bonds can be issued again
        vault.issueBond(user, 800, 0.036e18);
        assertEq(vault.totalCommittedUSD(), 101 * 800 * 1e18, "Should have 101 bonds now");
    }

    // ═══════ BULL RUN SCENARIO ═══════

    /// @notice Simulate a bull run: price rises from $0.036 to $1.00, verify capacity
    ///         increases and system handles high volume.
    function test_Simulation_BullRunScenario() public {
        // Phase 1: Baseline at $0.036
        oracle.setPrice(0.036e18);
        uint256 capacityAtBaseline = vault.availableCapacityUSD();
        assertGt(capacityAtBaseline, 0, "Should have capacity at baseline price");

        // Phase 2: Price rises to $1.00
        oracle.setPrice(1.0e18);
        uint256 capacityAtDollar = vault.availableCapacityUSD();

        // Capacity should be dramatically higher (~27.8x: $1.00 / $0.036)
        assertGt(capacityAtDollar, capacityAtBaseline * 20, "Capacity should increase >20x at $1.00");

        // Phase 3: Issue many bonds at high price to test system under load
        uint256 bondsIssued = 0;
        uint256 bondSize = 10_000; // $10,000 per bond

        // Issue bonds until we approach 80% of capacity
        uint256 targetCommitment = (capacityAtDollar * 80) / 100;
        while (vault.totalCommittedUSD() / 1e18 < targetCommitment && bondsIssued < 2000) {
            vault.issueBond(user, bondSize, 0.036e18);
            bondsIssued++;
        }

        assertGt(bondsIssued, 100, "Should issue many bonds at high price");

        // Verify system integrity after heavy issuance
        uint256 committedUSD = vault.totalCommittedUSD();
        assertEq(committedUSD, bondsIssued * bondSize * 1e18, "Committed USD should match exactly");

        // Vault should still hold all tokens (no tokens leave during issuance)
        assertEq(token.balanceOf(address(vault)), 70_000_000 * 1e18, "Vault balance unchanged during issuance");

        // Remaining capacity should be reduced but positive
        uint256 remainingCapacity = vault.availableCapacityUSD();
        assertGt(remainingCapacity, 0, "Should still have some remaining capacity");
        assertLt(remainingCapacity, capacityAtDollar, "Remaining capacity should be less than initial");
    }
}
