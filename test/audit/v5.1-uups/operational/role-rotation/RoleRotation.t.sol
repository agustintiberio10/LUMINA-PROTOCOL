// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {MaintenanceReserve} from "../../../../../src/treasury/MaintenanceReserve.sol";
import {CEXLiquidityReserve} from "../../../../../src/treasury/CEXLiquidityReserve.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {TreasuryVesting} from "../../../../../src/token/TreasuryVesting.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

contract MockERC20R is IERC20 {
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

contract InertRouterR is IDexRouter {
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract FakeOracleR {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

contract FakeMPR {
    uint256 public constant BUYER_FEE_BPS = 150;
    uint256 public constant BPS_DENOMINATOR = 10000;

    function executeBuy(uint256) external {}

    function getListing(uint256) external pure returns (address, uint256, uint256, uint256, bool) {
        return (address(0), 0, 0, 0, false);
    }
}

/// @dev Minimal Gnosis-Safe-like contract for multisig transition tests.
contract MockMultisig {
    address[] public signers;

    function addSigner(address s) external {
        signers.push(s);
    }

    // Allows test-contract to execute admin ops AS this multisig.
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "multisig exec failed");
        return ret;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MAIN TEST CONTRACT
// ─────────────────────────────────────────────────────────────────────────

contract RoleRotationTest is Test {
    address internal admin = address(this);
    address internal newAdmin = makeAddr("newAdmin");
    address internal attacker = makeAddr("attacker");
    address internal eoa = makeAddr("eoa");

    // ═════════════════════ helpers ═════════════════════

    function _deployBV() internal returns (BondVault vault) {
        MockERC20R lumina = new MockERC20R("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracleR oracle = new FakeOracleR();
        vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
    }

    function _deployBE() internal returns (BuybackEngine be) {
        MockERC20R usdc = new MockERC20R("USDC", "USDC");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        MockERC20R lumina = new MockERC20R("LUM", "LUM");
        FakeOracleR oracle = new FakeOracleR();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        SolvencyOracle sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(oracle), admin);
        address mp = address(new FakeMPR());
        be = ProxyDeployer.deployBuybackEngine(
            address(cb), address(vault), address(sol), address(oracle), mp, address(usdc), admin
        );
    }

    function _deployMR() internal returns (MaintenanceReserve mr, MockERC20R usdc) {
        usdc = new MockERC20R("USDC", "USDC");
        mr = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);
    }

    function _deployCEX() internal returns (CEXLiquidityReserve cex, MockERC20R lumina) {
        lumina = new MockERC20R("LUM", "LUM");
        cex = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), admin);
    }

    function _deployMP() internal returns (LuminaBondMarketplace mp) {
        MockERC20R usdc = new MockERC20R("USDC", "USDC");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        mp = ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), makeAddr("burner"), admin);
    }

    function _deploySol() internal returns (SolvencyOracle sol) {
        MockERC20R lumina = new MockERC20R("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracleR oracle = new FakeOracleR();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(oracle), admin);
    }

    // ═════════════════════ A. AccessControl admin transfer ═════════════════════

    function test_Rotation_BondVault_Admin_TransferWorks() public {
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();
        bytes32 callerRole = v.AUTHORIZED_CALLER_ADMIN_ROLE();

        // Grant newAdmin; both now hold role.
        v.grantRole(role, newAdmin);
        assertTrue(v.hasRole(role, newAdmin));
        assertTrue(v.hasRole(role, admin));

        // newAdmin with DEFAULT_ADMIN_ROLE can grant other roles (e.g. caller role).
        vm.prank(newAdmin);
        v.grantRole(callerRole, makeAddr("x"));
        assertTrue(v.hasRole(callerRole, makeAddr("x")));

        // Revoke old admin. newAdmin still has role.
        vm.prank(newAdmin);
        v.revokeRole(role, admin);
        assertFalse(v.hasRole(role, admin));
        assertTrue(v.hasRole(role, newAdmin));
    }

    function test_Rotation_BondVault_SimultaneousMultipleAdmins() public {
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();

        address a1 = makeAddr("a1");
        address a2 = makeAddr("a2");
        address a3 = makeAddr("a3");
        v.grantRole(role, a1);
        v.grantRole(role, a2);
        v.grantRole(role, a3);

        assertTrue(v.hasRole(role, a1));
        assertTrue(v.hasRole(role, a2));
        assertTrue(v.hasRole(role, a3));
        assertTrue(v.hasRole(role, admin));

        // All four can act independently.
        vm.prank(a1);
        v.grantRole(v.AUTHORIZED_CALLER_ADMIN_ROLE(), makeAddr("x1"));
        vm.prank(a2);
        v.grantRole(v.AUTHORIZED_CALLER_ADMIN_ROLE(), makeAddr("x2"));
        vm.prank(a3);
        v.grantRole(v.AUTHORIZED_CALLER_ADMIN_ROLE(), makeAddr("x3"));
    }

    function test_Rotation_Marketplace_Admin_TransferAndFeeManagerPropagation() public {
        LuminaBondMarketplace mp = _deployMP();
        bytes32 adminRole = mp.DEFAULT_ADMIN_ROLE();
        bytes32 feeMgrRole = mp.FEE_MANAGER_ROLE();

        // Deployer has both (initialize grants admin + fee-manager to _admin).
        assertTrue(mp.hasRole(adminRole, admin));
        assertTrue(mp.hasRole(feeMgrRole, admin));

        // Grant a separate fee-manager.
        address feeMgr = makeAddr("feeMgr");
        mp.grantRole(feeMgrRole, feeMgr);

        vm.prank(feeMgr);
        mp.setTwapBurner(makeAddr("newBurner"));
    }

    // ═════════════════════ B. Ownable transfer (OZ v5 = 1-step) ═════════════════════

    function test_Rotation_TreasuryVesting_Ownable_OneStepTransfer() public {
        MockERC20R lumina = new MockERC20R("LUM", "LUM");
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(address(lumina));

        tv.transferOwnership(newAdmin);
        assertEq(tv.owner(), newAdmin);

        // Old owner cannot.
        vm.expectRevert();
        tv.transferOwnership(attacker);

        // New can.
        vm.prank(newAdmin);
        tv.transferOwnership(makeAddr("finalOwner"));
    }

    function test_Rotation_CoverRouter_Ownable_OneStepTransfer() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("pm"), makeAddr("b"));
        r.transferOwnership(newAdmin);
        assertEq(r.owner(), newAdmin);

        vm.prank(newAdmin);
        r.setPaused(true);
        assertTrue(r.paused());
    }

    function test_Rotation_TWAPBurner_Ownable_OneStepTransfer() public {
        MockERC20R usdc = new MockERC20R("USDC", "USDC");
        MockERC20R lumina = new MockERC20R("LUM", "LUM");
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertRouterR()));

        tb.transferOwnership(newAdmin);
        assertEq(tb.owner(), newAdmin);

        vm.prank(newAdmin);
        tb.setMaxSlippageBps(300);
    }

    function test_Rotation_Ownable2StepNotUsed_NoPendingOwner() public {
        // OZ v5 Ownable is 1-step — verify that `pendingOwner()` selector does NOT exist
        // on CoverRouterV2 (confirms we're NOT using Ownable2Step).
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("pm"), makeAddr("b"));
        (bool ok,) = address(r).call(abi.encodeWithSignature("pendingOwner()"));
        assertFalse(ok, "CoverRouterV2 must not expose pendingOwner (not Ownable2Step)");
    }

    // ═════════════════════ C. Grant-before-revoke (no gap) ═════════════════════

    function test_Rotation_NoGap_GrantBeforeRevoke_BothAdminsActive() public {
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();
        bytes32 callerRole = v.AUTHORIZED_CALLER_ADMIN_ROLE();

        // Correct rotation pattern: grant new BEFORE revoking old.
        v.grantRole(role, newAdmin);

        // Between grant and revoke: BOTH hold DEFAULT_ADMIN_ROLE.
        assertTrue(v.hasRole(role, admin));
        assertTrue(v.hasRole(role, newAdmin));

        // Both can exercise admin power (grantRole requires DEFAULT_ADMIN_ROLE).
        vm.prank(newAdmin);
        v.grantRole(callerRole, makeAddr("x1"));
        v.grantRole(callerRole, makeAddr("x2")); // old admin still works

        // Revoke old — only newAdmin remains.
        vm.prank(newAdmin);
        v.revokeRole(role, admin);

        assertFalse(v.hasRole(role, admin));
        assertTrue(v.hasRole(role, newAdmin));

        // Old admin no longer can grant.
        vm.expectRevert();
        v.grantRole(callerRole, makeAddr("x3"));
    }

    // ═════════════════════ D. Revoke-before-grant (DANGEROUS gap) ═════════════════════

    function test_Rotation_DangerousGap_RevokeBeforeGrant_ContractLosesAdmin() public {
        // DOCUMENTATION of anti-pattern: if you revoke the only admin FIRST,
        // there's no one left to grant a new admin. Contract becomes stuck.
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();

        // Revoke self — now nobody has admin role.
        v.renounceRole(role, admin);
        assertFalse(v.hasRole(role, admin));

        // Rescue attempt: any EOA tries to grantRole — fails, nobody has admin.
        address rescuer = makeAddr("rescuer");
        vm.prank(rescuer);
        vm.expectRevert();
        v.grantRole(role, rescuer);

        // Even the original deployer cannot.
        vm.expectRevert();
        v.grantRole(role, admin);
    }

    function test_Rotation_MultiAdmin_OneRenounces_OthersStillFunctional() public {
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();

        address admin2 = makeAddr("admin2");
        v.grantRole(role, admin2);

        // Admin renounces.
        v.renounceRole(role, admin);
        assertFalse(v.hasRole(role, admin));
        assertTrue(v.hasRole(role, admin2));

        // admin2 can still manage.
        vm.prank(admin2);
        v.grantRole(role, makeAddr("admin3"));
        assertTrue(v.hasRole(role, makeAddr("admin3")));
    }

    // ═════════════════════ E. RenounceRole permanence ═════════════════════

    function test_Rotation_RenounceRole_CannotBeReclaimed() public {
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();

        v.renounceRole(role, admin);

        // Admin can't re-grant to self.
        vm.expectRevert();
        v.grantRole(role, admin);
    }

    function test_Rotation_RenounceOwnership_Permanent() public {
        MockERC20R lumina = new MockERC20R("LUM", "LUM");
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(address(lumina));

        tv.renounceOwnership();
        assertEq(tv.owner(), address(0));

        // No one can call admin funcs.
        vm.expectRevert();
        tv.transferOwnership(admin);
    }

    function test_Rotation_CoverRouter_RenounceOwnership_FreezesAdmin() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("pm"), makeAddr("b"));
        r.renounceOwnership();
        assertEq(r.owner(), address(0));

        // setPaused now impossible forever.
        vm.expectRevert();
        r.setPaused(true);
    }

    // ═════════════════════ F. Operator rotation (BuybackEngine) ═════════════════════

    function test_Rotation_BuybackOperator_GrantRevoke() public {
        BuybackEngine be = _deployBE();
        bytes32 operatorRole = be.BUYBACK_OPERATOR_ROLE();

        address oldOp = makeAddr("oldOp");
        address newOp = makeAddr("newOp");

        // Grant both, revoke old.
        be.grantRole(operatorRole, oldOp);
        be.grantRole(operatorRole, newOp);
        assertTrue(be.hasRole(operatorRole, oldOp));
        assertTrue(be.hasRole(operatorRole, newOp));

        be.revokeRole(operatorRole, oldOp);
        assertFalse(be.hasRole(operatorRole, oldOp));
        assertTrue(be.hasRole(operatorRole, newOp));
    }

    function test_Rotation_BuybackOperator_NonAdminCannotGrant() public {
        BuybackEngine be = _deployBE();
        bytes32 operatorRole = be.BUYBACK_OPERATOR_ROLE();

        vm.prank(attacker);
        vm.expectRevert();
        be.grantRole(operatorRole, attacker);
    }

    // ═════════════════════ G. SolvencyOracle ADMIN_ROLE rotation ═════════════════════

    function test_Rotation_SolvencyOracle_AdminRole_Rotate() public {
        SolvencyOracle sol = _deploySol();
        bytes32 adminRole = sol.ADMIN_ROLE();

        address newPauser = makeAddr("newPauser");
        sol.grantRole(adminRole, newPauser);

        // newPauser can toggle emergency pause.
        vm.prank(newPauser);
        sol.setEmergencyPause(true);
        assertTrue(sol.emergencyPaused());

        // Revoke.
        sol.revokeRole(adminRole, newPauser);
        vm.prank(newPauser);
        vm.expectRevert();
        sol.setEmergencyPause(false);
    }

    // ═════════════════════ H. MaintenanceReserve SPENDER_ROLE rotation ═════════════════════

    function test_Rotation_MaintenanceReserve_SpenderRole_Rotate() public {
        (MaintenanceReserve mr, MockERC20R usdc) = _deployMR();
        usdc.mint(address(mr), 1000e6);

        bytes32 spenderRole = mr.SPENDER_ROLE();
        address oldSpender = makeAddr("oldSpender");
        address newSpender = makeAddr("newSpender");

        mr.grantRole(spenderRole, oldSpender);
        vm.prank(oldSpender);
        mr.spend(makeAddr("t1"), 10e6, MaintenanceReserve.SpendCategory.Other, "test");

        mr.grantRole(spenderRole, newSpender);
        mr.revokeRole(spenderRole, oldSpender);

        // Old cannot.
        vm.prank(oldSpender);
        vm.expectRevert();
        mr.spend(makeAddr("t2"), 10e6, MaintenanceReserve.SpendCategory.Other, "test");

        // New can.
        vm.prank(newSpender);
        mr.spend(makeAddr("t3"), 10e6, MaintenanceReserve.SpendCategory.Other, "test");
    }

    // ═════════════════════ I. CEX ALLOCATOR_ROLE rotation ═════════════════════

    function test_Rotation_CEX_AllocatorRole_Rotate() public {
        (CEXLiquidityReserve cex, MockERC20R lumina) = _deployCEX();
        lumina.mint(address(cex), 10_000_000e18);

        bytes32 allocRole = cex.ALLOCATOR_ROLE();
        address oldAlloc = makeAddr("oldAlloc");
        address newAlloc = makeAddr("newAlloc");

        cex.grantRole(allocRole, oldAlloc);
        cex.grantRole(allocRole, newAlloc);

        vm.prank(oldAlloc);
        cex.allocate(
            makeAddr("r1"),
            100e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "test"
        );

        cex.revokeRole(allocRole, oldAlloc);

        vm.prank(oldAlloc);
        vm.expectRevert();
        cex.allocate(
            makeAddr("r2"),
            100e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "test2"
        );

        vm.prank(newAlloc);
        cex.allocate(
            makeAddr("r3"),
            100e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "test3"
        );
    }

    // ═════════════════════ J. AuthorizedCaller mapping rotation (BondVault) ═════════════════════

    function test_Rotation_BondVault_AuthorizedCaller_SetAndUnset() public {
        BondVault v = _deployBV();

        address oldCaller = makeAddr("oldCaller");
        address newCaller = makeAddr("newCaller");

        v.setAuthorizedCaller(oldCaller, true);
        assertTrue(v.authorizedCallers(oldCaller));

        v.setAuthorizedCaller(newCaller, true);
        v.setAuthorizedCaller(oldCaller, false);

        assertFalse(v.authorizedCallers(oldCaller));
        assertTrue(v.authorizedCallers(newCaller));
    }

    function test_Rotation_BondVault_AuthorizedCaller_RevokeStopsAccess() public {
        BondVault v = _deployBV();

        address caller = makeAddr("caller");
        v.setAuthorizedCaller(caller, true);
        assertTrue(v.authorizedCallers(caller));

        // Authorized caller can burn (but requires balance — verified via revert-on-no-balance).
        vm.prank(caller);
        vm.expectRevert(bytes("Insufficient reserves"));
        v.burnFromReserves(1);

        // Revoke.
        v.setAuthorizedCaller(caller, false);

        // Now revert is "not authorized" instead.
        vm.prank(caller);
        vm.expectRevert(bytes("BondVault: caller not authorized"));
        v.burnFromReserves(1);
    }

    // ═════════════════════ K. EOA → Multisig transition ═════════════════════

    function test_Rotation_EOA_To_Multisig_Transition() public {
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();

        MockMultisig ms = new MockMultisig();
        ms.addSigner(makeAddr("signer1"));
        ms.addSigner(makeAddr("signer2"));

        // 1. Grant role to multisig (from EOA).
        v.grantRole(role, address(ms));
        assertTrue(v.hasRole(role, address(ms)));

        // 2. Multisig can now act via exec.
        bytes memory data = abi.encodeWithSelector(
            v.grantRole.selector, v.AUTHORIZED_CALLER_ADMIN_ROLE(), makeAddr("new_caller_admin")
        );
        ms.exec(address(v), data);
        assertTrue(v.hasRole(v.AUTHORIZED_CALLER_ADMIN_ROLE(), makeAddr("new_caller_admin")));

        // 3. Revoke EOA.
        v.renounceRole(role, admin);
        assertFalse(v.hasRole(role, admin));
        assertTrue(v.hasRole(role, address(ms)));
    }

    function test_Rotation_Multisig_To_AnotherMultisig() public {
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();

        MockMultisig ms1 = new MockMultisig();
        MockMultisig ms2 = new MockMultisig();

        // Grant ms1, revoke admin (EOA).
        v.grantRole(role, address(ms1));
        v.renounceRole(role, admin);

        // ms1 is sole admin. Transition to ms2.
        ms1.exec(address(v), abi.encodeWithSelector(v.grantRole.selector, role, address(ms2)));
        ms2.exec(address(v), abi.encodeWithSelector(v.revokeRole.selector, role, address(ms1)));

        assertTrue(v.hasRole(role, address(ms2)));
        assertFalse(v.hasRole(role, address(ms1)));
        assertFalse(v.hasRole(role, admin));
    }

    // ═════════════════════ L. Role hierarchy — DEFAULT_ADMIN_ROLE admins every role ═════════════════════

    function test_Rotation_DefaultAdmin_IsAdminOfAllRoles() public {
        BondVault v = _deployBV();
        // DEFAULT_ADMIN_ROLE is the admin of itself AND of AUTHORIZED_CALLER_ADMIN_ROLE.
        assertEq(v.getRoleAdmin(v.DEFAULT_ADMIN_ROLE()), v.DEFAULT_ADMIN_ROLE());
        assertEq(v.getRoleAdmin(v.AUTHORIZED_CALLER_ADMIN_ROLE()), v.DEFAULT_ADMIN_ROLE());
    }

    function test_Rotation_NonDefaultAdmin_CannotGrantDefaultAdmin() public {
        BondVault v = _deployBV();
        bytes32 authCallerAdmin = v.AUTHORIZED_CALLER_ADMIN_ROLE();
        bytes32 defaultAdmin = v.DEFAULT_ADMIN_ROLE();

        address partialAdm = makeAddr("partialAdmAdmin");
        v.grantRole(authCallerAdmin, partialAdm);

        // partialAdm holds AUTHORIZED_CALLER_ADMIN_ROLE but not DEFAULT_ADMIN_ROLE.
        // Cannot grant DEFAULT_ADMIN_ROLE.
        vm.prank(partialAdm);
        vm.expectRevert();
        v.grantRole(defaultAdmin, partialAdm);
    }

    // ═════════════════════ M. LuminaTokenV2 role management ═════════════════════

    function test_Rotation_LuminaToken_BurnerRole_GrantRevoke() public {
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );
        bytes32 burner = token.BURNER_ROLE();
        address newBurner = makeAddr("newBurner");

        token.grantRole(burner, newBurner);
        assertTrue(token.hasRole(burner, newBurner));

        token.revokeRole(burner, newBurner);
        assertFalse(token.hasRole(burner, newBurner));
    }

    function test_Rotation_LuminaToken_AdminRotate_PreservesSupply() public {
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );
        uint256 supplyBefore = token.totalSupply();

        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        token.grantRole(role, newAdmin);
        token.renounceRole(role, admin);

        // Token supply unaffected.
        assertEq(token.totalSupply(), supplyBefore);
        // newAdmin is now the sole admin.
        assertTrue(token.hasRole(role, newAdmin));
    }

    // ═════════════════════ N. Event emission on role changes ═════════════════════

    function test_Rotation_BondVault_RoleGranted_RevokedEvents() public {
        BondVault v = _deployBV();
        bytes32 role = v.AUTHORIZED_CALLER_ADMIN_ROLE();

        // OZ emits RoleGranted(bytes32 role, address account, address sender).
        vm.recordLogs();
        v.grantRole(role, newAdmin);
        v.revokeRole(role, newAdmin);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 grantedSig = keccak256("RoleGranted(bytes32,address,address)");
        bytes32 revokedSig = keccak256("RoleRevoked(bytes32,address,address)");
        uint256 granted;
        uint256 revoked;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(v)) continue;
            if (logs[i].topics[0] == grantedSig) granted++;
            if (logs[i].topics[0] == revokedSig) revoked++;
        }
        assertEq(granted, 1);
        assertEq(revoked, 1);
    }

    // ═════════════════════ O. PolicyManagerV2 Ownable ═════════════════════

    function test_Rotation_PolicyManager_Ownable_Transfer() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("v"));
        pm.transferOwnership(newAdmin);
        assertEq(pm.owner(), newAdmin);

        vm.prank(newAdmin);
        pm.registerProduct(keccak256("P"), makeAddr("shield"));
    }

    // ═════════════════════ P. Timelock-style (documented pattern) ═════════════════════

    function test_Rotation_Timelock_GrantedViaCurrentAdmin() public {
        // Timelock is just another address; roles work the same.
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();

        address timelock = makeAddr("timelock");
        v.grantRole(role, timelock);
        assertTrue(v.hasRole(role, timelock));

        // In production: admin would then renounce, leaving timelock as sole admin.
        v.renounceRole(role, admin);
        assertFalse(v.hasRole(role, admin));
        assertTrue(v.hasRole(role, timelock));
    }

    // ═════════════════════ Q. Accidental admin loss ═════════════════════

    function test_Rotation_AccidentalRenounce_NoRecovery() public {
        BondVault v = _deployBV();
        bytes32 role = v.DEFAULT_ADMIN_ROLE();

        // Single admin renounces "accidentally".
        v.renounceRole(role, admin);

        // No one has the role.
        assertFalse(v.hasRole(role, admin));
        assertFalse(v.hasRole(role, newAdmin));

        // Contract is admin-less forever. Cannot upgrade or manage.
        vm.prank(newAdmin);
        vm.expectRevert();
        v.grantRole(role, newAdmin);
    }

    // ═════════════════════ R. Cross-contract rotation consistency ═════════════════════

    function test_Rotation_CrossContract_RotateAdmin_AllContractsIndependent() public {
        // Rotating admin on BondVault does NOT affect Marketplace admin (separate contracts).
        BondVault v = _deployBV();
        LuminaBondMarketplace mp = _deployMP();

        v.grantRole(v.DEFAULT_ADMIN_ROLE(), newAdmin);
        v.renounceRole(v.DEFAULT_ADMIN_ROLE(), admin);

        // Marketplace admin untouched.
        assertTrue(mp.hasRole(mp.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(mp.hasRole(mp.DEFAULT_ADMIN_ROLE(), newAdmin));
    }
}
