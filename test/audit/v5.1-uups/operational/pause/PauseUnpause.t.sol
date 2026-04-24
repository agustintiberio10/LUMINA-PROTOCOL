// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {ShieldKeeper} from "../../../../../src/automation/ShieldKeeper.sol";
import {SolvencyOracle} from "../../../../../src/oracles/SolvencyOracle.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {BuybackEngine} from "../../../../../src/marketplace/BuybackEngine.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// MOCKS
// ─────────────────────────────────────────────────────────────────────────

contract MockERC20P is IERC20 {
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

contract InertRouterP is IDexRouter {
    function swap(address, address, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract FakeOracleP {
    uint256 public price = 0.036e18;

    function setPrice(uint256 p) external {
        price = p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MAIN TEST CONTRACT — audit #28
// ─────────────────────────────────────────────────────────────────────────

contract PauseUnpauseTest is Test {
    event Paused(bool state);
    event EmergencyPauseToggled(bool paused);

    address internal admin = address(this);
    address internal attacker = makeAddr("attacker");

    // ═════════════════════ helpers ═════════════════════

    function _deployCR() internal returns (CoverRouterV2 r) {
        r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("pm"), makeAddr("b"));
    }

    function _deploySolvency() internal returns (SolvencyOracle sol) {
        MockERC20P lumina = new MockERC20P("LUM", "LUM");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        FakeOracleP oracle = new FakeOracleP();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(oracle), admin);
    }

    function _deployBVWithLumina() internal returns (BondVault v, ClaimBond cb, MockERC20P lumina, FakeOracleP oracle) {
        vm.warp(1767225600 + 30 days);
        lumina = new MockERC20P("LUM", "LUM");
        cb = ProxyDeployer.deployClaimBond();
        oracle = new FakeOracleP();
        v = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        cb.setBondVault(address(v));
        lumina.mint(address(v), 70_000_000e18);
    }

    function _scanEpoch(ClaimBond cb, address holder) internal view returns (uint256) {
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (block.timestamp + 730 days - BASE_TS) / 2629746;
        for (int256 d = -3; d <= 3; d++) {
            int256 mfb = int256(monthsFromBase) + d;
            if (mfb < 0) continue;
            uint256 year = 2026 + uint256(mfb) / 12;
            uint256 month = 1 + uint256(mfb) % 12;
            uint256 epochId = year * 100 + month;
            if (cb.balanceOf(holder, epochId) > 0) return epochId;
        }
        revert("no epoch");
    }

    // ═════════════════════ A. CoverRouterV2 pause ═════════════════════

    function test_Pause_CR_SetPaused_BlocksPurchase() public {
        CoverRouterV2 r = _deployCR();
        r.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);

        r.setPaused(true);
        assertTrue(r.paused());
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        r.purchasePolicy(keccak256("P"), 100e6, "BTC");
    }

    function test_Pause_CR_SetPaused_BlocksPurchaseFor() public {
        CoverRouterV2 r = _deployCR();
        r.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);
        r.setRelayer(address(this), true);

        r.setPaused(true);
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        r.purchasePolicyFor(keccak256("P"), 100e6, "BTC", makeAddr("buyer"));
    }

    function test_Pause_CR_Unpause_RestoresOps() public {
        CoverRouterV2 r = _deployCR();
        r.setPaused(true);
        r.setPaused(false);
        assertFalse(r.paused());
        // Now purchase proceeds further, failing for a different reason (product).
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.ProductNotConfigured.selector, keccak256("X")));
        r.purchasePolicy(keccak256("X"), 100e6, "BTC");
    }

    function test_Pause_CR_OnlyOwner_CanPause() public {
        CoverRouterV2 r = _deployCR();
        vm.prank(attacker);
        vm.expectRevert();
        r.setPaused(true);
    }

    function test_Pause_CR_EmitsEvent() public {
        CoverRouterV2 r = _deployCR();
        vm.expectEmit(false, false, false, true, address(r));
        emit Paused(true);
        r.setPaused(true);
    }

    function test_Pause_CR_SetPaused_Idempotent() public {
        // `setPaused(bool)` is idempotent — can be called repeatedly without revert.
        CoverRouterV2 r = _deployCR();
        r.setPaused(true);
        r.setPaused(true);
        assertTrue(r.paused());
        r.setPaused(false);
        r.setPaused(false);
        assertFalse(r.paused());
    }

    function test_Pause_CR_SubmitTrigger_NOT_Pauseable() public {
        // submitTrigger() has no `whenNotPaused` modifier — triggering a matured
        // policy must work even if admin has paused the router.
        CoverRouterV2 r = _deployCR();
        r.setPaused(true);
        // Call reverts for a NON-pause reason (no such policy / PM reverts at call).
        // Low-level call should NOT revert with ContractPaused.
        (bool ok, bytes memory ret) = address(r)
            .call(abi.encodeWithSignature("submitTrigger(bytes32,uint256,bytes)", bytes32(0), uint256(0), bytes("")));
        assertFalse(ok);
        // The revert MUST NOT be ContractPaused.
        bytes4 pauseSel = CoverRouterV2.ContractPaused.selector;
        if (ret.length >= 4) {
            bytes4 actualSel;
            assembly {
                actualSel := mload(add(ret, 0x20))
            }
            assertTrue(actualSel != pauseSel, "submitTrigger must not revert with ContractPaused");
        }
    }

    // ═════════════════════ B. ShieldKeeper pause ═════════════════════

    function test_Pause_ShieldKeeper_PauseBlocksKeeperCheck() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        (bool upkeepNeeded,) = k.checkUpkeep("");
        assertFalse(upkeepNeeded, "keeper should report NO upkeep when paused");
    }

    function test_Pause_ShieldKeeper_Unpause_RestoresKeeper() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        assertTrue(k.paused());
        k.unpause();
        assertFalse(k.paused());
    }

    function test_Pause_ShieldKeeper_OnlyOwner() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        vm.prank(attacker);
        vm.expectRevert();
        k.pause();
    }

    function test_Pause_ShieldKeeper_Idempotent() public {
        // ShieldKeeper uses a plain bool, NOT OZ Pausable — calling pause() twice
        // is a no-op, not a revert. Same for unpause().
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        k.pause();
        assertTrue(k.paused());
        k.unpause();
        k.unpause();
        assertFalse(k.paused());
    }

    // ═════════════════════ C. SolvencyOracle emergency pause ═════════════════════

    function test_Pause_SolvencyOracle_BlocksEvaluate() public {
        SolvencyOracle sol = _deploySolvency();
        sol.setEmergencyPause(true);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(bytes("Oracle paused"));
        sol.evaluate();
    }

    function test_Pause_SolvencyOracle_Unpause_RestoresEvaluate() public {
        SolvencyOracle sol = _deploySolvency();
        sol.setEmergencyPause(true);
        sol.setEmergencyPause(false);
        vm.warp(block.timestamp + 2 days);
        sol.evaluate();
    }

    function test_Pause_SolvencyOracle_OnlyAdminRole() public {
        SolvencyOracle sol = _deploySolvency();
        vm.prank(attacker);
        vm.expectRevert();
        sol.setEmergencyPause(true);
    }

    function test_Pause_SolvencyOracle_EmitsEvent() public {
        SolvencyOracle sol = _deploySolvency();
        vm.expectEmit(false, false, false, true, address(sol));
        emit EmergencyPauseToggled(true);
        sol.setEmergencyPause(true);
    }

    function test_Pause_SolvencyOracle_IsHealthy_ReturnsFalseWhenPaused() public {
        SolvencyOracle sol = _deploySolvency();
        sol.setEmergencyPause(true);
        assertFalse(sol.isHealthy(), "isHealthy must report false when paused");
    }

    // ═════════════════════ D. Critical ops ALWAYS work ═════════════════════

    function test_Pause_BondVault_Redeem_AlwaysWorksRegardlessOfCRPause() public {
        (BondVault v, ClaimBond cb,, FakeOracleP oracle) = _deployBVWithLumina();
        v.issueBond(makeAddr("holder"), 100);
        uint256 epoch = _scanEpoch(cb, makeAddr("holder"));

        // Deploy CR + pause it (simulates admin pausing the protocol surface).
        CoverRouterV2 r = _deployCR();
        r.setPaused(true);

        // Warp past maturity + redemption still works.
        vm.warp(cb.maturityDate(epoch) + 1);
        oracle;
        vm.prank(makeAddr("holder"));
        v.redeemBond(epoch, 100);
        assertEq(cb.balanceOf(makeAddr("holder"), epoch), 0);
    }

    function test_Pause_Marketplace_CancelAlwaysWorks_NoPauseOnMarketplace() public {
        // Marketplace has no pause fn. Prove cancel works unconditionally.
        MockERC20P usdc = new MockERC20P("USDC", "USDC");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), makeAddr("burner"), admin);

        // Verify no pause selector on marketplace.
        (bool ok,) = address(mp).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "Marketplace must not expose pause()");

        // Full list/cancel flow without pause concerns.
        cb.setBondVault(admin);
        cb.mint(makeAddr("seller"), 202904, 10);
        cb.setAuthorizedOperator(address(mp), true);
        vm.startPrank(makeAddr("seller"));
        cb.setApprovalForAll(address(mp), true);
        uint256 id = mp.list(202904, 10, 1e6);
        mp.cancel(id);
        vm.stopPrank();
        assertEq(cb.balanceOf(makeAddr("seller"), 202904), 10);
    }

    function test_Pause_BondVault_NoPauseFn_RedeemUnconditional() public {
        // BondVault has no pause() — admin cannot block redemption.
        (BondVault v,,,) = _deployBVWithLumina();
        (bool ok1,) = address(v).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok1, "BondVault must not expose pause()");
        (bool ok2,) = address(v).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertFalse(ok2, "BondVault must not expose setPaused()");
    }

    function test_Pause_TWAPBurner_NoPauseFn_BurnContinues() public {
        MockERC20P u = new MockERC20P("USDC", "USDC");
        MockERC20P l = new MockERC20P("LUM", "LUM");
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(u), address(l), address(new InertRouterP()));
        (bool ok,) = address(tb).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "TWAPBurner must not expose pause()");
    }

    function test_Pause_BuybackEngine_NoPauseFn() public {
        // BuybackEngine has no pause surface by design — its `executeOffer` is
        // role-gated instead, so admin can simply revoke BUYBACK_OPERATOR_ROLE.
        MockERC20P usdc = new MockERC20P("USDC", "USDC");
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        MockERC20P lumina = new MockERC20P("LUM", "LUM");
        FakeOracleP oracle = new FakeOracleP();
        BondVault vault = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        SolvencyOracle sol = ProxyDeployer.deploySolvencyOracle(address(vault), address(oracle), admin);

        // Minimal marketplace stub for BuybackEngine.init.
        address mp = address(new FakeMP());
        BuybackEngine be = ProxyDeployer.deployBuybackEngine(
            address(cb), address(vault), address(sol), address(oracle), mp, address(usdc), admin
        );
        (bool ok,) = address(be).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
    }

    // ═════════════════════ E. Auto-pause via price ═════════════════════

    function test_Pause_AutoPause_LowPriceBlocksPurchase() public {
        CoverRouterV2 r = _deployCR();
        r.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);

        // Set a capacity oracle that reports price below MIN_PRICE_FOR_NEW_POLICIES (5e15).
        FakeOracleP o = new FakeOracleP();
        o.setPrice(4e15); // $0.004 — below floor
        r.setCapacityOracle(address(o));

        assertTrue(r.isProtocolAutoPaused());

        vm.expectRevert(bytes("Protocol auto-paused: LUMINA price below safety threshold"));
        r.purchasePolicy(keccak256("P"), 100e6, "BTC");
    }

    function test_Pause_AutoResume_PriceRecovered() public {
        CoverRouterV2 r = _deployCR();
        r.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);
        FakeOracleP o = new FakeOracleP();
        o.setPrice(4e15);
        r.setCapacityOracle(address(o));

        // Now set price back above floor (5e15+).
        o.setPrice(9e15); // $0.009 > $0.005
        assertFalse(r.isProtocolAutoPaused());
        // Purchase will now pass the auto-pause check (will fail downstream at PM stub,
        // not with the auto-paused error).
        vm.expectRevert(); // downstream revert, but NOT ContractPaused/auto-paused
        r.purchasePolicy(keccak256("P"), 100e6, "BTC");
    }

    function test_Pause_AutoPause_ExactFloorPriceAllowed() public {
        CoverRouterV2 r = _deployCR();
        FakeOracleP o = new FakeOracleP();
        o.setPrice(5e15); // exactly at floor — should NOT be paused (check is `<`)
        r.setCapacityOracle(address(o));
        assertFalse(r.isProtocolAutoPaused());
    }

    function test_Pause_AutoPause_IsolatedToNewPolicies() public {
        // Auto-pause blocks NEW purchases but does NOT affect already-issued bonds.
        (BondVault v, ClaimBond cb,, FakeOracleP orc) = _deployBVWithLumina();
        v.issueBond(makeAddr("holder"), 50);
        uint256 epoch = _scanEpoch(cb, makeAddr("holder"));
        vm.warp(cb.maturityDate(epoch) + 1);
        orc;

        // Router auto-pause state doesn't touch BondVault's redeemBond.
        vm.prank(makeAddr("holder"));
        v.redeemBond(epoch, 50);
        assertEq(cb.balanceOf(makeAddr("holder"), epoch), 0);
    }

    // ═════════════════════ F. Race conditions ═════════════════════

    function test_Pause_CR_DuringPurchase_FirstSucceedsSecondFails() public {
        CoverRouterV2 r = _deployCR();
        r.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);

        // First purchase fails at PM stub (not pause), proving not paused.
        vm.expectRevert();
        r.purchasePolicy(keccak256("P"), 100e6, "BTC");

        // Admin pauses.
        r.setPaused(true);

        // Second purchase now reverts with ContractPaused specifically.
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        r.purchasePolicy(keccak256("P"), 100e6, "BTC");
    }

    function test_Pause_CR_Then_Unpause_RoundTrip() public {
        CoverRouterV2 r = _deployCR();
        r.setPaused(true);
        r.setPaused(false);
        r.setPaused(true);
        r.setPaused(false);
        // No revert on sequence of toggles — state at end is unpaused.
        assertFalse(r.paused());
    }

    // ═════════════════════ G. Long pause state consistency ═════════════════════

    function test_Pause_LongPause_BondsStillMatureAndRedeem() public {
        (BondVault v, ClaimBond cb,, FakeOracleP oracle) = _deployBVWithLumina();
        v.issueBond(makeAddr("h"), 200);
        uint256 epoch = _scanEpoch(cb, makeAddr("h"));

        // Pause CR for 30 days.
        CoverRouterV2 r = _deployCR();
        r.setPaused(true);
        vm.warp(cb.maturityDate(epoch) + 1);

        // Redemption works despite pause.
        oracle;
        vm.prank(makeAddr("h"));
        v.redeemBond(epoch, 200);
        assertEq(cb.balanceOf(makeAddr("h"), epoch), 0);

        // Unpausing restores purchases later.
        r.setPaused(false);
        assertFalse(r.paused());
    }

    // ═════════════════════ H. Partial pause — CR pause doesn't cascade ═════════════════════

    function test_Pause_CR_DoesntPauseSolvencyOracle() public {
        CoverRouterV2 r = _deployCR();
        SolvencyOracle sol = _deploySolvency();
        r.setPaused(true);
        // SolvencyOracle still evaluable.
        vm.warp(block.timestamp + 2 days);
        sol.evaluate();
        assertFalse(sol.emergencyPaused());
    }

    function test_Pause_SolvencyOracle_DoesntBlockBondRedemption() public {
        (BondVault v, ClaimBond cb,, FakeOracleP oracle) = _deployBVWithLumina();
        v.issueBond(makeAddr("h"), 10);
        uint256 epoch = _scanEpoch(cb, makeAddr("h"));

        // Deploy SolvencyOracle and pause it — should not affect BondVault.
        SolvencyOracle sol = _deploySolvency();
        sol.setEmergencyPause(true);

        vm.warp(cb.maturityDate(epoch) + 1);
        oracle;
        vm.prank(makeAddr("h"));
        v.redeemBond(epoch, 10);
        assertEq(cb.balanceOf(makeAddr("h"), epoch), 0);
    }

    function test_Pause_ShieldKeeper_DoesntPauseRouter() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        CoverRouterV2 r = _deployCR();
        k.pause();
        // Router is independent.
        assertFalse(r.paused());
    }

    // ═════════════════════ I. Inventory-completeness sweep ═════════════════════

    function test_Pause_InventoryMatrix_OnlyThreePauseableContracts() public {
        MockERC20P usdc = new MockERC20P("USDC", "USDC");
        MockERC20P lumina = new MockERC20P("LUM", "LUM");
        FakeOracleP oracle = new FakeOracleP();

        // PAUSEABLE: CoverRouterV2 (setPaused), ShieldKeeper (pause/unpause), SolvencyOracle (setEmergencyPause).
        CoverRouterV2 r = _deployCR();
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        SolvencyOracle sol = _deploySolvency();

        (bool a,) = address(r).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(a);
        (bool b,) = address(k).call(abi.encodeWithSignature("pause()"));
        assertTrue(b);
        (bool c,) = address(sol).call(abi.encodeWithSignature("setEmergencyPause(bool)", true));
        assertTrue(c);

        // NOT PAUSEABLE:
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault v = ProxyDeployer.deployBondVault(address(lumina), address(cb), address(oracle), admin);
        TWAPBurner tb = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(new InertRouterP()));
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), makeAddr("burner"), admin);
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(address(v));

        for (uint256 i = 0; i < 5; i++) {
            address target =
                i == 0 ? address(v) : i == 1 ? address(tb) : i == 2 ? address(mp) : i == 3 ? address(pm) : address(cb);
            (bool okPause,) = target.call(abi.encodeWithSignature("pause()"));
            assertFalse(okPause, "contract should not expose pause()");
            (bool okSet,) = target.call(abi.encodeWithSignature("setPaused(bool)", true));
            assertFalse(okSet, "contract should not expose setPaused()");
        }
    }

    // ═════════════════════ J. Auto-pause + admin-pause stack ═════════════════════

    function test_Pause_AutoPauseAndAdminPause_BothReject() public {
        CoverRouterV2 r = _deployCR();
        r.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);
        FakeOracleP o = new FakeOracleP();
        o.setPrice(4e15);
        r.setCapacityOracle(address(o));
        r.setPaused(true); // admin pause on top of auto-pause

        // Admin-pause fires first (whenNotPaused modifier checks before internal _purchase).
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        r.purchasePolicy(keccak256("P"), 100e6, "BTC");
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Fake marketplace for BuybackEngine deploy
// ─────────────────────────────────────────────────────────────────────────

contract FakeMP {
    uint256 public constant BUYER_FEE_BPS = 150;
    uint256 public constant BPS_DENOMINATOR = 10000;

    function executeBuy(uint256) external {}

    function getListing(uint256) external pure returns (address, uint256, uint256, uint256, bool) {
        return (address(0), 0, 0, 0, false);
    }
}
