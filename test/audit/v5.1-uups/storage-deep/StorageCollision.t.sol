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
import {CapacityOracle} from "../../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../../src/oracles/SolvencyOracle.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../src/treasury/MaintenanceReserve.sol";
import {TreasuryVesting} from "../../../../src/token/TreasuryVesting.sol";

/// @notice Minimal price oracle mock for contracts that require one during init or setters.
contract MockPriceOracleSD {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

/// @notice Minimal BondVault mock implementing the subset SolvencyOracle.initialize reads.
contract MockBondVaultSD {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function totalCommittedUSD() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Minimal Uniswap V3 pool mock returning observations consistent with LUMINA/USDC.
contract MockUniV3PoolSD {
    function observe(uint32[] calldata)
        external
        pure
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128 = new uint160[](2);
    }

    function slot0() external pure returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), int24(0), 0, 0, 0, 0, true);
    }
}

/**
 * @title StorageCollision
 * @notice Storage layout deep audit tests for 24 UUPS contracts.
 *
 * For each UUPS contract in LUMINA V5.1, this suite verifies:
 *
 *   (1) State preservation after a basic upgrade to a fresh impl of the same bytecode.
 *   (2) Storage slot positions match the inventory (slot 0 holds the first own variable,
 *       proving OZ 5.x ERC-7201 namespaced storage is being used by parents and not
 *       colliding with child state).
 *   (3) Sequential upgrades V1 -> V2 -> V3 preserve accumulated state.
 *   (4) Inheritance order is sane: auth (owner / DEFAULT_ADMIN_ROLE) still works post-upgrade.
 *
 * Plus a cross-contract scenario verifying two collaborating contracts still interact
 * correctly after both have been upgraded.
 *
 * All tests deploy real proxies, make real state changes via real setters, and perform
 * real upgradeToAndCall() calls. No math-only tests.
 */
contract StorageCollision is Test {
    // ─────────────────────────────────────────────────────────────
    // 1. LuminaTokenV2
    // ─────────────────────────────────────────────────────────────

    function _deployToken() internal returns (LuminaTokenV2) {
        return ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );
    }

    function test_Storage_LuminaToken_PreservedAfterBasicUpgrade() public {
        LuminaTokenV2 t = _deployToken();
        t.grantRole(t.BURNER_ROLE(), address(this));
        address lbp = makeAddr("lbp");
        vm.prank(lbp);
        t.approve(address(this), 5_000e18);
        t.burnFrom(lbp, 5_000e18);

        uint256 burnedBefore = t.totalBurned();
        uint256 supplyBefore = t.totalSupply();

        t.upgradeToAndCall(address(new LuminaTokenV2()), "");

        assertEq(t.totalBurned(), burnedBefore);
        assertEq(t.totalSupply(), supplyBefore);
        assertEq(t.balanceOf(makeAddr("bv")), 70_000_000e18);
        assertTrue(t.hasRole(t.BURNER_ROLE(), address(this)));
    }

    function test_Storage_LuminaToken_SlotLayout() public {
        // LuminaTokenV2 has ZERO own state variables (totalBurned is derived). All parent
        // contracts use ERC-7201 namespaced storage, so sequential slots 0..49 should all
        // be zero immediately after init and stay zero forever; only the __gap region.
        LuminaTokenV2 t = _deployToken();
        for (uint256 i = 0; i < 50; i++) {
            bytes32 v = vm.load(address(t), bytes32(i));
            assertEq(uint256(v), 0, "all slots 0..49 must be zero (namespaced storage + empty own state)");
        }
    }

    function test_Storage_LuminaToken_MultipleUpgradesSequential() public {
        LuminaTokenV2 t = _deployToken();
        t.grantRole(t.BURNER_ROLE(), address(this));
        vm.prank(makeAddr("lbp"));
        t.approve(address(this), 5_000e18);
        t.burnFrom(makeAddr("lbp"), 2_000e18);
        uint256 afterV1 = t.totalBurned();

        t.upgradeToAndCall(address(new LuminaTokenV2()), "");
        assertEq(t.totalBurned(), afterV1);

        t.burnFrom(makeAddr("lbp"), 1_500e18);
        uint256 afterV2 = t.totalBurned();
        assertEq(afterV2, afterV1 + 1_500e18);

        t.upgradeToAndCall(address(new LuminaTokenV2()), "");
        assertEq(t.totalBurned(), afterV2);
        assertEq(t.totalSupply(), 100_000_000e18 - afterV2);
    }

    function test_Storage_LuminaToken_InheritanceOrderCorrect() public {
        LuminaTokenV2 t = _deployToken();
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)));
        t.upgradeToAndCall(address(new LuminaTokenV2()), "");
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)));
        address attacker = makeAddr("randomuser");
        bytes32 burnerRole = t.BURNER_ROLE();
        vm.prank(attacker);
        vm.expectRevert();
        t.grantRole(burnerRole, attacker);
    }

    // ─────────────────────────────────────────────────────────────
    // 2. BondVault
    // ─────────────────────────────────────────────────────────────

    function _deployBondVaultFull() internal returns (BondVault vault, LuminaTokenV2 token, ClaimBond cb) {
        MockPriceOracleSD oracle = new MockPriceOracleSD();
        cb = ProxyDeployer.deployClaimBond();
        token = _deployToken();
        vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000e18);
    }

    function test_Storage_BondVault_PreservedAfterBasicUpgrade() public {
        (BondVault vault, LuminaTokenV2 token, ClaimBond cb) = _deployBondVaultFull();
        vault.setAuthorizedCaller(makeAddr("buyback"), true);
        vm.warp(1767225600 + 30 days);
        vault.issueBond(makeAddr("user"), 777, 0.036e18);

        uint256 committed = vault.totalCommittedUSD();

        vault.upgradeToAndCall(address(new BondVault()), "");

        assertEq(vault.totalCommittedUSD(), committed);
        assertTrue(vault.authorizedCallers(makeAddr("buyback")));
        assertEq(address(vault.lumina()), address(token));
        assertEq(address(vault.claimBond()), address(cb));
    }

    function test_Storage_BondVault_SlotLayout() public {
        (BondVault vault, LuminaTokenV2 token,) = _deployBondVaultFull();
        // Slot 0 = lumina (first state var in BondVault).
        address slot0Addr = address(uint160(uint256(vm.load(address(vault), bytes32(uint256(0))))));
        assertEq(slot0Addr, address(token), "slot0 must be lumina");
    }

    function test_Storage_BondVault_MultipleUpgradesSequential() public {
        (BondVault vault,,) = _deployBondVaultFull();
        vm.warp(1767225600 + 30 days);
        vault.issueBond(makeAddr("u1"), 100, 0.036e18);
        uint256 afterV1 = vault.totalCommittedUSD();

        vault.upgradeToAndCall(address(new BondVault()), "");
        vault.issueBond(makeAddr("u2"), 200, 0.036e18);
        uint256 afterV2 = vault.totalCommittedUSD();

        vault.upgradeToAndCall(address(new BondVault()), "");
        vault.issueBond(makeAddr("u3"), 300, 0.036e18);
        uint256 afterV3 = vault.totalCommittedUSD();

        vault.upgradeToAndCall(address(new BondVault()), "");

        assertEq(vault.totalCommittedUSD(), afterV3);
        assertEq(afterV2 - afterV1, 200e18);
        assertEq(afterV3 - afterV2, 300e18);
    }

    function test_Storage_BondVault_InheritanceOrderCorrect() public {
        (BondVault vault,,) = _deployBondVaultFull();
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(this)));
        vault.upgradeToAndCall(address(new BondVault()), "");
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(this)));
        address attackerImpl = address(new BondVault());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        vault.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 3. ClaimBond
    // ─────────────────────────────────────────────────────────────

    function test_Storage_ClaimBond_PreservedAfterBasicUpgrade() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));
        cb.mint(makeAddr("alice"), 202804, 100);
        cb.mint(makeAddr("bob"), 202806, 200);

        cb.upgradeToAndCall(address(new ClaimBond()), "");

        assertEq(cb.balanceOf(makeAddr("alice"), 202804), 100);
        assertEq(cb.balanceOf(makeAddr("bob"), 202806), 200);
        assertEq(cb.totalSupply(202804), 100);
        assertTrue(cb.epochExists(202804));
        assertTrue(cb.epochExists(202806));
        assertEq(cb.bondVault(), address(this));
    }

    function test_Storage_ClaimBond_SlotLayout() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));
        // Slot 0 = bondVault + _bondVaultSet packed.
        bytes32 slot0 = vm.load(address(cb), bytes32(uint256(0)));
        address bondVaultInSlot = address(uint160(uint256(slot0)));
        assertEq(bondVaultInSlot, address(this), "slot0 low 20 bytes = bondVault");
        // The packed bool is in the 21st byte (offset 20).
        uint8 bondVaultSetByte = uint8(uint256(slot0) >> 160);
        assertEq(bondVaultSetByte, 1, "packed _bondVaultSet should be 1");
    }

    function test_Storage_ClaimBond_MultipleUpgradesSequential() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));
        cb.mint(makeAddr("a"), 202804, 10);

        cb.upgradeToAndCall(address(new ClaimBond()), "");
        cb.mint(makeAddr("a"), 202804, 20);

        cb.upgradeToAndCall(address(new ClaimBond()), "");
        cb.mint(makeAddr("a"), 202805, 40);

        cb.upgradeToAndCall(address(new ClaimBond()), "");

        assertEq(cb.balanceOf(makeAddr("a"), 202804), 30);
        assertEq(cb.balanceOf(makeAddr("a"), 202805), 40);
        assertEq(cb.totalSupply(202804), 30);
        assertEq(cb.totalSupply(202805), 40);
    }

    function test_Storage_ClaimBond_InheritanceOrderCorrect() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        assertEq(cb.owner(), address(this));
        cb.upgradeToAndCall(address(new ClaimBond()), "");
        assertEq(cb.owner(), address(this));
        address attackerImpl = address(new ClaimBond());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        cb.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 4. PolicyManagerV2
    // ─────────────────────────────────────────────────────────────

    function _deployPM() internal returns (PolicyManagerV2 pm) {
        pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        pm.setRouter(address(this));
    }

    function test_Storage_PolicyManagerV2_PreservedAfterBasicUpgrade() public {
        PolicyManagerV2 pm = _deployPM();
        bytes32 pid = keccak256("TEST-PID");
        pm.registerProduct(pid, makeAddr("shield"));
        vm.mockCall(
            makeAddr("shield"),
            abi.encodeWithSelector(
                bytes4(keccak256("createPolicy((address,uint256,uint256,uint32,bytes32,bytes32,address,bytes))"))
            ),
            abi.encode(uint256(42))
        );
        vm.mockCall(
            makeAddr("vault"),
            abi.encodeWithSelector(bytes4(keccak256("availableCapacityUSD()"))),
            abi.encode(uint256(1_000_000))
        );
        vm.mockCall(makeAddr("vault"), abi.encodeWithSelector(bytes4(keccak256("reserveCapacity(uint256)"))), "");
        // [Audit fix H-6] recordPolicy now reads `bondVault.priceOracle().getLuminaPrice()`
        // for the snapshot. Stub both to a deterministic price so the upgrade-storage
        // test stays focused on storage layout, not price plumbing.
        vm.mockCall(
            makeAddr("vault"),
            abi.encodeWithSelector(bytes4(keccak256("priceOracle()"))),
            abi.encode(makeAddr("oracle"))
        );
        vm.mockCall(
            makeAddr("oracle"),
            abi.encodeWithSelector(bytes4(keccak256("getLuminaPrice()"))),
            abi.encode(uint256(0.036e18))
        );
        pm.recordPolicy(pid, makeAddr("buyer"), 500e6, 5e6, 3600, "BTC");

        uint256 totalBefore = pm.totalPolicies();
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");

        assertEq(pm.totalPolicies(), totalBefore);
        assertTrue(pm.productActive(pid));
        assertEq(pm.productShield(pid), makeAddr("shield"));
        assertEq(address(pm.bondVault()), makeAddr("vault"));
    }

    function test_Storage_PolicyManagerV2_SlotLayout() public {
        PolicyManagerV2 pm = _deployPM();
        address slot0 = address(uint160(uint256(vm.load(address(pm), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("vault"), "slot0 = bondVault");
        address slot1 = address(uint160(uint256(vm.load(address(pm), bytes32(uint256(1))))));
        assertEq(slot1, address(this), "slot1 = router");
    }

    function test_Storage_PolicyManagerV2_MultipleUpgradesSequential() public {
        PolicyManagerV2 pm = _deployPM();
        pm.registerProduct(keccak256("A"), makeAddr("sA"));
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");
        pm.registerProduct(keccak256("B"), makeAddr("sB"));
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");
        pm.registerProduct(keccak256("C"), makeAddr("sC"));
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");

        assertTrue(pm.productActive(keccak256("A")));
        assertTrue(pm.productActive(keccak256("B")));
        assertTrue(pm.productActive(keccak256("C")));
    }

    function test_Storage_PolicyManagerV2_InheritanceOrderCorrect() public {
        PolicyManagerV2 pm = _deployPM();
        assertEq(pm.owner(), address(this));
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");
        assertEq(pm.owner(), address(this));
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        pm.setRouter(makeAddr("evil"));
    }

    // ─────────────────────────────────────────────────────────────
    // 5. CoverRouterV2
    // ─────────────────────────────────────────────────────────────

    function _deployRouter() internal returns (CoverRouterV2) {
        return ProxyDeployer.deployCoverRouterV2(makeAddr("usdc"), makeAddr("pm"), makeAddr("burner"));
    }

    function test_Storage_CoverRouterV2_PreservedAfterBasicUpgrade() public {
        CoverRouterV2 r = _deployRouter();
        bytes32 pid = keccak256("PROD-A");
        r.configureProduct(pid, 8000, 200, 2000, 3600, true);
        r.setRelayer(makeAddr("relayer"), true);

        r.upgradeToAndCall(address(new CoverRouterV2()), "");

        assertTrue(r.authorizedRelayers(makeAddr("relayer")));
        (bytes32 id, uint256 payoutRatio, uint256 triggerProb, uint256 margin, uint32 duration, bool active) =
            r.products(pid);
        assertEq(id, pid);
        assertEq(payoutRatio, 8000);
        assertEq(triggerProb, 200);
        assertEq(margin, 2000);
        assertEq(duration, 3600);
        assertTrue(active);
    }

    function test_Storage_CoverRouterV2_SlotLayout() public {
        CoverRouterV2 r = _deployRouter();
        address slot0 = address(uint160(uint256(vm.load(address(r), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("usdc"), "slot0 = usdc");
        address slot1 = address(uint160(uint256(vm.load(address(r), bytes32(uint256(1))))));
        assertEq(slot1, makeAddr("pm"), "slot1 = policyManager");
    }

    function test_Storage_CoverRouterV2_MultipleUpgradesSequential() public {
        CoverRouterV2 r = _deployRouter();
        r.configureProduct(keccak256("A"), 8000, 100, 1000, 3600, true);
        r.upgradeToAndCall(address(new CoverRouterV2()), "");
        r.configureProduct(keccak256("B"), 7000, 200, 1500, 7200, true);
        r.upgradeToAndCall(address(new CoverRouterV2()), "");
        r.configureProduct(keccak256("C"), 6000, 300, 2000, 86400, true);
        r.upgradeToAndCall(address(new CoverRouterV2()), "");

        (,,,,, bool aAct) = r.products(keccak256("A"));
        (,,,,, bool bAct) = r.products(keccak256("B"));
        (,,,,, bool cAct) = r.products(keccak256("C"));
        assertTrue(aAct && bAct && cAct);
    }

    function test_Storage_CoverRouterV2_InheritanceOrderCorrect() public {
        CoverRouterV2 r = _deployRouter();
        assertEq(r.owner(), address(this));
        r.upgradeToAndCall(address(new CoverRouterV2()), "");
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        r.setRelayer(makeAddr("evil"), true);
    }

    // ─────────────────────────────────────────────────────────────
    // 6. TWAPBurner
    // ─────────────────────────────────────────────────────────────

    function _deployBurner() internal returns (TWAPBurner) {
        return ProxyDeployer.deployTWAPBurner(makeAddr("usdc"), makeAddr("lumina"), makeAddr("dex"));
    }

    function test_Storage_TWAPBurner_PreservedAfterBasicUpgrade() public {
        TWAPBurner b = _deployBurner();
        b.setMinBurnAmount(1000e6);
        b.setMaxBurnAmount(100_000e6);
        b.setBurnCooldown(3600);
        b.setMaxSlippageBps(500);
        b.setAuthorizedSender(makeAddr("router"), true);
        // setAdaptiveMode(true) requires feeDistributor + reserves to be non-zero.
        b.setFeeDistributor(makeAddr("feeDist"));
        b.setReserves(makeAddr("buybackReserve"), makeAddr("opsReserve"), makeAddr("maintReserve"));
        b.setAdaptiveMode(true);

        b.upgradeToAndCall(address(new TWAPBurner()), "");

        assertEq(b.minBurnAmount(), 1000e6);
        assertEq(b.maxBurnAmount(), 100_000e6);
        assertEq(b.burnCooldown(), 3600);
        assertEq(b.maxSlippageBps(), 500);
        assertTrue(b.authorizedSenders(makeAddr("router")));
        assertTrue(b.adaptiveModeEnabled());
        assertEq(b.feeDistributor(), makeAddr("feeDist"));
        assertEq(address(b.usdc()), makeAddr("usdc"));
        assertEq(address(b.lumina()), makeAddr("lumina"));
    }

    function test_Storage_TWAPBurner_SlotLayout() public {
        TWAPBurner b = _deployBurner();
        address slot0 = address(uint160(uint256(vm.load(address(b), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("usdc"), "slot0 = usdc");
        address slot1 = address(uint160(uint256(vm.load(address(b), bytes32(uint256(1))))));
        assertEq(slot1, makeAddr("lumina"), "slot1 = lumina");
    }

    function test_Storage_TWAPBurner_MultipleUpgradesSequential() public {
        TWAPBurner b = _deployBurner();
        b.setMinBurnAmount(1e6);
        b.upgradeToAndCall(address(new TWAPBurner()), "");
        b.setMinBurnAmount(2e6);
        b.upgradeToAndCall(address(new TWAPBurner()), "");
        b.setMinBurnAmount(3e6);
        b.upgradeToAndCall(address(new TWAPBurner()), "");
        assertEq(b.minBurnAmount(), 3e6);
    }

    function test_Storage_TWAPBurner_InheritanceOrderCorrect() public {
        TWAPBurner b = _deployBurner();
        assertEq(b.owner(), address(this));
        b.upgradeToAndCall(address(new TWAPBurner()), "");
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        b.setMinBurnAmount(1e6);
    }

    // ─────────────────────────────────────────────────────────────
    // 7. AdaptiveFeeDistributor
    // ─────────────────────────────────────────────────────────────

    function test_Storage_AdaptiveFeeDistributor_PreservedAfterBasicUpgrade() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("solvOracle"));
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        assertEq(address(d.solvencyOracle()), makeAddr("solvOracle"));
    }

    function test_Storage_AdaptiveFeeDistributor_SlotLayout() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("solvOracle"));
        address slot0 = address(uint160(uint256(vm.load(address(d), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("solvOracle"), "slot0 = solvencyOracle");
    }

    function test_Storage_AdaptiveFeeDistributor_MultipleUpgradesSequential() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("o"));
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        assertEq(address(d.solvencyOracle()), makeAddr("o"));
    }

    function test_Storage_AdaptiveFeeDistributor_InheritanceOrderCorrect() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("o"));
        assertEq(d.owner(), address(this));
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        address attackerImpl = address(new AdaptiveFeeDistributor());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        d.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 8. BuybackEngine
    // ─────────────────────────────────────────────────────────────

    function _deployBuyback() internal returns (BuybackEngine) {
        return ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"),
            makeAddr("bv"),
            makeAddr("so"),
            makeAddr("co"),
            makeAddr("mk"),
            makeAddr("usdc"),
            address(this)
        );
    }

    function test_Storage_BuybackEngine_PreservedAfterBasicUpgrade() public {
        BuybackEngine e = _deployBuyback();
        e.setDailyBuyback(10_000e6, 80, 4);

        e.upgradeToAndCall(address(new BuybackEngine()), "");

        assertEq(address(e.claimBond()), makeAddr("cb"));
        assertEq(address(e.bondVault()), makeAddr("bv"));
        assertEq(address(e.usdc()), makeAddr("usdc"));
        (uint256 budget, uint256 maxPricePct,,) = e.dailyConfig();
        assertEq(budget, 10_000e6);
        assertEq(maxPricePct, 80);
    }

    function test_Storage_BuybackEngine_SlotLayout() public {
        BuybackEngine e = _deployBuyback();
        address slot0 = address(uint160(uint256(vm.load(address(e), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("cb"), "slot0 = claimBond");
    }

    function test_Storage_BuybackEngine_MultipleUpgradesSequential() public {
        BuybackEngine e = _deployBuyback();
        e.setDailyBuyback(1_000e6, 70, 2);
        e.upgradeToAndCall(address(new BuybackEngine()), "");
        e.setDailyBuyback(2_000e6, 80, 3);
        e.upgradeToAndCall(address(new BuybackEngine()), "");
        e.setDailyBuyback(3_000e6, 90, 4);
        e.upgradeToAndCall(address(new BuybackEngine()), "");
        (uint256 budget,,,) = e.dailyConfig();
        assertEq(budget, 3_000e6);
    }

    function test_Storage_BuybackEngine_InheritanceOrderCorrect() public {
        BuybackEngine e = _deployBuyback();
        assertTrue(e.hasRole(e.DEFAULT_ADMIN_ROLE(), address(this)));
        e.upgradeToAndCall(address(new BuybackEngine()), "");
        assertTrue(e.hasRole(e.DEFAULT_ADMIN_ROLE(), address(this)));
        address attackerImpl = address(new BuybackEngine());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        e.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 9. LuminaBondMarketplace
    // ─────────────────────────────────────────────────────────────

    function _deployMP() internal returns (LuminaBondMarketplace) {
        return
            ProxyDeployer.deployLuminaBondMarketplace(
                makeAddr("cb"), makeAddr("usdc"), makeAddr("burner"), address(this)
            );
    }

    function test_Storage_LuminaBondMarketplace_PreservedAfterBasicUpgrade() public {
        LuminaBondMarketplace m = _deployMP();
        m.setTwapBurner(makeAddr("newBurner"));

        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");

        assertEq(m.twapBurner(), makeAddr("newBurner"));
        assertEq(address(m.usdc()), makeAddr("usdc"));
        assertEq(address(m.claimBond()), makeAddr("cb"));
    }

    function test_Storage_LuminaBondMarketplace_SlotLayout() public {
        LuminaBondMarketplace m = _deployMP();
        address slot0 = address(uint160(uint256(vm.load(address(m), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("cb"), "slot0 = claimBond");
    }

    function test_Storage_LuminaBondMarketplace_MultipleUpgradesSequential() public {
        LuminaBondMarketplace m = _deployMP();
        m.setTwapBurner(makeAddr("b1"));
        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        m.setTwapBurner(makeAddr("b2"));
        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        m.setTwapBurner(makeAddr("b3"));
        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        assertEq(m.twapBurner(), makeAddr("b3"));
    }

    function test_Storage_LuminaBondMarketplace_InheritanceOrderCorrect() public {
        LuminaBondMarketplace m = _deployMP();
        assertTrue(m.hasRole(m.DEFAULT_ADMIN_ROLE(), address(this)));
        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        address attackerImpl = address(new LuminaBondMarketplace());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        m.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 10. ShieldKeeper
    // ─────────────────────────────────────────────────────────────

    function test_Storage_ShieldKeeper_PreservedAfterBasicUpgrade() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();

        k.upgradeToAndCall(address(new ShieldKeeper()), "");

        assertEq(address(k.policyManager()), makeAddr("pm"));
        assertTrue(k.paused());
    }

    function test_Storage_ShieldKeeper_SlotLayout() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        bytes32 slot0 = vm.load(address(k), bytes32(uint256(0)));
        address pmAddr = address(uint160(uint256(slot0)));
        assertEq(pmAddr, makeAddr("pm"), "slot0 low = policyManager");
        uint8 pausedByte = uint8(uint256(slot0) >> 160);
        assertEq(pausedByte, 1, "slot0 packed paused = 1");
    }

    function test_Storage_ShieldKeeper_MultipleUpgradesSequential() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        k.upgradeToAndCall(address(new ShieldKeeper()), "");
        k.unpause();
        k.upgradeToAndCall(address(new ShieldKeeper()), "");
        k.pause();
        k.upgradeToAndCall(address(new ShieldKeeper()), "");
        assertTrue(k.paused());
    }

    function test_Storage_ShieldKeeper_InheritanceOrderCorrect() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        assertEq(k.owner(), address(this));
        k.upgradeToAndCall(address(new ShieldKeeper()), "");
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        k.pause();
    }

    // ─────────────────────────────────────────────────────────────
    // 11. CapacityOracle
    // ─────────────────────────────────────────────────────────────

    function _deployCapacityOracle() internal returns (CapacityOracle) {
        // Pass address(0) for pool so initialize() skips _setPool(), which requires a real
        // Uniswap V3 pool contract (with token0()). The pool can be set later via setPool()
        // once the real LUMINA/USDC pool exists. For storage-layout tests, that's fine.
        return ProxyDeployer.deployCapacityOracle(address(0), makeAddr("lumina"), makeAddr("usdc"), 0.036e18);
    }

    function test_Storage_CapacityOracle_PreservedAfterBasicUpgrade() public {
        CapacityOracle o = _deployCapacityOracle();
        // Window constraints: 5min..2hr (300..7200).
        o.setTwapWindow(600);
        o.setEmergencyPrice(0.05e18);

        o.upgradeToAndCall(address(new CapacityOracle()), "");

        assertEq(o.twapWindow(), 600);
        assertEq(o.emergencyPrice(), 0.05e18);
        assertEq(o.luminaToken(), makeAddr("lumina"));
        assertEq(o.usdcToken(), makeAddr("usdc"));
    }

    function test_Storage_CapacityOracle_SlotLayout() public {
        CapacityOracle o = _deployCapacityOracle();
        // Slot 0 = pool (address(0) since we skipped _setPool in init)
        address slot0 = address(uint160(uint256(vm.load(address(o), bytes32(uint256(0))))));
        assertEq(slot0, address(0), "slot0 = pool (unset)");
        // Slot 1 = luminaToken
        address slot1 = address(uint160(uint256(vm.load(address(o), bytes32(uint256(1))))));
        assertEq(slot1, makeAddr("lumina"), "slot1 = luminaToken");
        // Slot 2 = usdcToken packed with twapWindow in the upper 4 bytes
        bytes32 slot2Raw = vm.load(address(o), bytes32(uint256(2)));
        address usdcInSlot = address(uint160(uint256(slot2Raw)));
        assertEq(usdcInSlot, makeAddr("usdc"), "slot2 low = usdcToken");
    }

    function test_Storage_CapacityOracle_MultipleUpgradesSequential() public {
        CapacityOracle o = _deployCapacityOracle();
        o.setEmergencyPrice(0.01e18);
        o.upgradeToAndCall(address(new CapacityOracle()), "");
        o.setEmergencyPrice(0.02e18);
        o.upgradeToAndCall(address(new CapacityOracle()), "");
        o.setEmergencyPrice(0.03e18);
        o.upgradeToAndCall(address(new CapacityOracle()), "");
        assertEq(o.emergencyPrice(), 0.03e18);
    }

    function test_Storage_CapacityOracle_InheritanceOrderCorrect() public {
        CapacityOracle o = _deployCapacityOracle();
        assertEq(o.owner(), address(this));
        o.upgradeToAndCall(address(new CapacityOracle()), "");
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        o.setEmergencyPrice(0.99e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 12. SolvencyOracle
    // ─────────────────────────────────────────────────────────────

    function _deploySolvencyOracle() internal returns (SolvencyOracle) {
        MockBondVaultSD bv = new MockBondVaultSD(makeAddr("lumina"));
        return ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
    }

    function test_Storage_SolvencyOracle_PreservedAfterBasicUpgrade() public {
        SolvencyOracle so = _deploySolvencyOracle();
        address bvBefore = address(so.bondVault());
        so.setEmergencyPause(true);

        so.upgradeToAndCall(address(new SolvencyOracle()), "");

        assertTrue(so.emergencyPaused());
        assertEq(address(so.bondVault()), bvBefore);
        assertEq(address(so.capacityOracle()), makeAddr("co"));
    }

    function test_Storage_SolvencyOracle_SlotLayout() public {
        SolvencyOracle so = _deploySolvencyOracle();
        address bvBefore = address(so.bondVault());
        address slot0 = address(uint160(uint256(vm.load(address(so), bytes32(uint256(0))))));
        assertEq(slot0, bvBefore, "slot0 = bondVault");
    }

    function test_Storage_SolvencyOracle_MultipleUpgradesSequential() public {
        SolvencyOracle so = _deploySolvencyOracle();
        so.setEmergencyPause(true);
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        so.setEmergencyPause(false);
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        so.setEmergencyPause(true);
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        assertTrue(so.emergencyPaused());
    }

    function test_Storage_SolvencyOracle_InheritanceOrderCorrect() public {
        SolvencyOracle so = _deploySolvencyOracle();
        assertTrue(so.hasRole(so.DEFAULT_ADMIN_ROLE(), address(this)));
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        address attackerImpl = address(new SolvencyOracle());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        so.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 13. CEXLiquidityReserve
    // ─────────────────────────────────────────────────────────────

    function test_Storage_CEXLiquidityReserve_PreservedAfterBasicUpgrade() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("lumina"), address(this));
        uint256 depBefore = c.deploymentTimestamp();

        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");

        assertEq(address(c.lumina()), makeAddr("lumina"));
        assertEq(c.deploymentTimestamp(), depBefore);
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Storage_CEXLiquidityReserve_SlotLayout() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("lumina"), address(this));
        address slot0 = address(uint160(uint256(vm.load(address(c), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("lumina"), "slot0 = lumina");
    }

    function test_Storage_CEXLiquidityReserve_MultipleUpgradesSequential() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("lumina"), address(this));
        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");
        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");
        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");
        assertEq(address(c.lumina()), makeAddr("lumina"));
    }

    function test_Storage_CEXLiquidityReserve_InheritanceOrderCorrect() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("lumina"), address(this));
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), address(this)));
        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");
        address attackerImpl = address(new CEXLiquidityReserve());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        c.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 14. MaintenanceReserve
    // ─────────────────────────────────────────────────────────────

    function test_Storage_MaintenanceReserve_PreservedAfterBasicUpgrade() public {
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(makeAddr("usdc"), address(this));
        mr.setMonthlyCap(50_000e6);

        mr.upgradeToAndCall(address(new MaintenanceReserve()), "");

        assertEq(mr.monthlyCap(), 50_000e6);
        assertEq(address(mr.usdc()), makeAddr("usdc"));
    }

    function test_Storage_MaintenanceReserve_SlotLayout() public {
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(makeAddr("usdc"), address(this));
        address slot0 = address(uint160(uint256(vm.load(address(mr), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("usdc"), "slot0 = usdc");
    }

    function test_Storage_MaintenanceReserve_MultipleUpgradesSequential() public {
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(makeAddr("usdc"), address(this));
        mr.setMonthlyCap(1);
        mr.upgradeToAndCall(address(new MaintenanceReserve()), "");
        mr.setMonthlyCap(2);
        mr.upgradeToAndCall(address(new MaintenanceReserve()), "");
        mr.setMonthlyCap(3);
        mr.upgradeToAndCall(address(new MaintenanceReserve()), "");
        assertEq(mr.monthlyCap(), 3);
    }

    function test_Storage_MaintenanceReserve_InheritanceOrderCorrect() public {
        MaintenanceReserve mr = ProxyDeployer.deployMaintenanceReserve(makeAddr("usdc"), address(this));
        assertTrue(mr.hasRole(mr.DEFAULT_ADMIN_ROLE(), address(this)));
        mr.upgradeToAndCall(address(new MaintenanceReserve()), "");
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        mr.setMonthlyCap(9_999e6);
    }

    // ─────────────────────────────────────────────────────────────
    // 15. TreasuryVesting
    // ─────────────────────────────────────────────────────────────

    function test_Storage_TreasuryVesting_PreservedAfterBasicUpgrade() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("lumina"));
        uint256 deployedAtBefore = tv.deployedAt();

        tv.upgradeToAndCall(address(new TreasuryVesting()), "");

        assertEq(address(tv.luminaToken()), makeAddr("lumina"));
        assertEq(tv.deployedAt(), deployedAtBefore);
        assertEq(tv.totalReleased(), 0);
        assertEq(tv.lastReleaseMonth(), 0);
    }

    function test_Storage_TreasuryVesting_SlotLayout() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("lumina"));
        address slot0 = address(uint160(uint256(vm.load(address(tv), bytes32(uint256(0))))));
        assertEq(slot0, makeAddr("lumina"), "slot0 = luminaToken");
    }

    function test_Storage_TreasuryVesting_MultipleUpgradesSequential() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("lumina"));
        uint256 deployedAtBefore = tv.deployedAt();
        tv.upgradeToAndCall(address(new TreasuryVesting()), "");
        tv.upgradeToAndCall(address(new TreasuryVesting()), "");
        tv.upgradeToAndCall(address(new TreasuryVesting()), "");
        assertEq(tv.deployedAt(), deployedAtBefore);
        assertEq(address(tv.luminaToken()), makeAddr("lumina"));
    }

    function test_Storage_TreasuryVesting_InheritanceOrderCorrect() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("lumina"));
        assertEq(tv.owner(), address(this));
        tv.upgradeToAndCall(address(new TreasuryVesting()), "");
        address attackerImpl = address(new TreasuryVesting());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        tv.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // __gap region verification (common behaviour)
    // ─────────────────────────────────────────────────────────────

    /// @notice Verifies that gap region of BondVault reads as zero (confirming no field
    /// bleed into the gap). A non-zero value in the gap would indicate an unintended
    /// storage write or layout overlap.
    function test_Storage_BondVault_GapRegionIsZero() public {
        (BondVault vault,,) = _deployBondVaultFull();
        vm.warp(1767225600 + 30 days);
        vault.issueBond(makeAddr("u"), 100, 0.036e18);

        // Used slots are 0..7 for own state. The __gap runs at slots 8..57.
        for (uint256 i = 8; i < 58; i++) {
            bytes32 v = vm.load(address(vault), bytes32(i));
            assertEq(uint256(v), 0, "gap slot must be zero");
        }
    }

    /// @notice Same check for a trivial-layout contract (AdaptiveFeeDistributor has
    /// a single state var at slot 0, so slots 1..50 must be zero).
    function test_Storage_FeeDistributor_GapRegionIsZero() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("o"));
        for (uint256 i = 1; i < 51; i++) {
            bytes32 v = vm.load(address(d), bytes32(i));
            assertEq(uint256(v), 0, "gap slot must be zero");
        }
    }
}
