// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {USDCConverter} from "../src/libraries/USDCConverter.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";

/// @dev Mock oracle that returns a configurable price
contract MockPriceOracle {
    int256 private _price;
    bool private _shouldRevert;

    function setPrice(int256 price_) external { _price = price_; }
    function setShouldRevert(bool v) external { _shouldRevert = v; }

    function getLatestPrice(bytes32) external view returns (int256) {
        if (_shouldRevert) revert("Oracle down");
        return _price;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function oracleKey() external pure returns (address) {
        return address(0);
    }
}

/// @dev Wrapper to call library functions (libraries with internal functions need a wrapper)
contract ConverterHarness {
    function strictConvert(uint256 usdAmount, IOracle oracle, bytes32 asset) external view returns (uint256) {
        return USDCConverter.usdToUSDCStrict(usdAmount, oracle, asset);
    }

    function safeConvert(uint256 usdAmount, IOracle oracle, bytes32 asset) external view returns (uint256 amount, bool fallback_) {
        return USDCConverter.usdToUSDCSafe(usdAmount, oracle, asset);
    }

    function strictReverse(uint256 usdcAmount, IOracle oracle, bytes32 asset) external view returns (uint256) {
        return USDCConverter.usdcToUSDStrict(usdcAmount, oracle, asset);
    }
}

contract USDCConverterTest is Test {
    MockPriceOracle oracle;
    ConverterHarness converter;
    bytes32 constant USDC_ASSET = "USDC";

    function setUp() public {
        oracle = new MockPriceOracle();
        converter = new ConverterHarness();
        // Default: $1.00 = 100_000_000 (8 decimals)
        oracle.setPrice(100_000_000);
    }

    // ═══════════════════════════════════════════════════════════
    //  STRICT MODE — Successful conversion
    // ═══════════════════════════════════════════════════════════

    function test_StrictConvert_1to1() public {
        // $1000 USD (6 decimals) at $1.00 USDC → 1000 USDC
        uint256 result = converter.strictConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
        assertEq(result, 1000e6);
    }

    function test_StrictConvert_AtSlightDepeg() public {
        // USDC at $0.99 → need slightly more USDC to cover $1000
        oracle.setPrice(99_000_000); // $0.99
        uint256 result = converter.strictConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
        assertGt(result, 1000e6); // More USDC needed
    }

    // ═══════════════════════════════════════════════════════════
    //  STRICT MODE — Reverts
    // ═══════════════════════════════════════════════════════════

    function test_StrictConvert_RevertsOnZeroPrice() public {
        oracle.setPrice(0);
        vm.expectRevert("Negative oracle price");
        converter.strictConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
    }

    function test_StrictConvert_RevertsOnNegativePrice() public {
        oracle.setPrice(-1);
        vm.expectRevert("Negative oracle price");
        converter.strictConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
    }

    function test_StrictConvert_RevertsOnPriceTooLow() public {
        oracle.setPrice(90_000_000); // $0.90 — below $0.95 min
        vm.expectRevert();
        converter.strictConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
    }

    function test_StrictConvert_RevertsOnPriceTooHigh() public {
        oracle.setPrice(200_000_000); // $2.00 — above $1.50 max
        vm.expectRevert();
        converter.strictConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
    }

    function test_StrictConvert_RevertsOnZeroAmount() public {
        vm.expectRevert();
        converter.strictConvert(0, IOracle(address(oracle)), USDC_ASSET);
    }

    function test_StrictConvert_RevertsOnNoFeed() public {
        vm.expectRevert();
        converter.strictConvert(1000e6, IOracle(address(oracle)), bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════
    //  SAFE MODE — Successful with oracle
    // ═══════════════════════════════════════════════════════════

    function test_SafeConvert_UsesOracleWhenAvailable() public {
        (uint256 amount, bool usedFallback) = converter.safeConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
        assertEq(amount, 1000e6);
        assertFalse(usedFallback);
    }

    // ═══════════════════════════════════════════════════════════
    //  SAFE MODE — Fallback when oracle fails
    // ═══════════════════════════════════════════════════════════

    function test_SafeConvert_FallbackOnOracleRevert() public {
        oracle.setShouldRevert(true);
        (uint256 amount, bool usedFallback) = converter.safeConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
        assertEq(amount, 1000e6); // 1:1 fallback
        assertTrue(usedFallback);
    }

    function test_SafeConvert_FallbackOnNegativePrice() public {
        oracle.setPrice(-100);
        (uint256 amount, bool usedFallback) = converter.safeConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
        assertEq(amount, 1000e6); // 1:1 fallback
        assertTrue(usedFallback);
    }

    function test_SafeConvert_FallbackOnPriceOutOfRange() public {
        oracle.setPrice(200_000_000); // $2.00 — out of range
        (uint256 amount, bool usedFallback) = converter.safeConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
        assertEq(amount, 1000e6); // 1:1 fallback
        assertTrue(usedFallback);
    }

    function test_SafeConvert_FallbackOnNoFeed() public {
        (uint256 amount, bool usedFallback) = converter.safeConvert(1000e6, IOracle(address(oracle)), bytes32(0));
        assertEq(amount, 1000e6); // 1:1 fallback
        assertTrue(usedFallback);
    }

    function test_SafeConvert_ZeroAmountReturnsZero() public {
        (uint256 amount, bool usedFallback) = converter.safeConvert(0, IOracle(address(oracle)), USDC_ASSET);
        assertEq(amount, 0);
        assertFalse(usedFallback);
    }

    // ═══════════════════════════════════════════════════════════
    //  DECIMAL NORMALIZATION
    // ═══════════════════════════════════════════════════════════

    function test_DecimalNormalization_At99Cents() public {
        oracle.setPrice(99_000_000); // $0.99
        // $1000 USD (1e9) at $0.99/USDC → ~1010.101... USDC
        // Formula: (1e9 * 1e8 + 99e6 - 1) / 99e6 = ceil(1010101010.1) = 1010101011
        uint256 result = converter.strictConvert(1000e6, IOracle(address(oracle)), USDC_ASSET);
        assertGt(result, 1000e6);
        assertApproxEqAbs(result, 1010101011, 1);
    }

    function test_ReverseConvert() public {
        // 1000 USDC at $1.00 → $1000 USD
        uint256 result = converter.strictReverse(1000e6, IOracle(address(oracle)), USDC_ASSET);
        assertEq(result, 1000e6);
    }
}
