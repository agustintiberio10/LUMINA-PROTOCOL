// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaOracleV2} from "../src/oracles/LuminaOracleV2.sol";
import {BTCCatastropheShieldV2} from "../src/products/BTCCatastropheShieldV2.sol";
import {ETHApocalypseShieldV2} from "../src/products/ETHApocalypseShieldV2.sol";
import {IShield} from "../src/interfaces/IShield.sol";

/// @notice Smoke tests for V2 shields proving the EIP-712 proof path is enforced.
/// @dev    We deploy a real LuminaOracleV2 and register a fake Chainlink aggregator
///         via vm.mockCall. The "router" is an EOA we vm.prank from.
contract ShieldsV2EIP712Test is Test {
    LuminaOracleV2 oracle;
    BTCCatastropheShieldV2 bcs;
    ETHApocalypseShieldV2 eas;

    address oracleKeyAddr;
    uint256 oracleKeyPriv;

    address router = address(0xD1);
    address buyer  = address(0xBEEF);

    // Fake Chainlink aggregators (any non-zero address will do — we mock calls to them).
    address btcFeed = address(0xB7C);
    address ethFeed = address(0xE7B);

    // Prices in Chainlink 8-decimal scale.
    int256 constant BTC_STRIKE = 50_000_00000000; // $50,000
    int256 constant ETH_STRIKE = 3_000_00000000;  // $3,000

    // EIP-712 constants (re-declared for manual digest construction)
    bytes32 constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant PRICE_PROOF_TYPEHASH = keccak256(
        "PriceProof(int256 price,bytes32 asset,uint256 verifiedAt)"
    );

    function setUp() public {
        (oracleKeyAddr, oracleKeyPriv) = makeAddrAndKey("oracleKey");

        // Deploy real oracle (no L2 sequencer feed → skip sequencer check).
        oracle = new LuminaOracleV2(address(this), oracleKeyAddr, address(0));

        // Mock latestRoundData() on our fake aggregators so registerFeed succeeds
        // and so _doCreatePolicy can read a sane strike.
        _mockFeed(btcFeed, BTC_STRIKE);
        _mockFeed(ethFeed, ETH_STRIKE);

        oracle.registerFeed(bytes32("BTC"), btcFeed, 3600);
        oracle.registerFeed(bytes32("ETH"), ethFeed, 3600);

        bcs = new BTCCatastropheShieldV2(router, address(oracle));
        eas = new ETHApocalypseShieldV2(router, address(oracle));
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    function _mockFeed(address feed, int256 price) internal {
        // AggregatorV3.latestRoundData: (roundId, answer, startedAt, updatedAt, answeredInRound)
        vm.mockCall(
            feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), price, uint256(block.timestamp), uint256(block.timestamp), uint80(1))
        );
        // Chainlink feeds expose decimals() — LuminaOracleV2 doesn't call it, but be safe.
        vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
    }

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

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultParams(bytes32 asset) internal view returns (IShield.CreatePolicyParams memory) {
        return IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 1000e6,
            premiumAmount: 50e6,
            durationSeconds: 14 days,
            asset: asset,
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });
    }

    /// @dev Builds an oracle proof payload encoded the way the shield expects:
    ///      abi.encode(int256 verifiedPrice, bytes32 asset, uint256 verifiedAt, bytes signature)
    function _buildProof(
        int256 price,
        bytes32 asset,
        uint256 verifiedAt,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, signature);
    }

    // ═══════════════════════════════════════════════════════════
    //  BCS V2
    // ═══════════════════════════════════════════════════════════

    function test_BCSv2_validProof_triggers() public {
        // Create policy via "router"
        vm.prank(router);
        uint256 policyId = bcs.createPolicy(_defaultParams(bytes32("BTC")));
        assertEq(policyId, 1);

        // Warp past the 1h waiting period into the ACTIVE window.
        vm.warp(block.timestamp + 2 hours);

        // Price below trigger (strike/2 - 1) → payout.
        int256 crashPrice = (BTC_STRIKE / 2) - 1;
        uint256 verifiedAt = block.timestamp;

        bytes32 digest = oracle.priceProofDigest(crashPrice, bytes32("BTC"), verifiedAt);
        bytes memory sig = _sign(oracleKeyPriv, digest);
        bytes memory proof = _buildProof(crashPrice, bytes32("BTC"), verifiedAt, sig);

        vm.prank(router);
        IShield.PayoutResult memory result = bcs.verifyAndCalculate(policyId, proof);

        assertTrue(result.triggered, "should trigger");
        assertEq(result.recipient, buyer, "payout recipient should be buyer");
        assertGt(result.payoutAmount, 0, "payout should be > 0");
    }

    function test_BCSv2_proofWithWrongChainId_reverts() public {
        vm.prank(router);
        uint256 policyId = bcs.createPolicy(_defaultParams(bytes32("BTC")));

        vm.warp(block.timestamp + 2 hours);

        int256 crashPrice = (BTC_STRIKE / 2) - 1;
        uint256 verifiedAt = block.timestamp;

        // Build digest against chainId = 1 instead of block.chainid.
        uint256 wrongChainId = 1;
        vm.assume(wrongChainId != block.chainid);
        bytes32 wrongDigest = _priceProofDigest(
            address(oracle), wrongChainId, crashPrice, bytes32("BTC"), verifiedAt
        );
        bytes memory sig = _sign(oracleKeyPriv, wrongDigest);
        bytes memory proof = _buildProof(crashPrice, bytes32("BTC"), verifiedAt, sig);

        vm.prank(router);
        vm.expectRevert(BTCCatastropheShieldV2.InvalidOracleProof.selector);
        bcs.verifyAndCalculate(policyId, proof);
    }

    function test_BCSv2_proofWithWrongOracleAddress_reverts() public {
        vm.prank(router);
        uint256 policyId = bcs.createPolicy(_defaultParams(bytes32("BTC")));

        vm.warp(block.timestamp + 2 hours);

        int256 crashPrice = (BTC_STRIKE / 2) - 1;
        uint256 verifiedAt = block.timestamp;

        // Build digest against a fake verifyingContract (different oracle).
        address fakeOracle = address(0xBAD0);
        bytes32 wrongDigest = _priceProofDigest(
            fakeOracle, block.chainid, crashPrice, bytes32("BTC"), verifiedAt
        );
        bytes memory sig = _sign(oracleKeyPriv, wrongDigest);
        bytes memory proof = _buildProof(crashPrice, bytes32("BTC"), verifiedAt, sig);

        vm.prank(router);
        vm.expectRevert(BTCCatastropheShieldV2.InvalidOracleProof.selector);
        bcs.verifyAndCalculate(policyId, proof);
    }

    // ═══════════════════════════════════════════════════════════
    //  EAS V2
    // ═══════════════════════════════════════════════════════════

    function test_EASv2_validProof_triggers() public {
        vm.prank(router);
        uint256 policyId = eas.createPolicy(_defaultParams(bytes32("ETH")));
        assertEq(policyId, 1);

        vm.warp(block.timestamp + 2 hours);

        // ETH needs -60% drop: trigger = strike * 40 / 100. Go just below it.
        int256 crashPrice = (ETH_STRIKE * 40) / 100 - 1;
        uint256 verifiedAt = block.timestamp;

        bytes32 digest = oracle.priceProofDigest(crashPrice, bytes32("ETH"), verifiedAt);
        bytes memory sig = _sign(oracleKeyPriv, digest);
        bytes memory proof = _buildProof(crashPrice, bytes32("ETH"), verifiedAt, sig);

        vm.prank(router);
        IShield.PayoutResult memory result = eas.verifyAndCalculate(policyId, proof);

        assertTrue(result.triggered, "should trigger");
        assertEq(result.recipient, buyer, "payout recipient should be buyer");
        assertGt(result.payoutAmount, 0, "payout should be > 0");
    }

    function test_EASv2_proofWithWrongChainId_reverts() public {
        vm.prank(router);
        uint256 policyId = eas.createPolicy(_defaultParams(bytes32("ETH")));

        vm.warp(block.timestamp + 2 hours);

        int256 crashPrice = (ETH_STRIKE * 40) / 100 - 1;
        uint256 verifiedAt = block.timestamp;

        uint256 wrongChainId = 1;
        vm.assume(wrongChainId != block.chainid);
        bytes32 wrongDigest = _priceProofDigest(
            address(oracle), wrongChainId, crashPrice, bytes32("ETH"), verifiedAt
        );
        bytes memory sig = _sign(oracleKeyPriv, wrongDigest);
        bytes memory proof = _buildProof(crashPrice, bytes32("ETH"), verifiedAt, sig);

        vm.prank(router);
        // ETHApocalypseShieldV2 re-uses the same InvalidOracleProof error name.
        vm.expectRevert(ETHApocalypseShieldV2.InvalidOracleProof.selector);
        eas.verifyAndCalculate(policyId, proof);
    }
}
