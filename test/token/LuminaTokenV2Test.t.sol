// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/v2/token/LuminaTokenV2.sol";

contract LuminaTokenV2Test is Test {
    LuminaTokenV2 token;
    address bondVault = makeAddr("bondVault");
    address lbpDeposit = makeAddr("lbpDeposit");
    address founderVesting = makeAddr("founderVesting");
    address treasuryVesting = makeAddr("treasuryVesting");
    address deployer;

    function setUp() public {
        deployer = address(this);
        token = new LuminaTokenV2(bondVault, lbpDeposit, founderVesting, treasuryVesting);
    }

    function test_totalSupply() public view {
        assertEq(token.totalSupply(), 100_000_000 * 1e18);
    }

    function test_distribution() public view {
        assertEq(token.balanceOf(bondVault), 82_000_000 * 1e18);
        assertEq(token.balanceOf(lbpDeposit), 5_000_000 * 1e18);
        assertEq(token.balanceOf(founderVesting), 10_000_000 * 1e18);
        assertEq(token.balanceOf(treasuryVesting), 3_000_000 * 1e18);
    }

    function test_noMint() public view {
        // There is no mint function — verified by the absence of any public/external mint
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function test_totalBurned_initially_zero() public view {
        assertEq(token.totalBurned(), 0);
    }

    function test_burn_reduces_supply() public {
        // LBP deposit burns some tokens
        vm.prank(lbpDeposit);
        token.burn(1000 * 1e18);
        assertEq(token.totalBurned(), 1000 * 1e18);
        assertEq(token.totalSupply(), 100_000_000 * 1e18 - 1000 * 1e18);
    }

    function test_burnerRole_can_burnFrom() public {
        token.grantRole(token.BURNER_ROLE(), deployer);
        // First approve (for standard burnFrom) or use role-based
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
        vm.expectRevert("Zero bondVault");
        new LuminaTokenV2(address(0), lbpDeposit, founderVesting, treasuryVesting);
    }

    /// @notice [LBL-H1] Duplicate recipient addresses must revert (distribution-collapse guard).
    function test_duplicateRecipient_reverts() public {
        // bondVault == treasury would silently merge 82M+3M into one address
        vm.expectRevert("Duplicate: bondVault/treasury");
        new LuminaTokenV2(bondVault, lbpDeposit, founderVesting, bondVault);

        vm.expectRevert("Duplicate: lbp/founder");
        new LuminaTokenV2(bondVault, lbpDeposit, lbpDeposit, treasuryVesting);

        vm.expectRevert("Duplicate: bondVault/lbp");
        new LuminaTokenV2(bondVault, bondVault, founderVesting, treasuryVesting);
    }

    function test_name_and_symbol() public view {
        assertEq(token.name(), "Lumina Protocol");
        assertEq(token.symbol(), "LUMINA");
    }
}
