// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {SolvencyOracle} from "../../../src/oracles/SolvencyOracle.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {BuybackEngine} from "../../../src/marketplace/BuybackEngine.sol";
import {MockCapacityOracleV5} from "../../mocks/MockCapacityOracleV5.sol";
import {MockSolvencyOracle} from "../../mocks/MockSolvencyOracle.sol";
import {MockClaimBondV5} from "../../mocks/MockClaimBondV5.sol";
import {MockBondVaultV5} from "../../mocks/MockBondVaultV5.sol";
import {MockMarketplace} from "../../mocks/MockMarketplace.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";

/// @notice Minimal mock USDC for access control tests
contract MockUSDC_AC {
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

/// @notice Minimal mock swap router for TWAPBurner construction
contract MockSwapRouter_AC {
    function exactInputSingle(bytes calldata) external payable returns (uint256) {
        return 0;
    }
}

/// @title AccessControlAttacks
/// @notice Tests that access control boundaries hold against unauthorized callers.
contract AccessControlAttacks is Test {
    address attacker = makeAddr("attacker");
    address admin = makeAddr("admin");
    address policyManager = makeAddr("policyManager");

    // ================================================================
    // Test 1: Unauthorized caller tries BondVault.decreaseObligations
    // ================================================================
    function test_Attack_UnauthorizedBuybackEngineCallsBondVault() public {
        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18);
        ClaimBond claimBond = new ClaimBond();
        BondVault vault = new BondVault(address(new MockUSDC_AC()), address(claimBond), address(oracle), policyManager);

        // attacker is not authorized
        vm.prank(attacker);
        vm.expectRevert("BondVault: caller not authorized");
        vault.decreaseObligations(100e18);
    }

    // ================================================================
    // Test 2: Unauthorized caller tries BondVault.burnFromReserves
    // ================================================================
    function test_Attack_UnauthorizedBurnFromReserves() public {
        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18);
        ClaimBond claimBond = new ClaimBond();
        BondVault vault = new BondVault(address(new MockUSDC_AC()), address(claimBond), address(oracle), policyManager);

        vm.prank(attacker);
        vm.expectRevert("BondVault: caller not authorized");
        vault.burnFromReserves(1e18);
    }

    // ================================================================
    // Test 3: Unregistered shield tries to create a policy via
    //         PolicyManager.recordPolicy (only router can call)
    // ================================================================
    function test_Attack_UnregisteredShieldPolicyCreation() public {
        MockBondVaultV5 mockVault = new MockBondVaultV5(address(0x1));

        PolicyManagerV2 pm = new PolicyManagerV2(address(mockVault));
        // router is not set, so any caller reverts with OnlyRouter()

        vm.prank(attacker);
        vm.expectRevert(PolicyManagerV2.OnlyRouter.selector);
        pm.recordPolicy(keccak256("FAKE_PRODUCT"), attacker, 1000e6, 10e6, uint32(3600), bytes32("BTC"));
    }

    // ================================================================
    // Test 4: Non-admin tries setEmergencyPause on SolvencyOracle
    // ================================================================
    function test_Attack_NonOwnerPausesSolvencyOracle() public {
        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18);
        MockUSDC_AC lumina = new MockUSDC_AC();
        // SolvencyOracle needs a BondVault that exposes totalCommittedUSD() and lumina()
        MockBondVaultV5 mockVault = new MockBondVaultV5(address(lumina));

        SolvencyOracle solvency = new SolvencyOracle(address(mockVault), address(oracle), admin);

        // attacker (no ADMIN_ROLE) tries to pause
        vm.prank(attacker);
        vm.expectRevert();
        solvency.setEmergencyPause(true);
    }

    // ================================================================
    // Test 5: Non-owner tries setFeeDistributor on TWAPBurner
    // ================================================================
    function test_Attack_NonAdminChangesTwapBurnerDistributor() public {
        MockUSDC_AC usdc = new MockUSDC_AC();
        MockUSDC_AC lumina = new MockUSDC_AC();
        MockSwapRouter_AC router = new MockSwapRouter_AC();

        TWAPBurner burner = new TWAPBurner(address(usdc), address(lumina), address(router));

        // attacker is not owner
        vm.prank(attacker);
        vm.expectRevert();
        burner.setFeeDistributor(attacker);
    }

    // ================================================================
    // Test 6: Non-operator tries setDailyBuyback on BuybackEngine
    // ================================================================
    function test_Attack_NonOperatorSetsDailyBuyback() public {
        MockClaimBondV5 claimBond = new MockClaimBondV5();
        MockBondVaultV5 bondVault = new MockBondVaultV5(address(0x1));
        MockSolvencyOracle solvencyOracle = new MockSolvencyOracle();
        MockCapacityOracleV5 capacityOracle = new MockCapacityOracleV5();
        MockMarketplace marketplace = new MockMarketplace();
        MockUSDC_AC usdc = new MockUSDC_AC();

        BuybackEngine engine = new BuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            admin
        );

        // Warp past activation so the only guard is the role check
        vm.warp(block.timestamp + 366 days);

        vm.prank(attacker);
        vm.expectRevert();
        engine.setDailyBuyback(1000e6, 80, 24);
    }
}
