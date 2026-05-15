// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";
import "../../src/treasury/CEXLiquidityReserve.sol";
import "../../src/treasury/MaintenanceReserve.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract MockPriceOracleEC {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockUSDCec {
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

contract EdgeCasesTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault bondVault;
    CEXLiquidityReserve cexReserve;
    MaintenanceReserve maintenanceReserve;
    MockPriceOracleEC oracle;
    MockUSDCec usdc;

    address deployer;
    address multisig = makeAddr("multisig");
    address user = makeAddr("user");

    uint256 constant BASE_TS = 1767225600;

    function setUp() public {
        vm.chainId(8453);
        deployer = address(this);
        vm.warp(BASE_TS + 60 days);

        oracle = new MockPriceOracleEC();
        usdc = new MockUSDCec();
        claimBond = ProxyDeployer.deployClaimBond();

        token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("tempBondVault"), makeAddr("tempCEX"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        bondVault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), deployer);

        claimBond.setBondVault(address(bondVault));
        deal(address(token), address(bondVault), 70_000_000e18);

        // Grant authorized caller for burnFromReserves tests
        bondVault.grantRole(bondVault.AUTHORIZED_CALLER_ADMIN_ROLE(), deployer);
        bondVault.setAuthorizedCaller(deployer, true);

        // CEX Reserve
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(address(token), multisig);
        deal(address(token), address(cexReserve), 14_000_000e18);

        // Maintenance Reserve
        maintenanceReserve = ProxyDeployer.deployMaintenanceReserve(address(usdc), multisig);
    }

    // ═══════ BOND VAULT EDGE CASES ═══════

    function test_EdgeCase_IssueBondWithMinimumAmount() public {
        // Issue a $1 bond — the smallest valid integer-dollar amount
        bondVault.issueBond(user, 1);
        assertEq(bondVault.totalCommittedUSD(), 1e18);

        // Verify bond token minted
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;
        assertEq(claimBond.balanceOf(user, epochId), 1);
    }

    function test_EdgeCase_RedeemBondAtExactMaturityTimestamp() public {
        bondVault.issueBond(user, 100);

        // Calculate epoch
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // The maturity date stored in ClaimBond is computed from epochId (YYYYMM)
        uint256 storedMaturity = claimBond.maturityDate(epochId);

        // Warp to exactly the stored maturity timestamp (not 1 second after)
        vm.warp(storedMaturity);

        // isMatured should be true at exact maturity (block.timestamp >= maturityDate)
        assertTrue(claimBond.isMatured(epochId));

        // Redeem at exact maturity second
        vm.prank(user);
        bondVault.redeemBond(epochId, 100);

        assertEq(claimBond.balanceOf(user, epochId), 0);
        assertGt(token.balanceOf(user), 0);
    }

    // ═══════ CEX RESERVE EDGE CASES ═══════

    function test_EdgeCase_CEXReserve_AllocateExactlyAtMonthlyCap() public {
        // MONTHLY_CAP = 1_000_000e18
        // Allocate exactly at the cap boundary
        address recipient = makeAddr("recipient");
        vm.prank(multisig);
        cexReserve.allocate(
            recipient,
            1_000_000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Exact monthly cap allocation"
        );
        assertEq(token.balanceOf(recipient), 1_000_000e18);

        // Next allocation in same month should revert
        vm.prank(multisig);
        vm.expectRevert("Monthly cap exceeded");
        cexReserve.allocate(
            recipient,
            1,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "One token over cap"
        );
    }

    // ═══════ MAINTENANCE RESERVE EDGE CASES ═══════

    function test_EdgeCase_MaintenanceSpend_ExactBalance() public {
        // Fund with exact amount and spend it all
        uint256 exactBalance = 250_000e6;
        usdc.mint(address(maintenanceReserve), exactBalance);

        address vendor = makeAddr("vendor");
        vm.prank(multisig);
        maintenanceReserve.spend(
            vendor, exactBalance, MaintenanceReserve.SpendCategory.Infrastructure, "Spend entire balance"
        );
        assertEq(usdc.balanceOf(vendor), exactBalance);
        assertEq(usdc.balanceOf(address(maintenanceReserve)), 0);
    }

    // ═══════ BURN FROM RESERVES EDGE CASES ═══════

    function test_EdgeCase_BondVault_BurnExactly5Percent() public {
        // burnFromReserves caps at (currentBalance * 5) / 100
        uint256 balance = token.balanceOf(address(bondVault));
        uint256 maxBurn = (balance * 5) / 100;

        // Burn exactly at the 5% cap — should succeed
        bondVault.burnFromReserves(maxBurn);

        uint256 newBalance = token.balanceOf(address(bondVault));
        assertEq(newBalance, balance - maxBurn);

        // Verify exceeding new 5% cap reverts
        uint256 newMax = (newBalance * 5) / 100;
        vm.expectRevert("Exceeds 5% per-tx cap");
        bondVault.burnFromReserves(newMax + 1);
    }
}
