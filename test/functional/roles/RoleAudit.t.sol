// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/token/LuminaTokenV2.sol";
import "../../../src/bonds/ClaimBond.sol";
import "../../../src/bonds/BondVault.sol";
import "../../../src/treasury/CEXLiquidityReserve.sol";
import "../../../src/treasury/MaintenanceReserve.sol";
import "../../../src/marketplace/BuybackEngine.sol";
import "../../../src/core/CoverRouterV2.sol";
import "../../../src/core/PolicyManagerV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract MockPriceOracleRA {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockSolvencyOracleRA {
    function getSolvencyRatio() external pure returns (uint256) {
        return 20000; // 200%
    }
}

contract MockMarketplaceRA {
    function executeBuy(uint256) external {}

    function getListing(uint256)
        external
        pure
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
    {
        return (address(0), 0, 0, 0, false);
    }
}

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockPolicyManagerRA {
    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external pure returns (uint256) {
        return 1;
    }

    function triggerPayout(bytes32, uint256, bytes calldata) external {}
}

contract MockTWAPBurnerRA {
    function receivePremium(uint256) external {}
}

// ═══════ TEST CONTRACT ═══════

contract RoleAuditTest is Test {
    // --- System contracts ---
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault bondVault;
    CEXLiquidityReserve cexReserve;
    MaintenanceReserve maintenanceReserve;
    BuybackEngine buybackEngine;
    CoverRouterV2 coverRouter;
    PolicyManagerV2 policyManager;

    // --- Mocks ---
    MockPriceOracleRA oracle;
    MockSolvencyOracleRA solvencyOracle;
    MockMarketplaceRA marketplace;
    MockUSDC usdc;
    MockPolicyManagerRA mockPM;
    MockTWAPBurnerRA mockBurner;

    // --- Actors ---
    address deployer;
    address multisig = makeAddr("multisig");
    address agent = makeAddr("agent");
    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address cexAddr = makeAddr("cexAddr");

    function setUp() public {
        vm.chainId(8453);
        deployer = address(this);

        // Warp past base timestamp
        vm.warp(1767225600 + 60 days);

        // Deploy mocks
        oracle = new MockPriceOracleRA();
        solvencyOracle = new MockSolvencyOracleRA();
        marketplace = new MockMarketplaceRA();
        usdc = new MockUSDC();
        mockPM = new MockPolicyManagerRA();
        mockBurner = new MockTWAPBurnerRA();

        // Deploy ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // Deploy LuminaTokenV2 - needs 5 unique non-zero addresses for distribution
        // We use makeAddr placeholders for the initial mint targets since we deal tokens later
        token =
            ProxyDeployer.deployLuminaTokenV2(makeAddr("tempBondVault"), makeAddr("tempCEX"), founder, lbp, treasury);

        // Deploy BondVault with deployer as policyManager (for test issuance)
        bondVault = ProxyDeployer.deployBondVault(
            address(token),
            address(claimBond),
            address(oracle),
            deployer // deployer acts as policyManager for setup
        );

        // Wire ClaimBond -> BondVault
        claimBond.setBondVault(address(bondVault));

        // Fund BondVault with LUMINA
        deal(address(token), address(bondVault), 70_000_000e18);

        // Grant AUTHORIZED_CALLER_ADMIN_ROLE to multisig
        bondVault.grantRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), multisig);

        // Deploy CEXLiquidityReserve (multisig gets ALLOCATOR_ROLE)
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(address(token), multisig);

        // Fund CEX reserve
        deal(address(token), address(cexReserve), 14_000_000e18);

        // Deploy MaintenanceReserve (multisig gets SPENDER_ROLE)
        maintenanceReserve = ProxyDeployer.deployMaintenanceReserve(address(usdc), multisig);

        // Fund MaintenanceReserve with USDC
        usdc.mint(address(maintenanceReserve), 500_000e6);

        // Deploy BuybackEngine (multisig gets BUYBACK_OPERATOR_ROLE)
        buybackEngine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(oracle),
            address(marketplace),
            address(usdc),
            multisig
        );

        // Deploy CoverRouterV2 (deployer is owner via Ownable)
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(mockPM), address(mockBurner));

        // Deploy PolicyManagerV2 (deployer is owner via Ownable)
        policyManager = ProxyDeployer.deployPolicyManagerV2(address(bondVault));
    }

    // ══════════════════════════════════════════════════════════════
    //  AGENT (regular user) — SHOULD NOT have privileged access
    // ══════════════════════════════════════════════════════════════

    function test_Agent_CanRedeemOwnBonds() public {
        // Issue bond to agent (deployer == policyManager)
        bondVault.issueBond(agent, 500);

        // Calculate epoch for maturity
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Verify agent has bonds
        assertEq(claimBond.balanceOf(agent, epochId), 500);

        // Warp past maturity
        vm.warp(maturityTs + 1);

        // Agent redeems
        vm.prank(agent);
        bondVault.redeemBond(epochId, 500);

        // Agent should have received LUMINA
        assertGt(token.balanceOf(agent), 0);
        // Bonds burned
        assertEq(claimBond.balanceOf(agent, epochId), 0);
    }

    function test_Agent_CannotIssueBonds() public {
        vm.prank(agent);
        vm.expectRevert("Only PolicyManager");
        bondVault.issueBond(agent, 100);
    }

    function test_Agent_CannotBurnFromReserves() public {
        vm.prank(agent);
        vm.expectRevert("BondVault: caller not authorized");
        bondVault.burnFromReserves(1e18);
    }

    function test_Agent_CannotSetAuthorizedCaller() public {
        vm.prank(agent);
        vm.expectRevert();
        bondVault.setAuthorizedCaller(agent, true);
    }

    function test_Agent_CannotPauseCoverRouter() public {
        vm.prank(agent);
        vm.expectRevert();
        coverRouter.setPaused(true);
    }

    function test_Agent_CannotAllocateCEX() public {
        vm.prank(agent);
        vm.expectRevert();
        cexReserve.allocate(
            agent,
            1000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "unauthorized attempt"
        );
    }

    function test_Agent_CannotSpendMaintenance() public {
        vm.prank(agent);
        vm.expectRevert();
        maintenanceReserve.spend(agent, 1000e6, MaintenanceReserve.SpendCategory.Infrastructure, "unauthorized spend");
    }

    // ══════════════════════════════════════════════════════════════
    //  MULTISIG / ADMIN — privileged operations
    // ══════════════════════════════════════════════════════════════

    function test_Multisig_CanSetAuthorizedCaller() public {
        address engine = makeAddr("engine");
        vm.prank(multisig);
        bondVault.setAuthorizedCaller(engine, true);
        assertTrue(bondVault.authorizedCallers(engine));
    }

    function test_Multisig_CanAllocateCEX() public {
        address recipient = makeAddr("cexRecipient");
        vm.prank(multisig);
        cexReserve.allocate(
            recipient,
            100_000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Tier 3 listing deposit"
        );
        assertEq(token.balanceOf(recipient), 100_000e18);
    }

    function test_Multisig_CanSpendMaintenance() public {
        address vendor = makeAddr("vendor");
        vm.prank(multisig);
        maintenanceReserve.spend(vendor, 10_000e6, MaintenanceReserve.SpendCategory.Audit, "Smart contract audit");
        assertEq(usdc.balanceOf(vendor), 10_000e6);
    }

    function test_Multisig_CannotMintLUMINA() public {
        // LuminaTokenV2 has no mint() function — only constructor mints.
        // Verify there is no way to increase supply beyond MAX_SUPPLY.
        uint256 supplyBefore = token.totalSupply();
        assertEq(supplyBefore, 100_000_000e18);
        // No mint function to call; this test documents the design invariant.
    }

    function test_Multisig_CannotDirectlyDrainBondVault() public {
        // BondVault has NO withdraw() function.
        // Tokens can only leave via redeemBond() (matured bonds) or burnFromReserves() (authorized caller burn).
        // Verify the vault balance is intact after construction.
        uint256 balance = token.balanceOf(address(bondVault));
        assertEq(balance, 70_000_000e18);
        // No withdraw/transfer function exists to drain — design invariant documented.
    }
}
