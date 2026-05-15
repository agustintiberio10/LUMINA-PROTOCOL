// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {CapacityOracle} from "../../../../../src/oracles/CapacityOracle.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../../src/treasury/MaintenanceReserve.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {FlashBTCShield1h} from "../../../../../src/products/FlashBTCShield1h.sol";
import {IShield} from "../../../../../src/interfaces/IShield.sol";

import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUSDC_DR {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockSwap_DR is IDexRouter {
    using SafeERC20 for IERC20;

    IERC20 public lumina;

    constructor(address _l) {
        lumina = IERC20(_l);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external returns (uint256 out) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        out = amountIn * 27 * 1e12;
        lumina.safeTransfer(msg.sender, out);
    }

    function getQuote(address, address, uint256 amountIn) external pure returns (uint256) {
        return amountIn * 27 * 1e12;
    }
}

contract MockShieldOracle_DR {
    mapping(bytes32 => int256) public prices;
    bool public revertOnRead;

    constructor() {
        prices["BTC"] = 65_000e8;
    }

    function setPrice(bytes32 a, int256 p) external {
        prices[a] = p;
    }

    function setRevert(bool v) external {
        revertOnRead = v;
    }

    function getLatestPrice(bytes32 a) external view returns (int256) {
        require(!revertOnRead, "oracle down");
        int256 p = prices[a];
        return p > 0 ? p : int256(1e8);
    }

    function getSequencerDowntime(uint256) external pure returns (uint256) {
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
 * @title DisasterRecovery
 * @notice Audits LUMINA V5.1's response to disaster scenarios:
 *           - BondVault drained / insufficient
 *           - Oracle returns extreme prices / reverts
 *           - Mass redemption (bank run)
 *           - LUMINA price collapse → auto-pause
 *           - Emergency-price admin recovery
 *           - Pause-during-redemption (bonds still redeemable)
 *           - Manual settlement without keeper
 *           - Multiple simultaneous disasters
 *           - Admin rotation
 *           - recoverToken restrictions
 */
contract DisasterRecovery is Test {
    ClaimBond claimBond;
    BondVault bondVault;
    LuminaTokenV2 lumina;
    CapacityOracle capacityOracle;
    CEXLiquidityReserve cexReserve;
    TreasuryVesting treasuryVesting;
    MaintenanceReserve maintenanceReserve;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;
    FlashBTCShield1h flashBtc1h;
    MockUSDC_DR usdc;
    MockSwap_DR swapRouter;
    MockShieldOracle_DR shieldOracle;

    address deployer;
    address multisig = makeAddr("multisig");
    address founder = makeAddr("founder");
    address lbpDeposit = makeAddr("lbpDeposit");
    address opsWallet = makeAddr("opsWallet");
    address holder = makeAddr("holder");
    address attacker = makeAddr("attacker");

    bytes32 constant ID_FLASHBTC1H = keccak256("FLASHBTC1H-001");
    uint256 constant BASE_TS = 1_767_225_600;

    function setUp() public {
        vm.chainId(8453);
        deployer = address(this);
        vm.warp(BASE_TS + 60 days);

        usdc = new MockUSDC_DR();
        shieldOracle = new MockShieldOracle_DR();

        maintenanceReserve = ProxyDeployer.deployMaintenanceReserve(address(usdc), multisig);
        claimBond = ProxyDeployer.deployClaimBond();

        uint64 n = vm.getNonce(deployer);
        address predictedLumina = vm.computeCreateAddress(deployer, n + 9);

        capacityOracle = ProxyDeployer.deployCapacityOracle(address(0), predictedLumina, address(usdc), 0.036e18);
        // Deploy BondVault with policyManager=0; wired after policyManager exists.
        bondVault =
            ProxyDeployer.deployBondVault(predictedLumina, address(claimBond), address(capacityOracle), address(0));
        cexReserve = ProxyDeployer.deployCEXLiquidityReserve(predictedLumina, multisig);
        treasuryVesting = ProxyDeployer.deployTreasuryVesting(predictedLumina);

        lumina = ProxyDeployer.deployLuminaTokenV2(
            address(bondVault), address(cexReserve), founder, lbpDeposit, address(treasuryVesting)
        );
        require(address(lumina) == predictedLumina, "lumina addr");
        claimBond.setBondVault(address(bondVault));

        swapRouter = new MockSwap_DR(address(lumina));
        deal(address(lumina), address(swapRouter), 1_000_000e18);

        twapBurner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(swapRouter));
        policyManager = ProxyDeployer.deployPolicyManagerV2(address(bondVault));
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        policyManager.setRouter(address(coverRouter));
        coverRouter.setCapacityOracle(address(capacityOracle));
        bondVault.setPolicyManager(address(policyManager));

        twapBurner.setAuthorizedSender(address(coverRouter), true);
        twapBurner.setReserves(address(0xCAFE), opsWallet, address(maintenanceReserve));
        twapBurner.setCapacityOracle(address(capacityOracle));
        lumina.grantRole(lumina.BURNER_ROLE(), address(twapBurner));

        flashBtc1h = ProxyDeployer.deployFlashBTCShield1h(address(policyManager), address(shieldOracle));
        policyManager.registerProduct(ID_FLASHBTC1H, address(flashBtc1h));
        coverRouter.configureProduct(ID_FLASHBTC1H, 8000, 200, 2000, 3600, true);
    }

    function _params(uint32 d, bytes32 a) internal returns (IShield.CreatePolicyParams memory p) {
        p.buyer = makeAddr("buyer");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = d;
        p.asset = a;
    }

    function _epochOf(address h) internal view returns (uint256) {
        for (uint256 e = 202600; e <= 210012; e++) {
            if (claimBond.balanceOf(h, e) > 0) return e;
        }
        revert("no epoch");
    }

    function _fundAndPurchase(address buyer, uint256 coverage) internal returns (uint256 pid) {
        usdc.mint(buyer, 1_000e6);
        vm.prank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(buyer);
        pid = coverRouter.purchasePolicy(ID_FLASHBTC1H, coverage, "BTC");
    }

    // ═══════════════════════════════════════════════════════════
    // A. BONDVAULT INSUFFICIENT
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_BondVault_Insufficient_Reverts() public {
        vm.prank(address(policyManager));
        bondVault.issueBond(holder, 100);
        uint256 epoch = _epochOf(holder);

        // Simulate post-drain state directly. burnFromReserves has a 5%-per-tx
        // cap so draining via that path takes many tx; in production the
        // vault would never reach zero naturally.
        deal(address(lumina), address(bondVault), 1);

        vm.warp(block.timestamp + 800 days);
        vm.prank(holder);
        vm.expectRevert(bytes("Insufficient reserve"));
        bondVault.redeemBond(epoch, 100);

        assertEq(claimBond.balanceOf(holder, epoch), 100, "balance preserved");
        assertEq(bondVault.totalCommittedUSD(), 100 * 1e18, "committed preserved");
    }

    // ═══════════════════════════════════════════════════════════
    // B. ORACLE MANIPULATION
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_Oracle_ExtremePrice_RejectedByM01Bounds() public {
        shieldOracle.setPrice("BTC", 100_000_000e8);
        usdc.mint(holder, 1_000e6);
        vm.prank(holder);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(holder);
        vm.expectRevert(); // PriceOutOfSanityBounds
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
    }

    function test_DR_UUPS_Oracle_ZeroPrice_Rejected() public {
        shieldOracle.setPrice("BTC", 0);
        usdc.mint(holder, 1_000e6);
        vm.prank(holder);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(holder);
        vm.expectRevert();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
    }

    function test_DR_UUPS_Oracle_Reverts_RecoverableWhenRestored() public {
        usdc.mint(holder, 1_000e6);
        vm.prank(holder);
        usdc.approve(address(coverRouter), type(uint256).max);

        shieldOracle.setRevert(true);
        vm.prank(holder);
        vm.expectRevert(bytes("oracle down"));
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");

        shieldOracle.setRevert(false);
        vm.prank(holder);
        uint256 pid = coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
        assertGt(pid, 0);
    }

    // ═══════════════════════════════════════════════════════════
    // C. LUMINA PRICE COLLAPSE → AUTO-PAUSE
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_LuminaCrash_AutoPause_BlocksNewPolicies() public {
        usdc.mint(holder, 100e6);
        vm.prank(holder);
        usdc.approve(address(coverRouter), type(uint256).max);

        capacityOracle.setEmergencyPrice(1e15);

        vm.prank(holder);
        vm.expectRevert();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
    }

    function test_DR_UUPS_LuminaCrash_AdminRestoresPrice_ResumeOps() public {
        usdc.mint(holder, 100e6);
        vm.prank(holder);
        usdc.approve(address(coverRouter), type(uint256).max);

        capacityOracle.setEmergencyPrice(1e15);
        vm.prank(holder);
        vm.expectRevert();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");

        capacityOracle.setEmergencyPrice(0.036e18);
        vm.prank(holder);
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
    }

    function test_DR_UUPS_CircuitBreaker_GetterReflectsBlocked() public {
        capacityOracle.setEmergencyPrice(1e15);
        bool blocked = coverRouter.isProtocolAutoPaused();
        assertTrue(blocked);
    }

    // ═══════════════════════════════════════════════════════════
    // D. EMERGENCY PRICE — ADMIN-ONLY
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_CapacityOracle_EmergencyPrice_AdminOnly() public {
        vm.prank(attacker);
        vm.expectRevert();
        capacityOracle.setEmergencyPrice(0.5e18);

        capacityOracle.setEmergencyPrice(0.05e18);
        assertEq(capacityOracle.getLuminaPrice(), 0.05e18);
    }

    // ═══════════════════════════════════════════════════════════
    // E. PAUSE — REDEMPTIONS STILL WORK
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_CoverRouter_Paused_BondRedemption_StillWorks() public {
        vm.prank(address(policyManager));
        bondVault.issueBond(holder, 100);
        uint256 epoch = _epochOf(holder);

        coverRouter.setPaused(true);

        vm.warp(block.timestamp + 800 days);

        vm.prank(holder);
        bondVault.redeemBond(epoch, 100);
        assertEq(claimBond.balanceOf(holder, epoch), 0);
    }

    function test_DR_UUPS_CoverRouter_Paused_NewPurchases_Reverted() public {
        usdc.mint(holder, 100e6);
        vm.prank(holder);
        usdc.approve(address(coverRouter), type(uint256).max);

        coverRouter.setPaused(true);

        vm.prank(holder);
        vm.expectRevert();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");
    }

    // ═══════════════════════════════════════════════════════════
    // F. KEEPER FAILURE — MANUAL SETTLE STILL WORKS
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_KeeperDown_AnyoneCanSettle() public {
        uint256 pid = _fundAndPurchase(holder, 1000e6);

        vm.warp(block.timestamp + 3600 + 24 hours + 1);

        vm.prank(makeAddr("randomCaller"));
        flashBtc1h.checkAndSettlePolicy(pid);
        assertEq(uint256(flashBtc1h.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    // ═══════════════════════════════════════════════════════════
    // G. MASS REDEMPTION (BANK RUN)
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_MassRedemption_100Holders_AllSucceedIfVaultSufficient() public {
        address[] memory holders = new address[](100);
        for (uint256 i = 0; i < 100; i++) {
            holders[i] = address(uint160(0x800000 + i));
            vm.prank(address(policyManager));
            bondVault.issueBond(holders[i], 10);
        }

        uint256 epoch = _epochOf(holders[0]);
        vm.warp(block.timestamp + 800 days);

        for (uint256 i = 0; i < 100; i++) {
            vm.prank(holders[i]);
            bondVault.redeemBond(epoch, 10);
        }
        assertEq(bondVault.totalCommittedUSD(), 0, "all obligations cleared");
    }

    function test_DR_UUPS_MassRedemption_Insufficient_LaterRevert_EarlierKeptFunds() public {
        address[] memory holders = new address[](20);
        for (uint256 i = 0; i < 20; i++) {
            holders[i] = address(uint160(0x900000 + i));
            vm.prank(address(policyManager));
            bondVault.issueBond(holders[i], 10_000);
        }
        uint256 epoch = _epochOf(holders[0]);
        vm.warp(block.timestamp + 800 days);

        // Drain to ~3M LUMINA so only ~5 of the 20 redemptions succeed.
        deal(address(lumina), address(bondVault), 3_000_000e18);

        uint256 succeeded;
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(holders[i]);
            try bondVault.redeemBond(epoch, 10_000) {
                succeeded++;
            } catch {}
        }
        assertGt(succeeded, 0, "at least early holders redeemed");
        assertLt(succeeded, 20, "later holders blocked by insufficient reserve");
    }

    // ═══════════════════════════════════════════════════════════
    // H. RECOVERY ADMIN PATHS
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_MaintenanceReserve_RecoverToken_BlocksUSDC() public {
        usdc.mint(address(maintenanceReserve), 1_000e6);
        vm.prank(multisig);
        vm.expectRevert(bytes("Cannot recover USDC"));
        maintenanceReserve.recoverToken(address(usdc), 500e6);
    }

    function test_DR_UUPS_MaintenanceReserve_RecoverToken_OtherTokens_Allowed() public {
        deal(address(lumina), address(maintenanceReserve), 100e18);
        vm.prank(multisig);
        maintenanceReserve.recoverToken(address(lumina), 100e18);
        assertEq(lumina.balanceOf(multisig), 100e18);
    }

    function test_DR_UUPS_TWAPBurner_RecoverToken_BlocksUSDC_AndLUMINA() public {
        usdc.mint(address(twapBurner), 1_000e6);
        deal(address(lumina), address(twapBurner), 1_000e18);

        vm.expectRevert();
        twapBurner.recoverToken(address(usdc), 500e6);

        vm.expectRevert();
        twapBurner.recoverToken(address(lumina), 500e18);
    }

    // ═══════════════════════════════════════════════════════════
    // I. ADMIN ROTATION
    // ═══════════════════════════════════════════════════════════

    function test_DR_UUPS_Admin_Rotation_TransferOwnership() public {
        coverRouter.transferOwnership(multisig);
        assertEq(coverRouter.owner(), multisig);

        vm.expectRevert();
        coverRouter.setPaused(true);

        vm.prank(multisig);
        coverRouter.setPaused(true);
        assertTrue(coverRouter.paused());
    }

    // ═══════════════════════════════════════════════════════════
    // J. MULTIPLE SIMULTANEOUS DISASTERS
    // ═══════════════════════════════════════════════════════════

    /// @notice Combined: shield oracle reverts + LUMINA crash + admin pause.
    ///         The protocol fails-safe: new policies blocked, redemptions
    ///         still possible (bonds were issued earlier).
    function test_DR_UUPS_TripleDisaster_FailsSafe() public {
        vm.prank(address(policyManager));
        bondVault.issueBond(holder, 100);
        uint256 epoch = _epochOf(holder);

        shieldOracle.setRevert(true);
        capacityOracle.setEmergencyPrice(1e15);
        coverRouter.setPaused(true);

        usdc.mint(holder, 100e6);
        vm.prank(holder);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(holder);
        vm.expectRevert();
        coverRouter.purchasePolicy(ID_FLASHBTC1H, 1000e6, "BTC");

        // Redemption uses CapacityOracle.getLuminaPrice = 1e15 which equals
        // MIN_REDEEM_PRICE (1e15) exactly → still passes the floor.
        vm.warp(block.timestamp + 800 days);
        vm.prank(holder);
        bondVault.redeemBond(epoch, 100);
        assertEq(claimBond.balanceOf(holder, epoch), 0);
    }
}
