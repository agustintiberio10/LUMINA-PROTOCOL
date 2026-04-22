// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../../src/oracles/CapacityOracle.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract MockUniswapPool {
    int24 public mockTick = -92000; // approximately $0.036 for LUMINA/USDC
    address public token0_;
    address public token1_;

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

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiq)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(mockTick) * 1800; // 30 min window
        secondsPerLiq = new uint160[](2);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, mockTick, 0, 0, 0, 0, true);
    }

    function setTick(int24 t) external {
        mockTick = t;
    }
}

contract CapacityOracleTest is Test {
    using ProxyDeployer for *;

    CapacityOracle oracle;
    address lumina = makeAddr("lumina");
    address usdc = makeAddr("usdc");

    function setUp() public {
        // Deploy without pool (emergency price only)
        oracle = ProxyDeployer.deployCapacityOracle(address(0), lumina, usdc, 0.036e18);
    }

    function test_emergency_price_when_no_pool() public view {
        uint256 price = oracle.getLuminaPrice();
        assertEq(price, 0.036e18);
    }

    function test_maxPoliciesPerDay_at_0036() public view {
        uint256 max = oracle.maxPoliciesPerDay();
        // 70M * 0.50 * 0.036 / (500 * 730 * 0.01) = ~345
        assertGt(max, 300);
        assertLt(max, 400);
    }

    function test_setEmergencyPrice() public {
        oracle.setEmergencyPrice(0.1e18);
        uint256 price = oracle.getLuminaPrice();
        assertEq(price, 0.1e18);
    }

    function test_maxPoliciesPerDay_at_1dollar() public {
        oracle.setEmergencyPrice(1e18);
        uint256 max = oracle.maxPoliciesPerDay();
        // 70M * 0.50 * 1.0 / (500 * 730 * 0.01) = ~9,589
        assertGt(max, 9000);
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

    // ═══════ getTWAP tests ═══════

    function test_GetTWAP_FallbackWhenNoPool() public view {
        // pool == address(0) → returns emergencyPrice
        uint256 twap = oracle.getTWAP(2592000); // 30 days
        assertEq(twap, 0.036e18, "Should return emergencyPrice when no pool");
    }

    function test_GetTWAP_RevertIf_PeriodZero() public {
        vm.expectRevert("Period must be > 0");
        oracle.getTWAP(0);
    }

    function test_GetTWAP_30Days_ReturnsFallback() public view {
        // No pool set → emergency fallback
        uint256 twap = oracle.getTWAP(30 days);
        assertEq(twap, 0.036e18);
    }

    // ═══════ setPool tests ═══════

    function test_SetPool_Success() public {
        MockUniswapPool mockPool = new MockUniswapPool(lumina, usdc);
        oracle.setPool(address(mockPool));
        assertEq(oracle.pool(), address(mockPool), "Pool address should be updated");
        assertTrue(oracle.isToken0Lumina(), "token0 is lumina so isToken0Lumina should be true");
    }

    function test_SetPool_RevertIf_NotOwner() public {
        MockUniswapPool mockPool = new MockUniswapPool(lumina, usdc);
        vm.prank(makeAddr("random"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("random")));
        oracle.setPool(address(mockPool));
    }

    function test_SetPool_RevertIf_ZeroAddress() public {
        vm.expectRevert("Zero pool");
        oracle.setPool(address(0));
    }

    // ═══════ BOND_RESERVE constant test ═══════

    function test_CapacityOracle_BondReserve_Is70M() public view {
        assertEq(oracle.BOND_RESERVE(), 70_000_000 * 1e18, "BOND_RESERVE should be 70M * 1e18");
    }
}
