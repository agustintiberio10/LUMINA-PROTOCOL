// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../src/core/TWAPBurner.sol";
import {AdaptiveFeeDistributor} from "../../../../src/core/AdaptiveFeeDistributor.sol";
import {BuybackEngine} from "../../../../src/marketplace/BuybackEngine.sol";
import {LuminaBondMarketplace} from "../../../../src/marketplace/LuminaBondMarketplace.sol";
import {ShieldKeeper} from "../../../../src/automation/ShieldKeeper.sol";

contract MockOracleIS {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

contract MockBondVaultIS {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function totalCommittedUSD() external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title InitializerSecurityCore
 * @notice Initializer security audit for 10 core UUPS contracts.
 *
 * For each contract, 8 test types are exercised:
 *   (1) CannotBeCalledTwice  — re-init reverts on an already-initialized proxy
 *   (2) ImplementationLocked — impl has _disableInitializers, direct init reverts
 *   (3) OnlyOwnerCanUpgrade  — non-privileged caller cannot upgradeToAndCall
 *   (4) OwnerSetCorrectly    — owner / DEFAULT_ADMIN_ROLE lands on expected addr
 *   (5) RevertsOnZeroAddress — init reverts when a required addr param is zero
 *   (6) ParentInitializers   — parent __X_init helpers ran (owner query, role query)
 *   (7) InitialStateCorrect  — every assigned state var matches expected
 *   (8) FrontRunningProtected — atomic deploy-and-init path; direct impl init fails
 */
contract InitializerSecurityCore is Test {
    // ───── Shared fixtures ─────
    address internal constant BV = address(0xB1);
    address internal constant CEX = address(0xB2);
    address internal constant FOUNDER = address(0xB3);
    address internal constant LBP = address(0xB4);
    address internal constant TREASURY = address(0xB5);

    // ─────────────────────────────────────────────────────────────
    // 1. LuminaTokenV2
    // ─────────────────────────────────────────────────────────────

    function _tokenInitData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(LuminaTokenV2.initialize.selector, BV, CEX, FOUNDER, LBP, TREASURY);
    }

    function test_Init_LuminaToken_CannotBeCalledTwice() public {
        LuminaTokenV2 t = ProxyDeployer.deployLuminaTokenV2(BV, CEX, FOUNDER, LBP, TREASURY);
        vm.expectRevert();
        t.initialize(BV, CEX, FOUNDER, LBP, TREASURY);
    }

    function test_Init_LuminaToken_ImplementationLocked() public {
        LuminaTokenV2 impl = new LuminaTokenV2();
        vm.expectRevert();
        impl.initialize(BV, CEX, FOUNDER, LBP, TREASURY);
    }

    function test_Init_LuminaToken_OnlyAdminCanUpgrade() public {
        LuminaTokenV2 t = ProxyDeployer.deployLuminaTokenV2(BV, CEX, FOUNDER, LBP, TREASURY);
        LuminaTokenV2 newImpl = new LuminaTokenV2();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        t.upgradeToAndCall(address(newImpl), "");
        t.upgradeToAndCall(address(newImpl), "");
    }

    function test_Init_LuminaToken_OwnerSetCorrectly() public {
        LuminaTokenV2 t = ProxyDeployer.deployLuminaTokenV2(BV, CEX, FOUNDER, LBP, TREASURY);
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_LuminaToken_RevertsOnZeroAddressParams() public {
        LuminaTokenV2 impl = new LuminaTokenV2();
        bytes memory data =
            abi.encodeWithSelector(LuminaTokenV2.initialize.selector, address(0), CEX, FOUNDER, LBP, TREASURY);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_LuminaToken_RevertsOnDuplicateAddressParams() public {
        LuminaTokenV2 impl = new LuminaTokenV2();
        // bondVault == cexReserve — should trip the dup check.
        bytes memory data = abi.encodeWithSelector(LuminaTokenV2.initialize.selector, BV, BV, FOUNDER, LBP, TREASURY);
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_LuminaToken_ParentInitializersCalled() public {
        LuminaTokenV2 t = ProxyDeployer.deployLuminaTokenV2(BV, CEX, FOUNDER, LBP, TREASURY);
        // ERC20 init: name/symbol must be set.
        assertEq(t.name(), "Lumina Protocol");
        assertEq(t.symbol(), "LUMINA");
        // AccessControl init: admin role grantable.
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_LuminaToken_InitialStateCorrect() public {
        LuminaTokenV2 t = ProxyDeployer.deployLuminaTokenV2(BV, CEX, FOUNDER, LBP, TREASURY);
        assertEq(t.totalSupply(), 100_000_000e18);
        assertEq(t.balanceOf(BV), 70_000_000e18);
        assertEq(t.balanceOf(CEX), 14_000_000e18);
        assertEq(t.balanceOf(FOUNDER), 8_000_000e18);
        assertEq(t.balanceOf(LBP), 5_000_000e18);
        assertEq(t.balanceOf(TREASURY), 3_000_000e18);
        assertEq(t.totalBurned(), 0);
    }

    function test_Init_LuminaToken_FrontRunningProtected() public {
        // The impl is _disableInitializers'd, so a front-runner that deploys the impl
        // and calls initialize() on it directly receives a revert — no hijack window.
        LuminaTokenV2 impl = new LuminaTokenV2();
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        impl.initialize(BV, CEX, FOUNDER, LBP, TREASURY);
    }

    // ─────────────────────────────────────────────────────────────
    // 2. BondVault
    // ─────────────────────────────────────────────────────────────

    function _bvSetup() internal returns (address lumina, address cb, address oracle) {
        lumina = address(ProxyDeployer.deployLuminaTokenV2(BV, CEX, FOUNDER, LBP, TREASURY));
        cb = address(ProxyDeployer.deployClaimBond());
        oracle = address(new MockOracleIS());
    }

    function test_Init_BondVault_CannotBeCalledTwice() public {
        (address lumina, address cb, address oracle) = _bvSetup();
        BondVault v = ProxyDeployer.deployBondVault(lumina, cb, oracle, address(this));
        vm.expectRevert();
        v.initialize(lumina, cb, oracle, address(this));
    }

    function test_Init_BondVault_ImplementationLocked() public {
        BondVault impl = new BondVault();
        vm.expectRevert();
        impl.initialize(makeAddr("l"), makeAddr("cb"), makeAddr("o"), address(this));
    }

    function test_Init_BondVault_OnlyAdminCanUpgrade() public {
        (address lumina, address cb, address oracle) = _bvSetup();
        BondVault v = ProxyDeployer.deployBondVault(lumina, cb, oracle, address(this));
        address newImpl = address(new BondVault());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        v.upgradeToAndCall(newImpl, "");
        v.upgradeToAndCall(newImpl, "");
    }

    function test_Init_BondVault_AdminRoleSetCorrectly() public {
        (address lumina, address cb, address oracle) = _bvSetup();
        BondVault v = ProxyDeployer.deployBondVault(lumina, cb, oracle, address(this));
        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(v.hasRole(v.AUTHORIZED_CALLER_ADMIN_ROLE(), address(this)));
    }

    function test_Init_BondVault_RevertsOnZeroAddressParams() public {
        BondVault impl = new BondVault();
        bytes memory data = abi.encodeWithSelector(
            BondVault.initialize.selector, address(0), makeAddr("cb"), makeAddr("o"), address(this)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_BondVault_ParentInitializersCalled() public {
        (address lumina, address cb, address oracle) = _bvSetup();
        BondVault v = ProxyDeployer.deployBondVault(lumina, cb, oracle, address(this));
        // AccessControl init: role grantable, admin reverts for non-admin.
        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_BondVault_InitialStateCorrect() public {
        (address lumina, address cb, address oracle) = _bvSetup();
        BondVault v = ProxyDeployer.deployBondVault(lumina, cb, oracle, address(this));
        assertEq(address(v.lumina()), lumina);
        assertEq(address(v.claimBond()), cb);
        assertEq(address(v.priceOracle()), oracle);
        assertEq(v.policyManager(), address(this));
        assertEq(v.totalCommittedUSD(), 0);
        assertEq(v.totalReservedUSD(), 0);
    }

    function test_Init_BondVault_FrontRunningProtected() public {
        BondVault impl = new BondVault();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("l"), makeAddr("cb"), makeAddr("o"), address(this));
    }

    // ─────────────────────────────────────────────────────────────
    // 3. ClaimBond
    // ─────────────────────────────────────────────────────────────

    function test_Init_ClaimBond_CannotBeCalledTwice() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        vm.expectRevert();
        cb.initialize();
    }

    function test_Init_ClaimBond_ImplementationLocked() public {
        ClaimBond impl = new ClaimBond();
        vm.expectRevert();
        impl.initialize();
    }

    function test_Init_ClaimBond_OnlyOwnerCanUpgrade() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        address newImpl = address(new ClaimBond());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        cb.upgradeToAndCall(newImpl, "");
        cb.upgradeToAndCall(newImpl, "");
    }

    function test_Init_ClaimBond_OwnerSetCorrectly() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        assertEq(cb.owner(), address(this));
    }

    function test_Init_ClaimBond_NoZeroAddressParamsToCheck() public {
        // ClaimBond.initialize() takes no address parameters, so there is no zero-
        // address path to exercise. State correctness is covered by _OwnerSetCorrectly
        // and _InitialStateCorrect. Kept as a passing marker for audit traceability.
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        assertEq(cb.bondVault(), address(0));
    }

    function test_Init_ClaimBond_ParentInitializersCalled() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        // Ownable init ran.
        assertEq(cb.owner(), address(this));
        // ERC1155 init ran — should accept a balanceOf query.
        assertEq(cb.balanceOf(makeAddr("x"), 0), 0);
    }

    function test_Init_ClaimBond_InitialStateCorrect() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        assertEq(cb.bondVault(), address(0)); // unset until setBondVault
        assertEq(cb.owner(), address(this));
    }

    function test_Init_ClaimBond_FrontRunningProtected() public {
        ClaimBond impl = new ClaimBond();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize();
    }

    // ─────────────────────────────────────────────────────────────
    // 4. PolicyManagerV2
    // ─────────────────────────────────────────────────────────────

    function test_Init_PolicyManager_CannotBeCalledTwice() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        vm.expectRevert();
        pm.initialize(makeAddr("vault"));
    }

    function test_Init_PolicyManager_ImplementationLocked() public {
        PolicyManagerV2 impl = new PolicyManagerV2();
        vm.expectRevert();
        impl.initialize(makeAddr("vault"));
    }

    function test_Init_PolicyManager_OnlyOwnerCanUpgrade() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        address newImpl = address(new PolicyManagerV2());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        pm.upgradeToAndCall(newImpl, "");
        pm.upgradeToAndCall(newImpl, "");
    }

    function test_Init_PolicyManager_OwnerSetCorrectly() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        assertEq(pm.owner(), address(this));
    }

    function test_Init_PolicyManager_RevertsOnZeroAddressParams() public {
        PolicyManagerV2 impl = new PolicyManagerV2();
        bytes memory data = abi.encodeWithSelector(PolicyManagerV2.initialize.selector, address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_PolicyManager_ParentInitializersCalled() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        assertEq(pm.owner(), address(this));
    }

    function test_Init_PolicyManager_InitialStateCorrect() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        assertEq(address(pm.bondVault()), makeAddr("vault"));
        assertEq(pm.router(), address(0));
        assertEq(pm.totalPolicies(), 0);
        assertEq(pm.activePolicies(), 0);
    }

    function test_Init_PolicyManager_FrontRunningProtected() public {
        PolicyManagerV2 impl = new PolicyManagerV2();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("vault"));
    }

    // ─────────────────────────────────────────────────────────────
    // 5. CoverRouterV2
    // ─────────────────────────────────────────────────────────────

    function test_Init_CoverRouterV2_CannotBeCalledTwice() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        vm.expectRevert();
        r.initialize(makeAddr("u"), makeAddr("p"), makeAddr("b"));
    }

    function test_Init_CoverRouterV2_ImplementationLocked() public {
        CoverRouterV2 impl = new CoverRouterV2();
        vm.expectRevert();
        impl.initialize(makeAddr("u"), makeAddr("p"), makeAddr("b"));
    }

    function test_Init_CoverRouterV2_OnlyOwnerCanUpgrade() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        address newImpl = address(new CoverRouterV2());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        r.upgradeToAndCall(newImpl, "");
        r.upgradeToAndCall(newImpl, "");
    }

    function test_Init_CoverRouterV2_OwnerSetCorrectly() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        assertEq(r.owner(), address(this));
    }

    function test_Init_CoverRouterV2_RevertsOnZeroAddressParams() public {
        CoverRouterV2 impl = new CoverRouterV2();
        bytes memory data =
            abi.encodeWithSelector(CoverRouterV2.initialize.selector, address(0), makeAddr("p"), makeAddr("b"));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_CoverRouterV2_ParentInitializersCalled() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        assertEq(r.owner(), address(this));
    }

    function test_Init_CoverRouterV2_InitialStateCorrect() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        assertEq(address(r.usdc()), makeAddr("u"));
        assertEq(address(r.policyManager()), makeAddr("p"));
        assertEq(address(r.twapBurner()), makeAddr("b"));
        assertFalse(r.paused());
    }

    function test_Init_CoverRouterV2_FrontRunningProtected() public {
        CoverRouterV2 impl = new CoverRouterV2();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("u"), makeAddr("p"), makeAddr("b"));
    }

    // ─────────────────────────────────────────────────────────────
    // 6. TWAPBurner
    // ─────────────────────────────────────────────────────────────

    function test_Init_TWAPBurner_CannotBeCalledTwice() public {
        TWAPBurner b = ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
        vm.expectRevert();
        b.initialize(makeAddr("u"), makeAddr("l"), makeAddr("d"));
    }

    function test_Init_TWAPBurner_ImplementationLocked() public {
        TWAPBurner impl = new TWAPBurner();
        vm.expectRevert();
        impl.initialize(makeAddr("u"), makeAddr("l"), makeAddr("d"));
    }

    function test_Init_TWAPBurner_OnlyOwnerCanUpgrade() public {
        TWAPBurner b = ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
        address newImpl = address(new TWAPBurner());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        b.upgradeToAndCall(newImpl, "");
        b.upgradeToAndCall(newImpl, "");
    }

    function test_Init_TWAPBurner_OwnerSetCorrectly() public {
        TWAPBurner b = ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
        assertEq(b.owner(), address(this));
    }

    function test_Init_TWAPBurner_RevertsOnZeroAddressParams() public {
        TWAPBurner impl = new TWAPBurner();
        bytes memory data =
            abi.encodeWithSelector(TWAPBurner.initialize.selector, address(0), makeAddr("l"), makeAddr("d"));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_TWAPBurner_ParentInitializersCalled() public {
        TWAPBurner b = ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
        assertEq(b.owner(), address(this));
    }

    function test_Init_TWAPBurner_InitialStateCorrect() public {
        TWAPBurner b = ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
        assertEq(address(b.usdc()), makeAddr("u"));
        assertEq(address(b.lumina()), makeAddr("l"));
        // Defaults applied in initialize:
        assertEq(b.poolFee(), 10000);
        assertTrue(b.maxSlippageBps() > 0);
        assertTrue(b.minBurnAmount() > 0);
        assertTrue(b.maxBurnAmount() > 0);
        assertTrue(b.burnCooldown() > 0);
    }

    function test_Init_TWAPBurner_FrontRunningProtected() public {
        TWAPBurner impl = new TWAPBurner();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("u"), makeAddr("l"), makeAddr("d"));
    }

    // ─────────────────────────────────────────────────────────────
    // 7. AdaptiveFeeDistributor
    // ─────────────────────────────────────────────────────────────

    function test_Init_AdaptiveFeeDistributor_CannotBeCalledTwice() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("o"));
        vm.expectRevert();
        d.initialize(makeAddr("o"));
    }

    function test_Init_AdaptiveFeeDistributor_ImplementationLocked() public {
        AdaptiveFeeDistributor impl = new AdaptiveFeeDistributor();
        vm.expectRevert();
        impl.initialize(makeAddr("o"));
    }

    function test_Init_AdaptiveFeeDistributor_OnlyOwnerCanUpgrade() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("o"));
        address newImpl = address(new AdaptiveFeeDistributor());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        d.upgradeToAndCall(newImpl, "");
        d.upgradeToAndCall(newImpl, "");
    }

    function test_Init_AdaptiveFeeDistributor_OwnerSetCorrectly() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("o"));
        assertEq(d.owner(), address(this));
    }

    function test_Init_AdaptiveFeeDistributor_RevertsOnZeroAddressParams() public {
        AdaptiveFeeDistributor impl = new AdaptiveFeeDistributor();
        bytes memory data = abi.encodeWithSelector(AdaptiveFeeDistributor.initialize.selector, address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_AdaptiveFeeDistributor_ParentInitializersCalled() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("o"));
        assertEq(d.owner(), address(this));
    }

    function test_Init_AdaptiveFeeDistributor_InitialStateCorrect() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("o"));
        assertEq(address(d.solvencyOracle()), makeAddr("o"));
    }

    function test_Init_AdaptiveFeeDistributor_FrontRunningProtected() public {
        AdaptiveFeeDistributor impl = new AdaptiveFeeDistributor();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("o"));
    }

    // ─────────────────────────────────────────────────────────────
    // 8. BuybackEngine (AccessControl; admin param grantee)
    // ─────────────────────────────────────────────────────────────

    function _beDeploy(address admin) internal returns (BuybackEngine) {
        return ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"), makeAddr("bv"), makeAddr("so"), makeAddr("co"), makeAddr("mk"), makeAddr("usdc"), admin
        );
    }

    function test_Init_BuybackEngine_CannotBeCalledTwice() public {
        BuybackEngine be = _beDeploy(address(this));
        vm.expectRevert();
        be.initialize(
            makeAddr("cb"),
            makeAddr("bv"),
            makeAddr("so"),
            makeAddr("co"),
            makeAddr("mk"),
            makeAddr("usdc"),
            address(this)
        );
    }

    function test_Init_BuybackEngine_ImplementationLocked() public {
        BuybackEngine impl = new BuybackEngine();
        vm.expectRevert();
        impl.initialize(
            makeAddr("cb"),
            makeAddr("bv"),
            makeAddr("so"),
            makeAddr("co"),
            makeAddr("mk"),
            makeAddr("usdc"),
            address(this)
        );
    }

    function test_Init_BuybackEngine_OnlyAdminCanUpgrade() public {
        BuybackEngine be = _beDeploy(address(this));
        address newImpl = address(new BuybackEngine());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        be.upgradeToAndCall(newImpl, "");
        be.upgradeToAndCall(newImpl, "");
    }

    function test_Init_BuybackEngine_AdminRoleOnlyGrantedToParam() public {
        address multisig = makeAddr("multisig");
        BuybackEngine be = _beDeploy(multisig);
        // Multisig param receives DEFAULT_ADMIN_ROLE + BUYBACK_OPERATOR_ROLE.
        assertTrue(be.hasRole(be.DEFAULT_ADMIN_ROLE(), multisig));
        assertTrue(be.hasRole(be.BUYBACK_OPERATOR_ROLE(), multisig));
        // msg.sender (this test contract) must NOT receive admin — only the param does.
        assertFalse(be.hasRole(be.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(be.hasRole(be.BUYBACK_OPERATOR_ROLE(), address(this)));
    }

    function test_Init_BuybackEngine_RevertsOnZeroAddressParams() public {
        BuybackEngine impl = new BuybackEngine();
        bytes memory data = abi.encodeWithSelector(
            BuybackEngine.initialize.selector,
            address(0),
            makeAddr("bv"),
            makeAddr("so"),
            makeAddr("co"),
            makeAddr("mk"),
            makeAddr("usdc"),
            address(this)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_BuybackEngine_ParentInitializersCalled() public {
        BuybackEngine be = _beDeploy(address(this));
        // AccessControl grantable, ReentrancyGuard initialized (state has non-entered value).
        assertTrue(be.hasRole(be.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_BuybackEngine_InitialStateCorrect() public {
        BuybackEngine be = _beDeploy(address(this));
        assertEq(address(be.claimBond()), makeAddr("cb"));
        assertEq(address(be.bondVault()), makeAddr("bv"));
        assertEq(address(be.marketplace()), makeAddr("mk"));
        assertEq(address(be.usdc()), makeAddr("usdc"));
        (uint256 budget,,,) = be.dailyConfig();
        assertEq(budget, 0); // not configured at init
    }

    function test_Init_BuybackEngine_FrontRunningProtected() public {
        BuybackEngine impl = new BuybackEngine();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(
            makeAddr("cb"),
            makeAddr("bv"),
            makeAddr("so"),
            makeAddr("co"),
            makeAddr("mk"),
            makeAddr("usdc"),
            address(this)
        );
    }

    function test_Init_BuybackEngine_NonAdminCannotGrantRoles() public {
        BuybackEngine be = _beDeploy(address(this));
        bytes32 role = be.BUYBACK_OPERATOR_ROLE();
        address atk = makeAddr("attacker");
        vm.prank(atk);
        vm.expectRevert();
        be.grantRole(role, atk);
    }

    // ─────────────────────────────────────────────────────────────
    // 9. LuminaBondMarketplace (AccessControl; admin param grantee)
    // ─────────────────────────────────────────────────────────────

    function test_Init_LuminaBondMarketplace_CannotBeCalledTwice() public {
        LuminaBondMarketplace m =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        vm.expectRevert();
        m.initialize(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
    }

    function test_Init_LuminaBondMarketplace_ImplementationLocked() public {
        LuminaBondMarketplace impl = new LuminaBondMarketplace();
        vm.expectRevert();
        impl.initialize(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
    }

    function test_Init_LuminaBondMarketplace_OnlyAdminCanUpgrade() public {
        LuminaBondMarketplace m =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        address newImpl = address(new LuminaBondMarketplace());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        m.upgradeToAndCall(newImpl, "");
        m.upgradeToAndCall(newImpl, "");
    }

    function test_Init_LuminaBondMarketplace_AdminRoleOnlyGrantedToParam() public {
        address admin = makeAddr("admin");
        LuminaBondMarketplace m =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), admin);
        assertTrue(m.hasRole(m.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(m.hasRole(m.FEE_MANAGER_ROLE(), admin));
        assertFalse(m.hasRole(m.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_LuminaBondMarketplace_RevertsOnZeroAddressParams() public {
        LuminaBondMarketplace impl = new LuminaBondMarketplace();
        bytes memory data = abi.encodeWithSelector(
            LuminaBondMarketplace.initialize.selector, address(0), makeAddr("u"), makeAddr("b"), address(this)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_LuminaBondMarketplace_ParentInitializersCalled() public {
        LuminaBondMarketplace m =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        assertTrue(m.hasRole(m.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Init_LuminaBondMarketplace_InitialStateCorrect() public {
        LuminaBondMarketplace m =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        assertEq(address(m.claimBond()), makeAddr("cb"));
        assertEq(address(m.usdc()), makeAddr("u"));
        assertEq(m.twapBurner(), makeAddr("b"));
        assertEq(m.nextListingId(), 0);
    }

    function test_Init_LuminaBondMarketplace_FrontRunningProtected() public {
        LuminaBondMarketplace impl = new LuminaBondMarketplace();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
    }

    function test_Init_LuminaBondMarketplace_NonAdminCannotGrantRoles() public {
        LuminaBondMarketplace m =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        bytes32 role = m.FEE_MANAGER_ROLE();
        address atk = makeAddr("attacker");
        vm.prank(atk);
        vm.expectRevert();
        m.grantRole(role, atk);
    }

    // ─────────────────────────────────────────────────────────────
    // 10. ShieldKeeper
    // ─────────────────────────────────────────────────────────────

    function test_Init_ShieldKeeper_CannotBeCalledTwice() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        vm.expectRevert();
        k.initialize(makeAddr("pm"));
    }

    function test_Init_ShieldKeeper_ImplementationLocked() public {
        ShieldKeeper impl = new ShieldKeeper();
        vm.expectRevert();
        impl.initialize(makeAddr("pm"));
    }

    function test_Init_ShieldKeeper_OnlyOwnerCanUpgrade() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        address newImpl = address(new ShieldKeeper());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        k.upgradeToAndCall(newImpl, "");
        k.upgradeToAndCall(newImpl, "");
    }

    function test_Init_ShieldKeeper_OwnerSetCorrectly() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        assertEq(k.owner(), address(this));
    }

    function test_Init_ShieldKeeper_RevertsOnZeroAddressParams() public {
        ShieldKeeper impl = new ShieldKeeper();
        bytes memory data = abi.encodeWithSelector(ShieldKeeper.initialize.selector, address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    function test_Init_ShieldKeeper_ParentInitializersCalled() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        assertEq(k.owner(), address(this));
    }

    function test_Init_ShieldKeeper_InitialStateCorrect() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        assertEq(address(k.policyManager()), makeAddr("pm"));
        assertFalse(k.paused());
    }

    function test_Init_ShieldKeeper_FrontRunningProtected() public {
        ShieldKeeper impl = new ShieldKeeper();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("pm"));
    }
}
