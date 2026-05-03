// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract FuzzMockOracleV2 {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title BondVaultFuzzV2
/// @notice Additional fuzz tests for BondVault V5.0 authorized-caller functions.
contract BondVaultFuzzV2 is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    FuzzMockOracleV2 oracle;

    address caller = makeAddr("authorizedCaller");
    address user = makeAddr("fuzzUser");

    function setUp() public {
        vm.warp(1767225600 + 60 days);

        oracle = new FuzzMockOracleV2();
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

        // Grant AUTHORIZED_CALLER_ADMIN_ROLE and set authorized caller
        vault.grantRole(vault.AUTHORIZED_CALLER_ADMIN_ROLE(), address(this));
        vault.setAuthorizedCaller(caller, true);

        // Issue some bonds to create obligations
        vault.issueBond(user, 100_000, 0.036e18); // $100K in bonds => 100_000 * 1e18 committed
    }

    /// @notice Fuzz: decreaseObligations never underflows totalCommittedUSD.
    function testFuzz_DecreaseObligations_NeverUnderflows(uint256 amount) public {
        uint256 committed = vault.totalCommittedUSD();
        amount = bound(amount, 1, committed);

        uint256 commitBefore = vault.totalCommittedUSD();

        vm.prank(caller);
        vault.decreaseObligations(amount);

        uint256 commitAfter = vault.totalCommittedUSD();
        assertEq(commitAfter, commitBefore - amount, "Committed should decrease by amount");
        assertTrue(commitAfter <= commitBefore, "Should never increase");
    }

    /// @notice Fuzz: decreaseObligations reverts when amount exceeds committed.
    function testFuzz_DecreaseObligations_RevertsIfExceedsCommitted(uint256 amount) public {
        uint256 committed = vault.totalCommittedUSD();
        amount = bound(amount, committed + 1, type(uint256).max);

        vm.prank(caller);
        vm.expectRevert("Amount exceeds committed");
        vault.decreaseObligations(amount);
    }

    /// @notice Fuzz: burnFromReserves respects the 5% per-tx cap.
    function testFuzz_BurnFromReserves_Respects5PercentCap(uint256 amount) public {
        uint256 balance = token.balanceOf(address(vault));
        uint256 maxBurn = (balance * 5) / 100;
        // Bound between cap+1 and balance to avoid hitting "Insufficient reserves" first
        amount = bound(amount, maxBurn + 1, balance);

        vm.prank(caller);
        vm.expectRevert("Exceeds 5% per-tx cap");
        vault.burnFromReserves(amount);
    }

    /// @notice Fuzz: burnFromReserves reduces vault token balance by the exact amount.
    function testFuzz_BurnFromReserves_ReducesBalance(uint256 amount) public {
        uint256 balance = token.balanceOf(address(vault));
        uint256 maxBurn = (balance * 5) / 100;
        amount = bound(amount, 1, maxBurn);

        // Grant BURNER_ROLE to vault so it can call burn()
        // LuminaTokenV2.burn() is from ERC20Burnable — the vault calls IBurnable(lumina).burn(amount)
        // which calls ERC20Burnable.burn on the vault's own tokens. No BURNER_ROLE needed for self-burn.
        // But we need the vault to hold the tokens and approve itself — actually burn() burns msg.sender's tokens.
        // The vault calls IBurnable(address(lumina)).burn(amount) which calls LuminaTokenV2.burn(amount)
        // which is ERC20Burnable.burn(amount) which burns msg.sender's (vault's) tokens. No role needed.

        uint256 balBefore = token.balanceOf(address(vault));

        vm.prank(caller);
        vault.burnFromReserves(amount);

        uint256 balAfter = token.balanceOf(address(vault));
        assertEq(balAfter, balBefore - amount, "Balance should decrease by burned amount");
    }
}
