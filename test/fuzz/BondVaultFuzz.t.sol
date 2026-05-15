// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract FuzzMockOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title BondVaultFuzz
/// @notice Fuzz tests for BondVault mint/redeem paths.
contract BondVaultFuzz is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    FuzzMockOracle oracle;

    address user = makeAddr("fuzzUser");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 60 days);

        oracle = new FuzzMockOracle();
        claimBond = ProxyDeployer.deployClaimBond();
        token = ProxyDeployer.deployLuminaTokenV2(
            address(0xF001), address(0xF005), address(0xF003), address(0xF002), address(0xF004)
        );

        vault = ProxyDeployer.deployBondVault(
            address(token),
            address(claimBond),
            address(oracle),
            address(this) // test contract = policyManager
        );

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 82_000_000 * 1e18);
    }

    function _getEpoch() internal view returns (uint256) {
        uint256 matTs = block.timestamp + 730 days;
        uint256 mfb = (matTs - 1767225600) / 2629746;
        return (2026 + mfb / 12) * 100 + (1 + mfb % 12);
    }

    /// @notice Fuzz: issue bond with random coverage, then check committed state.
    function testFuzz_issueBond(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000); // $1 to $1M

        uint256 cap = vault.availableCapacityUSD();
        if (amount > cap) {
            vm.expectRevert("Exceeds capacity");
            vault.issueBond(user, amount);
        } else {
            uint256 commitBefore = vault.totalCommittedUSD();
            vault.issueBond(user, amount);
            assertEq(
                vault.totalCommittedUSD(), commitBefore + amount * 1e18, "Committed should increase by amount * 1e18"
            );
            uint256 epoch = _getEpoch();
            assertEq(claimBond.balanceOf(user, epoch), amount, "Bond balance should match");
        }
    }

    /// @notice Fuzz: issue then redeem at random price, verify LUMINA received.
    function testFuzz_issueAndRedeem(uint256 amount, uint256 priceWad) public {
        amount = bound(amount, 1, 100_000);
        priceWad = bound(priceWad, 0.001e18, 100e18);

        // Limit to capacity
        uint256 cap = vault.availableCapacityUSD();
        if (amount > cap) return; // skip if over capacity

        vault.issueBond(user, amount);
        uint256 epoch = _getEpoch();

        // Warp to maturity
        vm.warp(claimBond.maturityDate(epoch) + 1);
        oracle.setPrice(priceWad);

        // Check if vault has enough LUMINA for this redemption at this price.
        // At very low prices + large bonds, the required LUMINA can exceed vault balance.
        // This is expected protocol behavior (SAFETY_FACTOR + capacity check mitigate it).
        uint256 expectedLumina = (amount * 1e36) / priceWad;
        uint256 vaultBalance = token.balanceOf(address(vault));

        if (expectedLumina > vaultBalance) {
            // Expected: vault cannot fulfill at this price/amount combo
            vm.prank(user);
            vm.expectRevert("Insufficient reserve");
            vault.redeemBond(epoch, amount);
        } else {
            uint256 balBefore = token.balanceOf(user);
            vm.prank(user);
            vault.redeemBond(epoch, amount);
            uint256 received = token.balanceOf(user) - balBefore;
            assertEq(received, expectedLumina, "Received LUMINA should match formula");
            assertEq(claimBond.balanceOf(user, epoch), 0, "Bonds should be fully burned");
        }
    }

    /// @notice Fuzz: issue, partial redeem at random amount, verify remainder.
    function testFuzz_partialRedeem(uint256 totalBond, uint256 redeemPart, uint256 priceWad) public {
        totalBond = bound(totalBond, 2, 50_000);
        priceWad = bound(priceWad, 0.001e18, 100e18);

        uint256 cap = vault.availableCapacityUSD();
        if (totalBond > cap) return;

        vault.issueBond(user, totalBond);
        uint256 epoch = _getEpoch();

        vm.warp(claimBond.maturityDate(epoch) + 1);
        oracle.setPrice(priceWad);

        redeemPart = bound(redeemPart, 1, totalBond);

        vm.prank(user);
        vault.redeemBond(epoch, redeemPart);

        uint256 remainder = totalBond - redeemPart;
        assertEq(claimBond.balanceOf(user, epoch), remainder, "Bond remainder should match");
    }

    /// @notice Fuzz: redemption at MIN_REDEEM_PRICE boundary.
    function testFuzz_redeemAtFloorPrice(uint256 amount) public {
        amount = bound(amount, 1, 1000);

        uint256 cap = vault.availableCapacityUSD();
        if (amount > cap) return;

        vault.issueBond(user, amount);
        uint256 epoch = _getEpoch();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        // Set to exactly MIN_REDEEM_PRICE ($0.001)
        oracle.setPrice(0.001e18);

        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        vault.redeemBond(epoch, amount);
        uint256 received = token.balanceOf(user) - balBefore;

        // amount * 1e36 / 0.001e18 = amount * 1e36 / 1e15 = amount * 1e21
        assertEq(received, amount * 1e21, "Floor redemption should give amount * 1000 LUMINA");
    }
}
