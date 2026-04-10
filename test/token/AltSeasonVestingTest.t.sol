// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaToken} from "../../src/token/LuminaToken.sol";
import {AltSeasonVesting} from "../../src/token/AltSeasonVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockLuminaOracleForVesting {
    mapping(bytes32 => int256) public prices;
    bool public shouldRevert;

    function setPrice(bytes32 asset, int256 price) external {
        prices[asset] = price;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        require(!shouldRevert, "Oracle down");
        return prices[asset];
    }
}

contract MockAavePoolForVesting {
    uint128 public borrowRate;
    bool public shouldRevert;

    function setBorrowRate(uint128 _rate) external {
        borrowRate = _rate;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function getReserveData(address)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        )
    {
        require(!shouldRevert, "Aave down");
        return (0, 0, 0, 0, borrowRate, 0, 0, 0, address(0), address(0), address(0), address(0), 0, 0, 0);
    }
}

contract AltSeasonVestingTest is Test {
    LuminaToken public token;
    AltSeasonVesting public vesting;
    MockLuminaOracleForVesting public oracle;
    MockAavePoolForVesting public aavePool;

    address treasury = makeAddr("treasury");
    address exitEngine = makeAddr("exitEngine");
    address exchange = makeAddr("exchange");
    address usdc = makeAddr("usdc");

    address[] recipients;
    uint256[] amounts;

    function setUp() public {
        oracle = new MockLuminaOracleForVesting();
        aavePool = new MockAavePoolForVesting();

        // Default prices: below thresholds
        oracle.setPrice(bytes32("ETH"), 200_000_000_000); // $2000 (8 dec)
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000 (8 dec)
        aavePool.setBorrowRate(3e25); // 3% APY

        recipients = new address[](7);
        amounts = new uint256[](7);

        recipients[0] = makeAddr("seed");
        recipients[1] = makeAddr("strategic");
        recipients[2] = makeAddr("community");
        recipients[3] = makeAddr("founder1");
        recipients[4] = makeAddr("founder2");
        recipients[5] = makeAddr("ecosystem");
        recipients[6] = makeAddr("devs");

        amounts[0] = 10_000_000 * 1e18; // Seed
        amounts[1] = 10_000_000 * 1e18; // Strategic
        amounts[2] = 10_000_000 * 1e18; // Community
        amounts[3] = 7_500_000 * 1e18;  // Founder 1
        amounts[4] = 7_500_000 * 1e18;  // Founder 2
        amounts[5] = 15_000_000 * 1e18; // Ecosystem
        amounts[6] = 5_000_000 * 1e18;  // Devs

        // Deploy vesting first to know address, then deploy token
        // We need to predict the vesting address or deploy in order
        // Deploy token with vesting address = address we'll compute
        // Simpler: deploy vesting, then deploy token with vesting address
        // But token mints to vesting in constructor, so vesting must exist as address

        // Compute vesting address
        address vestingAddr = computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        token = new LuminaToken(treasury, exitEngine, exchange, vestingAddr);

        vesting = new AltSeasonVesting(
            address(oracle), address(aavePool), address(token), usdc, recipients, amounts
        );

        require(address(vesting) == vestingAddr, "Address mismatch");
    }

    // ═══════ Initial State ═══════

    function test_initial_state() public {
        assertFalse(vesting.altSeasonTriggered());
        assertEq(vesting.tranchesReleased(), 0);
        assertEq(vesting.conditionsMetSince(), 0);
        assertEq(vesting.getAllocationsCount(), 7);
        assertEq(token.balanceOf(address(vesting)), 65_000_000 * 1e18);
    }

    function test_constructor_validates_65M() public {
        uint256[] memory badAmounts = new uint256[](7);
        for (uint256 i = 0; i < 7; i++) badAmounts[i] = 1e18;

        vm.expectRevert("Must be 65M total");
        new AltSeasonVesting(address(oracle), address(aavePool), address(token), usdc, recipients, badAmounts);
    }

    function test_constructor_validates_length_8() public {
        address[] memory shortRecipients = new address[](2);
        uint256[] memory shortAmounts = new uint256[](2);
        shortRecipients[0] = makeAddr("a");
        shortRecipients[1] = makeAddr("b");
        shortAmounts[0] = 1e18;
        shortAmounts[1] = 1e18;

        vm.expectRevert("Must have 7 allocations");
        new AltSeasonVesting(address(oracle), address(aavePool), address(token), usdc, shortRecipients, shortAmounts);
    }

    // ═══════ Conditions ═══════

    function test_conditions_0of3_no_trigger() public {
        // All below thresholds (default setup)
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0);
        assertFalse(vesting.altSeasonTriggered());
    }

    function test_conditions_1of3_no_trigger() public {
        // Only A active: ETH/BTC > 0.050
        oracle.setPrice(bytes32("ETH"), 500_000_000_000); // $5000
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000
        // ETH/BTC = 0.1 > 0.05 → A=true, B=true (5000>4000), so this is 2/3
        // Let me fix: set ETH below $4000 threshold but ratio > 0.05
        oracle.setPrice(bytes32("ETH"), 350_000_000_000); // $3500
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000
        // ETH/BTC = 0.07 > 0.05 → A=true, B=false (3500<4000), C=false → 1/3

        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0);
    }

    function test_conditions_2of3_starts_clock() public {
        // A + B active: ETH/BTC > 0.05 and ETH > $4000
        oracle.setPrice(bytes32("ETH"), 500_000_000_000); // $5000
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000
        // ETH/BTC = 0.1 > 0.05 → A=true, B=true (5000>4000), C=false → 2/3

        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), block.timestamp);
        assertFalse(vesting.altSeasonTriggered());
    }

    function test_conditions_2of3_not_sustained_7days() public {
        _set2of3Active();
        vesting.checkAltSeason();

        vm.warp(block.timestamp + 6 days);
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered());
    }

    function test_conditions_2of3_sustained_7days_triggers() public {
        _set2of3Active();
        vesting.checkAltSeason();

        vm.warp(block.timestamp + 7 days);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered());
        assertEq(vesting.triggerTimestamp(), block.timestamp);
    }

    function test_conditions_reset_if_drop_below_2() public {
        _set2of3Active();
        vesting.checkAltSeason();
        uint256 startedAt = vesting.conditionsMetSince();
        assertGt(startedAt, 0);

        vm.warp(block.timestamp + 5 days);

        // Drop to 0/3
        oracle.setPrice(bytes32("ETH"), 200_000_000_000); // $2000
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000
        aavePool.setBorrowRate(3e25);

        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0);

        // Re-activate 2/3
        _set2of3Active();
        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), startedAt);
    }

    function test_trigger_is_irreversible() public {
        _triggerAltSeason();
        assertTrue(vesting.altSeasonTriggered());

        // Drop prices
        oracle.setPrice(bytes32("ETH"), 100_000_000_000);
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000);
        aavePool.setBorrowRate(1e25);

        // Still triggered
        assertTrue(vesting.altSeasonTriggered());
    }

    function test_checkAltSeason_after_trigger_reverts() public {
        _triggerAltSeason();
        vm.expectRevert("Already triggered");
        vesting.checkAltSeason();
    }

    // ═══════ Tranches ═══════

    function test_release_tranche_0_immediate() public {
        _triggerAltSeason();
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 1);

        // Each recipient got 1/3 of their allocation
        (,uint256 totalAmount, uint256 released) = vesting.getAllocation(0);
        assertEq(released, totalAmount / 3);
    }

    function test_release_tranche_1_after_31_days() public {
        _triggerAltSeason();
        vesting.releaseTranche();

        vm.warp(block.timestamp + 31 days);
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 2);
    }

    function test_release_tranche_1_before_31_days_reverts() public {
        _triggerAltSeason();
        vesting.releaseTranche();

        vm.warp(block.timestamp + 20 days);
        vm.expectRevert("Too early for this tranche");
        vesting.releaseTranche();
    }

    function test_release_tranche_2_after_62_days() public {
        _triggerAltSeason();
        vesting.releaseTranche();

        vm.warp(vesting.triggerTimestamp() + 31 days);
        vesting.releaseTranche();

        vm.warp(vesting.triggerTimestamp() + 62 days);
        vesting.releaseTranche();

        assertEq(vesting.tranchesReleased(), 3);

        // All tokens distributed
        assertEq(token.balanceOf(address(vesting)), 0);

        // Verify each allocation fully released
        for (uint256 i = 0; i < 7; i++) {
            (address recipient, uint256 totalAmount, uint256 released) = vesting.getAllocation(i);
            assertEq(released, totalAmount);
            assertEq(token.balanceOf(recipient), totalAmount);
        }
    }

    function test_release_all_3_then_reverts() public {
        _releaseAll3Tranches();
        vm.expectRevert("All tranches released");
        vesting.releaseTranche();
    }

    function test_remainder_handling() public {
        _releaseAll3Tranches();

        for (uint256 i = 0; i < 7; i++) {
            (, uint256 totalAmount, uint256 released) = vesting.getAllocation(i);
            assertEq(released, totalAmount, "Released must equal totalAmount");
        }
    }

    // ═══════ updateRecipient ═══════

    function test_updateRecipient_by_owner() public {
        address newAddr = makeAddr("newRecipient");
        vesting.updateRecipient(0, newAddr);
        (address recipient,,) = vesting.getAllocation(0);
        assertEq(recipient, newAddr);
    }

    function test_updateRecipient_by_non_owner_reverts() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        vesting.updateRecipient(0, attacker);
    }

    function test_updateRecipient_to_zero_reverts() public {
        vm.expectRevert("Zero address");
        vesting.updateRecipient(0, address(0));
    }

    function test_amounts_are_immutable() public {
        // Verify no setter for totalAmount — checked by ensuring the struct field is correct
        for (uint256 i = 0; i < 7; i++) {
            (, uint256 totalAmount,) = vesting.getAllocation(i);
            assertEq(totalAmount, amounts[i]);
        }
    }

    // ═══════ Boundary tests ═══════

    function test_conditionA_boundary() public {
        // ETH/BTC = 0.050 exactly → false (must be > not >=)
        oracle.setPrice(bytes32("ETH"), 250_000_000_000); // $2500
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000
        // ratio = 2500/50000 = 0.05 exactly

        (bool condA,,) = vesting.getConditions();
        assertFalse(condA);

        // ETH/BTC slightly above
        oracle.setPrice(bytes32("ETH"), 250_100_000_000); // $2501
        (condA,,) = vesting.getConditions();
        assertTrue(condA);
    }

    function test_conditionB_boundary() public {
        // ETH = $4,000 exactly → false
        oracle.setPrice(bytes32("ETH"), 400_000_000_000);
        (, bool condB,) = vesting.getConditions();
        assertFalse(condB);

        // ETH slightly above
        oracle.setPrice(bytes32("ETH"), 400_100_000_000); // $4001
        (, condB,) = vesting.getConditions();
        assertTrue(condB);
    }

    function test_conditionC_boundary() public {
        // 7% exactly → false
        aavePool.setBorrowRate(uint128(7e25));
        (,, bool condC) = vesting.getConditions();
        assertFalse(condC);

        // Slightly above
        aavePool.setBorrowRate(uint128(7e25 + 1));
        (,, condC) = vesting.getConditions();
        assertTrue(condC);
    }

    function test_different_2of3_combinations_AB() public {
        // A+B
        _set2of3Active(); // sets A+B
        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), 0);
    }

    function test_different_2of3_combinations_AC() public {
        // A+C (ETH/BTC > 0.05, borrow > 7%, but ETH < $4000)
        oracle.setPrice(bytes32("ETH"), 350_000_000_000); // $3500
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000
        // ratio = 0.07 > 0.05 → A=true, B=false
        aavePool.setBorrowRate(uint128(8e25)); // C=true

        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), 0);
    }

    function test_different_2of3_combinations_BC() public {
        // B+C (ETH > $4000, borrow > 7%, but ETH/BTC <= 0.05)
        oracle.setPrice(bytes32("ETH"), 450_000_000_000); // $4500
        oracle.setPrice(bytes32("BTC"), 10_000_000_000_000); // $100000
        // ratio = 0.045 < 0.05 → A=false, B=true
        aavePool.setBorrowRate(uint128(8e25)); // C=true

        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), 0);
    }

    function test_release_after_recipient_change() public {
        _triggerAltSeason();

        address newAddr = makeAddr("newSeed");
        vesting.updateRecipient(0, newAddr);

        vesting.releaseTranche();

        (, uint256 totalAmount,) = vesting.getAllocation(0);
        uint256 expected = totalAmount / 3;
        assertEq(token.balanceOf(newAddr), expected);
        assertEq(token.balanceOf(recipients[0]), 0);
    }

    // ═══════ DoS Resistance ═══════

    function test_checkAltSeason_oracle_reverts() public {
        // Oracle goes down — checkAltSeason should still work, conditions = false
        oracle.setShouldRevert(true);
        vesting.checkAltSeason(); // Should NOT revert
        assertEq(vesting.conditionsMetSince(), 0);
        assertFalse(vesting.altSeasonTriggered());
    }

    function test_checkAltSeason_aave_reverts() public {
        // Aave goes down but oracle works — A+B can still trigger if met
        oracle.setPrice(bytes32("ETH"), 500_000_000_000); // $5000
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000
        aavePool.setShouldRevert(true);

        // A=true, B=true, C=false (Aave down) → 2/3 → starts clock
        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), 0);

        // Can still trigger after 7 days with only A+B
        vm.warp(block.timestamp + 7 days);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered());
    }

    // ═══════ Helpers ═══════

    function _set2of3Active() internal {
        oracle.setPrice(bytes32("ETH"), 500_000_000_000); // $5000
        oracle.setPrice(bytes32("BTC"), 5_000_000_000_000); // $50000
        // A=true (0.1>0.05), B=true (5000>4000), C=false → 2/3
    }

    function _triggerAltSeason() internal {
        _set2of3Active();
        vesting.checkAltSeason();
        vm.warp(block.timestamp + 7 days);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered());
    }

    function _releaseAll3Tranches() internal {
        _triggerAltSeason();
        vesting.releaseTranche();
        vm.warp(vesting.triggerTimestamp() + 31 days);
        vesting.releaseTranche();
        vm.warp(vesting.triggerTimestamp() + 62 days);
        vesting.releaseTranche();
    }
}
