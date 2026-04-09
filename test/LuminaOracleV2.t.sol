// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaOracleV2} from "../src/oracles/LuminaOracleV2.sol";

/// @notice Unit tests for LuminaOracleV2 — EIP-712 domain-separated proof verification.
/// @dev    We exercise ONLY signature verification here. No Chainlink feed is
///         registered; tests that touch the signature surface never call
///         getLatestPrice() and therefore never need a mock aggregator.
contract LuminaOracleV2Test is Test {
    LuminaOracleV2 oracle;

    address oracleKeyAddr;
    uint256 oracleKeyPriv;

    // Test asset id
    bytes32 constant BTC_ASSET = bytes32("BTC");

    // EIP-712 typehashes (mirrors the contract constants — re-derived for safety)
    bytes32 constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant PRICE_PROOF_TYPEHASH = keccak256(
        "PriceProof(int256 price,bytes32 asset,uint256 verifiedAt)"
    );
    bytes32 constant EXPLOIT_GOV_PROOF_TYPEHASH = keccak256(
        "ExploitGovProof(int256 govTokenPrice,int256 govTokenPrice24hAgo,bytes32 protocolId,uint256 verifiedAt)"
    );
    bytes32 constant EXPLOIT_RECEIPT_PROOF_TYPEHASH = keccak256(
        "ExploitReceiptProof(bool receiptTokenDepegged,bool contractPaused,bytes32 protocolId,uint256 verifiedAt)"
    );

    function setUp() public {
        (oracleKeyAddr, oracleKeyPriv) = makeAddrAndKey("oracleKey");
        // Deploy oracle with address(this) as owner, oracleKey as signer,
        // address(0) as sequencer feed (skip the L2 sequencer check).
        oracle = new LuminaOracleV2(address(this), oracleKeyAddr, address(0));
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS — manual EIP-712 digest construction
    // ═══════════════════════════════════════════════════════════

    function _domainSeparator(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("LuminaOracle")),
                keccak256(bytes("2")),
                chainId,
                verifyingContract
            )
        );
    }

    function _priceProofDigest(
        address verifyingContract,
        uint256 chainId,
        int256 price,
        bytes32 asset,
        uint256 verifiedAt
    ) internal pure returns (bytes32) {
        bytes32 ds = _domainSeparator(verifyingContract, chainId);
        bytes32 structHash = keccak256(abi.encode(PRICE_PROOF_TYPEHASH, price, asset, verifiedAt));
        return keccak256(abi.encodePacked("\x19\x01", ds, structHash));
    }

    function _exploitGovProofDigest(
        address verifyingContract,
        uint256 chainId,
        int256 govTokenPrice,
        int256 govTokenPrice24hAgo,
        bytes32 protocolId,
        uint256 verifiedAt
    ) internal pure returns (bytes32) {
        bytes32 ds = _domainSeparator(verifyingContract, chainId);
        bytes32 structHash = keccak256(
            abi.encode(
                EXPLOIT_GOV_PROOF_TYPEHASH,
                govTokenPrice,
                govTokenPrice24hAgo,
                protocolId,
                verifiedAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", ds, structHash));
    }

    function _exploitReceiptProofDigest(
        address verifyingContract,
        uint256 chainId,
        bool receiptTokenDepegged,
        bool contractPaused,
        bytes32 protocolId,
        uint256 verifiedAt
    ) internal pure returns (bytes32) {
        bytes32 ds = _domainSeparator(verifyingContract, chainId);
        bytes32 structHash = keccak256(
            abi.encode(
                EXPLOIT_RECEIPT_PROOF_TYPEHASH,
                receiptTokenDepegged,
                contractPaused,
                protocolId,
                verifiedAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", ds, structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ═══════════════════════════════════════════════════════════
    //  PRICE PROOF TESTS
    // ═══════════════════════════════════════════════════════════

    function test_verifyPriceProofEIP712_valid() public {
        int256 price = 50_000_00000000;
        uint256 verifiedAt = block.timestamp;

        bytes32 digest = oracle.priceProofDigest(price, BTC_ASSET, verifiedAt);
        bytes memory sig = _sign(oracleKeyPriv, digest);

        address signer = oracle.verifyPriceProofEIP712(price, BTC_ASSET, verifiedAt, sig);
        assertEq(signer, oracleKeyAddr, "signer should match oracleKey");
    }

    function test_verifyPriceProofEIP712_wrongChainId_fails() public {
        int256 price = 50_000_00000000;
        uint256 verifiedAt = block.timestamp;

        // Sign against chainId = 1 (not block.chainid — typically 31337 in Forge)
        uint256 wrongChainId = 1;
        vm.assume(wrongChainId != block.chainid);
        bytes32 wrongDigest = _priceProofDigest(address(oracle), wrongChainId, price, BTC_ASSET, verifiedAt);
        bytes memory sig = _sign(oracleKeyPriv, wrongDigest);

        // Verifying against the real (chainid-pinned) digest — should fail.
        address signer = oracle.verifyPriceProofEIP712(price, BTC_ASSET, verifiedAt, sig);
        assertEq(signer, address(0), "mismatched chainId must not recover oracleKey");
    }

    function test_verifyPriceProofEIP712_wrongVerifyingContract_fails() public {
        int256 price = 50_000_00000000;
        uint256 verifiedAt = block.timestamp;

        address fakeOracle = address(0xDEAD);
        bytes32 wrongDigest = _priceProofDigest(fakeOracle, block.chainid, price, BTC_ASSET, verifiedAt);
        bytes memory sig = _sign(oracleKeyPriv, wrongDigest);

        address signer = oracle.verifyPriceProofEIP712(price, BTC_ASSET, verifiedAt, sig);
        assertEq(signer, address(0), "mismatched verifyingContract must not recover oracleKey");
    }

    function test_verifyPriceProofEIP712_wrongSigner_fails() public {
        int256 price = 50_000_00000000;
        uint256 verifiedAt = block.timestamp;

        (, uint256 attackerPriv) = makeAddrAndKey("attacker");
        bytes32 digest = oracle.priceProofDigest(price, BTC_ASSET, verifiedAt);
        bytes memory sig = _sign(attackerPriv, digest);

        address signer = oracle.verifyPriceProofEIP712(price, BTC_ASSET, verifiedAt, sig);
        assertEq(signer, address(0), "non-authorized signer must return address(0)");
    }

    function test_verifyPriceProofEIP712_modifiedPrice_fails() public {
        int256 signedPrice = 100;
        int256 submittedPrice = 101;
        uint256 verifiedAt = block.timestamp;

        bytes32 digest = oracle.priceProofDigest(signedPrice, BTC_ASSET, verifiedAt);
        bytes memory sig = _sign(oracleKeyPriv, digest);

        // Submit with mutated price.
        address signer = oracle.verifyPriceProofEIP712(submittedPrice, BTC_ASSET, verifiedAt, sig);
        assertTrue(signer != oracleKeyAddr, "tampered price must not validate");
    }

    function test_priceProofDigest_matchesManualConstruction() public {
        int256 price = 42_000_00000000;
        uint256 verifiedAt = 1_700_000_000;

        bytes32 onChain = oracle.priceProofDigest(price, BTC_ASSET, verifiedAt);
        bytes32 manual = _priceProofDigest(address(oracle), block.chainid, price, BTC_ASSET, verifiedAt);

        assertEq(onChain, manual, "on-chain digest must match manual EIP-712 construction");
    }

    // ═══════════════════════════════════════════════════════════
    //  EXPLOIT GOV PROOF TESTS
    // ═══════════════════════════════════════════════════════════

    function test_verifyExploitGovProofEIP712_valid() public {
        int256 govNow = 1_00000000;            // $1 with 8 decimals
        int256 gov24h = 3_00000000;            // $3 with 8 decimals
        bytes32 protocolId = bytes32("AAVE");
        uint256 verifiedAt = block.timestamp;

        bytes32 digest = _exploitGovProofDigest(
            address(oracle), block.chainid, govNow, gov24h, protocolId, verifiedAt
        );
        bytes memory sig = _sign(oracleKeyPriv, digest);

        address signer = oracle.verifyExploitGovProofEIP712(
            govNow, gov24h, protocolId, verifiedAt, sig
        );
        assertEq(signer, oracleKeyAddr, "signer should match oracleKey");
    }

    function test_exploitReceiptProofDigest_view() public {
        bool depegged = true;
        bool paused = false;
        bytes32 protocolId = bytes32("AAVE");
        uint256 verifiedAt = 1_700_000_000;

        bytes32 onChain = oracle.exploitReceiptProofDigest(depegged, paused, protocolId, verifiedAt);
        bytes32 manual = _exploitReceiptProofDigest(
            address(oracle), block.chainid, depegged, paused, protocolId, verifiedAt
        );

        assertEq(onChain, manual, "exploit-receipt digest must match manual EIP-712 construction");
    }

    // ═══════════════════════════════════════════════════════════
    //  V1 BACKWARD COMPAT
    // ═══════════════════════════════════════════════════════════

    function test_v1_verifySignature_stillWorks() public {
        bytes32 rawDigest = keccak256("arbitrary v1 payload");
        bytes memory sig = _sign(oracleKeyPriv, rawDigest);

        address recovered = oracle.verifySignature(rawDigest, sig);
        assertEq(recovered, oracleKeyAddr, "V1 verifySignature must still recover oracleKey");
    }

    // ═══════════════════════════════════════════════════════════
    //  DOMAIN SEPARATOR PINNING
    // ═══════════════════════════════════════════════════════════

    function test_DOMAIN_SEPARATOR_pinnedToContract() public {
        // Deploy a second oracle at a different address and compare.
        LuminaOracleV2 oracle2 = new LuminaOracleV2(address(this), oracleKeyAddr, address(0));
        assertTrue(address(oracle) != address(oracle2), "deployment addresses must differ");
        assertTrue(
            oracle.DOMAIN_SEPARATOR() != oracle2.DOMAIN_SEPARATOR(),
            "DOMAIN_SEPARATOR must differ between two oracle deployments"
        );
    }
}
