// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {AdaptiveFeeDistributor} from "../../../../../src/core/AdaptiveFeeDistributor.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

contract MockERC20Ev is IERC20 {
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

contract InertRouterEv is IDexRouter {
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract FakeOracleEv {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

// ─────────────────────────────────────────────────────────────────────────
// Tests for fix #27 INFO findings
// ─────────────────────────────────────────────────────────────────────────

contract FixEventEmissionTest is Test {
    // Re-declared events to match emitters.
    event AuthorizedSenderUpdated(address indexed sender, bool authorized);
    event ReservesUpdated(
        address indexed buybackReserve, address indexed opsReserve, address indexed maintenanceReserve
    );
    event AdaptiveModeUpdated(bool enabled);
    event PolicyManagerUpdated(address indexed oldPM, address indexed newPM);
    event TwapBurnerUpdated(address indexed oldTB, address indexed newTB);
    event CapacityOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    address internal admin = address(this);
    address internal attacker = makeAddr("attacker");

    // ═══════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════

    function _deployTB() internal returns (TWAPBurner tb) {
        MockERC20Ev u = new MockERC20Ev("USDC", "USDC");
        MockERC20Ev l = new MockERC20Ev("LUM", "LUM");
        tb = ProxyDeployer.deployTWAPBurner(address(u), address(l), address(new InertRouterEv()));
    }

    function _deployTBWithFeeDistributor() internal returns (TWAPBurner tb, AdaptiveFeeDistributor adp) {
        tb = _deployTB();

        // Deploy a real SolvencyOracle + AdaptiveFeeDistributor so setAdaptiveMode(true) passes.
        MockERC20Ev lumina = new MockERC20Ev("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracleEv oracle = new FakeOracleEv();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        SolvencyOracle sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(oracle), admin);
        adp = ProxyDeployer.deployAdaptiveFeeDistributor(address(sol));

        tb.setFeeDistributor(address(adp));
        tb.setReserves(makeAddr("bb"), makeAddr("ops"), makeAddr("maint"));
    }

    function _deployCR() internal returns (CoverRouterV2 r) {
        r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("pm"), makeAddr("b"));
    }

    function _deployPM() internal returns (PolicyManagerV2 pm) {
        pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("v"));
    }

    // ═══════════════════════════════════════════════════════════
    // INFO-1: TWAPBurner.setAuthorizedSender
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_TWAPBurner_SetAuthorizedSender_EmitsOnTrue() public {
        TWAPBurner tb = _deployTB();
        address sender = makeAddr("sender");

        vm.expectEmit(true, false, false, true, address(tb));
        emit AuthorizedSenderUpdated(sender, true);
        tb.setAuthorizedSender(sender, true);
        assertTrue(tb.authorizedSenders(sender));
    }

    function test_Fix_Events_TWAPBurner_SetAuthorizedSender_EmitsOnFalse() public {
        TWAPBurner tb = _deployTB();
        address sender = makeAddr("sender");
        tb.setAuthorizedSender(sender, true);

        vm.expectEmit(true, false, false, true, address(tb));
        emit AuthorizedSenderUpdated(sender, false);
        tb.setAuthorizedSender(sender, false);
        assertFalse(tb.authorizedSenders(sender));
    }

    function test_Fix_Events_TWAPBurner_SetAuthorizedSender_NonOwner_NoEvent() public {
        TWAPBurner tb = _deployTB();
        vm.prank(attacker);
        vm.expectRevert();
        tb.setAuthorizedSender(makeAddr("x"), true);
    }

    // ═══════════════════════════════════════════════════════════
    // INFO-2: TWAPBurner.setReserves
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_TWAPBurner_SetReserves_EmitsAllThree() public {
        TWAPBurner tb = _deployTB();
        address bb = makeAddr("bb");
        address ops = makeAddr("ops");
        address maint = makeAddr("maint");

        vm.expectEmit(true, true, true, false, address(tb));
        emit ReservesUpdated(bb, ops, maint);
        tb.setReserves(bb, ops, maint);

        assertEq(tb.buybackReserve(), bb);
        assertEq(tb.opsReserve(), ops);
        assertEq(tb.maintenanceReserve(), maint);
    }

    function test_Fix_Events_TWAPBurner_SetReserves_NonOwner_NoEvent() public {
        TWAPBurner tb = _deployTB();
        vm.prank(attacker);
        vm.expectRevert();
        tb.setReserves(makeAddr("a"), makeAddr("b"), makeAddr("c"));
    }

    // ═══════════════════════════════════════════════════════════
    // INFO-3: TWAPBurner.setAdaptiveMode
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_TWAPBurner_SetAdaptiveMode_EmitsOnEnable() public {
        (TWAPBurner tb,) = _deployTBWithFeeDistributor();

        vm.expectEmit(false, false, false, true, address(tb));
        emit AdaptiveModeUpdated(true);
        tb.setAdaptiveMode(true);
        assertTrue(tb.adaptiveModeEnabled());
    }

    function test_Fix_Events_TWAPBurner_SetAdaptiveMode_EmitsOnDisable() public {
        (TWAPBurner tb,) = _deployTBWithFeeDistributor();
        tb.setAdaptiveMode(true);

        vm.expectEmit(false, false, false, true, address(tb));
        emit AdaptiveModeUpdated(false);
        tb.setAdaptiveMode(false);
        assertFalse(tb.adaptiveModeEnabled());
    }

    function test_Fix_Events_TWAPBurner_SetAdaptiveMode_NonOwner_Reverts() public {
        TWAPBurner tb = _deployTB();
        vm.prank(attacker);
        vm.expectRevert();
        tb.setAdaptiveMode(true);
    }

    // ═══════════════════════════════════════════════════════════
    // INFO-4: CoverRouterV2.setPolicyManager
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_CoverRouter_SetPolicyManager_EmitsOldNew() public {
        CoverRouterV2 r = _deployCR();
        address old = address(r.policyManager());
        address newPM = makeAddr("newPM");

        vm.expectEmit(true, true, false, false, address(r));
        emit PolicyManagerUpdated(old, newPM);
        r.setPolicyManager(newPM);
        assertEq(address(r.policyManager()), newPM);
    }

    function test_Fix_Events_CoverRouter_SetPolicyManager_RejectsZero() public {
        CoverRouterV2 r = _deployCR();
        vm.expectRevert(bytes("Zero"));
        r.setPolicyManager(address(0));
    }

    function test_Fix_Events_CoverRouter_SetPolicyManager_NonOwnerReverts() public {
        CoverRouterV2 r = _deployCR();
        vm.prank(attacker);
        vm.expectRevert();
        r.setPolicyManager(makeAddr("x"));
    }

    // ═══════════════════════════════════════════════════════════
    // INFO-4: CoverRouterV2.setTwapBurner
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_CoverRouter_SetTwapBurner_EmitsOldNew() public {
        CoverRouterV2 r = _deployCR();
        address old = address(r.twapBurner());
        address newTB = makeAddr("newTB");

        vm.expectEmit(true, true, false, false, address(r));
        emit TwapBurnerUpdated(old, newTB);
        r.setTwapBurner(newTB);
        assertEq(address(r.twapBurner()), newTB);
    }

    function test_Fix_Events_CoverRouter_SetTwapBurner_RejectsZero() public {
        CoverRouterV2 r = _deployCR();
        vm.expectRevert(bytes("Zero"));
        r.setTwapBurner(address(0));
    }

    // ═══════════════════════════════════════════════════════════
    // INFO-4: CoverRouterV2.setCapacityOracle
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_CoverRouter_SetCapacityOracle_EmitsOldNew() public {
        CoverRouterV2 r = _deployCR();
        // First set an initial oracle so old != 0.
        r.setCapacityOracle(makeAddr("initial"));
        address old = address(r.capacityOracle());
        address newOracle = makeAddr("newOracle");

        vm.expectEmit(true, true, false, false, address(r));
        emit CapacityOracleUpdated(old, newOracle);
        r.setCapacityOracle(newOracle);
        assertEq(address(r.capacityOracle()), newOracle);
    }

    function test_Fix_Events_CoverRouter_SetCapacityOracle_FirstCallOldIsZero() public {
        CoverRouterV2 r = _deployCR();
        address newOracle = makeAddr("newOracle");

        // First time: old = address(0).
        vm.expectEmit(true, true, false, false, address(r));
        emit CapacityOracleUpdated(address(0), newOracle);
        r.setCapacityOracle(newOracle);
    }

    function test_Fix_Events_CoverRouter_SetCapacityOracle_RejectsZero() public {
        CoverRouterV2 r = _deployCR();
        vm.expectRevert(bytes("Zero"));
        r.setCapacityOracle(address(0));
    }

    // ═══════════════════════════════════════════════════════════
    // INFO-5: PolicyManagerV2.setRouter
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_PolicyManager_SetRouter_EmitsOldNew() public {
        PolicyManagerV2 pm = _deployPM();
        // First set — old = 0, new = r1.
        address r1 = makeAddr("r1");
        vm.expectEmit(true, true, false, false, address(pm));
        emit RouterUpdated(address(0), r1);
        pm.setRouter(r1);

        // Second set — old = r1, new = r2.
        address r2 = makeAddr("r2");
        vm.expectEmit(true, true, false, false, address(pm));
        emit RouterUpdated(r1, r2);
        pm.setRouter(r2);
        assertEq(pm.router(), r2);
    }

    function test_Fix_Events_PolicyManager_SetRouter_RejectsZero() public {
        PolicyManagerV2 pm = _deployPM();
        vm.expectRevert(bytes("Zero router"));
        pm.setRouter(address(0));
    }

    function test_Fix_Events_PolicyManager_SetRouter_NonOwner_Reverts() public {
        PolicyManagerV2 pm = _deployPM();
        vm.prank(attacker);
        vm.expectRevert();
        pm.setRouter(makeAddr("x"));
    }

    // ═══════════════════════════════════════════════════════════
    // Monitoring scenarios
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_Scenario_AdminMakesThreeChanges_AllLogged() public {
        CoverRouterV2 r = _deployCR();
        vm.recordLogs();

        r.setPolicyManager(makeAddr("pm1"));
        r.setTwapBurner(makeAddr("tb1"));
        r.setCapacityOracle(makeAddr("oc1"));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Count logs emitted BY the router.
        uint256 routerLogs;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(r)) routerLogs++;
        }
        assertEq(routerLogs, 3, "Each config change emitted exactly one event");
    }

    function test_Fix_Events_Scenario_ReconstructCronology_FromEvents() public {
        PolicyManagerV2 pm = _deployPM();
        vm.recordLogs();

        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        address r3 = makeAddr("r3");
        pm.setRouter(r1);
        pm.setRouter(r2);
        pm.setRouter(r3);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Locate the 3 RouterUpdated events and verify their (old,new) sequencing.
        bytes32 sig = keccak256("RouterUpdated(address,address)");
        uint256 found;
        address[3] memory seenOld;
        address[3] memory seenNew;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == sig) {
                seenOld[found] = address(uint160(uint256(logs[i].topics[1])));
                seenNew[found] = address(uint160(uint256(logs[i].topics[2])));
                found++;
            }
        }
        assertEq(found, 3);
        assertEq(seenOld[0], address(0));
        assertEq(seenNew[0], r1);
        assertEq(seenOld[1], r1);
        assertEq(seenNew[1], r2);
        assertEq(seenOld[2], r2);
        assertEq(seenNew[2], r3);
    }

    // ═══════════════════════════════════════════════════════════
    // Logic preserved (regression smoke — setters still work)
    // ═══════════════════════════════════════════════════════════

    function test_Fix_Events_SetAuthorizedSender_StillMutatesMapping() public {
        TWAPBurner tb = _deployTB();
        address s = makeAddr("s");
        tb.setAuthorizedSender(s, true);
        assertTrue(tb.authorizedSenders(s));
        tb.setAuthorizedSender(s, false);
        assertFalse(tb.authorizedSenders(s));
    }

    function test_Fix_Events_SetReserves_StillMutatesAllThreeFields() public {
        TWAPBurner tb = _deployTB();
        tb.setReserves(makeAddr("a"), makeAddr("b"), makeAddr("c"));
        assertEq(tb.buybackReserve(), makeAddr("a"));
        assertEq(tb.opsReserve(), makeAddr("b"));
        assertEq(tb.maintenanceReserve(), makeAddr("c"));
    }

    function test_Fix_Events_SetPolicyManager_StillMutatesField() public {
        CoverRouterV2 r = _deployCR();
        r.setPolicyManager(makeAddr("pm"));
        assertEq(address(r.policyManager()), makeAddr("pm"));
    }

    function test_Fix_Events_SetRouter_StillMutatesField() public {
        PolicyManagerV2 pm = _deployPM();
        pm.setRouter(makeAddr("x"));
        assertEq(pm.router(), makeAddr("x"));
    }
}
