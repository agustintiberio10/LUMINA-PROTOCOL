// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaToken} from "../../src/token/LuminaToken.sol";
import {LuminaMerkleClaim} from "../../src/token/LuminaMerkleClaim.sol";

contract LuminaMerkleClaimTest is Test {
    LuminaToken public token;
    LuminaMerkleClaim public claimContract;

    address treasury = makeAddr("treasury");
    address exitEngine = makeAddr("exitEngine");
    address exchange = makeAddr("exchange");
    address vesting = makeAddr("vesting");

    // Test investors
    address investorA = makeAddr("investorA");
    address investorB = makeAddr("investorB");
    address investorC = makeAddr("investorC");
    address unknown = makeAddr("unknown");

    uint256 amountA = 500_000 * 1e18;
    uint256 amountB = 300_000 * 1e18;
    uint256 amountC = 200_000 * 1e18;
    uint256 totalPool = 1_000_000 * 1e18; // 1M total for the test pool

    bytes32 leafA;
    bytes32 leafB;
    bytes32 leafC;
    bytes32 merkleRoot;

    // Proofs
    bytes32[] proofA;
    bytes32[] proofB;
    bytes32[] proofC;

    function setUp() public {
        token = new LuminaToken(treasury, exitEngine, exchange, vesting);
        claimContract = new LuminaMerkleClaim(address(token));

        // Compute leaves
        leafA = keccak256(abi.encodePacked(investorA, amountA));
        leafB = keccak256(abi.encodePacked(investorB, amountB));
        leafC = keccak256(abi.encodePacked(investorC, amountC));

        // Build tree: 3 leaves → need padding
        // Layer 0: [leafA, leafB, leafC, leafC] (duplicate last for even count)
        // Layer 1: [hash(sort(leafA, leafB)), hash(sort(leafC, leafC))]
        // Layer 2: root = hash(sort(layer1[0], layer1[1]))

        bytes32 node01 = _hashPair(leafA, leafB);
        bytes32 node23 = _hashPair(leafC, leafC);
        merkleRoot = _hashPair(node01, node23);

        // Proof for A: [leafB, node23]
        proofA = new bytes32[](2);
        proofA[0] = leafB;
        proofA[1] = node23;

        // Proof for B: [leafA, node23]
        proofB = new bytes32[](2);
        proofB[0] = leafA;
        proofB[1] = node23;

        // Proof for C: [leafC, node01]
        proofC = new bytes32[](2);
        proofC[0] = leafC;
        proofC[1] = node01;

        // Set merkle root
        claimContract.setMerkleRoot(merkleRoot);

        // Fund the claim contract from treasury
        vm.prank(treasury);
        token.transfer(address(claimContract), totalPool);
    }

    // ═══════ Helper ═══════

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // ═══════ Tests ═══════

    function test_claim_with_valid_proof() public {
        vm.prank(investorA);
        claimContract.claim(amountA, proofA);

        assertEq(token.balanceOf(investorA), amountA);
        assertEq(claimContract.claimed(investorA), amountA);
    }

    function test_claim_with_invalid_proof_reverts() public {
        bytes32[] memory badProof = new bytes32[](2);
        badProof[0] = bytes32(uint256(1));
        badProof[1] = bytes32(uint256(2));

        vm.prank(investorA);
        vm.expectRevert("Invalid proof");
        claimContract.claim(amountA, badProof);
    }

    function test_claim_wrong_amount_reverts() public {
        vm.prank(investorA);
        vm.expectRevert("Invalid proof");
        claimContract.claim(1_000_000 * 1e18, proofA); // wrong amount
    }

    function test_claim_twice_fully_claimed() public {
        vm.prank(investorA);
        claimContract.claim(amountA, proofA);

        vm.prank(investorA);
        vm.expectRevert("Already fully claimed");
        claimContract.claim(amountA, proofA);
    }

    function test_partial_claim_insufficient_balance() public {
        // Use the main claimContract but reduce its balance first
        // Investors B and C claim first to reduce available tokens
        vm.prank(investorB);
        claimContract.claim(amountB, proofB);
        vm.prank(investorC);
        claimContract.claim(amountC, proofC);
        // Now contract has 1M - 300K - 200K = 500K, exactly what A needs

        // Reduce further: transfer some tokens out by having A claim from a new contract
        // Simpler: just test with a fresh contract
        LuminaMerkleClaim claim2 = new LuminaMerkleClaim(address(token));
        claim2.setMerkleRoot(merkleRoot);

        // Fund with only 200K
        vm.prank(treasury);
        token.transfer(address(claim2), 200_000 * 1e18);

        // InvestorA has 500K allocation, only 200K available
        vm.prank(investorA);
        claim2.claim(amountA, proofA);
        assertEq(claim2.claimed(investorA), 200_000 * 1e18);

        // Fund 300K more
        vm.prank(treasury);
        token.transfer(address(claim2), 300_000 * 1e18);

        // Claim remaining
        vm.prank(investorA);
        claim2.claim(amountA, proofA);
        assertEq(claim2.claimed(investorA), 500_000 * 1e18);
    }

    function test_multiple_investors_claim() public {
        vm.prank(investorA);
        claimContract.claim(amountA, proofA);

        vm.prank(investorB);
        claimContract.claim(amountB, proofB);

        vm.prank(investorC);
        claimContract.claim(amountC, proofC);

        assertEq(token.balanceOf(investorA), amountA);
        assertEq(token.balanceOf(investorB), amountB);
        assertEq(token.balanceOf(investorC), amountC);
        assertEq(token.balanceOf(address(claimContract)), 0);
    }

    function test_claimable_view_correct() public {
        // Before claim
        uint256 canClaim = claimContract.claimable(investorA, amountA, proofA);
        assertEq(canClaim, amountA);

        // After partial setup — claim half by reducing available
        LuminaMerkleClaim claim2 = new LuminaMerkleClaim(address(token));
        claim2.setMerkleRoot(merkleRoot);
        vm.prank(treasury);
        token.transfer(address(claim2), 200_000 * 1e18);

        // Claimable should be min(remaining, available)
        uint256 claimable2 = claim2.claimable(investorA, amountA, proofA);
        assertEq(claimable2, 200_000 * 1e18);

        // Invalid proof returns 0
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(0);
        assertEq(claim2.claimable(investorA, amountA, badProof), 0);
    }

    function test_set_merkle_root_only_owner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert();
        claimContract.setMerkleRoot(bytes32(uint256(123)));

        // Owner can set
        bytes32 newRoot = bytes32(uint256(456));
        claimContract.setMerkleRoot(newRoot);
        assertEq(claimContract.merkleRoot(), newRoot);
    }

    function test_available_tokens_view() public {
        assertEq(claimContract.availableTokens(), totalPool);

        // After claim
        vm.prank(investorA);
        claimContract.claim(amountA, proofA);
        assertEq(claimContract.availableTokens(), totalPool - amountA);
    }

    function test_claim_after_multiple_tranches() public {
        // Fresh claim contract with tranche simulation
        LuminaMerkleClaim trancheClaim = new LuminaMerkleClaim(address(token));
        trancheClaim.setMerkleRoot(merkleRoot);

        // 3 tranches of totalPool
        uint256 tranche1 = totalPool / 3;
        uint256 tranche2 = totalPool / 3;
        uint256 tranche3 = totalPool - tranche1 - tranche2;

        // Tranche 1
        vm.prank(treasury);
        token.transfer(address(trancheClaim), tranche1);

        // Investors claim in order — each gets what's available
        _tryClaim(trancheClaim, investorA, amountA, proofA);
        _tryClaim(trancheClaim, investorB, amountB, proofB);
        _tryClaim(trancheClaim, investorC, amountC, proofC);

        // Tranche 2
        vm.prank(treasury);
        token.transfer(address(trancheClaim), tranche2);
        _tryClaim(trancheClaim, investorA, amountA, proofA);
        _tryClaim(trancheClaim, investorB, amountB, proofB);
        _tryClaim(trancheClaim, investorC, amountC, proofC);

        // Tranche 3
        vm.prank(treasury);
        token.transfer(address(trancheClaim), tranche3);
        _tryClaim(trancheClaim, investorA, amountA, proofA);
        _tryClaim(trancheClaim, investorB, amountB, proofB);
        _tryClaim(trancheClaim, investorC, amountC, proofC);

        // Verify everyone got their full allocation
        assertEq(trancheClaim.claimed(investorA), amountA);
        assertEq(trancheClaim.claimed(investorB), amountB);
        assertEq(trancheClaim.claimed(investorC), amountC);
        assertEq(trancheClaim.availableTokens(), 0);
    }

    function _tryClaim(LuminaMerkleClaim c, address investor, uint256 amount, bytes32[] memory proof) internal {
        uint256 claimable = c.claimable(investor, amount, proof);
        if (claimable > 0) {
            vm.prank(investor);
            c.claim(amount, proof);
        }
    }

    function test_no_withdraw_exists() public {
        // Verify no withdraw/rescue selectors exist
        bytes4 withdrawSel = bytes4(keccak256("withdraw()"));
        bytes4 rescueSel = bytes4(keccak256("rescue(address,uint256)"));
        bytes4 emergencySel = bytes4(keccak256("emergencyWithdraw()"));
        bytes4 recoverSel = bytes4(keccak256("recoverTokens(address,uint256)"));

        (bool s1,) = address(claimContract).staticcall(abi.encodeWithSelector(withdrawSel));
        (bool s2,) = address(claimContract).staticcall(abi.encodeWithSelector(rescueSel, address(token), 1));
        (bool s3,) = address(claimContract).staticcall(abi.encodeWithSelector(emergencySel));
        (bool s4,) = address(claimContract).staticcall(abi.encodeWithSelector(recoverSel, address(token), 1));

        assertFalse(s1);
        assertFalse(s2);
        assertFalse(s3);
        assertFalse(s4);
    }

    function test_unknown_address_cannot_claim() public {
        vm.prank(unknown);
        vm.expectRevert("Invalid proof");
        claimContract.claim(100 * 1e18, proofA);
    }
}
