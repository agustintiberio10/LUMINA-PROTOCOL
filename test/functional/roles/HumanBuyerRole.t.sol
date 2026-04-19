// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/token/LuminaTokenV2.sol";
import "../../../src/bonds/ClaimBond.sol";
import "../../../src/bonds/BondVault.sol";
import "../../../src/treasury/CEXLiquidityReserve.sol";
import "../../../src/treasury/MaintenanceReserve.sol";
import "../../../src/core/CoverRouterV2.sol";

// ═══════ INLINE MOCKS ═══════

contract MockPriceOracleHB {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockUSDC_HB {
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

contract MockPolicyManagerHB {
    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external pure returns (uint256) {
        return 1;
    }

    function triggerPayout(bytes32, uint256, bytes calldata) external {}
}

contract MockTWAPBurnerHB {
    function receivePremium(uint256) external {}
}

// ═══════ TEST CONTRACT ═══════

/// @title HumanBuyerRoleAudit
/// @notice Validates that a human buyer (web channel) has the SAME permissions as an AI Agent.
///         The difference is the channel (web UI vs API), not the on-chain permissions.
///         Tests bond issuance, marketplace listing/cancel, redemption at maturity,
///         and denial of admin functions.
contract HumanBuyerRoleAudit is Test {
    // --- System contracts ---
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault bondVault;
    CEXLiquidityReserve cexReserve;
    MaintenanceReserve maintenanceReserve;
    CoverRouterV2 coverRouter;

    // --- Mocks ---
    MockPriceOracleHB oracle;
    MockUSDC_HB usdc;
    MockPolicyManagerHB mockPM;
    MockTWAPBurnerHB mockBurner;

    // --- Actors ---
    address deployer;
    address multisig = makeAddr("multisig");
    address humanBuyer = makeAddr("humanBuyer");

    // --- Computed epoch ---
    uint256 epochId;

    function setUp() public {
        deployer = address(this);

        // Warp past base timestamp
        vm.warp(1767225600 + 60 days);

        // Deploy mocks
        oracle = new MockPriceOracleHB();
        usdc = new MockUSDC_HB();
        mockPM = new MockPolicyManagerHB();
        mockBurner = new MockTWAPBurnerHB();

        // Deploy ClaimBond
        claimBond = new ClaimBond();

        // Deploy LuminaTokenV2
        token = new LuminaTokenV2(
            makeAddr("tempBondVault"), makeAddr("tempCEX"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        // Deploy BondVault with deployer as policyManager (for test issuance)
        bondVault = new BondVault(
            address(token),
            address(claimBond),
            address(oracle),
            deployer // deployer acts as policyManager for bond issuance
        );

        // Wire ClaimBond -> BondVault
        claimBond.setBondVault(address(bondVault));

        // Fund BondVault with LUMINA
        deal(address(token), address(bondVault), 70_000_000e18);

        // Grant AUTHORIZED_CALLER_ADMIN_ROLE to multisig
        bondVault.grantRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), multisig);

        // Deploy CEXLiquidityReserve (multisig gets ALLOCATOR_ROLE)
        cexReserve = new CEXLiquidityReserve(address(token), multisig);
        deal(address(token), address(cexReserve), 14_000_000e18);

        // Deploy MaintenanceReserve (multisig gets SPENDER_ROLE)
        maintenanceReserve = new MaintenanceReserve(address(usdc), multisig);
        usdc.mint(address(maintenanceReserve), 500_000e6);

        // Deploy CoverRouterV2 (deployer is owner via Ownable)
        coverRouter = new CoverRouterV2(address(usdc), address(mockPM), address(mockBurner));

        // Pre-compute epoch for bonds issued at current timestamp
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        epochId = year * 100 + month;
    }

    // ══════════════════════════════════════════════════════════════
    //  HUMAN BUYER — same on-chain permissions as AI Agent
    // ══════════════════════════════════════════════════════════════

    /// @notice Human buyer receives bonds via BondVault.issueBond (called by policyManager).
    ///         This simulates the result of a purchasePolicy flow: a triggered policy issues bonds.
    function test_HumanBuyer_CanPurchasePolicy_Directly() public {
        // Issue bond to humanBuyer (deployer == policyManager for testing)
        bondVault.issueBond(humanBuyer, 500);

        // Verify human has bonds in the correct epoch
        assertEq(claimBond.balanceOf(humanBuyer, epochId), 500);
    }

    /// @notice After bond issuance, the human holds ERC-1155 tokens (ClaimBond NFTs).
    function test_HumanBuyer_ReceivesNFT_WhenBondIssued() public {
        bondVault.issueBond(humanBuyer, 800);

        // Human has 800 bond tokens (each = $1 USD face value) in the maturity epoch
        uint256 balance = claimBond.balanceOf(humanBuyer, epochId);
        assertEq(balance, 800);

        // Verify epoch exists
        (bool exists,,,) = claimBond.getEpochInfo(epochId);
        assertTrue(exists);
    }

    /// @notice Human can approve and transfer their bonds (prerequisite for marketplace listing).
    function test_HumanBuyer_CanListBondInMarketplace() public {
        // Issue bonds to human
        bondVault.issueBond(humanBuyer, 300);

        // Human approves a third party (simulating marketplace) for their bonds
        address mockMarketplace = makeAddr("mockMarketplace");

        vm.prank(humanBuyer);
        claimBond.setApprovalForAll(mockMarketplace, true);

        assertTrue(claimBond.isApprovedForAll(humanBuyer, mockMarketplace));

        // Verify human still owns the bonds
        assertEq(claimBond.balanceOf(humanBuyer, epochId), 300);
    }

    /// @notice Human can cancel approval (revoke marketplace permission).
    function test_HumanBuyer_CanCancelListing() public {
        bondVault.issueBond(humanBuyer, 200);

        address mockMarketplace = makeAddr("mockMarketplace");

        // Approve
        vm.prank(humanBuyer);
        claimBond.setApprovalForAll(mockMarketplace, true);
        assertTrue(claimBond.isApprovedForAll(humanBuyer, mockMarketplace));

        // Revoke approval (cancel)
        vm.prank(humanBuyer);
        claimBond.setApprovalForAll(mockMarketplace, false);
        assertFalse(claimBond.isApprovedForAll(humanBuyer, mockMarketplace));

        // Human still has their bonds
        assertEq(claimBond.balanceOf(humanBuyer, epochId), 200);
    }

    /// @notice After 730+ days maturity, human can redeem bonds for LUMINA.
    function test_HumanBuyer_CanRedeemAtMaturity() public {
        // Issue bonds
        bondVault.issueBond(humanBuyer, 500);
        assertEq(claimBond.balanceOf(humanBuyer, epochId), 500);

        // Warp past maturity (730 days + buffer)
        vm.warp(block.timestamp + 731 days);

        // Human redeems
        vm.prank(humanBuyer);
        bondVault.redeemBond(epochId, 500);

        // Bonds burned
        assertEq(claimBond.balanceOf(humanBuyer, epochId), 0);
        // Human received LUMINA
        assertGt(token.balanceOf(humanBuyer), 0);
    }

    /// @notice Human buyer cannot access any admin/privileged functions.
    function test_HumanBuyer_CannotAccessAdminFunctions() public {
        // Cannot allocate from CEX reserve
        vm.prank(humanBuyer);
        vm.expectRevert();
        cexReserve.allocate(
            humanBuyer,
            1000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "unauthorized attempt"
        );

        // Cannot spend from maintenance reserve
        vm.prank(humanBuyer);
        vm.expectRevert();
        maintenanceReserve.spend(
            humanBuyer, 1000e6, MaintenanceReserve.SpendCategory.Infrastructure, "unauthorized spend"
        );

        // Cannot setAuthorizedCaller on BondVault
        vm.prank(humanBuyer);
        vm.expectRevert();
        bondVault.setAuthorizedCaller(humanBuyer, true);

        // Cannot pause CoverRouter
        vm.prank(humanBuyer);
        vm.expectRevert();
        coverRouter.setPaused(true);

        // Cannot issue bonds directly (only policyManager can)
        vm.prank(humanBuyer);
        vm.expectRevert("Only PolicyManager");
        bondVault.issueBond(humanBuyer, 100);
    }
}
