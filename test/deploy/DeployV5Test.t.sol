// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// ─── Core contracts ───
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {CapacityOracle} from "../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";
import {IShield} from "../../src/interfaces/IShield.sol";

// ═══════════════════════════════════════════════════════════════
//  INLINE MOCKS
// ═══════════════════════════════════════════════════════════════

contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

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

contract MockSwapRouter {
    /// @dev Returns a dummy value; in tests no real swap is executed.
    function exactInputSingle(bytes calldata) external pure returns (uint256) {
        return 1000e18;
    }
}

/// @dev Minimal mock that satisfies IShield interface enough for PolicyManager registration.
contract MockShield {
    bytes32 public immutable shieldProductId;
    address public immutable router;

    constructor(bytes32 _productId, address _router) {
        shieldProductId = _productId;
        router = _router;
    }

    function productId() external view returns (bytes32) {
        return shieldProductId;
    }

    function riskType() external pure returns (bytes32) {
        return keccak256("VOLATILE");
    }

    function maxAllocationBps() external pure returns (uint16) {
        return 3000;
    }

    function durationRange() external pure returns (uint32 minSeconds, uint32 maxSeconds) {
        return (3600, 86400);
    }

    function waitingPeriod() external pure returns (uint32) {
        return 0;
    }

    function createPolicy(IShield.CreatePolicyParams calldata) external pure returns (uint256) {
        return 1;
    }

    function verifyAndCalculate(uint256, bytes calldata) external pure returns (IShield.PayoutResult memory r) {
        r.triggered = true;
        r.payoutAmount = 800e6;
        r.recipient = address(0);
        r.reason = "TRIGGERED";
    }

    function markPaidOut(uint256) external pure {}
    function markExpired(uint256) external pure {}

    function getPolicyInfo(uint256) external pure returns (IShield.PolicyInfo memory info) {}

    function getPolicyStatus(uint256) external pure returns (IShield.PolicyStatus) {
        return IShield.PolicyStatus.ACTIVE;
    }

    function totalPolicies() external pure returns (uint256) {
        return 0;
    }

    function activePolicies() external pure returns (uint256) {
        return 0;
    }

    function totalActiveCoverage() external pure returns (uint256) {
        return 0;
    }
}

// ═══════════════════════════════════════════════════════════════
//  DEPLOY V5 TEST
// ═══════════════════════════════════════════════════════════════

contract DeployV5Test is Test {
    // ─── Addresses ───
    address deployer;
    address multisig;
    address founderVesting;
    address lbpDeposit;

    // ─── Mocks ───
    MockUSDC usdc;
    MockSwapRouter swapRouter;

    // ─── Core protocol ───
    MaintenanceReserve maintenanceReserve;
    ClaimBond claimBond;
    CapacityOracle capacityOracle;
    BondVault bondVault;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;
    LuminaTokenV2 lumina;
    SolvencyOracle solvencyOracle;
    AdaptiveFeeDistributor feeDistributor;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;
    LuminaBondMarketplace marketplace;
    BuybackEngine buybackEngine;

    // ─── Shields ───
    MockShield shield1;
    MockShield shield2;
    bytes32 constant PRODUCT_1 = keccak256("FLASHBTC1H-001");
    bytes32 constant PRODUCT_2 = keccak256("FLASHETH1H-001");

    // ─── Constants ───
    uint256 constant EMERGENCY_PRICE = 0.036e18; // $0.036
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC

    function setUp() public {
        // Warp to a known time (60 days after epoch base)
        vm.warp(BASE_TS + 60 days);

        deployer = address(this);
        multisig = makeAddr("multisig");
        founderVesting = makeAddr("founderVesting");
        lbpDeposit = makeAddr("lbpDeposit");

        // ──────────────────────────────────────────────────────
        // PHASE 1: Deploy mocks / peripherals
        // ──────────────────────────────────────────────────────
        usdc = new MockUSDC();
        swapRouter = new MockSwapRouter();

        // ──────────────────────────────────────────────────────
        // PHASE 2: Deploy contracts that have NO circular deps
        // ──────────────────────────────────────────────────────
        maintenanceReserve = new MaintenanceReserve(address(usdc), multisig);
        claimBond = new ClaimBond();

        // ──────────────────────────────────────────────────────
        // PHASE 3: CapacityOracle (pool = address(0) initially)
        //          Uses emergencyPrice until pool is configured.
        // ──────────────────────────────────────────────────────

        // We need lumina address for CapacityOracle but lumina needs bondVault...
        // Use a placeholder address for CapacityOracle's luminaToken - it's only
        // used to detect token0 in a pool, which is address(0) anyway.
        // We'll deploy CapacityOracle with a temporary lumina address and then
        // deploy the real token. The oracle only reads emergencyPrice when pool=0.

        // Deploy CEXReserve and TreasuryVesting first (they need lumina address too,
        // but we solve this with CREATE2 / deploy-order trick):
        // Actually we need to solve the dependency chain:
        //   lumina needs: bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting
        //   bondVault needs: lumina (as IERC20), claimBond, capacityOracle (as priceOracle)
        //   cexReserve needs: lumina
        //   treasuryVesting needs: lumina
        //
        // Solution: deploy CapacityOracle with placeholder lumina, deploy BondVault
        // with placeholder lumina, then deploy real lumina, then wire. But BondVault
        // stores lumina as immutable... So we need a different approach.
        //
        // The real deploy order is:
        //   1. ClaimBond (no deps)
        //   2. CapacityOracle (placeholder lumina = computed address)
        //   3. BondVault (placeholder lumina = computed address, claimBond, capacityOracle)
        //   4. CEXReserve (placeholder lumina = computed address)
        //   5. TreasuryVesting (placeholder lumina = computed address)
        //   6. LuminaTokenV2 (bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting)
        //
        // In Foundry tests we can use vm.computeCreateAddress to predict lumina's
        // address, or we can use a two-phase approach. Let's predict the address.

        // We need to count how many contracts deployer will deploy before LuminaTokenV2.
        // Current nonce accounting: this is a test contract, so we track via vm.getNonce.
        uint64 currentNonce = vm.getNonce(deployer);
        // Contracts still to deploy before lumina:
        //   capacityOracle (+1)
        //   bondVault (+1)
        //   cexReserve (+1)
        //   treasuryVesting (+1)
        //   then lumina at nonce = currentNonce + 4
        address predictedLumina = vm.computeCreateAddress(deployer, currentNonce + 4);

        capacityOracle = new CapacityOracle(
            address(0), // pool (none yet)
            predictedLumina, // luminaToken
            address(usdc), // usdcToken
            EMERGENCY_PRICE // emergencyPrice
        );

        bondVault = new BondVault(
            predictedLumina, // lumina
            address(claimBond), // claimBond
            address(capacityOracle), // priceOracle
            address(0) // policyManager (set later via one-shot)
        );

        cexReserve = new CEXLiquidityReserve(
            predictedLumina, // lumina
            multisig // admin
        );

        treasuryVesting = new TreasuryVesting(predictedLumina);

        // ──────────────────────────────────────────────────────
        // PHASE 4: Deploy LuminaTokenV2
        // ──────────────────────────────────────────────────────
        lumina = new LuminaTokenV2(
            address(bondVault), address(cexReserve), founderVesting, lbpDeposit, address(treasuryVesting)
        );
        // Verify prediction was correct
        require(address(lumina) == predictedLumina, "Lumina address prediction failed");

        // ──────────────────────────────────────────────────────
        // PHASE 5: Wire ClaimBond -> BondVault (one-shot)
        // ──────────────────────────────────────────────────────
        claimBond.setBondVault(address(bondVault));

        // ──────────────────────────────────────────────────────
        // PHASE 6: SolvencyOracle + AdaptiveFeeDistributor
        // ──────────────────────────────────────────────────────
        solvencyOracle = new SolvencyOracle(address(bondVault), address(capacityOracle), multisig);

        feeDistributor = new AdaptiveFeeDistributor(address(solvencyOracle));

        // ──────────────────────────────────────────────────────
        // PHASE 7: TWAPBurner
        // ──────────────────────────────────────────────────────
        twapBurner = new TWAPBurner(address(usdc), address(lumina), address(swapRouter));

        // ──────────────────────────────────────────────────────
        // PHASE 8: PolicyManagerV2 + CoverRouterV2
        // ──────────────────────────────────────────────────────
        policyManager = new PolicyManagerV2(address(bondVault));
        coverRouter = new CoverRouterV2(address(usdc), address(policyManager), address(twapBurner));

        // Wire PolicyManager -> Router
        policyManager.setRouter(address(coverRouter));

        // Wire BondVault -> PolicyManager (one-shot)
        bondVault.setPolicyManager(address(policyManager));

        // ──────────────────────────────────────────────────────
        // PHASE 9: Marketplace + BuybackEngine
        // ──────────────────────────────────────────────────────
        marketplace = new LuminaBondMarketplace(address(claimBond), address(usdc), address(twapBurner), multisig);

        buybackEngine = new BuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );

        // ──────────────────────────────────────────────────────
        // PHASE 10: Wire TWAPBurner
        // ──────────────────────────────────────────────────────
        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(
            address(buybackEngine), // buybackReserve
            multisig, // opsReserve
            address(maintenanceReserve) // maintenanceReserve
        );
        twapBurner.setCapacityOracle(address(capacityOracle));
        twapBurner.setAuthorizedSender(address(coverRouter), true);
        twapBurner.setAdaptiveMode(true);

        // Grant BURNER_ROLE to TWAPBurner
        lumina.grantRole(lumina.BURNER_ROLE(), address(twapBurner));

        // Authorize BuybackEngine in BondVault (deployer has AUTHORIZED_CALLER_ADMIN_ROLE)
        bondVault.setAuthorizedCaller(address(buybackEngine), true);

        // ──────────────────────────────────────────────────────
        // PHASE 11: Deploy & register test shields
        // ──────────────────────────────────────────────────────
        shield1 = new MockShield(PRODUCT_1, address(policyManager));
        shield2 = new MockShield(PRODUCT_2, address(policyManager));

        policyManager.registerProduct(PRODUCT_1, address(shield1));
        policyManager.registerProduct(PRODUCT_2, address(shield2));

        // ──────────────────────────────────────────────────────
        // PHASE 12: Transfer ownership to multisig
        // ──────────────────────────────────────────────────────
        capacityOracle.transferOwnership(multisig);
        twapBurner.transferOwnership(multisig);
        policyManager.transferOwnership(multisig);
        coverRouter.transferOwnership(multisig);
        treasuryVesting.transferOwnership(multisig);

        // Grant DEFAULT_ADMIN_ROLE on lumina to multisig, then revoke from deployer
        lumina.grantRole(lumina.DEFAULT_ADMIN_ROLE(), multisig);
        lumina.revokeRole(lumina.DEFAULT_ADMIN_ROLE(), deployer);

        // Transfer BondVault admin roles to multisig
        bondVault.grantRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), multisig);
        bondVault.grantRole(bondVault.DEFAULT_ADMIN_ROLE(), multisig);
        bondVault.revokeRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), deployer);
        bondVault.revokeRole(bondVault.DEFAULT_ADMIN_ROLE(), deployer);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: Correct token distribution (70/14/8/5/3)
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_CorrectBalances() public view {
        assertEq(lumina.totalSupply(), 100_000_000e18, "Total supply must be 100M");
        assertEq(lumina.balanceOf(address(bondVault)), 70_000_000e18, "BondVault must hold 70M");
        assertEq(lumina.balanceOf(address(cexReserve)), 14_000_000e18, "CEX Reserve must hold 14M");
        assertEq(lumina.balanceOf(founderVesting), 8_000_000e18, "Founder must hold 8M");
        assertEq(lumina.balanceOf(lbpDeposit), 5_000_000e18, "LBP must hold 5M");
        assertEq(lumina.balanceOf(address(treasuryVesting)), 3_000_000e18, "Treasury must hold 3M");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: Roles configured correctly
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_RolesConfigured() public view {
        // BURNER_ROLE granted to TWAPBurner
        assertTrue(lumina.hasRole(lumina.BURNER_ROLE(), address(twapBurner)), "TWAPBurner must have BURNER_ROLE");

        // TWAPBurner authorizedSenders includes coverRouter
        assertTrue(
            twapBurner.authorizedSenders(address(coverRouter)), "CoverRouter must be authorized sender on TWAPBurner"
        );

        // Multisig has DEFAULT_ADMIN_ROLE on lumina
        assertTrue(
            lumina.hasRole(lumina.DEFAULT_ADMIN_ROLE(), multisig), "Multisig must have DEFAULT_ADMIN_ROLE on lumina"
        );

        // Deployer no longer has DEFAULT_ADMIN_ROLE on lumina
        assertFalse(
            lumina.hasRole(lumina.DEFAULT_ADMIN_ROLE(), deployer), "Deployer must NOT have DEFAULT_ADMIN_ROLE on lumina"
        );

        // BuybackEngine: multisig has BUYBACK_OPERATOR_ROLE
        assertTrue(
            buybackEngine.hasRole(buybackEngine.BUYBACK_OPERATOR_ROLE(), multisig),
            "Multisig must have BUYBACK_OPERATOR_ROLE on BuybackEngine"
        );

        // BondVault: BuybackEngine is authorized caller
        assertTrue(
            bondVault.authorizedCallers(address(buybackEngine)), "BuybackEngine must be authorized caller in BondVault"
        );

        // BondVault: multisig has AUTHORIZED_CALLER_ADMIN_ROLE
        assertTrue(
            bondVault.hasRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), multisig),
            "Multisig must have AUTHORIZED_CALLER_ADMIN_ROLE on BondVault"
        );

        // BondVault: deployer no longer has admin roles
        assertFalse(
            bondVault.hasRole(bondVault.DEFAULT_ADMIN_ROLE(), deployer),
            "Deployer must NOT have DEFAULT_ADMIN_ROLE on BondVault"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: Wiring correct
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_WiringCorrect() public view {
        // TWAPBurner.feeDistributor
        assertEq(twapBurner.feeDistributor(), address(feeDistributor), "TWAPBurner.feeDistributor wrong");

        // TWAPBurner.adaptiveModeEnabled
        assertTrue(twapBurner.adaptiveModeEnabled(), "Adaptive mode must be enabled");

        // TWAPBurner.capacityOracle
        assertEq(twapBurner.capacityOracle(), address(capacityOracle), "TWAPBurner.capacityOracle wrong");

        // TWAPBurner reserves
        assertEq(twapBurner.buybackReserve(), address(buybackEngine), "buybackReserve wrong");
        assertEq(twapBurner.opsReserve(), multisig, "opsReserve wrong");
        assertEq(twapBurner.maintenanceReserve(), address(maintenanceReserve), "maintenanceReserve wrong");

        // PolicyManager.router
        assertEq(policyManager.router(), address(coverRouter), "PolicyManager.router wrong");

        // BondVault.policyManager
        assertEq(bondVault.policyManager(), address(policyManager), "BondVault.policyManager wrong");

        // ClaimBond.bondVault
        assertEq(claimBond.bondVault(), address(bondVault), "ClaimBond.bondVault wrong");

        // BondVault.priceOracle
        assertEq(address(bondVault.priceOracle()), address(capacityOracle), "BondVault.priceOracle wrong");

        // CoverRouter links
        assertEq(address(coverRouter.usdc()), address(usdc), "CoverRouter.usdc wrong");
        assertEq(address(coverRouter.policyManager()), address(policyManager), "CoverRouter.policyManager wrong");
        assertEq(address(coverRouter.twapBurner()), address(twapBurner), "CoverRouter.twapBurner wrong");

        // SolvencyOracle immutables
        assertEq(address(solvencyOracle.bondVault()), address(bondVault), "SolvencyOracle.bondVault wrong");
        assertEq(
            address(solvencyOracle.capacityOracle()), address(capacityOracle), "SolvencyOracle.capacityOracle wrong"
        );

        // AdaptiveFeeDistributor -> SolvencyOracle
        assertEq(
            address(feeDistributor.solvencyOracle()), address(solvencyOracle), "FeeDistributor.solvencyOracle wrong"
        );

        // Marketplace -> TWAPBurner
        assertEq(marketplace.twapBurner(), address(twapBurner), "Marketplace.twapBurner wrong");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: Ownership transferred to multisig
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_OwnershipTransferredToMultisig() public view {
        assertEq(capacityOracle.owner(), multisig, "CapacityOracle owner must be multisig");
        assertEq(twapBurner.owner(), multisig, "TWAPBurner owner must be multisig");
        assertEq(policyManager.owner(), multisig, "PolicyManager owner must be multisig");
        assertEq(coverRouter.owner(), multisig, "CoverRouter owner must be multisig");
        assertEq(treasuryVesting.owner(), multisig, "TreasuryVesting owner must be multisig");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: Shields registered in PolicyManager
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_ShieldsRegistered() public view {
        // Shield 1
        assertEq(policyManager.productShield(PRODUCT_1), address(shield1), "Shield 1 not registered");
        assertTrue(policyManager.productActive(PRODUCT_1), "Shield 1 not active");

        // Shield 2
        assertEq(policyManager.productShield(PRODUCT_2), address(shield2), "Shield 2 not registered");
        assertTrue(policyManager.productActive(PRODUCT_2), "Shield 2 not active");

        // Product count
        assertEq(policyManager.getProductCount(), 2, "Should have 2 products");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: BondVault.setPolicyManager one-shot
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_SetPolicyManagerOneShot() public {
        // Already set during setUp. Trying again must revert.
        vm.expectRevert("PolicyManager already set");
        bondVault.setPolicyManager(makeAddr("anotherPM"));
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: ClaimBond.setBondVault one-shot
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_SetBondVaultOneShot() public {
        // Already set during setUp. Trying again must revert.
        vm.expectRevert("Already set");
        claimBond.setBondVault(makeAddr("anotherVault"));
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: CapacityOracle returns emergency price (no pool)
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_CapacityOracleEmergencyPrice() public view {
        uint256 price = capacityOracle.getLuminaPrice();
        assertEq(price, EMERGENCY_PRICE, "Should return emergency price when pool is address(0)");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST: SolvencyOracle reads BondVault lumina token correctly
    // ═══════════════════════════════════════════════════════════════

    function test_FullDeploy_SolvencyOracleLuminaWiring() public view {
        assertEq(address(solvencyOracle.lumina()), address(lumina), "SolvencyOracle.lumina must match LuminaTokenV2");
    }
}
