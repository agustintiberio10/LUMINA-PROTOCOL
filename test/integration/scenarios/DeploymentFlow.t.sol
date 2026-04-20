// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../../src/interfaces/IDexRouter.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {CapacityOracle} from "../../../src/oracles/CapacityOracle.sol";
import "../../../script/DeployLuminaWithSaltMining.s.sol";

// ═══════ MINIMAL MOCKS ═══════

contract MockUSDCDeploy {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockSwapRouterDeploy is IDexRouter {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract MockPriceOracleDeploy {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

/// @title DeploymentFlowTest
/// @notice Integration tests verifying full system deployment, wiring, roles, and initial state.
contract DeploymentFlowTest is Test {
    // ═══════ CONTRACTS ═══════
    LuminaTokenV2 token;
    BondVault bondVault;
    ClaimBond claimBond;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;
    CapacityOracle capacityOracle;

    // ═══════ MOCKS ═══════
    MockUSDCDeploy usdc;
    MockSwapRouterDeploy swapRouter;
    MockPriceOracleDeploy priceOracle;

    // ═══════ ADDRESSES ═══════
    address deployer;
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");

    function setUp() public {
        deployer = address(this);

        // Warp to Jan 2 2026
        vm.warp(1767312000);

        // Deploy mocks
        usdc = new MockUSDCDeploy();
        priceOracle = new MockPriceOracleDeploy(0.036e18);

        // Deploy ClaimBond
        claimBond = new ClaimBond();

        // Predict BondVault address for token + PM constructors
        uint64 currentNonce = vm.getNonce(address(this));
        // token=currentNonce, swapRouter=+1, twapBurner=+2, policyManager=+3, bondVault=+4
        address predictedBondVault = vm.computeCreateAddress(address(this), currentNonce + 4);

        // Deploy token
        token = new LuminaTokenV2(predictedBondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);

        // Deploy swap router
        swapRouter = new MockSwapRouterDeploy(address(token));

        // Deploy TWAPBurner
        twapBurner = new TWAPBurner(address(usdc), address(token), address(swapRouter));

        // Deploy PolicyManagerV2
        policyManager = new PolicyManagerV2(predictedBondVault);

        // Deploy BondVault
        bondVault = new BondVault(address(token), address(claimBond), address(priceOracle), address(policyManager));
        require(address(bondVault) == predictedBondVault, "BondVault address prediction mismatch");

        // Wire ClaimBond
        claimBond.setBondVault(address(bondVault));

        // Deploy CapacityOracle (no pool set — will use emergency price)
        capacityOracle = new CapacityOracle(address(0), address(token), address(usdc), 0.036e18);

        // Deploy CoverRouter
        coverRouter = new CoverRouterV2(address(usdc), address(policyManager), address(twapBurner));

        // Wire PolicyManager
        policyManager.setRouter(address(coverRouter));

        // Grant BURNER_ROLE
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));
    }

    // ═══════ TEST 1: Full System Wiring ═══════

    function test_Deployment_FullSystemWiring() public view {
        // BondVault immutables
        assertEq(address(bondVault.lumina()), address(token), "BondVault.lumina");
        assertEq(address(bondVault.claimBond()), address(claimBond), "BondVault.claimBond");
        assertEq(address(bondVault.priceOracle()), address(priceOracle), "BondVault.priceOracle");
        assertEq(bondVault.policyManager(), address(policyManager), "BondVault.policyManager");

        // ClaimBond wiring
        assertEq(claimBond.bondVault(), address(bondVault), "ClaimBond.bondVault");

        // TWAPBurner immutables
        assertEq(address(twapBurner.usdc()), address(usdc), "TWAPBurner.usdc");
        assertEq(address(twapBurner.lumina()), address(token), "TWAPBurner.lumina");
        assertEq(address(twapBurner.dexRouters(0)), address(swapRouter), "TWAPBurner.dexRouters[0]");

        // PolicyManagerV2 wiring
        assertEq(address(policyManager.bondVault()), address(bondVault), "PM.bondVault");
        assertEq(policyManager.router(), address(coverRouter), "PM.router");

        // CoverRouterV2 wiring
        assertEq(address(coverRouter.usdc()), address(usdc), "CoverRouter.usdc");
        assertEq(address(coverRouter.policyManager()), address(policyManager), "CoverRouter.PM");
        assertEq(address(coverRouter.twapBurner()), address(twapBurner), "CoverRouter.twapBurner");

        // CapacityOracle immutables
        assertEq(capacityOracle.luminaToken(), address(token), "CapacityOracle.lumina");
        assertEq(capacityOracle.usdcToken(), address(usdc), "CapacityOracle.usdc");
        assertEq(capacityOracle.emergencyPrice(), 0.036e18, "CapacityOracle.emergencyPrice");
    }

    // ═══════ TEST 2: Role Granularity ═══════

    function test_Deployment_RoleGranularity() public view {
        // LuminaTokenV2: DEFAULT_ADMIN_ROLE granted to deployer
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer), "Deployer should have DEFAULT_ADMIN_ROLE");

        // LuminaTokenV2: BURNER_ROLE granted to TWAPBurner
        assertTrue(token.hasRole(token.BURNER_ROLE(), address(twapBurner)), "TWAPBurner should have BURNER_ROLE");

        // BURNER_ROLE NOT granted to random addresses
        assertFalse(token.hasRole(token.BURNER_ROLE(), address(bondVault)), "BondVault should NOT have BURNER_ROLE");
        assertFalse(token.hasRole(token.BURNER_ROLE(), deployer), "Deployer should NOT have BURNER_ROLE");

        // TWAPBurner: owner is deployer
        assertEq(twapBurner.owner(), deployer, "TWAPBurner owner should be deployer");

        // PolicyManagerV2: owner is deployer
        assertEq(policyManager.owner(), deployer, "PM owner should be deployer");

        // CoverRouterV2: owner is deployer
        assertEq(coverRouter.owner(), deployer, "CoverRouter owner should be deployer");

        // CapacityOracle: owner is deployer
        assertEq(capacityOracle.owner(), deployer, "CapacityOracle owner should be deployer");

        // ClaimBond: owner is deployer
        assertEq(claimBond.owner(), deployer, "ClaimBond owner should be deployer");
    }

    // ═══════ TEST 3: Salt Mining Address Ordering ═══════

    function test_Deployment_SaltMiningAddressOrdering() public {
        DeployLuminaWithSaltMining saltMiner = new DeployLuminaWithSaltMining();
        address USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

        // Use dummy pairwise-distinct addresses
        address bv = address(0x1001);
        address lbp = address(0x2002);
        address fv = address(0x3003);
        address tv = address(0x4004);

        (bytes32 salt, address predicted, uint256 iterations) = saltMiner.mineSalt(bv, lbp, fv, tv);

        // LUMINA address must be < USDC for token0 in Uniswap V3
        assertTrue(predicted < USDC_BASE, "LUMINA must be < USDC_BASE for token0 ordering");
        assertGt(iterations, 0, "Should have iterated at least once");
        assertTrue(salt != bytes32(0) || iterations == 1, "Salt should be valid");
    }

    // ═══════ TEST 4: Initial Balances ═══════

    function test_Deployment_InitialBalances() public view {
        // Verify exact distribution (70/14/8/5/3)
        assertEq(token.balanceOf(address(bondVault)), 70_000_000e18, "BondVault: 70M LUMINA");
        assertEq(token.balanceOf(cexReserve), 14_000_000e18, "CEX Reserve: 14M LUMINA");
        assertEq(token.balanceOf(founderVesting), 8_000_000e18, "Founder Vesting: 8M LUMINA");
        assertEq(token.balanceOf(lbpDeposit), 5_000_000e18, "LBP Deposit: 5M LUMINA");
        assertEq(token.balanceOf(treasuryVesting), 3_000_000e18, "Treasury Vesting: 3M LUMINA");

        // Total supply = MAX_SUPPLY
        assertEq(token.totalSupply(), token.MAX_SUPPLY(), "Total supply must equal MAX_SUPPLY");
        assertEq(token.totalSupply(), 100_000_000e18, "Total supply must be 100M");

        // No tokens burned yet
        assertEq(token.totalBurned(), 0, "No tokens burned initially");

        // BondVault internal state should be clean
        assertEq(bondVault.totalCommittedUSD(), 0, "No commitments initially");

        // TWAPBurner should have no USDC
        assertEq(twapBurner.totalUSDCReceived(), 0, "No USDC received initially");
        assertEq(twapBurner.totalLUMINABurned(), 0, "No LUMINA burned initially");
    }
}
