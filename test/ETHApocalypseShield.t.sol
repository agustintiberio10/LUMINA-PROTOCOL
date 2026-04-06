// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ETHApocalypseShield} from "../src/products/ETHApocalypseShield.sol";
import {IShield} from "../src/interfaces/IShield.sol";

/// @notice Mock oracle that returns a configurable price per asset
contract MockOracleEAS {
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

contract ETHApocalypseShieldTest is Test {
    ETHApocalypseShield shield;
    MockOracleEAS oracle;

    address router = address(0xD);
    address oracleKey = address(0xAA);
    address buyer = address(0xBEEF);

    function setUp() public {
        oracle = new MockOracleEAS(oracleKey);
        oracle.setPrice("ETH", 3_000_00000000);  // $3,000 in 8 decimals
        oracle.setPrice("BTC", 50_000_00000000); // $50,000 in 8 decimals

        shield = new ETHApocalypseShield(router, address(oracle));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: productId
    // ═══════════════════════════════════════════════════════════

    function test_EAS_productId() public {
        assertEq(shield.productId(), keccak256("ETHAPOC-001"));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: triggerDropBps constant == 6000
    // ═══════════════════════════════════════════════════════════

    function test_EAS_triggerDropBps() public {
        assertEq(shield.TRIGGER_DROP_BPS(), 6000);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: maxAllocationBps constant == 2500
    // ═══════════════════════════════════════════════════════════

    function test_EAS_maxAllocationBps() public {
        assertEq(shield.MAX_ALLOCATION_BPS(), 2500);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: only ETH — reverts on BTC
    // ═══════════════════════════════════════════════════════════

    function test_EAS_onlyETH_reverts_BTC() public {
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
        vm.expectRevert(abi.encodeWithSelector(ETHApocalypseShield.InvalidAsset.selector, bytes32("BTC")));
        shield.createPolicy(params);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: only ETH — accepts ETH
    // ═══════════════════════════════════════════════════════════

    function test_EAS_onlyETH_accepts_ETH() public {
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
        uint256 policyId = shield.createPolicy(params);
        assertEq(policyId, 1);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: trigger price is 40% of strike (60% drop)
    // ═══════════════════════════════════════════════════════════

    function test_EAS_triggerPrice_60percent() public {
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
        uint256 policyId = shield.createPolicy(params);

        ETHApocalypseShield.BSSData memory data = shield.getBSSData(policyId);
        int256 expectedStrike = 3_000_00000000; // $3,000
        int256 expectedTrigger = (expectedStrike * 40) / 100; // $1,200

        assertEq(data.strikePrice, expectedStrike);
        assertEq(data.triggerPrice, expectedTrigger);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: payout is 80% of coverage (20% deductible)
    // ═══════════════════════════════════════════════════════════

    function test_EAS_payout_80percent() public {
        uint256 coverageAmount = 10_000e6; // $10,000

        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: coverageAmount,
            premiumAmount: 500e6,
            durationSeconds: 14 days,
            asset: "ETH",
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
