// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BTCCatastropheShield} from "../src/products/BTCCatastropheShield.sol";
import {IShield} from "../src/interfaces/IShield.sol";

/// @notice Mock oracle that returns a configurable price per asset
contract MockOracleBCS {
    address public oracleKey;
    mapping(bytes32 => int256) public prices;

    constructor(address _key) {
        oracleKey = _key;
    }

    function setPrice(bytes32 asset, int256 price) external {
        prices[asset] = price;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return prices[asset];
    }

    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return oracleKey;
    }

    function getSequencerDowntime(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract BTCCatastropheShieldTest is Test {
    BTCCatastropheShield shield;
    MockOracleBCS oracle;

    address router = address(0xD);
    address oracleKey = address(0xAA);
    address buyer = address(0xBEEF);

    function setUp() public {
        oracle = new MockOracleBCS(oracleKey);
        oracle.setPrice("BTC", 50_000_00000000); // $50,000 in 8 decimals
        oracle.setPrice("ETH", 3_000_00000000);  // $3,000 in 8 decimals

        shield = new BTCCatastropheShield(router, address(oracle));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: productId
    // ═══════════════════════════════════════════════════════════

    function test_BCS_productId() public {
        assertEq(shield.productId(), keccak256("BTCCAT-001"));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: triggerDropBps constant == 5000
    // ═══════════════════════════════════════════════════════════

    function test_BCS_triggerDropBps() public {
        assertEq(shield.TRIGGER_DROP_BPS(), 5000);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: maxAllocationBps constant == 3000
    // ═══════════════════════════════════════════════════════════

    function test_BCS_maxAllocationBps() public {
        assertEq(shield.MAX_ALLOCATION_BPS(), 3000);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: only BTC — reverts on ETH
    // ═══════════════════════════════════════════════════════════

    function test_BCS_onlyBTC_reverts_ETH() public {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 1000e6,
            premiumAmount: 50e6,
            durationSeconds: 14 days,
            asset: "ETH",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(BTCCatastropheShield.InvalidAsset.selector, bytes32("ETH")));
        shield.createPolicy(params);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: only BTC — accepts BTC
    // ═══════════════════════════════════════════════════════════

    function test_BCS_onlyBTC_accepts_BTC() public {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 1000e6,
            premiumAmount: 50e6,
            durationSeconds: 14 days,
            asset: "BTC",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });

        vm.prank(router);
        uint256 policyId = shield.createPolicy(params);
        assertEq(policyId, 1);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: trigger price is 50% of strike
    // ═══════════════════════════════════════════════════════════

    function test_BCS_triggerPrice_50percent() public {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 1000e6,
            premiumAmount: 50e6,
            durationSeconds: 14 days,
            asset: "BTC",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });

        vm.prank(router);
        uint256 policyId = shield.createPolicy(params);

        BTCCatastropheShield.BSSData memory data = shield.getBSSData(policyId);
        int256 expectedStrike = 50_000_00000000; // $50,000
        int256 expectedTrigger = (expectedStrike * 50) / 100; // $25,000

        assertEq(data.strikePrice, expectedStrike);
        assertEq(data.triggerPrice, expectedTrigger);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: payout is 80% of coverage (20% deductible)
    // ═══════════════════════════════════════════════════════════

    function test_BCS_payout_80percent() public {
        uint256 coverageAmount = 10_000e6; // $10,000

        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: coverageAmount,
            premiumAmount: 500e6,
            durationSeconds: 14 days,
            asset: "BTC",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });

        vm.prank(router);
        uint256 policyId = shield.createPolicy(params);

        IShield.PolicyInfo memory info = shield.getPolicyInfo(policyId);
        // maxPayout should be 80% of coverage
        uint256 expectedPayout = (coverageAmount * 8000) / 10_000;
        assertEq(info.maxPayout, expectedPayout);
    }
}
