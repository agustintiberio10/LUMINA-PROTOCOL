// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/products/RateShockShield.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// Minimal mock Aave V3 pool that returns a configurable borrow rate
contract MockAaveV3Pool {
    uint128 public rate = 5e25; // 5% (below trigger)

    function getReserveData(address) external view returns (IAaveV3Pool.ReserveData memory data) {
        data.currentVariableBorrowRate = rate;
    }

    function setRate(uint128 r) external {
        rate = r;
    }
}

contract RateShockShieldTest is Test {
    RateShockShield shield;
    MockAaveV3Pool mockPool;

    address router = makeAddr("router");
    address oracle = makeAddr("oracle");
    address usdc = makeAddr("usdc");

    function setUp() public {
        vm.chainId(8453);
        mockPool = new MockAaveV3Pool();
        shield = ProxyDeployer.deployRateShockShield(router, oracle, address(mockPool), usdc);
    }

    function test_productId() public view {
        assertEq(shield.productId(), keccak256("RATESHOCK-001"));
    }

    function test_triggerRate_is_10_percent_RAY() public view {
        // 10% APY in RAY (27 decimals) = 10e25
        assertEq(shield.TRIGGER_RATE(), 10e25);
    }

    function test_durationRange_is_7_days() public view {
        (uint32 min, uint32 max) = shield.durationRange();
        assertEq(min, 604800);
        assertEq(max, 604800);
    }

    function test_deductibleBps() public view {
        assertEq(shield.DEDUCTIBLE_BPS(), 2000);
    }

    function test_currentBorrowRate_reads_pool() public {
        assertEq(shield.currentBorrowRate(), 5e25);
        mockPool.setRate(12e25);
        assertEq(shield.currentBorrowRate(), 12e25);
    }

    function test_immutables() public view {
        assertEq(address(shield.aavePool()), address(mockPool));
        assertEq(shield.usdc(), usdc);
    }
}
