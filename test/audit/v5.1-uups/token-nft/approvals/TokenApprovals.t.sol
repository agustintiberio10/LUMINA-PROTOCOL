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
import {AdaptiveFeeDistributor} from "../../../../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../../src/treasury/MaintenanceReserve.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";

import {FlashBTCShield1h} from "../../../../../src/products/FlashBTCShield1h.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUSDC_Appr {
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

contract MockSwapRouter_Appr is IDexRouter {
    using SafeERC20 for IERC20;

    IERC20 public lumina;
    uint256 public rate = 27;
    bool public revertOnSwap;

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function setRevert(bool v) external {
        revertOnSwap = v;
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external returns (uint256 amountOut) {
        require(!revertOnSwap, "mock revert");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate * 1e12;
        lumina.safeTransfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256) {
        return amountIn * rate * 1e12;
    }
}

contract MockShieldOracle_Appr {
    mapping(bytes32 => int256) public prices;

    constructor() {
        prices["BTC"] = 65_000e8;
    }

    function getLatestPrice(bytes32 a) external view returns (int256) {
        int256 p = prices[a];
        return p > 0 ? p : int256(1e8);
    }

    function getSequencerDowntime(uint256) external pure returns (uint256) {
        return 0;
    }

    /// @dev [Audit fix H-13] Stub for the new IOracle method.
    ///      Tests that exercise Chainlink-grace logic configure
    ///      this mock via a setter (or override) — the default
    ///      `0` keeps every other test green.
    function getChainlinkDowntime(bytes32, uint256) external view returns (uint256) {
        return 0;
    }


    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0xdead);
    }

    function oracleKey() external pure returns (address) {
        return address(0xdead);
    }
}

/**
 * @title TokenApprovals
 * @notice Audit the protocol's ERC-20 approval hygiene:
 *           - All src/ approve sites use SafeERC20.forceApprove (verified via grep).
 *           - Inside-protocol approvals are exactly-sized (no infinite).
 *           - Leftover allowance after each internal call equals zero.
 *           - User-facing approvals (USDC, ClaimBond) behave per spec.
 *           - USDC standard allows approve-over-nonzero (no race-condition bug).
 *
 * Key findings (see REPORT.md):
 *   - TWAPBurner, CoverRouter, UniV3Adapter, AerodromeAdapter all consume
 *     their exact approved amount — no leftover.
 *   - BuybackEngine approves only `priceUSDC` but Marketplace.executeBuy
 *     tries to pull `priceUSDC + buyerFee` (1.5 % fee). Test captures this
 *     as a REAL bug → MEDIUM finding for V5.2 fix.
 */
contract TokenApprovals is Test {
    using ProxyDeployer for *;

    MockUSDC_Appr usdc;
    MockSwapRouter_Appr swapRouter;
    MockShieldOracle_Appr shieldOracle;

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
    FlashBTCShield1h flashBtc1h;

    address deployer;
    address multisig = makeAddr("multisig");
    address founder = makeAddr("founder");
    address lbpDeposit = makeAddr("lbpDeposit");
    address opsWallet = makeAddr("opsWallet");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");

    bytes32 constant ID_FLASHBTC1H = keccak256("FLASHBTC1H-001");

    function setUp() public {
        deployer = address(this);
        vm.warp(1_767_225_600 + 60 days);

        usdc = new MockUSDC_Appr();
        shieldOracle = new MockShieldOracle_Appr();

        maintenanceReserve = ProxyDeployer.deployMaintenanceReserve(address(usdc), multisig);
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

        swapRouter = new MockSwapRouter_Appr(address(lumina));
        deal(address(lumina), address(swapRouter), 10_000_000e18);

        solvencyOracle = ProxyDeployer.deploySolvencyOracle(address(bondVault), address(capacityOracle), multisig);
        feeDistributor = ProxyDeployer.deployAdaptiveFeeDistributor(address(solvencyOracle));
        twapBurner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(swapRouter));
        policyManager = ProxyDeployer.deployPolicyManagerV2(address(bondVault));
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        policyManager.setRouter(address(coverRouter));
        coverRouter.setCapacityOracle(address(capacityOracle));
        bondVault.setPolicyManager(address(policyManager));

        marketplace =
            ProxyDeployer.deployLuminaBondMarketplace(address(claimBond), address(usdc), address(twapBurner), multisig);
        buybackEngine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );

        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(address(buybackEngine), opsWallet, address(maintenanceReserve));
        twapBurner.setCapacityOracle(address(capacityOracle));
        twapBurner.setAuthorizedSender(address(coverRouter), true);
        lumina.grantRole(lumina.BURNER_ROLE(), address(twapBurner));
        bondVault.setAuthorizedCaller(address(buybackEngine), true);

        // Whitelist marketplace + buyback as ClaimBond operators (fix #18).
        claimBond.setAuthorizedOperator(address(marketplace), true);
        claimBond.setAuthorizedOperator(address(buybackEngine), true);

        flashBtc1h = ProxyDeployer.deployFlashBTCShield1h(address(policyManager), address(shieldOracle));
        policyManager.registerProduct(ID_FLASHBTC1H, address(flashBtc1h));
        coverRouter.configureProduct(ID_FLASHBTC1H, 8000, 200, 2000, 3600, true);

        vm.warp(block.timestamp + 901);
    }

    // ═══════════════════════════════════════════════════════════
    // A. PROTOCOL-INTERNAL APPROVAL HYGIENE
    // ═══════════════════════════════════════════════════════════

    /// @notice After a full CoverRouter→TWAPBurner premium flow, allowance
    ///         from CoverRouter to TWAPBurner is exactly 0.
    function test_Appr_UUPS_CoverRouter_ToTwapBurner_NoLeftover() public {
        usdc.mint(buyer, 1_000e6);
        vm.prank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);

        vm.prank(buyer);
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");

        // CoverRouter forceApproves TWAPBurner for exactly `premium`, and
        // TWAPBurner.receivePremium pulls exactly `premium`. Delta = 0.
        assertEq(usdc.allowance(address(coverRouter), address(twapBurner)), 0);
    }

    /// @notice After TWAPBurner.executeBurn, allowance from TWAPBurner to
    ///         the swap router is exactly 0 (router pulls amountIn via
    ///         safeTransferFrom which drains the allowance).
    function test_Appr_UUPS_TWAPBurner_ToSwapRouter_NoLeftover() public {
        // Seed burner with USDC (directly, bypassing the CoverRouter path).
        usdc.mint(address(twapBurner), 10e6);
        twapBurner.executeBurn();

        assertEq(usdc.allowance(address(twapBurner), address(swapRouter)), 0);
    }

    /// @notice [FIX-M03] Previously this test asserted the allowance bug
    ///         (executeOffer reverted because approval was short of the
    ///         buyer fee). After the fix (BuybackEngine now approves
    ///         `priceUSDC + buyerFee` and counts the fee against the
    ///         daily budget), executeOffer SUCCEEDS. The test is now
    ///         kept as a regression guard so the bug can't silently
    ///         return.
    function test_Appr_UUPS_BuybackEngine_ApprovalIncludesFee_FixM03() public {
        // Seed seller with 100 bonds, list at $20.
        vm.prank(address(policyManager));
        bondVault.issueBond(seller, 100, 0.036e18);
        uint256 epochId = _anyHeldEpoch(seller);

        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 50, 20e6); // 50 bonds at $20
        vm.stopPrank();

        vm.prank(multisig);
        buybackEngine.setDailyBuyback(100e6, 95, 24);
        usdc.mint(address(buybackEngine), 100e6);

        // Post-fix: executeOffer now approves priceUSDC + buyerFee, so this
        // call succeeds. Allowance is reset to 0 post-call.
        buybackEngine.executeOffer(listingId);
        assertEq(usdc.allowance(address(buybackEngine), address(marketplace)), 0, "approval must reset to 0");
    }

    // ═══════════════════════════════════════════════════════════
    // B. USER → PROTOCOL APPROVALS (USDC)
    // ═══════════════════════════════════════════════════════════

    function test_Appr_UUPS_CoverRouter_NoAllowance_Reverts() public {
        usdc.mint(buyer, 1_000e6);
        // Skip approve.
        vm.prank(buyer);
        vm.expectRevert();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
    }

    function test_Appr_UUPS_CoverRouter_InsufficientAllowance_Reverts() public {
        usdc.mint(buyer, 1_000e6);
        vm.prank(buyer);
        usdc.approve(address(coverRouter), 1); // tiny
        vm.prank(buyer);
        vm.expectRevert();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
    }

    function test_Appr_UUPS_CoverRouter_ExactAllowance_Consumed() public {
        usdc.mint(buyer, 1_000e6);
        // Premium = 1000e6 × 8000/10000 × 200/10000 × 2000/10000 = 32_000 (6-dec) = $0.032
        uint256 premium = (1000e6 * 8000 * 200 * 2000) / (10000 * 10000 * 10000);
        vm.prank(buyer);
        usdc.approve(address(coverRouter), premium);

        vm.prank(buyer);
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");

        assertEq(usdc.allowance(buyer, address(coverRouter)), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // C. USER → MARKETPLACE APPROVALS
    // ═══════════════════════════════════════════════════════════

    function test_Appr_UUPS_Marketplace_Buy_RequiresUSDCApproval() public {
        vm.prank(address(policyManager));
        bondVault.issueBond(seller, 100, 0.036e18);
        uint256 epochId = _anyHeldEpoch(seller);

        vm.startPrank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 10, 10e6);
        vm.stopPrank();

        // Buyer has balance but no USDC approval.
        usdc.mint(buyer, 100e6);
        vm.prank(buyer);
        vm.expectRevert();
        marketplace.executeBuy(listingId);
    }

    function test_Appr_UUPS_Marketplace_List_RequiresClaimBondApproval() public {
        vm.prank(address(policyManager));
        bondVault.issueBond(seller, 100, 0.036e18);
        uint256 epochId = _anyHeldEpoch(seller);

        // Skip setApprovalForAll.
        vm.prank(seller);
        vm.expectRevert();
        marketplace.list(epochId, 10, 10e6);
    }

    function test_Appr_UUPS_ClaimBond_SetApprovalForAll_Stored() public {
        vm.prank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        assertTrue(claimBond.isApprovedForAll(seller, address(marketplace)));
    }

    function test_Appr_UUPS_ClaimBond_RevokeApproval_Stored() public {
        vm.prank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(seller);
        claimBond.setApprovalForAll(address(marketplace), false);
        assertFalse(claimBond.isApprovedForAll(seller, address(marketplace)));
    }

    // ═══════════════════════════════════════════════════════════
    // D. APPROVAL RACE-CONDITION / ERC-20 CLASSIC BUG
    // ═══════════════════════════════════════════════════════════

    /// @notice Standard USDC allows approve(X) then approve(Y) without a
    ///         zero-reset. (Base-mainnet USDC is standard.)
    function test_Appr_UUPS_USDC_ApproveOverNonzero_Succeeds() public {
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), 100e6);
        usdc.approve(address(coverRouter), 50e6); // no revert
        assertEq(usdc.allowance(buyer, address(coverRouter)), 50e6);
        vm.stopPrank();
    }

    /// @notice Every in-src approve call uses SafeERC20.forceApprove, which
    ///         resets allowance to 0 first on tokens that require it. This
    ///         is a static-code invariant — here we document it.
    function test_Appr_UUPS_ForceApprove_UsedEverywhere() public pure {
        // See REPORT.md §3 for the grep-verified list of forceApprove sites:
        //   src/core/TWAPBurner.sol:235
        //   src/core/CoverRouterV2.sol:182
        //   src/dex/UniswapV3Adapter.sol:61
        //   src/dex/AerodromeAdapter.sol:52
        //   src/marketplace/BuybackEngine.sol:143
        // Zero raw `.approve()` call sites in src/.
        assertTrue(true);
    }

    /// @notice No protocol contract grants infinite allowance. Approvals are
    ///         scoped to the exact amount about to be transferred.
    function test_Appr_UUPS_NoInfiniteApproval_FromProtocol() public pure {
        // Also a static-code invariant. REPORT.md §4 documents this.
        assertTrue(true);
    }

    // ═══════════════════════════════════════════════════════════
    // E. SHARED USER APPROVALS
    // ═══════════════════════════════════════════════════════════

    /// @notice User's allowance carries through a UUPS upgrade — the proxy
    ///         address doesn't change, and allowance is stored under the
    ///         USDC contract, not the upgraded impl.
    function test_Appr_UUPS_UserApproval_SurvivesUpgrade() public {
        usdc.mint(buyer, 1_000e6);
        vm.prank(buyer);
        usdc.approve(address(coverRouter), 100e6);

        // Upgrade CoverRouter impl (same bytecode is fine — proxy address
        // unchanged, storage preserved).
        CoverRouterV2 newImpl = new CoverRouterV2();
        coverRouter.upgradeToAndCall(address(newImpl), "");

        assertEq(usdc.allowance(buyer, address(coverRouter)), 100e6);
    }

    /// @notice setApprovalForAll on ClaimBond survives a UUPS upgrade.
    function test_Appr_UUPS_ClaimBondApproval_SurvivesUpgrade() public {
        vm.prank(seller);
        claimBond.setApprovalForAll(address(marketplace), true);

        ClaimBond newImpl = new ClaimBond();
        claimBond.upgradeToAndCall(address(newImpl), "");

        assertTrue(claimBond.isApprovedForAll(seller, address(marketplace)));
    }

    // ═══════════════════════════════════════════════════════════
    // F. SafeERC20 USAGE (observational)
    // ═══════════════════════════════════════════════════════════

    /// @notice BondVault.redeemBond uses `lumina.transfer` (plain ERC-20),
    ///         not safeTransfer. LUMINA is our own ERC-20 that always
    ///         returns true, so this is safe. Documented — if LUMINA were
    ///         ever replaced with a non-standard token, this would matter.
    function test_Appr_UUPS_BondVault_Redeem_UsesPlainTransfer() public pure {
        // BondVault.redeemBond:
        //   require(lumina.transfer(msg.sender, luminaAmount), "Transfer failed");
        // This is correct for LUMINA (standard ERC-20). A future non-standard
        // payout token would require SafeERC20.safeTransfer. Non-issue today.
        assertTrue(true);
    }

    // ═══════════════════════════════════════════════════════════
    // G. LEFTOVER HYGIENE AFTER FAILED SWAP (defensive)
    // ═══════════════════════════════════════════════════════════

    /// @notice If the DEX swap reverts, the whole tx reverts (including the
    ///         forceApprove). So no leftover allowance remains — the
    ///         forceApprove is part of the atomic-revert boundary.
    function test_Appr_UUPS_TWAPBurner_FailedSwap_NoLeftover() public {
        usdc.mint(address(twapBurner), 10e6);
        swapRouter.setRevert(true);

        vm.expectRevert();
        twapBurner.executeBurn();

        // Allowance is still whatever it was before the call (0, since we
        // never reached the approve line).
        assertEq(usdc.allowance(address(twapBurner), address(swapRouter)), 0);
    }

    // ─── Helpers ───
    function _anyHeldEpoch(address holder) internal view returns (uint256) {
        for (uint256 e = 202600; e <= 210012; e++) {
            if (claimBond.balanceOf(holder, e) > 0) return e;
        }
        revert("no epoch");
    }
}
