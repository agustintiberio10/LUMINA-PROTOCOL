// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";

contract MockPriceOracleStorage {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

/// @title StorageLayout
/// @notice Verifies that upgrades preserve storage layout correctly.
contract StorageLayout is Test {
    function test_LuminaToken_storagePreservedAfterUpgrade() public {
        address bondVault = makeAddr("bondVault");
        address cexReserve = makeAddr("cexReserve");
        address founderVesting = makeAddr("founderVesting");
        address lbpDeposit = makeAddr("lbpDeposit");
        address treasuryVesting = makeAddr("treasuryVesting");

        LuminaTokenV2 token =
            ProxyDeployer.deployLuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);

        // Grant burner role and burn some tokens to change state
        token.grantRole(token.BURNER_ROLE(), address(this));
        vm.prank(lbpDeposit);
        token.approve(address(this), 1000e18);
        token.burnFrom(lbpDeposit, 1000e18);

        uint256 totalBurnedBefore = token.totalBurned();
        uint256 supplyBefore = token.totalSupply();
        bool hasBurnerRole = token.hasRole(token.BURNER_ROLE(), address(this));

        // Upgrade
        LuminaTokenV2 newImpl = new LuminaTokenV2();
        token.upgradeToAndCall(address(newImpl), "");

        // All storage should be identical
        assertEq(token.totalBurned(), totalBurnedBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.hasRole(token.BURNER_ROLE(), address(this)), hasBurnerRole);
        assertEq(token.balanceOf(bondVault), 70_000_000 * 1e18);
        assertEq(token.balanceOf(lbpDeposit), 5_000_000 * 1e18 - 1000e18);
    }

    function test_BondVault_storageLayoutPreserved() public {
        MockPriceOracleStorage oracle = new MockPriceOracleStorage();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));

        // Set up authorized caller
        vault.setAuthorizedCaller(makeAddr("buyback"), true);

        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);

        vm.warp(1767225600 + 30 days);
        vault.issueBond(makeAddr("user"), 500);

        // Record state
        uint256 committedBefore = vault.totalCommittedUSD();
        bool isAuthorized = vault.authorizedCallers(makeAddr("buyback"));

        // Upgrade
        BondVault newImpl = new BondVault();
        vault.upgradeToAndCall(address(newImpl), "");

        // Verify
        assertEq(vault.totalCommittedUSD(), committedBefore);
        assertEq(vault.authorizedCallers(makeAddr("buyback")), isAuthorized);
        assertEq(address(vault.lumina()), address(token));
        assertEq(address(vault.claimBond()), address(cb));
        assertEq(address(vault.priceOracle()), address(oracle));
    }

    function test_ClaimBond_storageLayoutPreserved() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));

        // Create state
        cb.mint(makeAddr("alice"), 202804, 1000);
        cb.mint(makeAddr("bob"), 202806, 2000);

        uint256 aliceBalance = cb.balanceOf(makeAddr("alice"), 202804);
        uint256 bobBalance = cb.balanceOf(makeAddr("bob"), 202806);
        uint256 supply202804 = cb.totalSupply(202804);
        uint256 maturity = cb.maturityDate(202804);

        // Upgrade
        ClaimBond newImpl = new ClaimBond();
        cb.upgradeToAndCall(address(newImpl), "");

        // Verify
        assertEq(cb.balanceOf(makeAddr("alice"), 202804), aliceBalance);
        assertEq(cb.balanceOf(makeAddr("bob"), 202806), bobBalance);
        assertEq(cb.totalSupply(202804), supply202804);
        assertEq(cb.maturityDate(202804), maturity);
        assertTrue(cb.epochExists(202804));
        assertTrue(cb.epochExists(202806));
        assertEq(cb.bondVault(), address(this));
    }
}
