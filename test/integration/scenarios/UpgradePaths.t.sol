// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../../src/interfaces/IDexRouter.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {LuminaBondMarketplace} from "../../../src/marketplace/LuminaBondMarketplace.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {MockFeeDistributor} from "../../mocks/MockFeeDistributor.sol";

// ═══════ INLINE MOCKS ═══════

contract MockUSDCUpgrade is IERC20 {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockSwapRouterUpgrade is IDexRouter {
    IERC20 public lumina;
    uint256 public rate = 27;

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * rate * 1e12);
        lumina.transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract MockCapacityOracleUpgrade {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

contract UpgradePathsTest is Test {
    using ProxyDeployer for *;

    LuminaTokenV2 token;
    MockUSDCUpgrade usdc;
    MockSwapRouterUpgrade swapRouter;
    TWAPBurner twapBurner;
    MockFeeDistributor feeDistributorA;
    MockFeeDistributor feeDistributorB;
    BondVault bondVault;
    ClaimBond claimBond;
    MockCapacityOracleUpgrade capacityOracle;
    LuminaBondMarketplace marketplace;

    address admin = makeAddr("admin");
    address buybackReserve = makeAddr("buybackReserve");
    address opsReserve = makeAddr("opsReserve");
    address maintenanceReserve = makeAddr("maintenanceReserve");

    function setUp() public {
        vm.warp(1_770_000_000); // after Jan 1 2026 (BASE_TS = 1767225600) for valid bond epochs

        usdc = new MockUSDCUpgrade();
        capacityOracle = new MockCapacityOracleUpgrade(0.036e18);

        token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        swapRouter = new MockSwapRouterUpgrade(address(token));
        deal(address(token), address(swapRouter), 5_000_000e18);

        // TWAPBurner
        twapBurner = ProxyDeployer.deployTWAPBurner(address(usdc), address(token), address(swapRouter));
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));

        // Two fee distributors
        feeDistributorA = new MockFeeDistributor();
        feeDistributorB = new MockFeeDistributor();
        // Set different distributions
        feeDistributorA.setDistribution(8500, 800, 200, 500); // 85/8/2/5
        feeDistributorB.setDistribution(6500, 2500, 500, 500); // 65/25/5/5

        // Configure TWAPBurner adaptive mode with distributor A
        twapBurner.setFeeDistributor(address(feeDistributorA));
        twapBurner.setReserves(buybackReserve, opsReserve, maintenanceReserve);
        twapBurner.setAdaptiveMode(true);

        // ClaimBond + BondVault (for test 2)
        claimBond = ProxyDeployer.deployClaimBond();
        address policyManager = address(this); // act as PM
        bondVault =
            ProxyDeployer.deployBondVault(address(token), address(claimBond), address(capacityOracle), policyManager);
        deal(address(token), address(bondVault), 70_000_000e18);
        claimBond.setBondVault(address(bondVault));

        // Marketplace (for test 3)
        marketplace =
            ProxyDeployer.deployLuminaBondMarketplace(address(claimBond), address(usdc), address(twapBurner), admin);
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 1: Change fee distributor on TWAPBurner
    // ═══════════════════════════════════════════════════════════════

    function test_Upgrade_ChangeFeeDistributor() public {
        // Fund TWAPBurner
        usdc.mint(address(twapBurner), 10_000e6);

        // Execute burn with distributor A (85/8/2/5)
        twapBurner.executeBurn();

        uint256 buybackA = usdc.balanceOf(buybackReserve);
        uint256 opsA = usdc.balanceOf(opsReserve);
        assertEq(buybackA, 800e6, "Distributor A: buyback should be 8%");
        assertEq(opsA, 200e6, "Distributor A: ops should be 2%");

        // Switch to distributor B
        twapBurner.setFeeDistributor(address(feeDistributorB));

        // Fund again and wait for cooldown
        usdc.mint(address(twapBurner), 10_000e6);
        vm.warp(block.timestamp + 901);

        twapBurner.executeBurn();

        // Distributor B: 65/25/5/5 on 10_000
        uint256 buybackTotal = usdc.balanceOf(buybackReserve);
        uint256 opsTotal = usdc.balanceOf(opsReserve);
        assertEq(buybackTotal - buybackA, 2500e6, "Distributor B: buyback should be 25%");
        assertEq(opsTotal - opsA, 500e6, "Distributor B: ops should be 5%");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 2: Revoke authorized caller from BondVault
    // ═══════════════════════════════════════════════════════════════

    function test_Upgrade_RevokeAuthorizedCaller() public {
        address caller = makeAddr("buybackEngine");

        // Authorize caller (we are policyManager)
        bondVault.setAuthorizedCaller(caller, true);
        assertTrue(bondVault.authorizedCallers(caller), "Caller should be authorized");

        // Issue a bond to create some obligations
        bondVault.issueBond(makeAddr("holder"), 100); // $100
        assertGt(bondVault.totalCommittedUSD(), 0, "Should have commitments");

        // Caller can decrease obligations
        vm.prank(caller);
        bondVault.decreaseObligations(50e18); // reduce $50 in 18-dec USD-wei

        // Now revoke authorization
        bondVault.setAuthorizedCaller(caller, false);
        assertFalse(bondVault.authorizedCallers(caller), "Caller should be revoked");

        // Caller can no longer call decreaseObligations
        vm.prank(caller);
        vm.expectRevert("BondVault: caller not authorized");
        bondVault.decreaseObligations(50e18);

        // Caller can no longer call burnFromReserves
        vm.prank(caller);
        vm.expectRevert("BondVault: caller not authorized");
        bondVault.burnFromReserves(1e18);
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 3: Change TWAPBurner on marketplace
    // ═══════════════════════════════════════════════════════════════

    function test_Upgrade_ChangeTwapBurnerOnMarketplace() public {
        // Initial twapBurner is set
        assertEq(marketplace.twapBurner(), address(twapBurner), "Initial burner should match");

        // Create new burner address
        address newBurner = makeAddr("newTwapBurner");

        // Admin changes the twapBurner on marketplace
        vm.prank(admin);
        marketplace.setTwapBurner(newBurner);

        assertEq(marketplace.twapBurner(), newBurner, "Marketplace should point to new burner");

        // Verify fees go to new address by simulating a trade
        // Setup: mint bonds, list them, buy them
        // Issue a bond for a seller
        address seller = makeAddr("seller");
        bondVault.issueBond(seller, 100); // $100 bond

        uint256 maturityTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Seller lists bonds
        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 50, 40e6); // 50 bonds at $40 USDC
        vm.stopPrank();

        // Buyer buys
        address buyer = makeAddr("buyer");
        usdc.mint(buyer, 100e6);
        vm.startPrank(buyer);
        // Total buyer pays: 40e6 + 1.5% fee = 40e6 + 600_000 = 40_600_000
        usdc.approve(address(marketplace), 50e6);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        // Fees should have gone to newBurner
        // Seller fee: 40e6 * 150 / 10000 = 600_000
        // Buyer fee: 40e6 * 150 / 10000 = 600_000
        // Total fees to newBurner: 1_200_000
        uint256 newBurnerBalance = usdc.balanceOf(newBurner);
        assertEq(newBurnerBalance, 1_200_000, "Fees should go to new burner address");

        // Old burner should have received nothing from this trade
        uint256 oldBurnerBalance = usdc.balanceOf(address(twapBurner));
        assertEq(oldBurnerBalance, 0, "Old burner should receive no fees");
    }
}
