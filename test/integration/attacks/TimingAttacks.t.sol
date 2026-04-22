// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BuybackEngine} from "../../../src/marketplace/BuybackEngine.sol";
import {SolvencyOracle} from "../../../src/oracles/SolvencyOracle.sol";
import {CEXLiquidityReserve} from "../../../src/treasury/CEXLiquidityReserve.sol";
import {MockSolvencyOracle} from "../../mocks/MockSolvencyOracle.sol";
import {MockCapacityOracleV5} from "../../mocks/MockCapacityOracleV5.sol";
import {MockClaimBondV5} from "../../mocks/MockClaimBondV5.sol";
import {MockBondVaultV5} from "../../mocks/MockBondVaultV5.sol";
import {MockMarketplace} from "../../mocks/MockMarketplace.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @notice Minimal ERC20 mock for timing tests
contract MockLumina_Time {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @notice Minimal USDC mock for timing tests
contract MockUSDC_Time {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @title TimingAttacks
/// @notice Tests that time-lock and schedule-based guards reject premature actions.
contract TimingAttacks is Test {
    address attacker = makeAddr("attacker");
    address admin = makeAddr("admin");

    // ================================================================
    // Test 1: BuybackEngine.executeOffer without daily config reverts
    // ================================================================
    function test_Attack_BuybackWithoutConfig() public {
        MockClaimBondV5 claimBond = new MockClaimBondV5();
        MockBondVaultV5 bondVault = new MockBondVaultV5(address(0x1));
        MockSolvencyOracle solvencyOracle = new MockSolvencyOracle();
        MockCapacityOracleV5 capacityOracle = new MockCapacityOracleV5();
        MockMarketplace marketplace = new MockMarketplace();
        MockUSDC_Time usdc = new MockUSDC_Time();

        BuybackEngine engine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            admin
        );

        // Try to executeOffer without configuring daily buyback
        // validUntil defaults to 0, so block.timestamp > 0 => "Daily offer expired"
        vm.expectRevert("Daily offer expired");
        engine.executeOffer(0);
    }

    // ================================================================
    // Test 2: SolvencyOracle.evaluate before 24h interval
    // ================================================================
    function test_Attack_SolvencyEvaluateBeforeInterval() public {
        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18);
        MockLumina_Time lumina = new MockLumina_Time();
        MockBondVaultV5 mockVault = new MockBondVaultV5(address(lumina));

        SolvencyOracle solvency = new SolvencyOracle(address(mockVault), address(oracle), admin);

        // Constructor sets lastEvaluation = block.timestamp
        // Try to evaluate immediately (before EVALUATION_INTERVAL = 1 day)
        vm.expectRevert("Evaluation interval not reached");
        solvency.evaluate();

        // Even 23 hours later should fail
        vm.warp(block.timestamp + 23 hours);
        vm.expectRevert("Evaluation interval not reached");
        solvency.evaluate();

        // At exactly 24 hours it should succeed
        vm.warp(block.timestamp + 1 hours);
        solvency.evaluate(); // should not revert
    }

    // ================================================================
    // Test 3: CEXLiquidityReserve Strategic bucket locked for 18 months
    // ================================================================
    function test_Attack_CEXStrategicBeforeUnlock() public {
        MockLumina_Time lumina = new MockLumina_Time();

        CEXLiquidityReserve reserve = new CEXLiquidityReserve(address(lumina), admin);

        // Fund with full allocation
        lumina.mint(address(reserve), 14_000_000e18);

        // Strategic lock = 547 days (~18 months)
        // Try to allocate from Strategic immediately
        vm.prank(admin);
        vm.expectRevert("Insufficient in sub-bucket");
        reserve.allocate(
            attacker,
            100e18,
            CEXLiquidityReserve.SubBucket.StrategicReserve,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1,
            "Early strategic grab"
        );

        // Warp to 546 days (still locked)
        vm.warp(block.timestamp + 546 days);
        vm.prank(admin);
        vm.expectRevert("Insufficient in sub-bucket");
        reserve.allocate(
            attacker,
            100e18,
            CEXLiquidityReserve.SubBucket.StrategicReserve,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1,
            "Still locked attempt"
        );

        // Warp to 548 days (past lock)
        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        reserve.allocate(
            attacker,
            100e18,
            CEXLiquidityReserve.SubBucket.StrategicReserve,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_1,
            "Unlocked allocation"
        );
        // Verify allocation went through
        assertEq(lumina.balanceOf(attacker), 100e18);
    }

    // ================================================================
    // Test 4: BuybackEngine expired daily offer
    // ================================================================
    function test_Attack_ExpiredDailyBuybackOffer() public {
        MockClaimBondV5 claimBond = new MockClaimBondV5();
        MockBondVaultV5 bondVault = new MockBondVaultV5(address(0x1));
        MockSolvencyOracle solvencyOracle = new MockSolvencyOracle();
        MockCapacityOracleV5 capacityOracle = new MockCapacityOracleV5();
        capacityOracle.setPrice(0.036e18);
        MockMarketplace marketplace = new MockMarketplace();
        MockUSDC_Time usdc = new MockUSDC_Time();

        BuybackEngine engine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            admin
        );

        // Admin sets a daily buyback config with 24-hour validity
        vm.prank(admin);
        engine.setDailyBuyback(10_000e6, 80, 24); // 24 hours

        // Setup a listing on marketplace
        marketplace.setListing(0, makeAddr("seller"), 202801, 10, 100e6, true);
        claimBond.setMaturityDate(202801, block.timestamp + 365 days);
        claimBond.mint(address(engine), 202801, 10);

        // Warp 25 hours (past validUntil)
        vm.warp(block.timestamp + 25 hours);

        // Try to execute -- should fail due to expiry
        vm.expectRevert("Daily offer expired");
        engine.executeOffer(0);
    }
}
