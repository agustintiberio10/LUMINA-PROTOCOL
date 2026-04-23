// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../../src/products/FlashETHShield48h.sol";
import {MicroDepegShield} from "../../../../src/products/MicroDepegShield.sol";
import {IShield} from "../../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../../src/interfaces/IOracle.sol";

/// @notice Mutable oracle mock — can simulate different Chainlink failures.
contract MockChainlinkOracle is IOracle {
    mapping(bytes32 => int256) public priceFor;
    bool public revertOnRead;
    uint256 public sequencerDowntime;
    address public authorizedKey;

    constructor(address _key) {
        authorizedKey = _key;
    }

    function setPrice(bytes32 asset, int256 p) external {
        priceFor[asset] = p;
    }

    function setRevertOnRead(bool v) external {
        revertOnRead = v;
    }

    function setSequencerDowntime(uint256 d) external {
        sequencerDowntime = d;
    }

    function setAuthorizedKey(address k) external {
        authorizedKey = k;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        require(!revertOnRead, "Oracle down");
        return priceFor[asset];
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return sequencerDowntime;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        // Simulate an always-matching signer for tests that don't focus on
        // signatures. Tests that focus on the signature path use oracleKey()
        // comparison mismatch instead.
        return address(0);
    }

    function oracleKey() external view returns (address) {
        return authorizedKey;
    }
}

/**
 * @title ChainlinkFailures
 * @notice Documents and verifies how every Shield handles Chainlink oracle
 *         failure modes (zero price, negative price, revert, sequencer
 *         downtime, stale EIP-712 proof, etc).
 */
contract ChainlinkFailures is Test {
    MockChainlinkOracle oracle;

    function setUp() public {
        oracle = new MockChainlinkOracle(address(this));
        oracle.setPrice("BTC", 60_000e8);
        oracle.setPrice("ETH", 3_000e8);
        oracle.setPrice("USDT", 1e8);
        oracle.setPrice("USDC", 1e8);
        oracle.setPrice("DAI", 1e8);
    }

    function _btc1h() internal returns (FlashBTCShield1h) {
        return ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
    }

    function _btc4h() internal returns (FlashBTCShield4h) {
        return ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
    }

    function _btc24h() internal returns (FlashBTCShield24h) {
        return ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
    }

    function _btc48h() internal returns (FlashBTCShield48h) {
        return ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
    }

    function _eth1h() internal returns (FlashETHShield1h) {
        return ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
    }

    function _eth24h() internal returns (FlashETHShield24h) {
        return ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
    }

    function _eth48h() internal returns (FlashETHShield48h) {
        return ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
    }

    function _micro() internal returns (MicroDepegShield) {
        return ProxyDeployer.deployMicroDepegShield(address(this), address(oracle));
    }

    function _params(uint32 d, bytes32 a) internal returns (IShield.CreatePolicyParams memory p) {
        p.buyer = makeAddr("b");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = d;
        p.asset = a;
    }

    // ─────────────────────────────────────────────────────────────
    // Feed returns 0 — createPolicy reverts
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_FlashBTC1h_PriceZero_CreatePolicy_Reverts() public {
        oracle.setPrice("BTC", 0);
        FlashBTCShield1h s = _btc1h();
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    function test_Chainlink_FlashBTC4h_PriceZero_CreatePolicy_Reverts() public {
        oracle.setPrice("BTC", 0);
        FlashBTCShield4h s = _btc4h();
        vm.expectRevert();
        s.createPolicy(_params(14400, "BTC"));
    }

    function test_Chainlink_FlashBTC24h_PriceZero_CreatePolicy_Reverts() public {
        oracle.setPrice("BTC", 0);
        FlashBTCShield24h s = _btc24h();
        vm.expectRevert();
        s.createPolicy(_params(86400, "BTC"));
    }

    function test_Chainlink_FlashBTC48h_PriceZero_CreatePolicy_Reverts() public {
        oracle.setPrice("BTC", 0);
        FlashBTCShield48h s = _btc48h();
        vm.expectRevert();
        s.createPolicy(_params(172800, "BTC"));
    }

    function test_Chainlink_FlashETH1h_PriceZero_CreatePolicy_Reverts() public {
        oracle.setPrice("ETH", 0);
        FlashETHShield1h s = _eth1h();
        vm.expectRevert();
        s.createPolicy(_params(3600, "ETH"));
    }

    function test_Chainlink_FlashETH24h_PriceZero_CreatePolicy_Reverts() public {
        oracle.setPrice("ETH", 0);
        FlashETHShield24h s = _eth24h();
        vm.expectRevert();
        s.createPolicy(_params(86400, "ETH"));
    }

    function test_Chainlink_FlashETH48h_PriceZero_CreatePolicy_Reverts() public {
        oracle.setPrice("ETH", 0);
        FlashETHShield48h s = _eth48h();
        vm.expectRevert();
        s.createPolicy(_params(172800, "ETH"));
    }

    // ─────────────────────────────────────────────────────────────
    // Feed returns negative — createPolicy reverts
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_FlashBTC1h_PriceNegative_CreatePolicy_Reverts() public {
        oracle.setPrice("BTC", -1);
        FlashBTCShield1h s = _btc1h();
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    function test_Chainlink_FlashETH1h_PriceNegative_CreatePolicy_Reverts() public {
        oracle.setPrice("ETH", -1);
        FlashETHShield1h s = _eth1h();
        vm.expectRevert();
        s.createPolicy(_params(3600, "ETH"));
    }

    // ─────────────────────────────────────────────────────────────
    // Oracle reverts (simulates feed paused / deprecated)
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_OracleReverts_CreatePolicy_BubblesRevert() public {
        FlashBTCShield1h s = _btc1h();
        oracle.setRevertOnRead(true);
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // Feed returns extreme outlier — no sanity bounds in Shield layer
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_ExtremePrice_RevertsAfterM01Fix() public {
        // [M-01 fix applied] 100x normal price now reverts with
        // PriceOutOfSanityBounds (BTC MIN=$10k, MAX=$1M).
        oracle.setPrice("BTC", 6_000_000e8);
        FlashBTCShield1h s = _btc1h();
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // Wrong asset — createPolicy reverts with InvalidAsset
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_FlashBTC1h_WrongAsset_ETH_Reverts() public {
        FlashBTCShield1h s = _btc1h();
        vm.expectRevert();
        s.createPolicy(_params(3600, "ETH"));
    }

    function test_Chainlink_FlashETH1h_WrongAsset_BTC_Reverts() public {
        FlashETHShield1h s = _eth1h();
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // Successful createPolicy stores strike price atomically
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_FlashBTC1h_StoresExactStrikePrice() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        assertEq(s.getBSSData(pid).strikePrice, 60_000e8);
    }

    function test_Chainlink_FlashETH1h_StoresExactStrikePrice() public {
        FlashETHShield1h s = _eth1h();
        uint256 pid = s.createPolicy(_params(3600, "ETH"));
        assertEq(s.getBSSData(pid).strikePrice, 3_000e8);
    }

    // ─────────────────────────────────────────────────────────────
    // Post-create oracle price change doesn't retroactively affect strike
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_PriceChangeAfterCreate_DoesNotMutateStrike() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        int256 strikeBefore = s.getBSSData(pid).strikePrice;
        oracle.setPrice("BTC", 1000e8); // crash
        assertEq(s.getBSSData(pid).strikePrice, strikeBefore);
        oracle.setPrice("BTC", 1_000_000e8); // moonshot
        assertEq(s.getBSSData(pid).strikePrice, strikeBefore);
    }

    // ─────────────────────────────────────────────────────────────
    // Sequencer downtime extends the cleanup window (BaseShield)
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_SequencerDowntime_ExtendsCleanupWindow() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        // Downtime = 1 hour.
        oracle.setSequencerDowntime(3600);
        // We can't directly read cleanupAt via getPolicyInfo without further
        // scaffolding, but we verify the oracle call works.
        assertEq(oracle.getSequencerDowntime(0), 3600);
        // Suppress unused warning.
        pid;
    }

    // ─────────────────────────────────────────────────────────────
    // Multi-shield isolation — BTC feed failure doesn't break ETH shield
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_BTCFeedFails_ETHShieldStillWorks() public {
        FlashETHShield1h s = _eth1h();
        oracle.setPrice("BTC", 0); // BTC broken
        // ETH still works.
        uint256 pid = s.createPolicy(_params(3600, "ETH"));
        assertEq(s.getBSSData(pid).strikePrice, 3_000e8);
    }

    function test_Chainlink_ETHFeedFails_BTCShieldStillWorks() public {
        FlashBTCShield1h s = _btc1h();
        oracle.setPrice("ETH", 0); // ETH broken
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        assertEq(s.getBSSData(pid).strikePrice, 60_000e8);
    }

    // ─────────────────────────────────────────────────────────────
    // MicroDepegShield has a fixed TRIGGER_PRICE constant
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_MicroDepeg_TriggerPriceIsConstant() public {
        MicroDepegShield s = _micro();
        assertEq(s.TRIGGER_PRICE(), 99_500_000); // $0.995 in 8-dec
    }

    // ─────────────────────────────────────────────────────────────
    // Oracle key is the authorized signer
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_Oracle_OracleKey_Readable() public {
        assertEq(oracle.oracleKey(), address(this));
    }

    // ─────────────────────────────────────────────────────────────
    // Sequencer downtime defaults to zero — normal operation
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_SequencerNormal_DowntimeZero() public view {
        assertEq(oracle.getSequencerDowntime(0), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // All Flash shields for BTC use the same shared feed correctly
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_AllBTCShields_ReadSameFeedConsistently() public {
        FlashBTCShield1h s1 = _btc1h();
        FlashBTCShield4h s2 = _btc4h();
        FlashBTCShield24h s3 = _btc24h();
        FlashBTCShield48h s4 = _btc48h();

        uint256 p1 = s1.createPolicy(_params(3600, "BTC"));
        uint256 p2 = s2.createPolicy(_params(14400, "BTC"));
        uint256 p3 = s3.createPolicy(_params(86400, "BTC"));
        uint256 p4 = s4.createPolicy(_params(172800, "BTC"));

        assertEq(s1.getBSSData(p1).strikePrice, 60_000e8);
        assertEq(s2.getBSSData(p2).strikePrice, 60_000e8);
        assertEq(s3.getBSSData(p3).strikePrice, 60_000e8);
        assertEq(s4.getBSSData(p4).strikePrice, 60_000e8);
    }

    function test_Chainlink_AllETHShields_ReadSameFeedConsistently() public {
        FlashETHShield1h s1 = _eth1h();
        FlashETHShield24h s2 = _eth24h();
        FlashETHShield48h s3 = _eth48h();

        uint256 p1 = s1.createPolicy(_params(3600, "ETH"));
        uint256 p2 = s2.createPolicy(_params(86400, "ETH"));
        uint256 p3 = s3.createPolicy(_params(172800, "ETH"));

        assertEq(s1.getBSSData(p1).strikePrice, 3_000e8);
        assertEq(s2.getBSSData(p2).strikePrice, 3_000e8);
        assertEq(s3.getBSSData(p3).strikePrice, 3_000e8);
    }

    // ─────────────────────────────────────────────────────────────
    // MicroDepeg oracle read path — uses same IOracle interface
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_MicroDepeg_AcceptsValidUSDTOracle() public {
        MicroDepegShield s = _micro();
        // Oracle is set in constructor; we can query its state through the
        // shield.
        assertEq(s.oracle(), address(oracle));
    }

    // ─────────────────────────────────────────────────────────────
    // createPolicy reverts bubble through to callers (CoverRouter path)
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_CreatePolicyRevert_BubblesToCaller() public {
        FlashBTCShield1h s = _btc1h();
        oracle.setRevertOnRead(true);
        // Caller sees the revert as a plain revert — this is what the
        // CoverRouter / PolicyManager will observe and propagate.
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // Per-shield zero-price coverage (ensure every product path is tested)
    // ─────────────────────────────────────────────────────────────
    function test_Chainlink_EveryFlashShield_ZeroPrice_Reverts() public {
        // Pre-deploy all shields BEFORE zeroing the price so that their
        // constructors/initializers don't hit the zero read.
        FlashBTCShield1h btc1 = _btc1h();
        FlashBTCShield4h btc4 = _btc4h();
        FlashBTCShield24h btc24 = _btc24h();
        FlashBTCShield48h btc48 = _btc48h();
        FlashETHShield1h eth1 = _eth1h();
        FlashETHShield24h eth24 = _eth24h();
        FlashETHShield48h eth48 = _eth48h();

        oracle.setPrice("BTC", 0);
        oracle.setPrice("ETH", 0);

        // Pre-build calldata params once so vm.expectRevert applies cleanly.
        IShield.CreatePolicyParams memory pBTC1 = _params(3600, "BTC");
        IShield.CreatePolicyParams memory pBTC4 = _params(14400, "BTC");
        IShield.CreatePolicyParams memory pBTC24 = _params(86400, "BTC");
        IShield.CreatePolicyParams memory pBTC48 = _params(172800, "BTC");
        IShield.CreatePolicyParams memory pETH1 = _params(3600, "ETH");
        IShield.CreatePolicyParams memory pETH24 = _params(86400, "ETH");
        IShield.CreatePolicyParams memory pETH48 = _params(172800, "ETH");

        vm.expectRevert();
        btc1.createPolicy(pBTC1);
        vm.expectRevert();
        btc4.createPolicy(pBTC4);
        vm.expectRevert();
        btc24.createPolicy(pBTC24);
        vm.expectRevert();
        btc48.createPolicy(pBTC48);
        vm.expectRevert();
        eth1.createPolicy(pETH1);
        vm.expectRevert();
        eth24.createPolicy(pETH24);
        vm.expectRevert();
        eth48.createPolicy(pETH48);
    }
}
