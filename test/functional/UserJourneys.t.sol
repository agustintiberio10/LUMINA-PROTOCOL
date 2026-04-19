// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";
import "../../src/treasury/CEXLiquidityReserve.sol";
import "../../src/treasury/MaintenanceReserve.sol";
import "../../src/marketplace/BuybackEngine.sol";
import "../../src/marketplace/LuminaBondMarketplace.sol";

// ═══════ INLINE MOCKS ═══════

contract MockPriceOracleUJ {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockSolvencyOracleUJ {
    function getSolvencyRatio() external pure returns (uint256) {
        return 20000; // 200%
    }
}

contract MockMarketplaceUJ {
    function executeBuy(uint256) external {}

    function getListing(uint256)
        external
        pure
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
    {
        return (address(0), 0, 0, 0, false);
    }
}

contract MockUSDCuj {
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

// ═══════ TEST CONTRACT ═══════

contract UserJourneysTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault bondVault;
    CEXLiquidityReserve cexReserve;
    MaintenanceReserve maintenanceReserve;
    BuybackEngine buybackEngine;
    LuminaBondMarketplace marketplace;

    MockPriceOracleUJ oracle;
    MockSolvencyOracleUJ solvencyOracle;
    MockMarketplaceUJ mockMktForEngine;
    MockUSDCuj usdc;

    address deployer;
    address multisig = makeAddr("multisig");
    address agent = makeAddr("agent");
    address buyer = makeAddr("buyer");
    address twapBurner = makeAddr("twapBurner");

    uint256 constant BASE_TS = 1767225600;

    function setUp() public {
        deployer = address(this);
        vm.warp(BASE_TS + 60 days);

        // Deploy mocks
        oracle = new MockPriceOracleUJ();
        solvencyOracle = new MockSolvencyOracleUJ();
        mockMktForEngine = new MockMarketplaceUJ();
        usdc = new MockUSDCuj();

        // Deploy core
        claimBond = new ClaimBond();

        token = new LuminaTokenV2(
            makeAddr("tempBondVault"), makeAddr("tempCEX"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        bondVault = new BondVault(address(token), address(claimBond), address(oracle), deployer);

        claimBond.setBondVault(address(bondVault));
        deal(address(token), address(bondVault), 70_000_000e18);

        // CEX Reserve
        cexReserve = new CEXLiquidityReserve(address(token), multisig);
        deal(address(token), address(cexReserve), 14_000_000e18);

        // Maintenance Reserve
        maintenanceReserve = new MaintenanceReserve(address(usdc), multisig);
        usdc.mint(address(maintenanceReserve), 500_000e6);

        // Marketplace (real, for listing tests)
        marketplace = new LuminaBondMarketplace(address(claimBond), address(usdc), twapBurner, multisig);

        // BuybackEngine (uses mock marketplace for engine-specific tests)
        buybackEngine = new BuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(oracle),
            address(mockMktForEngine),
            address(usdc),
            multisig
        );
    }

    // ═══════ JOURNEY 1: Agent buys bonds and redeems after 730 days ═══════

    function test_Journey_Agent_BuysAndRedeems_30Days() public {
        // Step 1: Agent receives bonds (via policy trigger, deployer == policyManager)
        bondVault.issueBond(agent, 800);

        // Calculate epoch
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Verify agent holds 800 bond tokens ($800 face value)
        assertEq(claimBond.balanceOf(agent, epochId), 800);
        assertEq(bondVault.totalCommittedUSD(), 800e18);

        // Step 2: Wait 730 days for maturity
        vm.warp(maturityTs + 1);
        assertTrue(claimBond.isMatured(epochId));

        // Step 3: Agent redeems bonds for LUMINA
        uint256 agentBalBefore = token.balanceOf(agent);
        vm.prank(agent);
        bondVault.redeemBond(epochId, 800);

        // Verify outcomes
        uint256 agentBalAfter = token.balanceOf(agent);
        uint256 luminaReceived = agentBalAfter - agentBalBefore;

        // $800 at $0.036/LUMINA = 800 * 1e36 / 0.036e18 = ~22,222 LUMINA
        assertGt(luminaReceived, 22_000e18);
        assertLt(luminaReceived, 23_000e18);
        assertEq(claimBond.balanceOf(agent, epochId), 0);
        assertEq(bondVault.totalCommittedUSD(), 0);
    }

    // ═══════ JOURNEY 2: Agent lists bonds on marketplace ═══════

    function test_Journey_Agent_ListsOnMarketplace() public {
        // Step 1: Agent gets bonds
        bondVault.issueBond(agent, 500);

        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        assertEq(claimBond.balanceOf(agent, epochId), 500);

        // Step 2: Agent approves marketplace and lists bonds at $400 USDC (discount)
        vm.prank(agent);
        claimBond.setApprovalForAll(address(marketplace), true);

        vm.prank(agent);
        uint256 listingId = marketplace.list(epochId, 500, 400e6);

        // Bonds transferred to marketplace
        assertEq(claimBond.balanceOf(agent, epochId), 0);
        assertEq(claimBond.balanceOf(address(marketplace), epochId), 500);

        // Step 3: Buyer purchases the listing
        // Buyer needs USDC: price + buyer fee (1.5%)
        uint256 buyerFee = (400e6 * 150) / 10000; // 6e6
        uint256 totalCost = 400e6 + buyerFee;
        usdc.mint(buyer, totalCost);

        vm.prank(buyer);
        usdc.approve(address(marketplace), totalCost);

        vm.prank(buyer);
        marketplace.executeBuy(listingId);

        // Buyer now holds the bonds
        assertEq(claimBond.balanceOf(buyer, epochId), 500);

        // Seller received price minus seller fee
        uint256 sellerFee = (400e6 * 150) / 10000;
        assertEq(usdc.balanceOf(agent), 400e6 - sellerFee);

        // Fees went to twapBurner
        assertEq(usdc.balanceOf(twapBurner), sellerFee + buyerFee);
    }

    // ═══════ JOURNEY 3: Multisig daily operations ═══════

    function test_Journey_Multisig_DailyOps() public {
        // Step 1: Multisig allocates from CEX reserve
        address cexPartner = makeAddr("cexPartner");
        vm.prank(multisig);
        cexReserve.allocate(
            cexPartner,
            500_000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_2,
            "Tier 2 CEX listing deposit"
        );
        assertEq(token.balanceOf(cexPartner), 500_000e18);

        // Step 2: Multisig pays for an audit
        address auditor = makeAddr("auditor");
        vm.prank(multisig);
        maintenanceReserve.spend(
            auditor, 50_000e6, MaintenanceReserve.SpendCategory.Audit, "Trail of Bits audit Phase 7"
        );
        assertEq(usdc.balanceOf(auditor), 50_000e6);

        // Step 3: Multisig configures buyback (must wait 365 days after deployment)
        vm.warp(block.timestamp + 365 days);

        vm.prank(multisig);
        buybackEngine.setDailyBuyback(
            10_000e6, // $10K daily budget
            80, // max 80% of face value
            24 // 24 hour duration
        );

        // Verify config
        (uint256 budget, uint256 maxPct, uint256 validUntil, uint256 spent) = buybackEngine.dailyConfig();
        assertEq(budget, 10_000e6);
        assertEq(maxPct, 80);
        assertGt(validUntil, block.timestamp);
        assertEq(spent, 0);
    }
}
