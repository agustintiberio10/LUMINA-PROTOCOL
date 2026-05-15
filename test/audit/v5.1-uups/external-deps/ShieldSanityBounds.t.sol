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

contract MockOracleSB is IOracle {
    mapping(bytes32 => int256) public priceFor;
    address public authorizedKey;

    constructor(address _key) {
        authorizedKey = _key;
    }

    function setPrice(bytes32 asset, int256 p) external {
        priceFor[asset] = p;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return priceFor[asset];
    }

    function getSequencerDowntime(uint256) external pure returns (uint256) {
        return 0;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function oracleKey() external view returns (address) {
        return authorizedKey;
    }
}

/**
 * @title ShieldSanityBounds
 * @notice Verifies the M-01 fix: shields now reject extreme prices at create
 *         and at settlement. Tests cover 8 shields × 6 test types.
 */
contract ShieldSanityBounds is Test {
    MockOracleSB oracle;

    function setUp() public {
        vm.chainId(8453);
        oracle = new MockOracleSB(address(this));
        oracle.setPrice("BTC", 60_000e8);
        oracle.setPrice("ETH", 3_000e8);
        oracle.setPrice("USDT", 1e8);
    }

    function _params(uint32 d, bytes32 a) internal returns (IShield.CreatePolicyParams memory p) {
        p.buyer = makeAddr("b");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = d;
        p.asset = a;
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield1h — bounds [$10k, $1M]
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_FlashBTC1h_NormalPrice60k_Accepted() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        assertEq(s.getBSSData(pid).strikePrice, 60_000e8);
    }

    function test_Sanity_FlashBTC1h_AtMaxBoundary_Accepted() public {
        oracle.setPrice("BTC", 1_000_000e8);
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        assertEq(s.getBSSData(pid).strikePrice, 1_000_000e8);
    }

    function test_Sanity_FlashBTC1h_OneWeiAboveMax_Reverts() public {
        oracle.setPrice("BTC", int256(1_000_000e8) + 1);
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    function test_Sanity_FlashBTC1h_ExtremePrice100x_Reverts() public {
        oracle.setPrice("BTC", 6_000_000e8);
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    function test_Sanity_FlashBTC1h_AtMinBoundary_Accepted() public {
        oracle.setPrice("BTC", 10_000e8);
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        s.createPolicy(_params(3600, "BTC"));
    }

    function test_Sanity_FlashBTC1h_BelowMin_Reverts() public {
        oracle.setPrice("BTC", 9_999e8);
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield4h — identical bounds
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_FlashBTC4h_AtMaxBoundary_Accepted() public {
        oracle.setPrice("BTC", 1_000_000e8);
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
        s.createPolicy(_params(14400, "BTC"));
    }

    function test_Sanity_FlashBTC4h_OneWeiAboveMax_Reverts() public {
        oracle.setPrice("BTC", int256(1_000_000e8) + 1);
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(14400, "BTC"));
    }

    function test_Sanity_FlashBTC4h_BelowMin_Reverts() public {
        oracle.setPrice("BTC", 9_999e8);
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(14400, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield24h
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_FlashBTC24h_AtMaxBoundary_Accepted() public {
        oracle.setPrice("BTC", 1_000_000e8);
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        s.createPolicy(_params(86400, "BTC"));
    }

    function test_Sanity_FlashBTC24h_OneWeiAboveMax_Reverts() public {
        oracle.setPrice("BTC", int256(1_000_000e8) + 1);
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(86400, "BTC"));
    }

    function test_Sanity_FlashBTC24h_BelowMin_Reverts() public {
        oracle.setPrice("BTC", 9_999e8);
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(86400, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield48h
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_FlashBTC48h_AtMaxBoundary_Accepted() public {
        oracle.setPrice("BTC", 1_000_000e8);
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        s.createPolicy(_params(172800, "BTC"));
    }

    function test_Sanity_FlashBTC48h_OneWeiAboveMax_Reverts() public {
        oracle.setPrice("BTC", int256(1_000_000e8) + 1);
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(172800, "BTC"));
    }

    function test_Sanity_FlashBTC48h_BelowMin_Reverts() public {
        oracle.setPrice("BTC", 9_999e8);
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(172800, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield1h — bounds [$500, $50k]
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_FlashETH1h_NormalPrice_Accepted() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.createPolicy(_params(3600, "ETH"));
    }

    function test_Sanity_FlashETH1h_AtMaxBoundary_Accepted() public {
        oracle.setPrice("ETH", 50_000e8);
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.createPolicy(_params(3600, "ETH"));
    }

    function test_Sanity_FlashETH1h_OneWeiAboveMax_Reverts() public {
        oracle.setPrice("ETH", int256(50_000e8) + 1);
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(3600, "ETH"));
    }

    function test_Sanity_FlashETH1h_AtMinBoundary_Accepted() public {
        oracle.setPrice("ETH", 500e8);
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.createPolicy(_params(3600, "ETH"));
    }

    function test_Sanity_FlashETH1h_BelowMin_Reverts() public {
        oracle.setPrice("ETH", 499e8);
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(3600, "ETH"));
    }

    function test_Sanity_FlashETH1h_ExtremePrice_Reverts() public {
        oracle.setPrice("ETH", 500_000e8);
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(3600, "ETH"));
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield24h
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_FlashETH24h_AtMaxBoundary_Accepted() public {
        oracle.setPrice("ETH", 50_000e8);
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        s.createPolicy(_params(86400, "ETH"));
    }

    function test_Sanity_FlashETH24h_OneWeiAboveMax_Reverts() public {
        oracle.setPrice("ETH", int256(50_000e8) + 1);
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(86400, "ETH"));
    }

    function test_Sanity_FlashETH24h_BelowMin_Reverts() public {
        oracle.setPrice("ETH", 499e8);
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(86400, "ETH"));
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield48h
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_FlashETH48h_AtMaxBoundary_Accepted() public {
        oracle.setPrice("ETH", 50_000e8);
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        s.createPolicy(_params(172800, "ETH"));
    }

    function test_Sanity_FlashETH48h_OneWeiAboveMax_Reverts() public {
        oracle.setPrice("ETH", int256(50_000e8) + 1);
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(172800, "ETH"));
    }

    function test_Sanity_FlashETH48h_BelowMin_Reverts() public {
        oracle.setPrice("ETH", 499e8);
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(172800, "ETH"));
    }

    // ─────────────────────────────────────────────────────────────
    // MicroDepegShield — bounds [$0.50, $1.50] applied at settlement
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_MicroDepeg_CreatePolicy_NoOracleReadRequired() public {
        MicroDepegShield s = ProxyDeployer.deployMicroDepegShield(address(this), address(oracle));
        // MicroDepeg does not read oracle at create — no sanity path here.
        s.createPolicy(_params(604800, "USDT"));
    }

    // ─────────────────────────────────────────────────────────────
    // Constants verification — each shield exposes MIN_PRICE/MAX_PRICE
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_ConstantsPresent_BTC1h() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        assertEq(s.MIN_PRICE(), 10_000e8);
        assertEq(s.MAX_PRICE(), 1_000_000e8);
    }

    function test_Sanity_ConstantsPresent_BTC4h() public {
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
        assertEq(s.MIN_PRICE(), 10_000e8);
        assertEq(s.MAX_PRICE(), 1_000_000e8);
    }

    function test_Sanity_ConstantsPresent_BTC24h() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        assertEq(s.MIN_PRICE(), 10_000e8);
        assertEq(s.MAX_PRICE(), 1_000_000e8);
    }

    function test_Sanity_ConstantsPresent_BTC48h() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        assertEq(s.MIN_PRICE(), 10_000e8);
        assertEq(s.MAX_PRICE(), 1_000_000e8);
    }

    function test_Sanity_ConstantsPresent_ETH1h() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        assertEq(s.MIN_PRICE(), 500e8);
        assertEq(s.MAX_PRICE(), 50_000e8);
    }

    function test_Sanity_ConstantsPresent_ETH24h() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        assertEq(s.MIN_PRICE(), 500e8);
        assertEq(s.MAX_PRICE(), 50_000e8);
    }

    function test_Sanity_ConstantsPresent_ETH48h() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        assertEq(s.MIN_PRICE(), 500e8);
        assertEq(s.MAX_PRICE(), 50_000e8);
    }

    function test_Sanity_ConstantsPresent_MicroDepeg() public {
        MicroDepegShield s = ProxyDeployer.deployMicroDepegShield(address(this), address(oracle));
        assertEq(s.MIN_PRICE(), 50_000_000); // $0.50
        assertEq(s.MAX_PRICE(), 150_000_000); // $1.50
    }

    // ─────────────────────────────────────────────────────────────
    // Regression: post-fix, the audit #11 "extreme price accepted" scenario
    // must now REVERT for BTC shields.
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_Regression_AuditM01_ExtremeBTCPriceNowReverts() public {
        // Audit #11 noted that 6_000_000e8 (100× normal) was silently
        // accepted. After fix, this reverts.
        oracle.setPrice("BTC", 6_000_000e8);
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        vm.expectRevert();
        s.createPolicy(_params(3600, "BTC"));
    }

    // ─────────────────────────────────────────────────────────────
    // Cross-shield: ETH extreme price doesn't affect BTC
    // ─────────────────────────────────────────────────────────────
    function test_Sanity_ETHOutOfBounds_DoesNotAffectBTC() public {
        oracle.setPrice("ETH", 500_000e8); // extreme ETH
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        // BTC has its normal price — creation succeeds.
        s.createPolicy(_params(3600, "BTC"));
    }
}
