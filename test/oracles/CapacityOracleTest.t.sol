// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/v2/oracles/CapacityOracle.sol";

contract MockUniswapPool {
    int24 public mockTick = -92000; // approximately $0.036 for LUMINA/USDC
    address public token0_;
    address public token1_;

    constructor(address _t0, address _t1) {
        token0_ = _t0;
        token1_ = _t1;
    }

    function token0() external view returns (address) { return token0_; }
    function token1() external view returns (address) { return token1_; }

    function observe(uint32[] calldata) external view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiq)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(mockTick) * 1800; // 30 min window
        secondsPerLiq = new uint160[](2);
    }

    function slot0() external view returns (
        uint160, int24, uint16, uint16, uint16, uint8, bool
    ) {
        return (0, mockTick, 0, 0, 0, 0, true);
    }

    function setTick(int24 t) external { mockTick = t; }
}

contract CapacityOracleTest is Test {
    CapacityOracle oracle;
    address lumina = makeAddr("lumina");
    address usdc = makeAddr("usdc");

    function setUp() public {
        // Deploy without pool (emergency price only)
        oracle = new CapacityOracle(address(0), lumina, usdc, 0.036e18);
    }

    function test_emergency_price_when_no_pool() public view {
        uint256 price = oracle.getLuminaPrice();
        assertEq(price, 0.036e18);
    }

    function test_maxPoliciesPerDay_at_0036() public view {
        uint256 max = oracle.maxPoliciesPerDay();
        // 82M * 0.50 * 0.036 / (500 * 730 * 0.01) = ~404
        assertGt(max, 350);
        assertLt(max, 450);
    }

    function test_setEmergencyPrice() public {
        oracle.setEmergencyPrice(0.10e18);
        uint256 price = oracle.getLuminaPrice();
        assertEq(price, 0.10e18);
    }

    function test_maxPoliciesPerDay_at_1dollar() public {
        oracle.setEmergencyPrice(1e18);
        uint256 max = oracle.maxPoliciesPerDay();
        // Should be ~11,233
        assertGt(max, 10000);
        assertLt(max, 12000);
    }

    function test_twapWindow_bounds() public {
        vm.expectRevert("Window: 5min-2hr");
        oracle.setTwapWindow(100); // too short

        vm.expectRevert("Window: 5min-2hr");
        oracle.setTwapWindow(10000); // too long

        oracle.setTwapWindow(600); // 10 min, valid
        assertEq(oracle.twapWindow(), 600);
    }

    function test_onlyOwner_setEmergencyPrice() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        oracle.setEmergencyPrice(1e18);
    }
}
