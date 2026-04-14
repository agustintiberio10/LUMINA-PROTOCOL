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

    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public other = makeAddr("other");

    uint256 public constant SHARES = 100e18;

    function setUp() public {
        nft = new VaultShareNFT();
        vault = new MockVault();

        // Give LP1 and LP2 vault shares
        vault.mint(lp1, 500e18);
        vault.mint(lp2, 300e18);
    }

    function test_wrap() public {
        vm.prank(lp1);
        uint256 tokenId = nft.wrap(address(vault), SHARES);

        assertEq(nft.ownerOf(tokenId), lp1);
        assertEq(tokenId, 0);

        (address v, uint256 shares, address depositor, uint256 ts) = nft.getPositionData(tokenId);
        assertEq(v, address(vault));
        assertEq(shares, SHARES);
        assertEq(depositor, lp1);
        assertEq(ts, block.timestamp);
    }

    function test_wrap_insufficient_shares_reverts() public {
        vm.prank(other); // other has 0 shares
        vm.expectRevert(abi.encodeWithSelector(VaultShareNFT.InsufficientShareBalance.selector, SHARES, 0));
        nft.wrap(address(vault), SHARES);
    }

    function test_wrap_zero_shares_reverts() public {
        vm.prank(lp1);
        vm.expectRevert(VaultShareNFT.ZeroShares.selector);
        nft.wrap(address(vault), 0);
    }

    function test_wrap_zero_address_reverts() public {
        vm.prank(lp1);
        vm.expectRevert(VaultShareNFT.ZeroAddress.selector);
        nft.wrap(address(0), SHARES);
    }

    function test_unwrap() public {
        vm.prank(lp1);
        uint256 tokenId = nft.wrap(address(vault), SHARES);

        vm.prank(lp1);
        nft.unwrap(tokenId);

        vm.expectRevert(); // ownerOf reverts for burned token
        nft.ownerOf(tokenId);
    }

    function test_unwrap_not_holder_reverts() public {
        vm.prank(lp1);
        uint256 tokenId = nft.wrap(address(vault), SHARES);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(VaultShareNFT.NotTokenOwner.selector, tokenId, other));
        nft.unwrap(tokenId);
    }

    function test_get_value() public {
        vm.prank(lp1);
        uint256 tokenId = nft.wrap(address(vault), SHARES);

        // 100e18 shares * 1e6 / 1e18 = 100e6 USDC value
        uint256 value = nft.getValue(tokenId);
        assertEq(value, 100e6);

        // Increase price per share to 1.5 USDC
        vault.setPricePerShare(1.5e6);
        value = nft.getValue(tokenId);
        assertEq(value, 150e6);
    }

    function test_transfer_nft() public {
        vm.prank(lp1);
        uint256 tokenId = nft.wrap(address(vault), SHARES);

        vm.prank(lp1);
        nft.transferFrom(lp1, other, tokenId);

        assertEq(nft.ownerOf(tokenId), other);
    }

    function test_multiple_wraps() public {
        vm.prank(lp1);
        uint256 tokenId0 = nft.wrap(address(vault), 200e18);

        vm.prank(lp2);
        uint256 tokenId1 = nft.wrap(address(vault), 150e18);

        assertEq(tokenId0, 0);
        assertEq(tokenId1, 1);
        assertEq(nft.ownerOf(tokenId0), lp1);
        assertEq(nft.ownerOf(tokenId1), lp2);
    }

    function test_token_uri() public {
        vm.prank(lp1);
        uint256 tokenId = nft.wrap(address(vault), SHARES);

        string memory uri = nft.tokenURI(tokenId);
        assertTrue(bytes(uri).length > 0);
        // Should start with data:application/json;base64,
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i]);
        }
    }

    function test_get_position_data_nonexistent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(VaultShareNFT.TokenDoesNotExist.selector, 999));
        nft.getPositionData(999);
    }
}
