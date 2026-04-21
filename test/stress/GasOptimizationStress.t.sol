// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract GasMockERC20 is ERC20 {
    constructor() ERC20("MockLUMINA", "mLUM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract GasMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract GasMockPriceOracle {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

// ═══════ TEST CONTRACT ═══════

contract GasOptimizationStress is Test {
    uint256 constant BASE_TS = 1767225600;

    BondVault vault;
    ClaimBond claimBond;
    GasMockERC20 lumina;
    GasMockPriceOracle oracle;
    GasMockUSDC usdc;
    LuminaBondMarketplace marketplace;

    address admin = address(0xAD);
    address twapBurner = address(0xBBBB);
    address seller = address(0x5E11);
    address buyer = address(0xBEEF);

    uint256 constant EPOCH_ID = 202804;

    function setUp() public {
        vm.warp(BASE_TS + 60 days);

        lumina = new GasMockERC20();
        oracle = new GasMockPriceOracle(0.036e18);
        usdc = new GasMockUSDC();
        claimBond = ProxyDeployer.deployClaimBond();

        // Deploy BondVault with address(this) as policyManager
        vault = ProxyDeployer.deployBondVault(address(lumina), address(claimBond), address(oracle), address(this));

        claimBond.setBondVault(address(vault));

        // Fund vault with 70M LUMINA
        lumina.mint(address(vault), 70_000_000e18);

        // Deploy marketplace
        marketplace = new LuminaBondMarketplace(address(claimBond), address(usdc), twapBurner, admin);
    }

    /// @notice Measure gas for issueBond. Must be under 300k gas.
    function test_Gas_IssueBond_Under300kGas() public {
        address user = address(0xCAFE);

        uint256 gasBefore = gasleft();
        vault.issueBond(user, 100);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 300_000, "issueBond exceeds 300k gas");
    }

    /// @notice Measure gas for redeemBond. Must be under 500k gas.
    function test_Gas_RedeemBond_Under500kGas() public {
        address user = address(0xCAFE);

        // Issue a bond first
        vault.issueBond(user, 100);

        // Calculate epoch
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Warp past maturity
        uint256 epochMaturity = BASE_TS + ((year - 2026) * 12 + (month - 1)) * 2629746;
        vm.warp(epochMaturity + 1);

        // Measure gas for redeem
        vm.prank(user);
        uint256 gasBefore = gasleft();
        vault.redeemBond(epochId, 100);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 500_000, "redeemBond exceeds 500k gas");
    }

    /// @notice Measure gas for marketplace list. Must be under 200k gas.
    function test_Gas_ListBond_Under200kGas() public {
        // Issue bond to seller via BondVault (which mints via ClaimBond)
        vault.issueBond(seller, 50);

        // Calculate epoch for the issued bond
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Seller approves marketplace
        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);

        uint256 gasBefore = gasleft();
        marketplace.list(epochId, 50, 40e6);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        assertLt(gasUsed, 200_000, "list exceeds 200k gas");
    }

    /// @notice Measure gas for marketplace executeBuy. Must be under 300k gas.
    function test_Gas_ExecuteBuy_Under300kGas() public {
        uint256 priceUSDC = 40e6;

        // Issue bond to seller
        vault.issueBond(seller, 50);

        // Calculate epoch
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Seller lists
        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 50, priceUSDC);
        vm.stopPrank();

        // Fund buyer with enough USDC (price + 1.5% buyer fee)
        uint256 buyerFee = (priceUSDC * 150) / 10000;
        usdc.mint(buyer, priceUSDC + buyerFee);

        // Buyer approves and buys
        vm.startPrank(buyer);
        usdc.approve(address(marketplace), type(uint256).max);

        uint256 gasBefore = gasleft();
        marketplace.executeBuy(listingId);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        assertLt(gasUsed, 300_000, "executeBuy exceeds 300k gas");
    }
}
