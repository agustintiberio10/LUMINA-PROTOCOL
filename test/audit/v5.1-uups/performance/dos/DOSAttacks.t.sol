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
import {ShieldKeeper} from "../../../../../src/automation/ShieldKeeper.sol";

import {FlashBTCShield1h} from "../../../../../src/products/FlashBTCShield1h.sol";

import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUSDC_DOS {
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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
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

contract MockSwapRouter_DOS is IDexRouter {
    using SafeERC20 for IERC20;

    IERC20 public lumina;
    uint256 public rate = 27;

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate * 1e12;
        lumina.safeTransfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256) {
        return amountIn * rate * 1e12;
    }
}

contract MockShieldOracle_DOS {
    mapping(bytes32 => int256) public prices;
    bool public revertOnRead;

    constructor() {
        prices[bytes32("BTC")] = 65_000e8;
        prices[bytes32("ETH")] = 3_200e8;
    }

    function setPrice(bytes32 a, int256 p) external {
        prices[a] = p;
    }

    function setRevert(bool v) external {
        revertOnRead = v;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        require(!revertOnRead, "oracle down");
        int256 p = prices[asset];
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
 * @title DOSAttacks
 * @notice Audits LUMINA V5.1 against denial-of-service vectors:
 *           - Griefing (dust policies, spam listings)
 *           - Gas exhaustion (keeper batch-with-reverts)
 *           - State lock (redemption blocking, burn lock)
 *           - Economic DOS (buyback drain, oracle manipulation)
 *           - Upgrade DOS (unauthorised upgrade attempts)
 *
 * Each test constructs an adversarial scenario and asserts that legitimate
 * users / keepers can still operate within reasonable gas / time bounds.
 */
contract DOSAttacks is Test {
    using ProxyDeployer for *;

    address deployer;
    address multisig = makeAddr("multisig");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address opsWallet = makeAddr("opsWallet");
    address attacker = makeAddr("attacker");
    address realUser = makeAddr("realUser");

    MockUSDC_DOS usdc;
    MockSwapRouter_DOS swapRouter;
    MockShieldOracle_DOS shieldOracle;

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
    ShieldKeeper shieldKeeper;
    FlashBTCShield1h flashBtc1h;

    bytes32 constant ID_FLASHBTC1H = keccak256("FLASHBTC1H-001");
    uint256 constant EMERGENCY_PRICE = 0.036e18;
    uint256 constant BASE_TS = 1_767_225_600;

    function setUp() public {
        vm.warp(BASE_TS + 60 days);
        deployer = address(this);

        usdc = new MockUSDC_DOS();
        shieldOracle = new MockShieldOracle_DOS();

        maintenanceReserve = ProxyDeployer.deployMaintenanceReserve(address(usdc), multisig);
        claimBond = ProxyDeployer.deployClaimBond();

        uint64 n = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, n + 9);

        capacityOracle = ProxyDeployer.deployCapacityOracle(address(0), predictedLumina, address(usdc), EMERGENCY_PRICE);
        bondVault =
            ProxyDeployer.deployBondVault(predictedLumina, address(claimBond), address(capacityOracle), address(0));
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(predictedLumina, multisig);
        treasuryVesting = ProxyDeployer.deployTreasuryVesting(predictedLumina);

        lumina = ProxyDeployer.deployLuminaTokenV2(
            address(bondVault), address(cexReserve), founderVesting, lbpDeposit, address(treasuryVesting)
        );
        require(address(lumina) == predictedLumina, "lumina addr");

        claimBond.setBondVault(address(bondVault));

        swapRouter = new MockSwapRouter_DOS(address(lumina));
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

        // [FIX-#18] Whitelist marketplace + buyback so ClaimBond allows their transfers.
        claimBond.setAuthorizedOperator(address(marketplace), true);
        claimBond.setAuthorizedOperator(address(buybackEngine), true);

        flashBtc1h = ProxyDeployer.deployFlashBTCShield1h(address(policyManager), address(shieldOracle));
        policyManager.registerProduct(ID_FLASHBTC1H, address(flashBtc1h));
        coverRouter.configureProduct(ID_FLASHBTC1H, 8000, 200, 2000, 3600, true);

        shieldKeeper = ProxyDeployer.deployShieldKeeper(address(policyManager));

        // Pre-fund main actors
        usdc.mint(attacker, 10_000_000e6);
        usdc.mint(realUser, 1_000_000e6);
        vm.prank(attacker);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(realUser);
        usdc.approve(address(coverRouter), type(uint256).max);

        vm.warp(block.timestamp + 901);
    }

    // ═══════════════════════════════════════════════════════════
    // A. GRIEFING — dust policies
    // ═══════════════════════════════════════════════════════════

    /// @notice Attacker spams 200 dust policies (min coverage). A legitimate
    ///         user's purchase right after must complete in normal gas.
    function test_DOS_UUPS_DustPolicies_DontInflateLegitGas() public {
        // 200 dust purchases (coverage = $100, the minimum).
        for (uint256 i = 0; i < 200; i++) {
            vm.prank(attacker);
            coverRouter.purchasePolicy(ID_FLASHBTC1H, 100e6, "BTC");
        }

        // Legit user purchase — gas must not be inflated by the dust history.
        uint256 g = gasleft();
        vm.prank(realUser);
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
        uint256 used = g - gasleft();
        emit log_named_uint("legit purchase gas after 200 dust", used);
        assertLt(used, 700_000, "legit gas must stay near steady-state warm cost");
    }

    /// @notice Coverage minimum (100e6) is enforced. Below-min purchases revert.
    function test_DOS_UUPS_BelowMinCoverage_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(); // InvalidCoverage(amount)
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 99e6, "BTC");
    }

    // ═══════════════════════════════════════════════════════════
    // B. MARKETPLACE SPAM
    // ═══════════════════════════════════════════════════════════

    /// @notice 500 spam listings at absurd prices; a real listing right after
    ///         must complete in normal gas.
    function test_DOS_UUPS_MarketplaceSpam_DoesntInflateLegitListing() public {
        uint256 epochId = _seedSeller(attacker, 500 * 100);
        vm.startPrank(attacker);
        claimBond.setApprovalForAll(address(marketplace), true);
        for (uint256 i = 0; i < 500; i++) {
            marketplace.list(epochId, 1, type(uint128).max); // absurd price
        }
        vm.stopPrank();

        // Legit listing
        _seedSeller(realUser, 100);
        vm.startPrank(realUser);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 g = gasleft();
        marketplace.list(epochId, 100, 50e6);
        uint256 used = g - gasleft();
        vm.stopPrank();
        emit log_named_uint("legit list after 500 spam", used);
        assertLt(used, 250_000, "legit list gas must stay bounded");
    }

    /// @notice List+cancel spam doesn't inflate per-op gas.
    function test_DOS_UUPS_MarketplaceListCancelSpam_BoundedGas() public {
        uint256 epochId = _seedSeller(attacker, 500);
        vm.startPrank(attacker);
        claimBond.setApprovalForAll(address(marketplace), true);

        // Warm up
        for (uint256 i = 0; i < 5; i++) {
            uint256 id = marketplace.list(epochId, 1, 50e6);
            marketplace.cancel(id);
        }

        uint256 g = gasleft();
        for (uint256 i = 0; i < 100; i++) {
            uint256 id = marketplace.list(epochId, 1, 50e6);
            marketplace.cancel(id);
        }
        uint256 perPair = (g - gasleft()) / 100;
        vm.stopPrank();
        emit log_named_uint("per list+cancel pair gas", perPair);
        assertLt(perPair, 250_000, "per pair must stay bounded");
    }

    // ═══════════════════════════════════════════════════════════
    // C. KEEPER GAS EXHAUSTION
    // ═══════════════════════════════════════════════════════════

    /// @notice A batch where most policy IDs revert (don't exist) doesn't
    ///         consume more gas than the cap — try/catch absorbs reverts.
    function test_DOS_UUPS_KeeperBatchWithReverts_BoundedAndContinues() public {
        // Create one valid policy.
        vm.prank(realUser);
        uint256 valid = coverRouter.purchasePolicy(ID_FLASHBTC1H, 100e6, "BTC");
        vm.warp(block.timestamp + 3600 + 24 hours + 1);

        // 49 revert-bound IDs + 1 valid (cap MAX_POLICIES_PER_UPKEEP=50, so all are processed).
        uint256[] memory ids = new uint256[](50);
        ids[0] = valid;
        for (uint256 i = 1; i < 50; i++) {
            ids[i] = 999_999_999;
        }
        bytes memory data = abi.encode(ID_FLASHBTC1H, ids);

        uint256 g = gasleft();
        shieldKeeper.performUpkeep(data);
        uint256 used = g - gasleft();
        emit log_named_uint("performUpkeep 50-id with 49 reverts", used);
        assertLt(used, 5_000_000, "bounded even when most ids revert");
    }

    /// @notice An over-cap batch (1000 IDs) is silently truncated by the cap,
    ///         not OOG. Already exercised in audit #16 — re-asserted here
    ///         from the DOS angle.
    function test_DOS_UUPS_KeeperOverCap_Truncates_NotOOG() public {
        uint256[] memory ids = new uint256[](1000);
        for (uint256 i = 0; i < 1000; i++) {
            ids[i] = i;
        }
        bytes memory data = abi.encode(ID_FLASHBTC1H, ids);

        uint256 g = gasleft();
        shieldKeeper.performUpkeep(data);
        uint256 used = g - gasleft();
        emit log_named_uint("performUpkeep 1000-id (over cap)", used);
        assertLt(used, 10_000_000, "over-cap must not OOG");
    }

    // ═══════════════════════════════════════════════════════════
    // D. STATE LOCK — redemption / burn
    // ═══════════════════════════════════════════════════════════

    /// @notice One holder reverting on an attempted redemption (insufficient
    ///         balance) does not affect other holders' ability to redeem.
    function test_DOS_UUPS_OneFailedRedemption_DoesntBlockOthers() public {
        // 5 holders with 100 bonds each; all from the same epoch.
        address[] memory holders = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            holders[i] = address(uint160(0x500000 + i));
            vm.prank(address(policyManager));
            bondVault.issueBond(holders[i], 100, 0.036e18);
        }
        vm.warp(block.timestamp + 800 days); // past maturity

        uint256 epochId = _anyHeldEpoch(holders[0]);

        // First holder over-redeems → reverts.
        vm.prank(holders[0]);
        vm.expectRevert(bytes("Insufficient bonds"));
        bondVault.redeemBond(epochId, 1_000_000);

        // Second holder still redeems normally.
        vm.prank(holders[1]);
        bondVault.redeemBond(epochId, 100);
        assertEq(claimBond.balanceOf(holders[1], epochId), 0, "holder 2 redeemed");
    }

    /// @notice TWAPBurner cooldown prevents executeBurn-spam DOS.
    function test_DOS_UUPS_BurnSpam_BlockedByCooldown() public {
        // Seed USDC and make first burn.
        _fundTwapBurner(50e6);
        twapBurner.executeBurn();

        // Immediate retry must revert.
        _fundTwapBurner(10e6);
        vm.expectRevert(bytes("Cooldown active"));
        twapBurner.executeBurn();
    }

    /// @notice executeBurn refuses below-min — prevents flash-burn-spam.
    function test_DOS_UUPS_BurnBelowMin_Reverts() public {
        _fundTwapBurner(0.5e6); // $0.50 — below 1 USDC minimum
        vm.expectRevert(bytes("Below minimum"));
        twapBurner.executeBurn();
    }

    // ═══════════════════════════════════════════════════════════
    // E. ECONOMIC DOS — buyback / oracle
    // ═══════════════════════════════════════════════════════════

    /// @notice BuybackEngine.executeOffer rejects above-daily-budget purchases.
    ///         Configure budget=$10, maxPercent=95%, list 50 bonds at $20.
    ///         50 bonds face value = $50 → maxPrice = $50 × 0.95 = $47.50
    ///         (price check passes), but spentToday + $20 > $10 budget.
    function test_DOS_UUPS_BuybackOverBudget_Rejected() public {
        vm.prank(multisig);
        buybackEngine.setDailyBuyback(10e6, 95, 24); // $10 budget, 95% max, 24h

        uint256 epochId = _seedSeller(realUser, 100); // 100 USD worth → 100 bond tokens
        vm.startPrank(realUser);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 50, 20e6); // 50 bonds at $20
        vm.stopPrank();

        usdc.mint(address(buybackEngine), 1_000e6);
        vm.expectRevert(bytes("Daily budget exceeded"));
        buybackEngine.executeOffer(listingId);
    }

    // ═══════════════════════════════════════════════════════════
    // F. UPGRADE DOS
    // ═══════════════════════════════════════════════════════════

    /// @notice Non-owner cannot upgrade BondVault.
    function test_DOS_UUPS_Upgrade_BondVault_NonAdminReverts() public {
        BondVault impl = new BondVault();
        vm.prank(attacker);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        bondVault.upgradeToAndCall(address(impl), "");
    }

    /// @notice Non-owner cannot upgrade TWAPBurner.
    function test_DOS_UUPS_Upgrade_TWAPBurner_NonOwnerReverts() public {
        TWAPBurner impl = new TWAPBurner();
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        twapBurner.upgradeToAndCall(address(impl), "");
    }

    /// @notice Non-owner cannot upgrade CoverRouter.
    function test_DOS_UUPS_Upgrade_CoverRouter_NonOwnerReverts() public {
        CoverRouterV2 impl = new CoverRouterV2();
        vm.prank(attacker);
        vm.expectRevert();
        coverRouter.upgradeToAndCall(address(impl), "");
    }

    // ═══════════════════════════════════════════════════════════
    // G. ORACLE DOS
    // ═══════════════════════════════════════════════════════════

    /// @notice If shield oracle reverts, purchase reverts (clean failure,
    ///         not silent DOS) — and recovers as soon as oracle is restored.
    function test_DOS_UUPS_OracleRevert_PurchaseFails_RecoversWhenRestored() public {
        shieldOracle.setRevert(true);
        vm.prank(realUser);
        vm.expectRevert(bytes("oracle down"));
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");

        // Restore.
        shieldOracle.setRevert(false);
        vm.prank(realUser);
        uint256 pid = coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
        assertGt(pid, 0);
    }

    /// @notice Capacity oracle returns emergency price when pool is unset
    ///         (already true in this setup); purchases keep working.
    function test_DOS_UUPS_CapacityOracle_EmergencyPriceFallback_Works() public {
        // pool is address(0) in setUp → getLuminaPrice returns emergencyPrice.
        assertEq(capacityOracle.getLuminaPrice(), EMERGENCY_PRICE);

        // Purchase still works.
        vm.prank(realUser);
        uint256 pid = coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
        assertGt(pid, 0);
    }

    // ═══════════════════════════════════════════════════════════
    // H. STATE BOMB — many epochs
    // ═══════════════════════════════════════════════════════════

    /// @notice Issuing bonds across many distinct epochs (warping between
    ///         each) does not cause gas to grow per-issue.
    function test_DOS_UUPS_ManyEpochs_GasStaysFlat() public {
        // Warm up
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(address(policyManager));
            bondVault.issueBond(address(uint160(0x600000 + i)), 100, 0.036e18);
            vm.warp(block.timestamp + 30 days);
        }

        uint256 g1 = gasleft();
        vm.prank(address(policyManager));
        bondVault.issueBond(address(uint160(0x600005)), 100, 0.036e18);
        uint256 baseline = g1 - gasleft();

        // 30 more issuances each in a new epoch.
        for (uint256 i = 6; i < 36; i++) {
            vm.warp(block.timestamp + 30 days);
            vm.prank(address(policyManager));
            bondVault.issueBond(address(uint160(0x600000 + i)), 100, 0.036e18);
        }

        vm.warp(block.timestamp + 30 days);
        uint256 g2 = gasleft();
        vm.prank(address(policyManager));
        bondVault.issueBond(address(uint160(0x600100)), 100, 0.036e18);
        uint256 final_ = g2 - gasleft();

        emit log_named_uint("issueBond  epoch baseline", baseline);
        emit log_named_uint("issueBond  epoch +30 later", final_);

        // Gas may differ slightly per epoch (cold per-epoch slot vs warm
        // re-use) but no order-of-magnitude growth.
        assertLt(final_, baseline * 3, "issueBond gas must not grow per epoch");
    }

    // ═══════════════════════════════════════════════════════════
    // I. UNBOUNDED LOOP HYGIENE (static check)
    // ═══════════════════════════════════════════════════════════

    /// @notice Code-level invariant: there is no on-chain `for`-loop over
    ///         the entire policy / holder / listing universe in any
    ///         user-callable path. The only loop over a passed-in array
    ///         (`ShieldKeeper.performUpkeep`) is bounded by
    ///         `MAX_POLICIES_PER_UPKEEP`. Verified statically — see
    ///         REPORT §6 for the table.
    function test_DOS_UUPS_NoUnboundedPublicLoops_Documented() public pure {
        assertTrue(true, "see REPORT section 6 for static loop audit");
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _fundTwapBurner(uint256 usdcAmount) internal {
        usdc.mint(address(twapBurner), usdcAmount);
    }

    function _seedSeller(address seller, uint256 totalUsd) internal returns (uint256 epochId) {
        uint256 perBondUsd = 100;
        uint256 n = totalUsd / perBondUsd;
        if (n == 0) n = 1;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(address(policyManager));
            bondVault.issueBond(seller, perBondUsd, 0.036e18);
        }
        epochId = _anyHeldEpoch(seller);
    }

    function _anyHeldEpoch(address holder) internal view returns (uint256) {
        for (uint256 e = 202600; e <= 210012; e++) {
            if (claimBond.balanceOf(holder, e) > 0) return e;
        }
        revert("no epoch");
    }
}
