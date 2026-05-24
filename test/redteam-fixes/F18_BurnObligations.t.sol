// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

contract F18Oracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

/// @title F-18 — ClaimBond.burnByHolder must decrement BondVault obligations.
contract F18_BurnObligationsTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    F18Oracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);

        oracle = new F18Oracle();

        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(claimBondProxy));

        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, makeAddr("tempVault"), makeAddr("cex"), founder, lbp, treasury
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        BondVault vaultImpl = new BondVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(this)
            )
        );
        vault = BondVault(address(vaultProxy));

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);

        // F-18 prerequisite: ClaimBond must be an authorized caller on the vault.
        vault.setAuthorizedCaller(address(claimBond), true);
    }

    function test_BurnByHolderDecreasesObligations() public {
        // Issue $1000 of bonds to user → totalCommittedUSD += 1000e18.
        vault.issueBond(user, 1_000);
        uint256 committedBefore = vault.totalCommittedUSD();
        assertEq(committedBefore, 1_000 * 1e18, "committed not set");

        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        uint256 epoch = (2026 + monthsFromBase / 12) * 100 + (1 + monthsFromBase % 12);

        // Holder burns $400 of bonds directly.
        vm.prank(user);
        claimBond.burnByHolder(user, epoch, 400);

        // Obligation must drop by exactly $400 (400 * 1e18).
        assertEq(vault.totalCommittedUSD(), committedBefore - 400 * 1e18, "obligations not decremented on holder burn");
        assertEq(claimBond.balanceOf(user, epoch), 600, "bond balance wrong");
    }

    /// When ClaimBond is NOT authorized, burnByHolder must still succeed (no
    /// brick) but skip the sync and emit ObligationsSyncSkipped.
    function test_BurnByHolderGracefulWhenUnauthorized() public {
        vault.setAuthorizedCaller(address(claimBond), false);

        vault.issueBond(user, 1_000);
        uint256 committedBefore = vault.totalCommittedUSD();

        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        uint256 epoch = (2026 + monthsFromBase / 12) * 100 + (1 + monthsFromBase % 12);

        vm.prank(user);
        claimBond.burnByHolder(user, epoch, 400); // must not revert

        // Obligation unchanged (sync skipped), but burn applied.
        assertEq(vault.totalCommittedUSD(), committedBefore, "should not decrement when unauthorized");
        assertEq(claimBond.balanceOf(user, epoch), 600, "burn should still apply");
    }
}
