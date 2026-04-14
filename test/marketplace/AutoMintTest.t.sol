// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StableShortVault} from "../../src/vaults/StableShortVault.sol";
import {CoverRouter} from "../../src/core/CoverRouter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockAavePool} from "../../src/mocks/MockAavePool.sol";

/**
 * @title AutoMintTest
 * @notice Tests for NFT auto-mint storage variables and setters on BaseVault and CoverRouter.
 *         Verifies FIX 10: vaultShareNFT / policyNFT storage + owner-only setters.
 */
contract AutoMintTest is Test {
    StableShortVault vault;
    CoverRouter router;

    address owner = address(0xA);
    address nonOwner = address(0xB);
    address nftAddr = makeAddr("nftContract");

    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave Base USDC", "aBasUSDC", 6);
        aavePool = new MockAavePool(address(aToken));

        // Deploy BaseVault (via StableShortVault) behind proxy
        StableShortVault vaultImpl = new StableShortVault();
        bytes memory vaultInit = abi.encodeCall(
            StableShortVault.initialize,
            (owner, address(usdc), address(0xC), address(0xD), address(aavePool), address(aToken))
        );
        vault = StableShortVault(address(new ERC1967Proxy(address(vaultImpl), vaultInit)));

        // Deploy CoverRouter behind proxy
        CoverRouter routerImpl = new CoverRouter();
        bytes memory routerInit = abi.encodeCall(
            CoverRouter.initialize,
            (owner, address(0x1), address(0x2), address(0x3), address(usdc), true, address(0x4), 100)
        );
        router = CoverRouter(address(new ERC1967Proxy(address(routerImpl), routerInit)));
    }

    // ═══════════════════════════════════════════
    // TEST 1: BaseVault has vaultShareNFT storage
    // ═══════════════════════════════════════════

    function test_vault_has_nft_storage() public {
        // vaultShareNFT should default to address(0)
        assertEq(vault.vaultShareNFT(), address(0));
    }

    // ═══════════════════════════════════════════
    // TEST 2: CoverRouter has policyNFT storage
    // ═══════════════════════════════════════════

    function test_router_has_nft_storage() public {
        // policyNFT should default to address(0)
        assertEq(router.policyNFT(), address(0));
    }

    // ═══════════════════════════════════════════
    // TEST 3: Owner can call setVaultShareNFT
    // ═══════════════════════════════════════════

    function test_set_vault_share_nft() public {
        vm.prank(owner);
        vault.setVaultShareNFT(nftAddr);
        assertEq(vault.vaultShareNFT(), nftAddr);
    }

    // ═══════════════════════════════════════════
    // TEST 4: Owner can call setPolicyNFT
    // ═══════════════════════════════════════════

    function test_set_policy_nft() public {
        vm.prank(owner);
        router.setPolicyNFT(nftAddr);
        assertEq(router.policyNFT(), nftAddr);
    }

    // ═══════════════════════════════════════════
    // TEST 5: Non-owner cannot set NFT addresses
    // ═══════════════════════════════════════════

    function test_non_owner_cannot_set() public {
        vm.startPrank(nonOwner);

        vm.expectRevert();
        vault.setVaultShareNFT(nftAddr);

        vm.expectRevert();
        router.setPolicyNFT(nftAddr);

        vm.stopPrank();
    }
}
