// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PolicyNFT} from "../../src/marketplace/PolicyNFT.sol";

// ═══════════════════════════════════════════════════════════
//  TEST
// ═══════════════════════════════════════════════════════════

contract PolicyNFTTest is Test {
    PolicyNFT public nft;

    address public admin = address(this);
    address public minter = makeAddr("minter");
    address public buyer = makeAddr("buyer");
    address public other = makeAddr("other");

    uint256 public constant POLICY_ID = 42;

    function setUp() public {
        nft = new PolicyNFT();
        nft.setMinter(minter, true);
    }

    function test_mint() public {
        vm.prank(minter);
        nft.mint(buyer, POLICY_ID);

        assertEq(nft.ownerOf(POLICY_ID), buyer);
    }

    function test_mint_not_minter_reverts() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.NotMinter.selector, other));
        nft.mint(buyer, POLICY_ID);
    }

    function test_burn_by_holder() public {
        vm.prank(minter);
        nft.mint(buyer, POLICY_ID);

        vm.prank(buyer);
        nft.burn(POLICY_ID);

        assertFalse(nft.isValid(POLICY_ID));
    }

    function test_burn_by_minter() public {
        vm.prank(minter);
        nft.mint(buyer, POLICY_ID);

        vm.prank(minter);
        nft.burn(POLICY_ID);

        assertFalse(nft.isValid(POLICY_ID));
    }

    function test_burn_not_holder_or_minter_reverts() public {
        vm.prank(minter);
        nft.mint(buyer, POLICY_ID);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.NotHolderOrMinter.selector, other, POLICY_ID));
        nft.burn(POLICY_ID);
    }

    function test_isValid() public {
        assertFalse(nft.isValid(POLICY_ID));

        vm.prank(minter);
        nft.mint(buyer, POLICY_ID);

        assertTrue(nft.isValid(POLICY_ID));
    }

    function test_transfer_nft() public {
        vm.prank(minter);
        nft.mint(buyer, POLICY_ID);

        vm.prank(buyer);
        nft.transferFrom(buyer, other, POLICY_ID);

        assertEq(nft.ownerOf(POLICY_ID), other);
    }

    function test_setMinter() public {
        address newMinter = makeAddr("newMinter");
        nft.setMinter(newMinter, true);
        assertTrue(nft.minters(newMinter));

        nft.setMinter(newMinter, false);
        assertFalse(nft.minters(newMinter));
    }

    function test_setMinter_not_owner_reverts() public {
        vm.prank(other);
        vm.expectRevert();
        nft.setMinter(other, true);
    }

    function test_token_uri() public {
        vm.prank(minter);
        nft.mint(buyer, POLICY_ID);

        string memory uri = nft.tokenURI(POLICY_ID);
        assertTrue(bytes(uri).length > 0);
        // Should start with data:application/json;base64,
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i]);
        }
    }
}
