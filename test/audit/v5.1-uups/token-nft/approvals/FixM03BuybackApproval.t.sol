// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {CapacityOracle} from "../../../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUSDC_M03 {
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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
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

/**
 * @title FixM03BuybackApproval
 * @notice Verifies the M-03 fix: BuybackEngine.executeOffer now approves
 *         priceUSDC + buyerFee (not just priceUSDC) so that the marketplace
 *         can pull the full amount. Counts the fee against the daily
 *         budget. Keeps CEI pattern and resets approval to 0 post-call.
 */
contract FixM03BuybackApproval is Test {
    using ProxyDeployer for *;

    ClaimBond claimBond;
    BondVault bondVault;
    LuminaTokenV2 lumina;
    CapacityOracle capacityOracle;
    SolvencyOracle solvencyOracle;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;
    LuminaBondMarketplace marketplace;
    BuybackEngine buybackEngine;
    MockUSDC_M03 usdc;

    address deployer;
    address multisig = makeAddr("multisig");
    address founder = makeAddr("founder");
    address lbpDeposit = makeAddr("lbpDeposit");
    address seller = makeAddr("seller");

    uint256 constant BUYER_FEE_BPS = 150; // 1.5 %
    uint256 constant BPS_DEN = 10_000;

    function setUp() public {
        deployer = address(this);
        vm.warp(1_767_225_600 + 60 days);

        usdc = new MockUSDC_M03();
        claimBond = ProxyDeployer.deployClaimBond();

        uint64 n = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, n + 9);

        capacityOracle = ProxyDeployer.deployCapacityOracle(address(0), predictedLumina, address(usdc), 0.036e18);
        bondVault =
            ProxyDeployer.deployBondVault(predictedLumina, address(claimBond), address(capacityOracle), address(0));
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(predictedLumina, multisig);
        treasuryVesting = ProxyDeployer.deployTreasuryVesting(predictedLumina);

        lumina = ProxyDeployer.deployLuminaTokenV2(
            address(bondVault), address(cexReserve), founder, lbpDeposit, address(treasuryVesting)
        );
        require(address(lumina) == predictedLumina, "lumina addr");

        claimBond.setBondVault(address(bondVault));

        solvencyOracle = ProxyDeployer.deploySolvencyOracle(address(bondVault), address(capacityOracle), multisig);

        marketplace = ProxyDeployer.deployLuminaBondMarketplace(
            address(claimBond), address(usdc), makeAddr("twapBurner"), multisig
        );
        // [Fix M-3 regression] Lower the per-unit price floor for this legacy
        // test - it predates the M-3 spam floor and uses arbitrary price/amount
        // ratios that aren't relevant to the M-3 behavior under test.
        vm.prank(multisig);
        marketplace.setMinPricePerUnit(1);
        buybackEngine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );
        // [M-10 grant] grant BUYBACK_OPERATOR_ROLE to address(this) so test calls reach the gated path.
        {
            bytes32 _m10_role_buybackEngine = buybackEngine.BUYBACK_OPERATOR_ROLE();
            vm.prank(multisig);
            buybackEngine.grantRole(_m10_role_buybackEngine, address(this));
        }

        // deployer (address(this)) acts as PolicyManager so we can drive
        // BondVault.issueBond to simulate policy triggers.
        bondVault.setPolicyManager(deployer);

        bondVault.setAuthorizedCaller(address(buybackEngine), true);
        claimBond.setAuthorizedOperator(address(marketplace), true);
        claimBond.setAuthorizedOperator(address(buybackEngine), true);
    }

    // ─── Helpers ───

    /// @dev Mirrors BondVault._timestampToEpoch(block.timestamp + 730 days).
    function _epoch() internal view returns (uint256) {
        uint256 maturity = block.timestamp + 730 days;
        uint256 BASE_TS = 1_767_225_600;
        uint256 monthsFromBase = (maturity - BASE_TS) / 2_629_746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }

    function _list(uint256 amount, uint256 priceUSDC) internal returns (uint256 listingId) {
        // Mint bonds via BondVault.issueBond so both claimBond balance and
        // bondVault.totalCommittedUSD are in sync (required for the
        // double-burn `decreaseObligations` path).
        bondVault.issueBond(seller, amount, 0.036e18);

        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        listingId = marketplace.list(_anyHeldEpoch(seller), amount, priceUSDC);
        vm.stopPrank();
    }

    function _anyHeldEpoch(address who) internal view returns (uint256) {
        for (uint256 e = 202600; e <= 210012; e++) {
            if (claimBond.balanceOf(who, e) > 0) return e;
        }
        revert("no epoch");
    }

    function _activateBuyback(uint256 budget, uint256 maxPricePercent) internal {
        vm.prank(multisig);
        buybackEngine.setDailyBuyback(budget, maxPricePercent, 24);
    }

    function _fundBuyback(uint256 amount) internal {
        usdc.mint(address(buybackEngine), amount);
    }

    // ═══════════════════════════════════════════════════════════
    // A. HAPPY PATH — executeOffer now succeeds
    // ═══════════════════════════════════════════════════════════

    function test_FixM03_ExecuteOffer_NowWorks() public {
        _activateBuyback(100e6, 95);
        _fundBuyback(100e6);
        uint256 listingId = _list(50, 20e6);

        // Previously reverted with insufficient allowance. Now succeeds.
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_0 = keccak256(abi.encode("m10-test-salt", uint256(0)));
            bytes32 _m10_commit_58_0 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_58_0));
            buybackEngine.commitBuyback(_m10_commit_58_0);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(listingId, type(uint256).max, _m10_salt_58_0);
        }
    }

    function test_FixM03_ExecuteOffer_UsdcOutflow_IsPricePlusFee() public {
        _activateBuyback(100e6, 95);
        _fundBuyback(100e6);
        uint256 price = 20e6;
        uint256 listingId = _list(50, price);

        uint256 before_ = usdc.balanceOf(address(buybackEngine));
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_1 = keccak256(abi.encode("m10-test-salt", uint256(1)));
            bytes32 _m10_commit_58_1 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_58_1));
            buybackEngine.commitBuyback(_m10_commit_58_1);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(listingId, type(uint256).max, _m10_salt_58_1);
        }
        uint256 after_ = usdc.balanceOf(address(buybackEngine));

        uint256 expectedFee = (price * BUYER_FEE_BPS) / BPS_DEN;
        assertEq(before_ - after_, price + expectedFee, "engine outflow must equal price + fee");
    }

    function test_FixM03_ExecuteOffer_BondsEndUpBurned() public {
        _activateBuyback(100e6, 95);
        _fundBuyback(100e6);
        uint256 epoch = _epoch();
        uint256 listingId = _list(50, 20e6);

        uint256 supplyBefore = claimBond.totalSupply(epoch);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_2 = keccak256(abi.encode("m10-test-salt", uint256(2)));
            bytes32 _m10_commit_58_2 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_58_2));
            buybackEngine.commitBuyback(_m10_commit_58_2);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(listingId, type(uint256).max, _m10_salt_58_2);
        }
        uint256 supplyAfter = claimBond.totalSupply(epoch);

        // Bonds are burned by BuybackEngine via _executeDoubleBurn.
        assertEq(supplyBefore - supplyAfter, 50, "50 bonds must be burned after executeOffer");
    }

    // ═══════════════════════════════════════════════════════════
    // B. DAILY BUDGET — now includes fee
    // ═══════════════════════════════════════════════════════════

    function test_FixM03_DailyBudget_IncludesFee() public {
        _activateBuyback(1000e6, 95);
        _fundBuyback(1000e6);
        uint256 price = 100e6;
        uint256 fee = (price * BUYER_FEE_BPS) / BPS_DEN;

        uint256 listingId = _list(200, price);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_3 = keccak256(abi.encode("m10-test-salt", uint256(3)));
            bytes32 _m10_commit_58_3 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_58_3));
            buybackEngine.commitBuyback(_m10_commit_58_3);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(listingId, type(uint256).max, _m10_salt_58_3);
        }

        // dailyConfig.spentToday is not public struct-field access; use the
        // auto-generated getter.
        (,,, uint256 spentToday) = buybackEngine.dailyConfig();
        assertEq(spentToday, price + fee, "spentToday must count price + fee");
    }

    function test_FixM03_DailyBudget_ExactLimitWithFee_Succeeds() public {
        // Budget set to exactly price + fee.
        uint256 price = 100e6;
        uint256 fee = (price * BUYER_FEE_BPS) / BPS_DEN;
        _activateBuyback(price + fee, 95);
        _fundBuyback(price + fee);
        uint256 listingId = _list(200, price);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_4 = keccak256(abi.encode("m10-test-salt", uint256(4)));
            bytes32 _m10_commit_58_4 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_58_4));
            buybackEngine.commitBuyback(_m10_commit_58_4);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(listingId, type(uint256).max, _m10_salt_58_4);
        }
    }

    function test_FixM03_DailyBudget_JustOverWithFee_Reverts() public {
        // Budget is price-only; fee pushes it over.
        uint256 price = 100e6;
        _activateBuyback(price, 95);
        _fundBuyback(price + 5e6);
        uint256 listingId = _list(200, price);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_5 = keccak256(abi.encode("m10-test-salt", uint256(5)));
            bytes32 _m10_commit_58_5 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_58_5));
            buybackEngine.commitBuyback(_m10_commit_58_5);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            // [M-10 expectRevert moved]
            vm.expectRevert(bytes("Daily budget exceeded"));
            buybackEngine.revealAndExecute(listingId, type(uint256).max, _m10_salt_58_5);
        }
    }

    function test_FixM03_MultipleOffers_ConsumeBudgetWithFees() public {
        _activateBuyback(1000e6, 95);
        _fundBuyback(1000e6);

        // Each offer uses 2000 bonds so maxAllowedPriceUSDC = 2000 × 0.95 = $1900
        // — well above every price below, so the price-cap check never fires.

        // Offer 1: $200 price → 200 + 3 = $203 spent.
        uint256 id1 = _list(2000, 200e6);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_6 = keccak256(abi.encode("m10-test-salt", uint256(6)));
            bytes32 _m10_commit_58_6 = keccak256(abi.encode(id1, type(uint256).max, _m10_salt_58_6));
            buybackEngine.commitBuyback(_m10_commit_58_6);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(id1, type(uint256).max, _m10_salt_58_6);
        }
        (,,, uint256 spent1) = buybackEngine.dailyConfig();
        assertEq(spent1, 203_000_000);

        // Offer 2: $300 price → 300 + 4.50 = $304.50. Total spent = $507.50.
        uint256 id2 = _list(2000, 300e6);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_7 = keccak256(abi.encode("m10-test-salt", uint256(7)));
            bytes32 _m10_commit_58_7 = keccak256(abi.encode(id2, type(uint256).max, _m10_salt_58_7));
            buybackEngine.commitBuyback(_m10_commit_58_7);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(id2, type(uint256).max, _m10_salt_58_7);
        }
        (,,, uint256 spent2) = buybackEngine.dailyConfig();
        assertEq(spent2, 203_000_000 + 304_500_000);

        // Offer 3: $500 price → 500 + 7.50 = $507.50. Total = $1015 > $1000.
        uint256 id3 = _list(2000, 500e6);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_8 = keccak256(abi.encode("m10-test-salt", uint256(8)));
            bytes32 _m10_commit_58_8 = keccak256(abi.encode(id3, type(uint256).max, _m10_salt_58_8));
            buybackEngine.commitBuyback(_m10_commit_58_8);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            // [M-10 expectRevert moved]
            vm.expectRevert(bytes("Daily budget exceeded"));
            buybackEngine.revealAndExecute(id3, type(uint256).max, _m10_salt_58_8);
        }
    }

    // ═══════════════════════════════════════════════════════════
    // C. APPROVAL HYGIENE — post-call reset
    // ═══════════════════════════════════════════════════════════

    function test_FixM03_Approval_ResetToZero_AfterExecution() public {
        _activateBuyback(100e6, 95);
        _fundBuyback(100e6);
        uint256 listingId = _list(50, 20e6);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_9 = keccak256(abi.encode("m10-test-salt", uint256(9)));
            bytes32 _m10_commit_58_9 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_58_9));
            buybackEngine.commitBuyback(_m10_commit_58_9);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(listingId, type(uint256).max, _m10_salt_58_9);
        }
        assertEq(usdc.allowance(address(buybackEngine), address(marketplace)), 0, "approval must reset to 0");
    }

    function test_FixM03_InsufficientEngineBalance_Reverts_NoDanglingApproval() public {
        _activateBuyback(1000e6, 95);
        _fundBuyback(10e6); // way below 20e6 + fee
        uint256 listingId = _list(50, 20e6);

        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_10 = keccak256(abi.encode("m10-test-salt", uint256(10)));
            bytes32 _m10_commit_58_10 = keccak256(abi.encode(listingId, type(uint256).max, _m10_salt_58_10));
            buybackEngine.commitBuyback(_m10_commit_58_10);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            // [M-10 expectRevert moved]
            vm.expectRevert();
            buybackEngine.revealAndExecute(listingId, type(uint256).max, _m10_salt_58_10);
        }

        // No dangling approval — the revert is atomic.
        assertEq(usdc.allowance(address(buybackEngine), address(marketplace)), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // D. CEI ORDERING — state updated before external call
    // ═══════════════════════════════════════════════════════════

    function test_FixM03_CEI_SpentTodayAlreadyUpdated_IfReentered() public {
        // The nonReentrant modifier prevents actual re-entry on executeOffer;
        // this test is a documentation test that spentToday is updated
        // BEFORE the external marketplace.executeBuy call. We assert the
        // post-call spentToday reflects the full total (price + fee).
        _activateBuyback(1000e6, 95);
        _fundBuyback(1000e6);
        uint256 price = 100e6;
        uint256 fee = (price * BUYER_FEE_BPS) / BPS_DEN;
        // 200 bonds so maxAllowedPriceUSDC = $190 — above the $100 price.
        uint256 id = _list(200, price);
        // [Fix M-10 patch] executeOffer was removed; route through commit-reveal.
        {
            bytes32 _m10_salt_58_11 = keccak256(abi.encode("m10-test-salt", uint256(11)));
            bytes32 _m10_commit_58_11 = keccak256(abi.encode(id, type(uint256).max, _m10_salt_58_11));
            buybackEngine.commitBuyback(_m10_commit_58_11);
            vm.roll(block.number + buybackEngine.MIN_REVEAL_DELAY_BLOCKS());
            buybackEngine.revealAndExecute(id, type(uint256).max, _m10_salt_58_11);
        }

        (,,, uint256 spentToday) = buybackEngine.dailyConfig();
        assertEq(spentToday, price + fee);
    }

    // ═══════════════════════════════════════════════════════════
    // E. FEE VARIABILITY (via marketplace upgrade path, documented)
    // ═══════════════════════════════════════════════════════════

    function test_FixM03_ReadsFeeFromMarketplaceAtCallTime() public {
        // BUYER_FEE_BPS is a public constant on Marketplace. If a future
        // upgrade changes the constant, BuybackEngine reads the new value
        // each call. Here we just assert the current value matches what
        // the test expects.
        assertEq(marketplace.BUYER_FEE_BPS(), BUYER_FEE_BPS);
        assertEq(marketplace.BPS_DENOMINATOR(), BPS_DEN);
    }
}
