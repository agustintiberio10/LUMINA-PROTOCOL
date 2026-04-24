// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {ShieldKeeper} from "../../../../../src/automation/ShieldKeeper.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {CapacityOracle} from "../../../../../src/oracles/CapacityOracle.sol";
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {MaintenanceReserve} from "../../../../../src/treasury/MaintenanceReserve.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

contract MockERC20Owner is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
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

contract InertRouter is IDexRouter {
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract FakeOracleOwner {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

contract FakeMarketplaceOwner {
    uint256 public constant BUYER_FEE_BPS = 150;
    uint256 public constant BPS_DENOMINATOR = 10000;

    function executeBuy(uint256) external {}

    function getListing(uint256) external pure returns (address, uint256, uint256, uint256, bool) {
        return (address(0), 0, 0, 0, false);
    }
}

contract MockPoolV3 {
    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        if (t0 < t1) {
            token0 = t0;
            token1 = t1;
        } else {
            token0 = t1;
            token1 = t0;
        }
    }

    function slot0() external pure returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool) {
        sqrtPriceX96 = 79228162514264337593543950336;
    }

    function fee() external pure returns (uint24) {
        return 3000;
    }
}

contract OwnerOperationsTest is Test {
    event ConfigUpdated(string param, uint256 value);
    event ProductConfigured(bytes32 indexed productId);
    event Paused(bool state);
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);

    address internal admin = address(this);
    address internal attacker = makeAddr("attacker");

    // ═════════════════════ helpers ═════════════════════

    function _deployTB() internal returns (TWAPBurner tb) {
        MockERC20Owner u = new MockERC20Owner("USDC", "USDC");
        MockERC20Owner l = new MockERC20Owner("LUM", "LUM");
        tb = ProxyDeployer.deployTWAPBurner(address(u), address(l), address(new InertRouter()));
    }

    function _deployCR() internal returns (CoverRouterV2 r) {
        r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("pm"), makeAddr("b"));
    }

    function _deployBV() internal returns (BondVault vault, ClaimBond cb, MockERC20Owner lumina) {
        lumina = new MockERC20Owner("LUM", "LUM");
        cb = ProxyDeployer.deployClaimBond();
        FakeOracleOwner oracle = new FakeOracleOwner();
        vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        cb.setBondVault(address(vault));
    }

    function _deployBE() internal returns (BuybackEngine be, MockERC20Owner usdc, ClaimBond cb) {
        usdc = new MockERC20Owner("USDC", "USDC");
        cb = ProxyDeployer.deployClaimBond();
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        FakeOracleOwner oracle = new FakeOracleOwner();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        SolvencyOracle sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(oracle), admin);
        address mp = address(new FakeMarketplaceOwner());
        be = ProxyDeployer.deployBuybackEngine(
            address(cb), address(vault), address(sol), address(oracle), mp, address(usdc), admin
        );
    }

    function _deploySolvency() internal returns (SolvencyOracle sol) {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracleOwner oracle = new FakeOracleOwner();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(oracle), admin);
    }

    // ═════════════════════ A. Boundary validation ═════════════════════

    function test_Admin_TWAPBurner_SetPoolFee_OnlyValidTiers() public {
        TWAPBurner tb = _deployTB();
        tb.setPoolFee(500);
        tb.setPoolFee(3000);
        tb.setPoolFee(10000);
        vm.expectRevert(bytes("Invalid fee tier"));
        tb.setPoolFee(100);
        vm.expectRevert(bytes("Invalid fee tier"));
        tb.setPoolFee(5000);
    }

    function test_Admin_TWAPBurner_SetMaxSlippageBps_BoundedRange() public {
        TWAPBurner tb = _deployTB();
        tb.setMaxSlippageBps(50);
        tb.setMaxSlippageBps(1000);
        vm.expectRevert(bytes("Slippage: 0.5%-10%"));
        tb.setMaxSlippageBps(49);
        vm.expectRevert(bytes("Slippage: 0.5%-10%"));
        tb.setMaxSlippageBps(1001);
    }

    function test_Admin_TWAPBurner_SetMinBurnAmount_MinFloorEnforced() public {
        TWAPBurner tb = _deployTB();
        tb.setMinBurnAmount(0.1e6);
        vm.expectRevert(bytes("Min too low"));
        tb.setMinBurnAmount(0.1e6 - 1);
    }

    function test_Admin_TWAPBurner_SetMaxBurnAmount_CannotBeBelowMin() public {
        TWAPBurner tb = _deployTB();
        tb.setMinBurnAmount(100e6);
        vm.expectRevert(bytes("Max < min"));
        tb.setMaxBurnAmount(99e6);
        tb.setMaxBurnAmount(100e6);
    }

    function test_Admin_TWAPBurner_SetBurnCooldown_BoundedRange() public {
        TWAPBurner tb = _deployTB();
        tb.setBurnCooldown(60);
        tb.setBurnCooldown(86400);
        vm.expectRevert(bytes("Cooldown: 1min-24hr"));
        tb.setBurnCooldown(59);
        vm.expectRevert(bytes("Cooldown: 1min-24hr"));
        tb.setBurnCooldown(86401);
    }

    function test_Admin_TWAPBurner_SetCapacityOracle_RejectsZero() public {
        TWAPBurner tb = _deployTB();
        vm.expectRevert(bytes("Zero oracle"));
        tb.setCapacityOracle(address(0));
    }

    function test_Admin_BuybackEngine_SetDailyBuyback_MaxPercentCapped() public {
        (BuybackEngine be,,) = _deployBE();
        vm.expectRevert(bytes("Max percent 1-95"));
        be.setDailyBuyback(1000e18, 96, 24);
        vm.expectRevert(bytes("Max percent 1-95"));
        be.setDailyBuyback(1000e18, 0, 24);
        be.setDailyBuyback(1000e18, 95, 24);
    }

    function test_Admin_CoverRouter_ConfigureProduct_DurationMustBePositive() public {
        CoverRouterV2 router = _deployCR();
        vm.expectRevert(bytes("Duration must be > 0"));
        router.configureProduct(keccak256("P"), 8000, 100, 15000, 0, true);
        router.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);
    }

    function test_Admin_CoverRouter_SetPolicyManager_RejectsZero() public {
        CoverRouterV2 router = _deployCR();
        vm.expectRevert(bytes("Zero"));
        router.setPolicyManager(address(0));
    }

    function test_Admin_CoverRouter_SetTwapBurner_RejectsZero() public {
        CoverRouterV2 router = _deployCR();
        vm.expectRevert(bytes("Zero"));
        router.setTwapBurner(address(0));
    }

    function test_Admin_BondVault_SetAuthorizedCaller_RejectsZero() public {
        (BondVault vault,,) = _deployBV();
        vm.expectRevert(bytes("Zero address"));
        vault.setAuthorizedCaller(address(0), true);
    }

    // ═════════════════════ B. Pause / unpause ═════════════════════

    function test_Admin_CoverRouter_SetPaused_BlocksPurchase() public {
        CoverRouterV2 router = _deployCR();
        router.setPaused(true);
        assertTrue(router.paused());
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        router.purchasePolicy(keccak256("P"), 100e6, "BTC");
    }

    function test_Admin_CoverRouter_Unpause_RestoresPurchaseAttempt() public {
        CoverRouterV2 router = _deployCR();
        router.setPaused(true);
        router.setPaused(false);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.ProductNotConfigured.selector, keccak256("X")));
        router.purchasePolicy(keccak256("X"), 100e6, "BTC");
    }

    function test_Admin_CoverRouter_Pause_EmitsEvent() public {
        CoverRouterV2 router = _deployCR();
        vm.expectEmit(false, false, false, true, address(router));
        emit Paused(true);
        router.setPaused(true);
    }

    function test_Admin_CoverRouter_Pause_NonOwnerReverts() public {
        CoverRouterV2 router = _deployCR();
        vm.prank(attacker);
        vm.expectRevert();
        router.setPaused(true);
    }

    function test_Admin_ShieldKeeper_PauseUnpause_Works() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        assertTrue(k.paused());
        k.unpause();
        assertFalse(k.paused());
    }

    function test_Admin_ShieldKeeper_Pause_NonOwnerReverts() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        vm.prank(attacker);
        vm.expectRevert();
        k.pause();
    }

    function test_Admin_ShieldKeeper_PauseIsIdempotent() public {
        // ShieldKeeper uses a plain `bool paused` (not OZ Pausable).
        // Calling pause() twice is a no-op — the second call does NOT revert.
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        assertTrue(k.paused());
        k.pause();
        assertTrue(k.paused());
    }

    function test_Admin_ShieldKeeper_UnpauseWhenNotPausedIsNoop() public {
        // Same — unpause on an unpaused keeper is a no-op.
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.unpause();
        assertFalse(k.paused());
    }

    function test_Admin_SolvencyOracle_EmergencyPause_BlocksEvaluate() public {
        SolvencyOracle sol = _deploySolvency();
        sol.setEmergencyPause(true);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(bytes("Oracle paused"));
        sol.evaluate();
        sol.setEmergencyPause(false);
        sol.evaluate();
    }

    // ═════════════════════ C. Config changes don't corrupt pre-existing state ═════════════════════

    function test_Admin_CoverRouter_ReconfigureProduct_DoesNotDuplicateList() public {
        CoverRouterV2 router = _deployCR();
        router.configureProduct(keccak256("A"), 8000, 100, 15000, 3600, true);
        router.configureProduct(keccak256("B"), 7000, 200, 14000, 7200, true);
        assertEq(router.getProductCount(), 2);
        router.configureProduct(keccak256("A"), 9000, 150, 16000, 3600, true);
        assertEq(router.getProductCount(), 2);
        CoverRouterV2.ProductConfig memory cfg = router.getProductConfig(keccak256("A"));
        assertEq(cfg.payoutRatioBps, 9000);
    }

    function test_Admin_CoverRouter_ReconfigureProduct_CanToggleActive() public {
        CoverRouterV2 router = _deployCR();
        router.configureProduct(keccak256("A"), 8000, 100, 15000, 3600, true);
        assertTrue(router.getProductConfig(keccak256("A")).active);
        router.configureProduct(keccak256("A"), 8000, 100, 15000, 3600, false);
        assertFalse(router.getProductConfig(keccak256("A")).active);
    }

    function test_Admin_BondVault_RevokeAuthorizedCaller_ExistingStateUnaffected() public {
        // Warp to after BondVault epoch base (Jan 1 2026) so issueBond can map an epoch.
        vm.warp(1767225600 + 30 days);
        (BondVault vault,, MockERC20Owner lumina) = _deployBV();
        lumina.mint(address(vault), 70_000_000e18);

        address buyback = makeAddr("buyback");
        vault.setAuthorizedCaller(buyback, true);
        vault.issueBond(makeAddr("holder"), 10);
        uint256 committedBefore = vault.totalCommittedUSD();

        vault.setAuthorizedCaller(buyback, false);
        assertFalse(vault.authorizedCallers(buyback));
        assertEq(vault.totalCommittedUSD(), committedBefore);
    }

    // ═════════════════════ D. Role management flow ═════════════════════

    function test_Admin_BondVault_GrantRevoke_AuthorizedCallerAdminRole() public {
        (BondVault vault,,) = _deployBV();
        address newAdmin = makeAddr("newAdmin");

        vault.grantRole(vault.AUTHORIZED_CALLER_ADMIN_ROLE(), newAdmin);
        vm.prank(newAdmin);
        vault.setAuthorizedCaller(makeAddr("x"), true);
        assertTrue(vault.authorizedCallers(makeAddr("x")));

        vault.revokeRole(vault.AUTHORIZED_CALLER_ADMIN_ROLE(), newAdmin);
        vm.prank(newAdmin);
        vm.expectRevert();
        vault.setAuthorizedCaller(makeAddr("y"), true);
    }

    function test_Admin_MaintenanceReserve_GrantSpender_NewSpenderCanSpend() public {
        MockERC20Owner usdc = new MockERC20Owner("USDC", "USDC");
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);
        usdc.mint(address(mr), 100e6);

        address spender = makeAddr("spender");
        mr.grantRole(mr.SPENDER_ROLE(), spender);

        vm.prank(spender);
        mr.spend(makeAddr("target"), 10e6, MaintenanceReserve.SpendCategory.Other, "test");
        assertEq(usdc.balanceOf(makeAddr("target")), 10e6);
    }

    function test_Admin_CEX_GrantAllocator_NewAllocatorCanAllocate() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        CEXLiquidityReserve cex = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), admin);
        lumina.mint(address(cex), 10_000_000e18);

        address newAllocator = makeAddr("alloc");
        cex.grantRole(cex.ALLOCATOR_ROLE(), newAllocator);
        vm.prank(newAllocator);
        cex.allocate(
            makeAddr("recipient"),
            1000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "test alloc"
        );
        assertEq(lumina.balanceOf(makeAddr("recipient")), 1000e18);
    }

    function test_Admin_BondVault_NonAdmin_CannotGrantRole() public {
        (BondVault vault,,) = _deployBV();
        bytes32 role = vault.DEFAULT_ADMIN_ROLE(); // pre-compute to avoid vm.prank being consumed
        vm.prank(attacker);
        vm.expectRevert();
        vault.grantRole(role, attacker);
    }

    function test_Admin_Marketplace_GrantFeeManager_CanSetTwapBurner() public {
        MockERC20Owner usdc = new MockERC20Owner("USDC", "USDC");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), makeAddr("burner"), admin);

        address feeMgr = makeAddr("feeMgr");
        mp.grantRole(mp.FEE_MANAGER_ROLE(), feeMgr);

        vm.prank(feeMgr);
        mp.setTwapBurner(makeAddr("newBurner"));
        assertEq(mp.twapBurner(), makeAddr("newBurner"));
    }

    function test_Admin_SolvencyOracle_GrantAdminRole_NewCanPause() public {
        SolvencyOracle sol = _deploySolvency();
        address newAdmin = makeAddr("newAdmin");
        sol.grantRole(sol.ADMIN_ROLE(), newAdmin);

        vm.prank(newAdmin);
        sol.setEmergencyPause(true);
        assertTrue(sol.emergencyPaused());
    }

    // ═════════════════════ E. Ownership transfer (OZ v5 = 1-step) ═════════════════════

    function test_Admin_TreasuryVesting_TransferOwnership_OneStep() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(address(lumina));

        address newOwner = makeAddr("newOwner");
        tv.transferOwnership(newOwner);
        assertEq(tv.owner(), newOwner);

        vm.expectRevert();
        tv.transferOwnership(attacker);
    }

    function test_Admin_CoverRouter_TransferOwnership_OneStep() public {
        CoverRouterV2 router = _deployCR();
        address newOwner = makeAddr("newOwner");
        router.transferOwnership(newOwner);
        assertEq(router.owner(), newOwner);

        vm.prank(newOwner);
        router.setPaused(true);
        assertTrue(router.paused());
    }

    function test_Admin_TreasuryVesting_NonOwner_CannotTransfer() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(address(lumina));

        vm.prank(attacker);
        vm.expectRevert();
        tv.transferOwnership(attacker);
    }

    // ═════════════════════ F. Admin invariants — safety constants ═════════════════════

    function test_Admin_BondVault_CannotModifySafetyFactor() public {
        (BondVault vault,,) = _deployBV();
        (bool ok,) = address(vault).call(abi.encodeWithSignature("setSafetyFactor(uint256)", uint256(10000)));
        assertFalse(ok);
        assertEq(vault.SAFETY_FACTOR_BPS(), 5000);
    }

    function test_Admin_BondVault_CannotModifyMinRedeemPrice() public {
        (BondVault vault,,) = _deployBV();
        (bool ok,) = address(vault).call(abi.encodeWithSignature("setMinRedeemPrice(uint256)", uint256(0)));
        assertFalse(ok);
        assertEq(vault.MIN_REDEEM_PRICE(), 0.001e18);
    }

    function test_Admin_CoverRouter_CannotLowerMinPrice() public {
        CoverRouterV2 router = _deployCR();
        assertEq(router.MIN_PRICE_FOR_NEW_POLICIES(), 5e15);
        (bool ok,) = address(router).call(abi.encodeWithSignature("setMinPrice(uint256)", uint256(1)));
        assertFalse(ok);
    }

    function test_Admin_TWAPBurner_CannotDisableCooldown() public {
        TWAPBurner tb = _deployTB();
        vm.expectRevert(bytes("Cooldown: 1min-24hr"));
        tb.setBurnCooldown(0);
    }

    function test_Admin_Marketplace_CannotModifyFeeConstants() public {
        MockERC20Owner usdc = new MockERC20Owner("USDC", "USDC");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), makeAddr("burner"), admin);

        assertEq(mp.SELLER_FEE_BPS(), 150);
        assertEq(mp.BUYER_FEE_BPS(), 150);
        (bool ok,) = address(mp).call(abi.encodeWithSignature("setSellerFee(uint256)", uint256(500)));
        assertFalse(ok);
    }

    // ═════════════════════ G. Event emission ═════════════════════

    function test_Admin_TWAPBurner_SetMaxSlippageBps_EmitsConfigUpdated() public {
        TWAPBurner tb = _deployTB();
        vm.expectEmit(false, false, false, true, address(tb));
        emit ConfigUpdated("maxSlippageBps", 300);
        tb.setMaxSlippageBps(300);
    }

    function test_Admin_CoverRouter_ConfigureProduct_EmitsEvent() public {
        CoverRouterV2 router = _deployCR();
        vm.expectEmit(true, false, false, false, address(router));
        emit ProductConfigured(keccak256("P"));
        router.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);
    }

    function test_Admin_BondVault_SetAuthorizedCaller_EmitsEvent() public {
        (BondVault vault,,) = _deployBV();
        vm.expectEmit(true, false, false, true, address(vault));
        emit AuthorizedCallerUpdated(makeAddr("bb"), true);
        vault.setAuthorizedCaller(makeAddr("bb"), true);
    }

    // ═════════════════════ H. Upgrade authorization (untested proxies) ═════════════════════

    function test_Admin_MaintenanceReserve_Upgrade_OnlyAdmin() public {
        MockERC20Owner usdc = new MockERC20Owner("USDC", "USDC");
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);
        MaintenanceReserve newImpl = new MaintenanceReserve();

        vm.prank(attacker);
        vm.expectRevert();
        mr.upgradeToAndCall(address(newImpl), "");

        mr.upgradeToAndCall(address(newImpl), "");
    }

    function test_Admin_ClaimBond_Upgrade_OnlyOwner() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        ClaimBond newImpl = new ClaimBond();

        vm.prank(attacker);
        vm.expectRevert();
        cb.upgradeToAndCall(address(newImpl), "");

        cb.upgradeToAndCall(address(newImpl), "");
    }

    function test_Admin_BuybackEngine_Upgrade_OnlyAdmin() public {
        (BuybackEngine be,,) = _deployBE();
        BuybackEngine newImpl = new BuybackEngine();

        vm.prank(attacker);
        vm.expectRevert();
        be.upgradeToAndCall(address(newImpl), "");

        be.upgradeToAndCall(address(newImpl), "");
    }

    function test_Admin_Marketplace_Upgrade_OnlyAdmin() public {
        MockERC20Owner usdc = new MockERC20Owner("USDC", "USDC");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), makeAddr("burner"), admin);
        LuminaBondMarketplace newImpl = new LuminaBondMarketplace();

        vm.prank(attacker);
        vm.expectRevert();
        mp.upgradeToAndCall(address(newImpl), "");

        mp.upgradeToAndCall(address(newImpl), "");
    }

    function test_Admin_SolvencyOracle_Upgrade_OnlyAdmin() public {
        SolvencyOracle sol = _deploySolvency();
        SolvencyOracle newImpl = new SolvencyOracle();

        vm.prank(attacker);
        vm.expectRevert();
        sol.upgradeToAndCall(address(newImpl), "");

        sol.upgradeToAndCall(address(newImpl), "");
    }

    // ═════════════════════ I. Renunciation ═════════════════════

    function test_Admin_BondVault_RenounceRole_LosesAdminPermanently() public {
        (BondVault vault,,) = _deployBV();
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vault.renounceRole(role, admin);
        assertFalse(vault.hasRole(role, admin));
        // After renounce, the only way to re-grant DEFAULT_ADMIN_ROLE is for someone
        // who still has it to call grantRole — but nobody does. Prove no address
        // can re-grant by having attacker try (also should revert).
        vm.prank(attacker);
        vm.expectRevert();
        vault.grantRole(role, admin);
    }

    function test_Admin_TreasuryVesting_RenounceOwnership_Permanent() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(address(lumina));
        tv.renounceOwnership();
        assertEq(tv.owner(), address(0));
        vm.expectRevert();
        tv.transferOwnership(admin);
    }

    // ═════════════════════ J. Misc non-admin rejections ═════════════════════

    function test_Admin_Marketplace_SetTwapBurner_RejectsZero() public {
        MockERC20Owner usdc = new MockERC20Owner("USDC", "USDC");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), makeAddr("burner"), admin);
        vm.expectRevert(bytes("Zero"));
        mp.setTwapBurner(address(0));
    }

    function test_Admin_BuybackEngine_NonAdmin_CannotSetBudget() public {
        (BuybackEngine be,,) = _deployBE();
        vm.prank(attacker);
        vm.expectRevert();
        be.setDailyBuyback(1000e18, 50, 24);
    }

    function test_Admin_PolicyManager_NonOwner_CannotRegisterProduct() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("v"));
        vm.prank(attacker);
        vm.expectRevert();
        pm.registerProduct(keccak256("P"), makeAddr("s"));
    }

    function test_Admin_CoverRouter_ConfigureProduct_NonOwner_Reverts() public {
        CoverRouterV2 router = _deployCR();
        vm.prank(attacker);
        vm.expectRevert();
        router.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);
    }

    // ═════════════════════ K. BondVault 2-step policyManager setter ═════════════════════

    function test_Admin_BondVault_SetPolicyManager_OneShotOnly() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracleOwner oracle = new FakeOracleOwner();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), address(0));

        vault.setPolicyManager(makeAddr("pm1"));
        assertEq(vault.policyManager(), makeAddr("pm1"));

        vm.expectRevert(bytes("PolicyManager already set"));
        vault.setPolicyManager(makeAddr("pm2"));
    }

    function test_Admin_BondVault_SetPolicyManager_OnlyDeployer() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracleOwner oracle = new FakeOracleOwner();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), address(0));

        vm.prank(attacker);
        vm.expectRevert(bytes("Only deployer"));
        vault.setPolicyManager(makeAddr("pm"));
    }

    function test_Admin_BondVault_SetPolicyManager_RejectsZero() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracleOwner oracle = new FakeOracleOwner();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), address(0));

        vm.expectRevert(bytes("Zero address"));
        vault.setPolicyManager(address(0));
    }

    // ═════════════════════ L. CapacityOracle admin ═════════════════════

    function test_Admin_CapacityOracle_NonOwner_CannotSetEmergencyPrice() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        MockERC20Owner usdc = new MockERC20Owner("USDC", "USDC");
        address pool = address(new MockPoolV3(address(lumina), address(usdc)));
        CapacityOracle cap = ProxyDeployer.deployCapacityOracle(pool, address(lumina), address(usdc), 0.036e18);

        vm.prank(attacker);
        vm.expectRevert();
        cap.setEmergencyPrice(0.05e18);
    }

    function test_Admin_CapacityOracle_Owner_CanSetEmergencyPrice() public {
        MockERC20Owner lumina = new MockERC20Owner("LUM", "LUM");
        MockERC20Owner usdc = new MockERC20Owner("USDC", "USDC");
        address pool = address(new MockPoolV3(address(lumina), address(usdc)));
        CapacityOracle cap = ProxyDeployer.deployCapacityOracle(pool, address(lumina), address(usdc), 0.036e18);

        cap.setEmergencyPrice(0.05e18);
        assertEq(cap.emergencyPrice(), 0.05e18);
    }

    // ═════════════════════ M. Race-condition: pause mid-op ═════════════════════

    function test_Admin_CoverRouter_Pause_MidPurchaseBlocked() public {
        CoverRouterV2 router = _deployCR();
        router.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);
        router.setPaused(true);
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        router.purchasePolicy(keccak256("P"), 100e6, "BTC");
    }
}
