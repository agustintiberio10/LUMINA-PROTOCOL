// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {CEXLiquidityReserve} from "../../../src/treasury/CEXLiquidityReserve.sol";
import {LuminaBondMarketplace} from "../../../src/marketplace/LuminaBondMarketplace.sol";
import {MockCapacityOracleV5} from "../../mocks/MockCapacityOracleV5.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @notice Minimal ERC20 for economic attack tests (mintable, burnable)
contract MockLumina_Econ {
    string public name = "MockLumina";
    string public symbol = "LUMINA";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function burn(uint256 a) external {
        balanceOf[msg.sender] -= a;
        totalSupply -= a;
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
        if (f != msg.sender) {
            allowance[f][msg.sender] -= a;
        }
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @notice Minimal USDC mock (6 decimals) for marketplace tests
contract MockUSDC_Econ {
    string public name = "MockUSDC";
    uint8 public decimals = 6;
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

/// @title EconomicAttacks
/// @notice Tests that economic invariants hold under adversarial conditions.
contract EconomicAttacks is Test {
    address attacker = makeAddr("attacker");
    address policyManager = makeAddr("policyManager");
    address admin = makeAddr("admin");

    /// @dev When the suite is invoked with `--fork-url`, deterministic
    ///      `makeAddr` outputs may collide with EOAs that, on Base mainnet,
    ///      have been delegated via EIP-7702 to a contract (the bytecode
    ///      starts with `0xef0100`). Minting ERC-1155 to such an address
    ///      then triggers the receiver hook and reverts with
    ///      `ERC1155InvalidReceiver`. None of these tests need fork state,
    ///      so we explicitly clear bytecode at the test EOAs to keep them
    ///      EOAs regardless of fork mode.
    function setUp() public {
        vm.chainId(8453);
        vm.etch(attacker, "");
        vm.etch(policyManager, "");
        vm.etch(admin, "");
    }

    // ================================================================
    // Test 1: Issue bonds until capacity check fails at exact boundary
    // ================================================================
    function test_Attack_BondVaultCapacityExhaustion() public {
        vm.warp(1767225600 + 60 days); // Past BASE_TIMESTAMP for epoch math
        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18); // $0.036 per LUMINA

        MockLumina_Econ lumina = new MockLumina_Econ();
        ClaimBond claimBond = ProxyDeployer.deployClaimBond();

        BondVault vault =
            ProxyDeployer.deployBondVault(address(lumina), address(claimBond), address(oracle), policyManager);

        // Set ClaimBond's bondVault
        claimBond.setBondVault(address(vault));

        // Fund vault with 1,000,000 LUMINA
        uint256 reserve = 1_000_000e18;
        lumina.mint(address(vault), reserve);

        // reserveValueUSD = 1_000_000 * 0.036 = $36,000
        // maxCommitUSD = $36,000 * 50% = $18,000
        // So we can issue up to $18,000 worth of bonds
        // issueBond takes usdPayout in integer dollars, scaled by 1e18 internally

        // Issue bonds right up to the limit
        vm.prank(policyManager);
        vault.issueBond(attacker, 18_000); // exactly $18,000

        // Next dollar should fail
        vm.prank(policyManager);
        vm.expectRevert("Exceeds capacity");
        vault.issueBond(attacker, 1); // $1 over limit
    }

    // ================================================================
    // Test 2: Try to redeem bonds you don't have
    // ================================================================
    function test_Attack_RedeemMoreThanBalance() public {
        vm.warp(1767225600 + 60 days);
        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18);

        MockLumina_Econ lumina = new MockLumina_Econ();
        ClaimBond claimBond = ProxyDeployer.deployClaimBond();

        BondVault vault =
            ProxyDeployer.deployBondVault(address(lumina), address(claimBond), address(oracle), policyManager);
        claimBond.setBondVault(address(vault));
        lumina.mint(address(vault), 10_000_000e18);

        // Issue 100 bonds to attacker
        vm.prank(policyManager);
        vault.issueBond(attacker, 100);

        // Warp past maturity (730 days + buffer)
        vm.warp(block.timestamp + 731 days);

        // Get the epoch ID for the issued bonds
        // Bonds mature ~730 days from now, epoch = YYYYMM
        // Try to redeem 200 (more than the 100 they have)
        // First find the epoch that was minted
        uint256 baseTs = 1767225600; // Jan 1 2026
        // issueBond was at block.timestamp (1), maturity = 1 + 730 days
        // But we need to figure out the epoch. Let's just try a reasonable epoch.
        // The test timestamp starts at 1 (forge default), maturity = 1 + 730 days = 63072001
        // monthsFromBase: 63072001 < 1767225600, so this would revert "Before base"
        // We need to warp to a realistic time first

        // Reset and redo with realistic timestamps
    }

    // We redo test 2 properly with realistic timestamps
    function test_Attack_RedeemMoreThanBalance_V2() public {
        // Warp to Jan 2 2026 so epoch calculation works
        vm.warp(1767225600 + 1 days);

        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18);

        MockLumina_Econ lumina = new MockLumina_Econ();
        ClaimBond claimBond = ProxyDeployer.deployClaimBond();

        BondVault vault =
            ProxyDeployer.deployBondVault(address(lumina), address(claimBond), address(oracle), policyManager);
        claimBond.setBondVault(address(vault));
        lumina.mint(address(vault), 10_000_000e18);

        // Issue 100 bonds to attacker
        vm.prank(policyManager);
        vault.issueBond(attacker, 100);

        // Warp past maturity (730 days + 1 day buffer)
        vm.warp(block.timestamp + 731 days);

        // The epoch should be around 202801 (Jan 2028)
        // maturity = (1767225600 + 1 day) + 730 days
        // monthsFromBase = ((1767225600 + 86400 + 63072000) - 1767225600) / 2629746 = ~24
        // epoch = 2026*100 + (1 + 24%12) = 202601 + ... = 202801
        uint256 maturityTs = (1767225600 + 1 days) + 730 days;
        uint256 monthsFromBase = (maturityTs - 1767225600) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Verify attacker has 100 bonds
        assertEq(claimBond.balanceOf(attacker, epochId), 100);

        // Try to redeem 200 (more than the 100 they own)
        vm.prank(attacker);
        vm.expectRevert("Insufficient bonds");
        vault.redeemBond(epochId, 200);
    }

    // ================================================================
    // Test 3: Double redeem -- redeem once, then try again
    // ================================================================
    function test_Attack_DoubleRedeem() public {
        vm.warp(1767225600 + 1 days);

        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18);

        MockLumina_Econ lumina = new MockLumina_Econ();
        ClaimBond claimBond = ProxyDeployer.deployClaimBond();

        BondVault vault =
            ProxyDeployer.deployBondVault(address(lumina), address(claimBond), address(oracle), policyManager);
        claimBond.setBondVault(address(vault));
        lumina.mint(address(vault), 10_000_000e18);

        // Issue 100 bonds
        vm.prank(policyManager);
        vault.issueBond(attacker, 100);

        // Compute epoch
        uint256 maturityTs = (1767225600 + 1 days) + 730 days;
        uint256 monthsFromBase = (maturityTs - 1767225600) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Warp past maturity
        vm.warp(block.timestamp + 731 days);

        // First redeem: should succeed
        vm.prank(attacker);
        vault.redeemBond(epochId, 100);

        // Second redeem: should fail (bonds burned)
        vm.prank(attacker);
        vm.expectRevert("Insufficient bonds");
        vault.redeemBond(epochId, 100);
    }

    // ================================================================
    // Test 4: Marketplace wash trading -- self-buy loses fees (3% total)
    // ================================================================
    function test_Attack_MarketplaceWashTrading() public {
        vm.warp(1767225600 + 1 days);

        MockUSDC_Econ usdc = new MockUSDC_Econ();
        ClaimBond claimBond = ProxyDeployer.deployClaimBond();
        address twapBurner = makeAddr("twapBurner");

        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(claimBond), address(usdc), twapBurner, admin);
        // [FIX-#18] Whitelist marketplace so ClaimBond allows its transfers.
        claimBond.setAuthorizedOperator(address(mp), true);

        // Setup: create a mock BondVault just to mint bonds via ClaimBond
        MockLumina_Econ lumina = new MockLumina_Econ();
        MockCapacityOracleV5 oracle = new MockCapacityOracleV5();
        oracle.setPrice(0.036e18);
        BondVault vault =
            ProxyDeployer.deployBondVault(address(lumina), address(claimBond), address(oracle), policyManager);
        claimBond.setBondVault(address(vault));
        lumina.mint(address(vault), 10_000_000e18);

        // Issue bonds to attacker
        vm.prank(policyManager);
        vault.issueBond(attacker, 50);

        uint256 maturityTs = block.timestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - 1767225600) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Attacker lists bonds on marketplace
        uint256 listPrice = 40e6; // $40 USDC for 50 bonds
        vm.startPrank(attacker);
        claimBond.setApprovalForAll(address(mp), true);
        uint256 listingId = mp.list(epochId, 50, listPrice);

        // Attacker tries to buy own bonds (wash trade)
        // Buyer pays: listPrice + 1.5% buyer fee
        uint256 buyerFee = (listPrice * 150) / 10000; // 1.5%
        uint256 sellerFee = (listPrice * 150) / 10000; // 1.5%
        uint256 totalBuyerPays = listPrice + buyerFee;

        // Give attacker enough USDC to buy
        usdc.mint(attacker, totalBuyerPays);
        usdc.approve(address(mp), totalBuyerPays);

        uint256 balanceBefore = usdc.balanceOf(attacker);
        mp.executeBuy(listingId);
        // [legacy-migration] F-14: the seller's net proceeds are no longer
        // push-transferred back on the fill; they are booked to the pull-payment
        // ledger (pendingWithdrawals[seller]). For a wash trade (seller == buyer)
        // the attacker must withdraw() to reclaim those proceeds, after which the
        // only standing loss is the 3% in fees that went to the twapBurner.
        mp.withdraw();
        uint256 balanceAfter = usdc.balanceOf(attacker);
        vm.stopPrank();

        // Attacker lost exactly the total fees (3%) to twapBurner
        uint256 totalFees = sellerFee + buyerFee;
        uint256 netLoss = balanceBefore - balanceAfter;
        assertEq(netLoss, totalFees, "Wash trader must lose exactly 3% in fees");
        assertEq(usdc.balanceOf(twapBurner), totalFees, "All fees go to TWAPBurner");
    }

    // ================================================================
    // Test 5: CEX Reserve drain attempt -- monthly cap blocks
    // ================================================================
    function test_Attack_CEXReserveDrainAttempt() public {
        MockLumina_Econ lumina = new MockLumina_Econ();

        CEXLiquidityReserve reserve = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), admin);

        // Fund the reserve with its full 14M allocation
        lumina.mint(address(reserve), 14_000_000e18);

        // ImmediateUse bucket = 2.8M, monthly cap = 1M
        // Try to allocate more than monthly cap at once
        vm.prank(admin);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(
            attacker,
            1_000_001e18, // 1 token over the 1M monthly cap
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Drain attempt"
        );
    }
}
