// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/token/FounderVesting.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// Mock oracle that returns configurable prices
contract MockOracle {
    int256 public ethPrice = 3000_00000000; // $3,000 (8 decimals)
    int256 public btcPrice = 60000_00000000; // $60,000 (8 decimals)

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (asset == bytes32("ETH")) return ethPrice;
        if (asset == bytes32("BTC")) return btcPrice;
        return 0;
    }

    function setEthPrice(int256 p) external {
        ethPrice = p;
    }

    function setBtcPrice(int256 p) external {
        btcPrice = p;
    }
}

// Mock Aave pool that returns configurable borrow rate
contract MockAavePool {
    uint128 public borrowRate = 5e25; // 5% (below threshold)

    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address) external view returns (ReserveData memory data) {
        data.currentVariableBorrowRate = borrowRate;
    }

    function setBorrowRate(uint128 r) external {
        borrowRate = r;
    }
}

contract FounderVestingTest is Test {
    using ProxyDeployer for *;

    LuminaTokenV2 token;
    FounderVesting vesting;
    MockOracle oracle;
    MockAavePool aavePool;

    address bondVault = makeAddr("bondVault");
    address lbp = makeAddr("lbp");
    address treasury = makeAddr("treasury");
    address founder = makeAddr("founder");
    address usdc = makeAddr("usdc");

    function setUp() public {
        oracle = new MockOracle();
        aavePool = new MockAavePool();
        token = ProxyDeployer.deployLuminaTokenV2(bondVault, makeAddr("cex"), address(0xdead), lbp, treasury);
        // We'll deploy vesting separately and transfer tokens to it
        vesting = new FounderVesting(address(oracle), address(aavePool), address(token), usdc, founder);
        // Simulate: token was minted to a temp address, now transfer to vesting
        // In real deploy, founderVesting address is known at construction
        // For test, we use deal to set the balance
        deal(address(token), address(vesting), 8_000_000 * 1e18);
    }

    function test_initial_state() public view {
        assertEq(vesting.recipient(), founder);
        assertFalse(vesting.altSeasonTriggered());
        assertEq(vesting.tranchesReleased(), 0);
        assertEq(vesting.totalReleased(), 0);
    }

    function test_conditions_not_met() public {
        // ETH=$3000, BTC=$60000 → ETH/BTC=0.05 (exactly at threshold, not above)
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered());
    }

    function test_conditions_met_but_not_sustained() public {
        // Set conditions: ETH=$5000 (>$4000), ETH/BTC=0.06 (>0.05)
        oracle.setEthPrice(5000_00000000);
        oracle.setBtcPrice(80000_00000000); // ETH/BTC = 0.0625
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered());
        assertTrue(vesting.conditionsMetSince() > 0);
    }

    function test_trigger_after_7_days() public {
        oracle.setEthPrice(5000_00000000);
        oracle.setBtcPrice(80000_00000000);
        vesting.checkAltSeason(); // starts sustained period
        vm.warp(block.timestamp + 7 days + 1);
        vesting.checkAltSeason(); // triggers
        assertTrue(vesting.altSeasonTriggered());
    }

    function test_release_3_tranches() public {
        // Trigger alt season
        oracle.setEthPrice(5000_00000000);
        oracle.setBtcPrice(80000_00000000);
        vesting.checkAltSeason();
        vm.warp(block.timestamp + 7 days + 1);
        vesting.checkAltSeason();

        // Tranche 1 — immediately
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 1);
        // [SR3] TRANCHE_AMOUNT = TOTAL_AMOUNT / 3 = integer division of 10M*1e18 / 3.
        // Compute at runtime so the test matches the actual integer-division result.
        uint256 total = 8_000_000 * 1e18;
        uint256 tranche = total / 3;
        assertEq(token.balanceOf(founder), tranche);

        // [SR3] Use explicit absolute timestamps anchored to the trigger event
        // to avoid any Foundry warp-composition quirk with `block.timestamp + X`.
        uint256 tts = vesting.triggerTimestamp();

        // Tranche 2 — after 31 days
        vm.warp(tts + 31 days + 1);
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 2);

        // Tranche 3 — after another 31 days (62 total from trigger)
        vm.warp(tts + 62 days + 1);
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 3);
        assertEq(token.balanceOf(founder), 8_000_000 * 1e18);
    }

    function test_cannot_release_before_trigger() public {
        vm.expectRevert("Not triggered");
        vesting.releaseTranche();
    }

    function test_cannot_release_too_early() public {
        oracle.setEthPrice(5000_00000000);
        oracle.setBtcPrice(80000_00000000);
        vesting.checkAltSeason();
        vm.warp(block.timestamp + 7 days + 1);
        vesting.checkAltSeason();
        vesting.releaseTranche(); // tranche 1

        // Tranche 2 is too early immediately after tranche 1 (needs +31 days)
        vm.expectRevert("Too early");
        vesting.releaseTranche();
    }

    function test_fallback_at_4_years() public {
        vm.warp(block.timestamp + 1460 days);
        vesting.triggerFallback();
        assertTrue(vesting.altSeasonTriggered());
    }

    function test_cannot_fallback_early() public {
        vm.warp(block.timestamp + 1000 days);
        vm.expectRevert("Fallback not reached");
        vesting.triggerFallback();
    }

    function test_updateRecipient() public {
        address newRecipient = makeAddr("newFounder");
        vesting.updateRecipient(newRecipient);
        assertEq(vesting.recipient(), newRecipient);
    }

    function test_nonOwner_cannot_updateRecipient() public {
        vm.prank(founder);
        vm.expectRevert();
        vesting.updateRecipient(makeAddr("attacker"));
    }
}
