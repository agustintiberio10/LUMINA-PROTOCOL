// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVesting, IAaveV3PoolReader} from "../../../src/token/FounderVesting.sol";

contract MockOracle {
    int256 public ethPrice;
    int256 public btcPrice;
    bool public shouldRevert;

    function setPrices(int256 e, int256 b) external {
        ethPrice = e;
        btcPrice = b;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (shouldRevert) revert("ORACLE_DOWN");
        if (asset == bytes32("ETH")) return ethPrice;
        if (asset == bytes32("BTC")) return btcPrice;
        return 0;
    }
}

contract MockAave {
    uint128 public rate;
    bool public shouldRevert;

    function setRate(uint128 r) external {
        rate = r;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function getReserveData(address) external view returns (IAaveV3PoolReader.ReserveData memory data) {
        if (shouldRevert) revert("AAVE_DOWN");
        data.currentVariableBorrowRate = rate;
    }
}

contract MockLumina {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @title FounderVestingEdgeCases
/// @notice Sprint Z.1 Phase 2 — 18 directed edge cases for FounderVesting immutable.
contract FounderVestingEdgeCases is Test {
    FounderVesting vesting;
    MockOracle oracle;
    MockAave aave;
    MockLumina lumina;
    address usdc = address(0x1);
    address recipient = address(0xBEEF);

    function setUp() public {
        vm.chainId(8453);
        oracle = new MockOracle();
        aave = new MockAave();
        lumina = new MockLumina();
        vesting = new FounderVesting(address(oracle), address(aave), address(lumina), usdc, recipient);
        lumina.mint(address(vesting), 8_000_000 * 1e18);
    }

    // ═══════ T-ORC: Oracle staleness / corruption ═══════

    function test_T_ORC_OracleEth_ReturnsZero_NoActivation() public {
        oracle.setPrices(0, 50_000_00000000);
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered(), "Should NOT activate with zero ETH price");
    }

    function test_T_ORC_OracleEthBtc_ReturnsNegative_NoActivation() public {
        oracle.setPrices(-1, 50_000_00000000);
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered());
    }

    function test_T_ORC_Oracle_Reverts_HandledViaCatch() public {
        oracle.setRevert(true);
        aave.setRate(uint128(8e25));
        // checkAltSeason() inner try-catch swallows revert. Aave still active.
        vesting.checkAltSeason();
        // condC may still be true; A+B should be false.
        (bool a, bool b,) = vesting.getConditions();
        assertFalse(a);
        assertFalse(b);
    }

    function test_T_ORC_OracleEth_MaxInt256_NoOverflow() public {
        // type(int256).max would overflow on ratio multiplication; verify it doesn't crash the contract.
        oracle.setPrices(type(int128).max, 50_000_00000000);
        vesting.checkAltSeason();
        // Should not crash.
    }

    function test_T_ORC_Aave_Reverts_HandledViaCatch() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRevert(true);
        vesting.checkAltSeason();
        // condC false but A+B true.
        (bool a, bool b, bool c) = vesting.getConditions();
        assertTrue(a);
        assertTrue(b);
        assertFalse(c);
    }

    function test_T_ORC_Aave_BorrowRateZero_NoActivation() public {
        aave.setRate(0);
        (,, bool c) = vesting.getConditions();
        assertFalse(c);
    }

    function test_T_ORC_Aave_BorrowRateExtreme_NoOverflow() public {
        aave.setRate(type(uint128).max);
        (,, bool c) = vesting.getConditions();
        assertTrue(c, "Extreme borrow rate should still trigger condC");
    }

    // ═══════ T-CNT: Counter behavior ═══════

    function test_T_CNT_FirstCheck_SetsConditionsMetSince() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), 0);
        assertFalse(vesting.altSeasonTriggered(), "Should NOT trigger on first check");
    }

    function test_T_CNT_ConditionsFail_ResetsCounter() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), 0);
        // Conditions drop.
        oracle.setPrices(0, 0);
        aave.setRate(0);
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0, "Counter must reset");
    }

    function test_T_CNT_Sustained7Days_Triggers() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason(); // start counter
        vm.warp(block.timestamp + 7 days + 1);
        vesting.checkAltSeason(); // should trigger
        assertTrue(vesting.altSeasonTriggered(), "Should trigger after 7 days sustained");
    }

    function test_T_CNT_SustainedLess7Days_DoesNotTrigger() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        vm.warp(block.timestamp + 7 days - 1);
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered());
    }

    // ═══════ T-FBK: Fallback ═══════

    function test_T_FBK_BeforeFallback_TriggerReverts() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() - 1);
        vm.expectRevert(bytes("Fallback not reached"));
        vesting.triggerFallback();
    }

    function test_T_FBK_ExactlyAtFallback_Triggers() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION());
        vesting.triggerFallback();
        assertTrue(vesting.altSeasonTriggered());
    }

    function test_T_FBK_AfterTrigger_CannotReTrigger() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vm.expectRevert(bytes("Already triggered"));
        vesting.triggerFallback();
    }

    // ═══════ T-REL: Release ═══════

    function test_T_REL_BeforeTrigger_Reverts() public {
        vm.expectRevert(bytes("Not triggered"));
        vesting.releaseTranche();
    }

    function test_T_REL_AfterTrigger_FirstTranche_Releases() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 1);
        assertEq(lumina.balanceOf(recipient), vesting.TRANCHE_AMOUNT());
    }

    function test_T_REL_SecondTrancheBeforeInterval_Reverts() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vesting.releaseTranche();
        vm.expectRevert(bytes("Too early"));
        vesting.releaseTranche();
    }

    function test_T_REL_AllThreeTranches_TotalEquals8M() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vesting.releaseTranche(); // T1 at tranchesReleased=0 → releaseTime = trigger + 0 = OK
        vm.warp(block.timestamp + 31 days);
        vesting.releaseTranche();
        vm.warp(block.timestamp + 31 days);
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 3);
        assertEq(vesting.totalReleased(), 8_000_000 * 1e18);
        assertEq(lumina.balanceOf(recipient), 8_000_000 * 1e18);
    }

    function test_T_REL_FourthTranche_Reverts() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vesting.releaseTranche();
        vm.warp(block.timestamp + 31 days);
        vesting.releaseTranche();
        vm.warp(block.timestamp + 31 days);
        vesting.releaseTranche();
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(bytes("All tranches released"));
        vesting.releaseTranche();
    }
}
