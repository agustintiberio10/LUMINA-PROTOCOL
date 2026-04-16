// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {InstantLiquidity} from "../../src/marketplace/InstantLiquidity.sol";
import {LuminaToken} from "../../src/token/LuminaToken.sol";
import {LuminaPriceOracle} from "../../src/token/LuminaPriceOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// ═══════════════════════════════════════════════════════════
//  MOCK VaultShareNFT (implements the IVaultShareNFT interface)
// ═══════════════════════════════════════════════════════════

contract ILMockVaultShareNFT is ERC721 {
    uint256 public nextId;

    struct Position {
        address vault;
        uint256 shares;
        uint256 depositedAt;
    }

    mapping(uint256 => Position) public positions;
    mapping(uint256 => uint256) public valueOverride;

    constructor() ERC721("Mock VaultShare NFT", "mvsNFT") {}

    function mintTo(address to, address vault, uint256 valueUsd6dec) external returns (uint256 id) {
        id = nextId++;
        positions[id] = Position(vault, valueUsd6dec, block.timestamp > 301 ? block.timestamp - 301 : 0);
        valueOverride[id] = valueUsd6dec;
        _mint(to, id);
    }

    function getValue(uint256 tokenId) external view returns (uint256) {
        return valueOverride[tokenId];
    }

    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return positions[tokenId];
    }
}

// ═══════════════════════════════════════════════════════════
//  MOCK PolicyNFT (implements the IPolicyNFT interface)
// ═══════════════════════════════════════════════════════════

contract ILMockPolicyNFT is ERC721 {
    uint256 public nextId;

    constructor() ERC721("Mock Policy NFT", "mpNFT") {}

    function mintTo(address to) external returns (uint256 id) {
        id = nextId++;
        _mint(to, id);
    }

    function isValid(uint256 tokenId) external view returns (bool) {
        try this.ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  TEST
// ═══════════════════════════════════════════════════════════

contract InstantLiquidityTest is Test {
    InstantLiquidity public il;
    LuminaToken public lumina;
    LuminaPriceOracle public oracle;
    ILMockVaultShareNFT public vaultNFT;
    ILMockPolicyNFT public policyNFT;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public exitReserve = makeAddr("exitReserve");
    address public exchangeReserve = makeAddr("exchangeReserve");
    address public vestingReserve = makeAddr("vestingReserve");

    address public seller = makeAddr("seller");
    address public mockVaultAddr = makeAddr("mockVault");

    // Oracle price: $0.04 per LUMINA = 40000 (6 decimals)
    uint256 public constant LUMINA_PRICE = 40000;

    function setUp() public {
        // Deploy tokens and oracle
        vm.startPrank(admin);
        lumina = new LuminaToken(treasury, exitReserve, exchangeReserve, vestingReserve);
        oracle = new LuminaPriceOracle(LUMINA_PRICE);
        vm.stopPrank();

        // Deploy mock NFTs
        vaultNFT = new ILMockVaultShareNFT();
        policyNFT = new ILMockPolicyNFT();

        // Deploy InstantLiquidity
        vm.prank(admin);
        il = new InstantLiquidity(address(lumina), address(oracle), address(vaultNFT), address(policyNFT));

        // Fund InstantLiquidity with LUMINA (from treasury)
        vm.prank(treasury);
        lumina.transfer(address(il), 1_000_000e18);

        // Admin setup: budget, discount, enable buying
        vm.startPrank(admin);
        il.setDailyBudget(100_000e6); // $100k daily budget
        il.setVaultDiscount(mockVaultAddr, 3000); // 30% discount
        il.setBuyingVaults(true);
        il.refreshPriceTimestamp();
        vm.stopPrank();

        // Warp past MIN_SELL_AGE so minted NFTs are old enough to sell
        vm.warp(block.timestamp + 301);
    }

    // ──────────────── Admin tests ────────────────

    function test_set_vault_discount() public {
        address newVault = makeAddr("newVault");
        vm.prank(admin);
        il.setVaultDiscount(newVault, 3000);
        assertEq(il.vaultDiscountBps(newVault), 3000);
    }

    function test_max_discount_reverts() public {
        vm.prank(admin);
        vm.expectRevert("Discount exceeds max");
        il.setVaultDiscount(mockVaultAddr, 5001); // > 50%
    }

    function test_set_daily_budget() public {
        vm.prank(admin);
        il.setDailyBudget(200_000e6);
        assertEq(il.dailyBudgetUsd6dec(), 200_000e6);
    }

    // ──────────────── Quote tests ────────────────

    function test_get_quote_vault() public {
        // Mint a vault NFT worth $1000
        uint256 tokenId = vaultNFT.mintTo(seller, mockVaultAddr, 1000e6);

        (uint256 luminaAmount, uint256 usdValue, uint256 discountBps) = il.getQuoteVault(tokenId);

        assertEq(discountBps, 3000); // 30%
        // usdValue = 1000e6 * (10000 - 3000) / 10000 = 700e6
        assertEq(usdValue, 700e6);
        // luminaAmount = 700e6 * 1e18 / 40000 = 700e6 * 1e18 / 4e4 = 17500e18
        assertEq(luminaAmount, 17_500e18);
    }

    // ──────────────── Sell vault NFT ────────────────

    function test_sell_vault_nft() public {
        uint256 tokenId = vaultNFT.mintTo(seller, mockVaultAddr, 1000e6);

        vm.prank(seller);
        vaultNFT.approve(address(il), tokenId);

        uint256 sellerBalBefore = lumina.balanceOf(seller);

        vm.prank(seller);
        il.sellVaultNFT(tokenId);

        // Seller should get 17500 LUMINA
        uint256 expectedLumina = 17_500e18;
        assertEq(lumina.balanceOf(seller), sellerBalBefore + expectedLumina);

        // NFT should now belong to IL contract
        assertEq(vaultNFT.ownerOf(tokenId), address(il));
    }

    // ──────────────── Daily budget tests ────────────────

    function test_daily_budget() public {
        // Sell a $1000 NFT -> $700 after discount is tracked
        uint256 tokenId = vaultNFT.mintTo(seller, mockVaultAddr, 1000e6);

        vm.prank(seller);
        vaultNFT.approve(address(il), tokenId);

        vm.prank(seller);
        il.sellVaultNFT(tokenId);

        assertEq(il.dailySpentUsd6dec(), 700e6);
    }

    function test_daily_limit_reverts() public {
        // Set small budget: $500
        vm.prank(admin);
        il.setDailyBudget(500e6);

        // Try to sell a $1000 NFT -> $700 after discount > $500 budget
        uint256 tokenId = vaultNFT.mintTo(seller, mockVaultAddr, 1000e6);

        vm.prank(seller);
        vaultNFT.approve(address(il), tokenId);

        vm.prank(seller);
        vm.expectRevert("Daily budget exceeded");
        il.sellVaultNFT(tokenId);
    }

    function test_daily_reset() public {
        // Sell one NFT worth $700 discounted
        uint256 tokenId1 = vaultNFT.mintTo(seller, mockVaultAddr, 1000e6);
        vm.prank(seller);
        vaultNFT.approve(address(il), tokenId1);
        vm.prank(seller);
        il.sellVaultNFT(tokenId1);

        assertEq(il.dailySpentUsd6dec(), 700e6);

        // Advance 1 day
        vm.warp(block.timestamp + 1 days);

        // Refresh oracle price timestamp after warp
        vm.prank(admin);
        il.refreshPriceTimestamp();

        // Sell another NFT - daily should have reset
        uint256 tokenId2 = vaultNFT.mintTo(seller, mockVaultAddr, 500e6);
        vm.prank(seller);
        vaultNFT.approve(address(il), tokenId2);
        vm.prank(seller);
        il.sellVaultNFT(tokenId2);

        // After reset, only the new sale's discounted amount
        // 500e6 * 7000 / 10000 = 350e6
        assertEq(il.dailySpentUsd6dec(), 350e6);
    }

    // ──────────────── Buying disabled tests ────────────────

    function test_not_buying_reverts() public {
        vm.prank(admin);
        il.setBuyingVaults(false);

        uint256 tokenId = vaultNFT.mintTo(seller, mockVaultAddr, 1000e6);
        vm.prank(seller);
        vaultNFT.approve(address(il), tokenId);

        vm.prank(seller);
        vm.expectRevert("Vault buying disabled");
        il.sellVaultNFT(tokenId);
    }

    // ──────────────── Pause tests ────────────────

    function test_pause() public {
        vm.prank(admin);
        il.pause();

        uint256 tokenId = vaultNFT.mintTo(seller, mockVaultAddr, 1000e6);
        vm.prank(seller);
        vaultNFT.approve(address(il), tokenId);

        vm.prank(seller);
        vm.expectRevert(); // EnforcedPause
        il.sellVaultNFT(tokenId);
    }

    function test_pause_unpause() public {
        vm.prank(admin);
        il.pause();

        vm.prank(admin);
        il.unpause();

        // Should work after unpause
        uint256 tokenId = vaultNFT.mintTo(seller, mockVaultAddr, 1000e6);
        vm.prank(seller);
        vaultNFT.approve(address(il), tokenId);

        vm.prank(seller);
        il.sellVaultNFT(tokenId);
        assertEq(vaultNFT.ownerOf(tokenId), address(il));
    }
}
