// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultShareNFT} from "../../src/marketplace/VaultShareNFT.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ═══════════════════════════════════════════════════════════
//  MOCK VAULT (ERC20 + convertToAssets)
// ═══════════════════════════════════════════════════════════

contract MockVault is ERC20 {
    uint256 public pricePerShare; // assets per 1e18 shares

    constructor() ERC20("Mock Vault", "mVLT") {
        pricePerShare = 1e6; // 1 share = 1 USDC initially
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPricePerShare(uint256 price) external {
        pricePerShare = price;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * pricePerShare / 1e18;
    }
}

// ═══════════════════════════════════════════════════════════
//  TEST
// ═══════════════════════════════════════════════════════════

contract VaultShareNFTTest is Test {
    VaultShareNFT public nft;
    MockVault public vault;

    address public admin = address(this);
    address public minterAddr = makeAddr("minterAddr");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public other = makeAddr("other");

    uint256 public constant SHARES = 100e18;

    function setUp() public {
        nft = new VaultShareNFT();
        vault = new MockVault();

        // Authorize minter
        nft.setMinter(minterAddr, true);
    }

    function test_mint() public {
        vm.prank(minterAddr);
        uint256 tokenId = nft.mint(lp1, address(vault), SHARES);

        assertEq(nft.ownerOf(tokenId), lp1);
        assertEq(tokenId, 0);

        VaultShareNFT.Position memory pos = nft.getPosition(tokenId);
        assertEq(pos.vault, address(vault));
        assertEq(pos.shares, SHARES);
        assertEq(pos.depositedAt, block.timestamp);
    }

    function test_mint_not_minter_reverts() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(VaultShareNFT.NotMinter.selector, other));
        nft.mint(lp1, address(vault), SHARES);
    }

    function test_burn_by_holder() public {
        vm.prank(minterAddr);
        uint256 tokenId = nft.mint(lp1, address(vault), SHARES);

        vm.prank(lp1);
        nft.burn(tokenId);

        vm.expectRevert(); // ownerOf reverts for burned token
        nft.ownerOf(tokenId);
    }

    function test_burn_by_minter() public {
        vm.prank(minterAddr);
        uint256 tokenId = nft.mint(lp1, address(vault), SHARES);

        vm.prank(minterAddr);
        nft.burn(tokenId);

        vm.expectRevert();
        nft.ownerOf(tokenId);
    }

    function test_burn_not_holder_or_minter_reverts() public {
        vm.prank(minterAddr);
        uint256 tokenId = nft.mint(lp1, address(vault), SHARES);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(VaultShareNFT.NotHolderOrMinter.selector, other, tokenId));
        nft.burn(tokenId);
    }

    function test_get_value() public {
        vm.prank(minterAddr);
        uint256 tokenId = nft.mint(lp1, address(vault), SHARES);

        // 100e18 shares * 1e6 / 1e18 = 100e6 USDC value
        uint256 value = nft.getValue(tokenId);
        assertEq(value, 100e6);

        // Increase price per share to 1.5 USDC
        vault.setPricePerShare(1.5e6);
        value = nft.getValue(tokenId);
        assertEq(value, 150e6);
    }

    function test_transfer_nft() public {
        vm.prank(minterAddr);
        uint256 tokenId = nft.mint(lp1, address(vault), SHARES);

        vm.prank(lp1);
        nft.transferFrom(lp1, other, tokenId);

        assertEq(nft.ownerOf(tokenId), other);
    }

    function test_multiple_mints() public {
        vm.prank(minterAddr);
        uint256 tokenId0 = nft.mint(lp1, address(vault), 200e18);

        vm.prank(minterAddr);
        uint256 tokenId1 = nft.mint(lp2, address(vault), 150e18);

        assertEq(tokenId0, 0);
        assertEq(tokenId1, 1);
        assertEq(nft.ownerOf(tokenId0), lp1);
        assertEq(nft.ownerOf(tokenId1), lp2);
    }

    function test_token_uri() public {
        vm.prank(minterAddr);
        uint256 tokenId = nft.mint(lp1, address(vault), SHARES);

        string memory uri = nft.tokenURI(tokenId);
        assertTrue(bytes(uri).length > 0);
        // Should start with data:application/json;base64,
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i]);
        }
    }

    function test_get_position_nonexistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(VaultShareNFT.TokenDoesNotExist.selector, 999));
        nft.getPosition(999);
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
}
