// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/LuminaTokenV2.sol";

contract LuminaTokenV2Test is Test {
    LuminaTokenV2 token;
    address bondVault = makeAddr("bondVault");
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");
    address deployer;

    function setUp() public {
        deployer = address(this);
        token = new LuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);
    }

    function test_totalSupply() public view {
        assertEq(token.totalSupply(), 100_000_000 * 1e18);
    }

    function test_distribution() public view {
        assertEq(token.balanceOf(bondVault), 70_000_000 * 1e18);
        assertEq(token.balanceOf(cexReserve), 14_000_000 * 1e18);
        assertEq(token.balanceOf(founderVesting), 8_000_000 * 1e18);
        assertEq(token.balanceOf(lbpDeposit), 5_000_000 * 1e18);
        assertEq(token.balanceOf(treasuryVesting), 3_000_000 * 1e18);
    }

    function test_noMint() public view {
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function test_totalBurned_initially_zero() public view {
        assertEq(token.totalBurned(), 0);
    }

    function test_burn_reduces_supply() public {
        vm.prank(lbpDeposit);
        token.burn(1000 * 1e18);
        assertEq(token.totalBurned(), 1000 * 1e18);
        assertEq(token.totalSupply(), 100_000_000 * 1e18 - 1000 * 1e18);
    }

    function test_burnerRole_can_burnFrom() public {
        token.grantRole(token.BURNER_ROLE(), deployer);
        vm.prank(lbpDeposit);
        token.approve(deployer, 500 * 1e18);
        token.burnFrom(lbpDeposit, 500 * 1e18);
        assertEq(token.totalBurned(), 500 * 1e18);
    }

    function test_nonBurner_cannot_burnFrom() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert();
        token.burnFrom(lbpDeposit, 100 * 1e18);
    }

    function test_zeroAddress_reverts() public {
        vm.expectRevert("BondVault zero address");
        new LuminaTokenV2(address(0), cexReserve, founderVesting, lbpDeposit, treasuryVesting);

        vm.expectRevert("CEXReserve zero address");
        new LuminaTokenV2(bondVault, address(0), founderVesting, lbpDeposit, treasuryVesting);
    }

    function test_duplicateRecipient_reverts() public {
        vm.expectRevert("Duplicate: bondVault/treasury");
        new LuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, bondVault);

        vm.expectRevert("Duplicate: bondVault/cexReserve");
        new LuminaTokenV2(bondVault, bondVault, founderVesting, lbpDeposit, treasuryVesting);

        vm.expectRevert("Duplicate: cexReserve/founder");
        new LuminaTokenV2(bondVault, cexReserve, cexReserve, lbpDeposit, treasuryVesting);
    }

    function test_name_and_symbol() public view {
        assertEq(token.name(), "Lumina Protocol");
        assertEq(token.symbol(), "LUMINA");
    }
}
