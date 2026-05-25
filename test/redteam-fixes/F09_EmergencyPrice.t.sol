// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/oracles/CapacityOracle.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

/// @notice Simple stable-TWAP mock: both windows report the same tick, so the
///         F-02 deviation breaker is satisfied and `getTWAP(twapWindow)` yields a
///         usable reference for the F-09 emergency-price deviation bound.
contract MockStablePool {
    address public token0_;
    address public token1_;
    int24 public tick = -92000; // ~ $0.036 LUMINA/USDC (matches existing tests)

    constructor(address _t0, address _t1) {
        token0_ = _t0;
        token1_ = _t1;
    }

    function token0() external view returns (address) {
        return token0_;
    }

    function token1() external view returns (address) {
        return token1_;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiq)
    {
        uint32 window = secondsAgos[0];
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(tick) * int56(int32(window));
        secondsPerLiq = new uint160[](2);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, tick, 0, 0, 0, 0, true);
    }
}

contract F09_EmergencyPriceTest is Test {
    CapacityOracle oracle;
    MockStablePool pool;
    address lumina = makeAddr("lumina");
    address usdc = makeAddr("usdc");

    event EmergencyPriceSet(uint256 oldPrice, uint256 newPrice, address by);
    event EmergencyPriceProposed(uint256 newPrice, uint256 eta, address by);

    function setUp() public {
        vm.chainId(8453);
        oracle = ProxyDeployer.deployCapacityOracle(address(0), lumina, usdc, 0.036e18);
        pool = new MockStablePool(lumina, usdc);
    }

    // ─────────────────────────────────────────────────────────────
    // F-09: deviation bound on the proposed emergency price
    // ─────────────────────────────────────────────────────────────

    function _refPrice() internal view returns (uint256) {
        return oracle.getTWAP(oracle.twapWindow());
    }

    function test_EmergencyPriceDeviationBounded() public {
        oracle.setPool(address(pool));
        uint256 ref = _refPrice();
        assertGt(ref, 0, "reference TWAP should be non-zero");

        // A value within 50% of the reference is accepted.
        uint256 ok = ref + (ref * 40) / 100; // +40%
        oracle.proposeEmergencyPrice(ok);
        assertEq(oracle.pendingEmergencyPrice(), ok);

        // A value > 50% away from the reference is rejected.
        uint256 tooHigh = ref * 3; // +200%
        vm.expectRevert("Emergency price deviates >50%");
        oracle.proposeEmergencyPrice(tooHigh);

        uint256 tooLow = ref / 4; // -75%
        vm.expectRevert("Emergency price deviates >50%");
        oracle.proposeEmergencyPrice(tooLow);
    }

    // ─────────────────────────────────────────────────────────────
    // F-09: 24h timelock on emergency price changes (pool set)
    // ─────────────────────────────────────────────────────────────

    function test_EmergencyPriceTimelockEnforced() public {
        oracle.setPool(address(pool));

        // Immediate setter is BLOCKED once a pool is set.
        vm.expectRevert("Pool set: use timelock");
        oracle.setEmergencyPrice(0.04e18);

        uint256 ref = _refPrice();
        uint256 newPrice = ref + (ref * 10) / 100; // +10%, within band

        // Propose, then try to apply too early.
        oracle.proposeEmergencyPrice(newPrice);
        vm.expectRevert("Timelock not elapsed");
        oracle.applyEmergencyPrice();

        // Just before the deadline: still blocked.
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 24 hours - 1);
        vm.expectRevert("Timelock not elapsed");
        oracle.applyEmergencyPrice();

        // At/after the deadline: applies.
        vm.warp(t0 + 24 hours);
        oracle.applyEmergencyPrice();
        assertEq(oracle.emergencyPrice(), newPrice, "price should update after timelock");
        assertEq(oracle.pendingEmergencyPriceTimestamp(), 0, "pending cleared");
    }

    // ─────────────────────────────────────────────────────────────
    // F-09: events
    // ─────────────────────────────────────────────────────────────

    function test_EmergencyPriceEmitsEvent() public {
        // Bootstrap path (no pool) emits EmergencyPriceSet(old,new,by).
        vm.expectEmit(true, true, true, true);
        emit EmergencyPriceSet(0.036e18, 0.05e18, address(this));
        oracle.setEmergencyPrice(0.05e18);

        // Now set a pool and exercise the timelocked path events.
        oracle.setPool(address(pool));
        uint256 ref = _refPrice();
        uint256 newPrice = ref + (ref * 5) / 100; // +5%

        vm.expectEmit(false, false, false, true);
        emit EmergencyPriceProposed(newPrice, block.timestamp + 24 hours, address(this));
        oracle.proposeEmergencyPrice(newPrice);

        uint256 oldEmergency = oracle.emergencyPrice();
        vm.warp(block.timestamp + 24 hours);
        vm.expectEmit(true, true, true, true);
        emit EmergencyPriceSet(oldEmergency, newPrice, address(this));
        oracle.applyEmergencyPrice();
    }

    // Bootstrap still works with no pool (deploy edge), no timelock required.
    function test_BootstrapSetterWorksWithoutPool() public {
        oracle.setEmergencyPrice(0.1e18);
        assertEq(oracle.emergencyPrice(), 0.1e18);
        assertEq(oracle.getLuminaPrice(), 0.1e18, "no-pool path returns emergencyPrice");
    }
}
