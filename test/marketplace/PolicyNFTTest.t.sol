// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PolicyNFT} from "../../src/marketplace/PolicyNFT.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {IShield} from "../../src/interfaces/IShield.sol";

// ═══════════════════════════════════════════════════════════
//  MOCKS
// ═══════════════════════════════════════════════════════════

contract MockShield {
    mapping(uint256 => IShield.PolicyInfo) public policies;

    function setPolicy(uint256 policyId, address insuredAgent, IShield.PolicyStatus status) external {
        policies[policyId] = IShield.PolicyInfo({
            policyId: policyId,
            insuredAgent: insuredAgent,
            coverageAmount: 1000e6,
            premiumPaid: 50e6,
            maxPayout: 1000e6,
            startTimestamp: block.timestamp,
            waitingEndsAt: block.timestamp + 1 hours,
            expiresAt: block.timestamp + 30 days,
            cleanupAt: block.timestamp + 30 days,
            status: status
        });
    }

    function getPolicyInfo(uint256 policyId) external view returns (IShield.PolicyInfo memory) {
        return policies[policyId];
    }
}

contract MockPolicyManager {
    mapping(bytes32 => IPolicyManager.ProductRegistration) public products;

    function setProduct(bytes32 productId, address shield) external {
        bytes32[] memory groups = new bytes32[](0);
        products[productId] = IPolicyManager.ProductRegistration({
            productId: productId,
            shield: shield,
            riskType: "VOLATILE",
            maxAllocationBps: 2000,
            correlationGroups: groups,
            active: true
        });
    }

    function getProduct(bytes32 productId) external view returns (IPolicyManager.ProductRegistration memory) {
        return products[productId];
    }
}

// ═══════════════════════════════════════════════════════════
//  TEST
// ═══════════════════════════════════════════════════════════

contract PolicyNFTTest is Test {
    PolicyNFT public nft;
    MockPolicyManager public pm;
    MockShield public shield;

    address public buyer = makeAddr("buyer");
    address public other = makeAddr("other");

    bytes32 public constant PRODUCT_ID = keccak256("BSS_ETH");
    uint256 public constant POLICY_ID = 1;

    function setUp() public {
        pm = new MockPolicyManager();
        shield = new MockShield();
        nft = new PolicyNFT(address(pm));

        pm.setProduct(PRODUCT_ID, address(shield));
        shield.setPolicy(POLICY_ID, buyer, IShield.PolicyStatus.ACTIVE);
    }

    function test_wrap_active_policy() public {
        vm.prank(buyer);
        uint256 tokenId = nft.wrap(PRODUCT_ID, POLICY_ID);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(tokenId, 0);
        assertTrue(nft.isWrapped(PRODUCT_ID, POLICY_ID));
    }

    function test_wrap_not_buyer_reverts() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.NotPolicyBuyer.selector, other, buyer));
        nft.wrap(PRODUCT_ID, POLICY_ID);
    }

    function test_wrap_already_wrapped_reverts() public {
        vm.prank(buyer);
        nft.wrap(PRODUCT_ID, POLICY_ID);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.AlreadyWrapped.selector, PRODUCT_ID, POLICY_ID));
        nft.wrap(PRODUCT_ID, POLICY_ID);
    }

    function test_wrap_expired_policy_reverts() public {
        shield.setPolicy(POLICY_ID, buyer, IShield.PolicyStatus.EXPIRED);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.PolicyNotActive.selector, PRODUCT_ID, POLICY_ID));
        nft.wrap(PRODUCT_ID, POLICY_ID);
    }

    function test_wrap_waiting_policy_succeeds() public {
        shield.setPolicy(POLICY_ID, buyer, IShield.PolicyStatus.WAITING);

        vm.prank(buyer);
        uint256 tokenId = nft.wrap(PRODUCT_ID, POLICY_ID);
        assertEq(nft.ownerOf(tokenId), buyer);
    }

    function test_unwrap() public {
        vm.prank(buyer);
        uint256 tokenId = nft.wrap(PRODUCT_ID, POLICY_ID);

        vm.prank(buyer);
        nft.unwrap(tokenId);

        assertFalse(nft.isWrapped(PRODUCT_ID, POLICY_ID));
        vm.expectRevert(); // ownerOf reverts for nonexistent token
        nft.ownerOf(tokenId);
    }

    function test_unwrap_not_holder_reverts() public {
        vm.prank(buyer);
        uint256 tokenId = nft.wrap(PRODUCT_ID, POLICY_ID);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.NotTokenHolder.selector, other, tokenId));
        nft.unwrap(tokenId);
    }

    function test_transfer_nft() public {
        vm.prank(buyer);
        uint256 tokenId = nft.wrap(PRODUCT_ID, POLICY_ID);

        vm.prank(buyer);
        nft.transferFrom(buyer, other, tokenId);

        assertEq(nft.ownerOf(tokenId), other);
    }

    function test_get_policy_data() public {
        vm.prank(buyer);
        uint256 tokenId = nft.wrap(PRODUCT_ID, POLICY_ID);

        (bytes32 productId, uint256 policyId, address originalBuyer) = nft.getPolicyData(tokenId);
        assertEq(productId, PRODUCT_ID);
        assertEq(policyId, POLICY_ID);
        assertEq(originalBuyer, buyer);
    }

    function test_token_uri() public {
        vm.prank(buyer);
        uint256 tokenId = nft.wrap(PRODUCT_ID, POLICY_ID);

        string memory uri = nft.tokenURI(tokenId);
        assertTrue(bytes(uri).length > 0);
        // Should start with data:application/json;base64,
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i]);
        }
    }

    function test_constructor_zero_address_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyNFT.ZeroAddress.selector, "policyManager"));
        new PolicyNFT(address(0));
    }
}
