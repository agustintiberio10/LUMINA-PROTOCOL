// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/token/LuminaTokenV2.sol";
import "../../../src/bonds/ClaimBond.sol";
import "../../../src/bonds/BondVault.sol";
import "../../../src/marketplace/LuminaBondMarketplace.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract MockPriceOracleSB {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockUSDC_SB {
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

/// @title BondSecondaryBuyerAudit
/// @notice Validates the secondary market flow: a buyer purchases bonds from another holder
///         on the LuminaBondMarketplace, paying price + 1.5% buyer fee. Seller receives
///         price - 1.5% seller fee. Both fees go to twapBurner.
contract BondSecondaryBuyerAudit is Test {
    // --- System contracts ---
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault bondVault;
    LuminaBondMarketplace marketplace;

    // --- Mocks ---
    MockPriceOracleSB oracle;
    MockUSDC_SB usdc;

    // --- Actors ---
    address deployer;
    address multisig = makeAddr("multisig");
    address originalHolder = makeAddr("originalHolder");
    address secondaryBuyer = makeAddr("secondaryBuyer");
    address twapBurner = makeAddr("twapBurner");

    // --- Computed epoch ---
    uint256 epochId;

    function setUp() public {
        vm.chainId(8453);
        deployer = address(this);

        // Warp past base timestamp
        vm.warp(1767225600 + 60 days);

        // Deploy mocks
        oracle = new MockPriceOracleSB();
        usdc = new MockUSDC_SB();

        // Deploy ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // Deploy LuminaTokenV2
        token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("tempBondVault"), makeAddr("tempCEX"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        // Deploy BondVault with deployer as policyManager (for test issuance)
        bondVault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), deployer);

        // Wire ClaimBond -> BondVault
        claimBond.setBondVault(address(bondVault));

        // Fund BondVault with LUMINA
        deal(address(token), address(bondVault), 70_000_000e18);

        // Deploy marketplace (multisig is admin)
        marketplace = ProxyDeployer.deployLuminaBondMarketplace(address(claimBond), address(usdc), twapBurner, multisig);
        // [FIX-#18] Whitelist marketplace so ClaimBond allows its transfers.
        claimBond.setAuthorizedOperator(address(marketplace), true);

        // Pre-compute epoch for bonds issued at current timestamp
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        epochId = year * 100 + month;

        // Issue bonds to originalHolder
        bondVault.issueBond(originalHolder, 1000);
        assertEq(claimBond.balanceOf(originalHolder, epochId), 1000);
    }

    // ═══════ HELPER ═══════

    /// @dev Original holder lists bonds on marketplace and returns listingId.
    function _listBonds(uint256 amount, uint256 priceUSDC) internal returns (uint256 listingId) {
        vm.startPrank(originalHolder);
        claimBond.setApprovalForAll(address(marketplace), true);
        listingId = marketplace.list(epochId, amount, priceUSDC);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════
    //  SECONDARY BUYER — purchases bonds from marketplace
    // ══════════════════════════════════════════════════════════════

    /// @notice Secondary buyer purchases a listed bond. Verifies NFT transfer,
    ///         seller receives price minus 1.5% fee, twapBurner gets 3% total fees.
    function test_SecondaryBuyer_CanBuyListedBond() public {
        uint256 amount = 500;
        uint256 priceUSDC = 400e6; // $400 for 500 bonds (discount)

        uint256 listingId = _listBonds(amount, priceUSDC);

        // Calculate expected fees
        uint256 sellerFee = (priceUSDC * 150) / 10000; // 1.5%
        uint256 buyerFee = (priceUSDC * 150) / 10000; // 1.5%
        uint256 totalBuyerPays = priceUSDC + buyerFee;
        uint256 sellerReceives = priceUSDC - sellerFee;

        // Fund secondary buyer with USDC
        usdc.mint(secondaryBuyer, totalBuyerPays);

        // Secondary buyer approves marketplace and buys
        vm.startPrank(secondaryBuyer);
        usdc.approve(address(marketplace), totalBuyerPays);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        // Buyer has the bonds now
        assertEq(claimBond.balanceOf(secondaryBuyer, epochId), amount);
        // [legacy-migration] F-14 pull-payment: seller proceeds are booked to
        // pendingWithdrawals; the seller must withdraw() before they hold USDC.
        vm.prank(originalHolder);
        marketplace.withdraw();
        // Seller received price minus seller fee
        assertEq(usdc.balanceOf(originalHolder), sellerReceives);
        // TwapBurner received both fees
        assertEq(usdc.balanceOf(twapBurner), sellerFee + buyerFee);
        // Buyer spent all their USDC
        assertEq(usdc.balanceOf(secondaryBuyer), 0);
    }

    /// @notice Verify the buyer pays exactly price + 1.5% buyer fee.
    function test_SecondaryBuyer_PaysBuyerFee_1_5Percent() public {
        uint256 amount = 200;
        uint256 priceUSDC = 180e6; // $180

        uint256 listingId = _listBonds(amount, priceUSDC);

        uint256 expectedBuyerFee = (priceUSDC * 150) / 10000; // 1.5% = $2.70
        uint256 totalBuyerPays = priceUSDC + expectedBuyerFee;

        // Verify via marketplace.calculateFees
        (, uint256 buyerFee,) = marketplace.calculateFees(priceUSDC);
        assertEq(buyerFee, expectedBuyerFee);

        // Fund and buy
        usdc.mint(secondaryBuyer, totalBuyerPays);
        vm.startPrank(secondaryBuyer);
        usdc.approve(address(marketplace), totalBuyerPays);

        uint256 balanceBefore = usdc.balanceOf(secondaryBuyer);
        marketplace.executeBuy(listingId);
        uint256 balanceAfter = usdc.balanceOf(secondaryBuyer);
        vm.stopPrank();

        // Buyer paid exactly totalBuyerPays
        assertEq(balanceBefore - balanceAfter, totalBuyerPays);
    }

    /// @notice Secondary buyer redeems purchased bonds after maturity for LUMINA.
    function test_SecondaryBuyer_CanRedeemPurchasedBond() public {
        uint256 amount = 300;
        uint256 priceUSDC = 250e6;

        uint256 listingId = _listBonds(amount, priceUSDC);

        // Buy the bonds
        uint256 buyerFee = (priceUSDC * 150) / 10000;
        uint256 totalPays = priceUSDC + buyerFee;
        usdc.mint(secondaryBuyer, totalPays);

        vm.startPrank(secondaryBuyer);
        usdc.approve(address(marketplace), totalPays);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        // Verify buyer owns bonds
        assertEq(claimBond.balanceOf(secondaryBuyer, epochId), amount);

        // Warp past maturity (730 days + buffer)
        vm.warp(block.timestamp + 731 days);

        // Redeem
        vm.prank(secondaryBuyer);
        bondVault.redeemBond(epochId, amount);

        // Bonds burned
        assertEq(claimBond.balanceOf(secondaryBuyer, epochId), 0);
        // Buyer received LUMINA
        assertGt(token.balanceOf(secondaryBuyer), 0);
    }

    /// @notice Both seller fee (1.5%) and buyer fee (1.5%) go to twapBurner address.
    function test_SecondaryBuyer_FeesGoToTWAPBurner() public {
        uint256 amount = 100;
        uint256 priceUSDC = 90e6; // $90

        uint256 listingId = _listBonds(amount, priceUSDC);

        uint256 sellerFee = (priceUSDC * 150) / 10000; // $1.35
        uint256 buyerFee = (priceUSDC * 150) / 10000; // $1.35
        uint256 totalFees = sellerFee + buyerFee; // $2.70
        uint256 totalPays = priceUSDC + buyerFee;

        uint256 twapBefore = usdc.balanceOf(twapBurner);

        usdc.mint(secondaryBuyer, totalPays);
        vm.startPrank(secondaryBuyer);
        usdc.approve(address(marketplace), totalPays);
        marketplace.executeBuy(listingId);
        vm.stopPrank();

        uint256 twapAfter = usdc.balanceOf(twapBurner);

        // TwapBurner received exactly both fees combined
        assertEq(twapAfter - twapBefore, totalFees);
        // Verify the 3% total (sellerFee + buyerFee = 3% of price)
        assertEq(totalFees, (priceUSDC * 300) / 10000);
    }
}
