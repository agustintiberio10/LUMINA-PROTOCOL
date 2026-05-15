// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {BaseShield} from "../../../../src/products/BaseShield.sol";
import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../../src/products/FlashETHShield48h.sol";
import {MicroDepegShield} from "../../../../src/products/MicroDepegShield.sol";
import {RateShockShield} from "../../../../src/products/RateShockShield.sol";

import {IShield} from "../../../../src/interfaces/IShield.sol";

/// @notice Minimal oracle returning positive price for any asset, sufficient for Shield.createPolicy.
contract MockOracleShieldSD {
    int256 public priceBTC = 60_000e8;
    int256 public priceETH = 3_000e8;

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (asset == "BTC") return priceBTC;
        if (asset == "ETH") return priceETH;
        if (asset == "USDC" || asset == "USDT" || asset == "DAI") return 1e8;
        return 100e8;
    }
}

/// @notice Minimal Aave pool mock for RateShockShield init.
contract MockAavePoolSD {
    function getReserveData(address)
        external
        pure
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        )
    {
        return (0, 0, 1e25, 0, 1e25, 0, 0, 0, address(0), address(0), address(0), address(0), 0, 0, 0);
    }
}

/**
 * @title StorageCollisionShields
 * @notice Storage layout deep audit for the 9 concrete Shield products + BaseShield abstract.
 *
 * Every shield inherits BaseShield storage:
 *   slot 0: router
 *   slot 1: oracle
 *   slot 2: _policies mapping
 *   slot 3: _policyCounter
 *   slot 4: _activePolicies
 *   slot 5: _totalActiveCoverage
 *   slots 6..55: BaseShield __gap
 *   slot 56..: child-specific state (+ child __gap_shield)
 *
 * The tests set router = address(this) so createPolicy() can be called directly,
 * then verify state survives a basic upgrade, a sequential triple upgrade, the
 * slot layout matches the inventory, and auth still works.
 */
contract StorageCollisionShields is Test {
    MockOracleShieldSD internal oracle;
    MockAavePoolSD internal aave;

    function setUp() public {
        vm.chainId(8453);
        oracle = new MockOracleShieldSD();
        aave = new MockAavePoolSD();
    }

    function _params(uint32 duration, bytes32 asset) internal returns (IShield.CreatePolicyParams memory p) {
        p.buyer = makeAddr("buyer");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = duration;
        p.asset = asset;
        p.stablecoin = "";
        p.protocol = address(0);
        p.extraData = "";
    }

    // ─────────────────────────────────────────────────────────────
    // Generic helpers (avoid duplicating 40 near-identical tests)
    // ─────────────────────────────────────────────────────────────

    function _assertSlotLayout(address proxy, address oracleAddr) internal view {
        address slot0 = address(uint160(uint256(vm.load(proxy, bytes32(uint256(0))))));
        address slot1 = address(uint160(uint256(vm.load(proxy, bytes32(uint256(1))))));
        assertEq(slot0, address(this), "slot0 = router");
        assertEq(slot1, oracleAddr, "slot1 = oracle");
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield1h
    // ─────────────────────────────────────────────────────────────

    function test_Storage_FlashBTCShield1h_PreservedAfterBasicUpgrade() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        uint256 activeBefore = s.activePolicies();

        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");

        assertEq(s.activePolicies(), activeBefore);
        assertEq(s.router(), address(this));
        assertEq(s.oracle(), address(oracle));
        FlashBTCShield1h.BSSData memory data = s.getBSSData(pid);
        assertGt(data.strikePrice, 0);
    }

    function test_Storage_FlashBTCShield1h_SlotLayout() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        _assertSlotLayout(address(s), address(oracle));
    }

    function test_Storage_FlashBTCShield1h_MultipleUpgradesSequential() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        s.createPolicy(_params(3600, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");
        s.createPolicy(_params(3600, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");
        s.createPolicy(_params(3600, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");
        assertEq(s.activePolicies(), 3);
        assertEq(s.totalPolicies(), 3);
    }

    function test_Storage_FlashBTCShield1h_InheritanceOrderCorrect() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        assertEq(s.owner(), address(this));
        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");
        address attackerImpl = address(new FlashBTCShield1h());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield4h
    // ─────────────────────────────────────────────────────────────

    function test_Storage_FlashBTCShield4h_PreservedAfterBasicUpgrade() public {
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
        s.createPolicy(_params(14400, "BTC"));
        uint256 tpBefore = s.totalPolicies();
        s.upgradeToAndCall(address(new FlashBTCShield4h()), "");
        assertEq(s.totalPolicies(), tpBefore);
        assertEq(s.router(), address(this));
    }

    function test_Storage_FlashBTCShield4h_SlotLayout() public {
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
        _assertSlotLayout(address(s), address(oracle));
    }

    function test_Storage_FlashBTCShield4h_MultipleUpgradesSequential() public {
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
        s.createPolicy(_params(14400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield4h()), "");
        s.createPolicy(_params(14400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield4h()), "");
        s.createPolicy(_params(14400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield4h()), "");
        assertEq(s.totalPolicies(), 3);
    }

    function test_Storage_FlashBTCShield4h_InheritanceOrderCorrect() public {
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashBTCShield4h()), "");
        address attackerImpl = address(new FlashBTCShield4h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield24h
    // ─────────────────────────────────────────────────────────────

    function test_Storage_FlashBTCShield24h_PreservedAfterBasicUpgrade() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        s.createPolicy(_params(86400, "BTC"));
        uint256 tpBefore = s.totalPolicies();
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        assertEq(s.totalPolicies(), tpBefore);
    }

    function test_Storage_FlashBTCShield24h_SlotLayout() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        _assertSlotLayout(address(s), address(oracle));
    }

    function test_Storage_FlashBTCShield24h_MultipleUpgradesSequential() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        s.createPolicy(_params(86400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        s.createPolicy(_params(86400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        s.createPolicy(_params(86400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        assertEq(s.totalPolicies(), 3);
    }

    function test_Storage_FlashBTCShield24h_InheritanceOrderCorrect() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        address attackerImpl = address(new FlashBTCShield24h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // FlashBTCShield48h
    // ─────────────────────────────────────────────────────────────

    function test_Storage_FlashBTCShield48h_PreservedAfterBasicUpgrade() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        s.createPolicy(_params(172800, "BTC"));
        uint256 tpBefore = s.totalPolicies();
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        assertEq(s.totalPolicies(), tpBefore);
    }

    function test_Storage_FlashBTCShield48h_SlotLayout() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        _assertSlotLayout(address(s), address(oracle));
    }

    function test_Storage_FlashBTCShield48h_MultipleUpgradesSequential() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        s.createPolicy(_params(172800, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        s.createPolicy(_params(172800, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        s.createPolicy(_params(172800, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        assertEq(s.totalPolicies(), 3);
    }

    function test_Storage_FlashBTCShield48h_InheritanceOrderCorrect() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        address attackerImpl = address(new FlashBTCShield48h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield1h
    // ─────────────────────────────────────────────────────────────

    function test_Storage_FlashETHShield1h_PreservedAfterBasicUpgrade() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.createPolicy(_params(3600, "ETH"));
        uint256 tpBefore = s.totalPolicies();
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        assertEq(s.totalPolicies(), tpBefore);
    }

    function test_Storage_FlashETHShield1h_SlotLayout() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        _assertSlotLayout(address(s), address(oracle));
    }

    function test_Storage_FlashETHShield1h_MultipleUpgradesSequential() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.createPolicy(_params(3600, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        s.createPolicy(_params(3600, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        s.createPolicy(_params(3600, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        assertEq(s.totalPolicies(), 3);
    }

    function test_Storage_FlashETHShield1h_InheritanceOrderCorrect() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        address attackerImpl = address(new FlashETHShield1h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield24h
    // ─────────────────────────────────────────────────────────────

    function test_Storage_FlashETHShield24h_PreservedAfterBasicUpgrade() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        s.createPolicy(_params(86400, "ETH"));
        uint256 tpBefore = s.totalPolicies();
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        assertEq(s.totalPolicies(), tpBefore);
    }

    function test_Storage_FlashETHShield24h_SlotLayout() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        _assertSlotLayout(address(s), address(oracle));
    }

    function test_Storage_FlashETHShield24h_MultipleUpgradesSequential() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        s.createPolicy(_params(86400, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        s.createPolicy(_params(86400, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        s.createPolicy(_params(86400, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        assertEq(s.totalPolicies(), 3);
    }

    function test_Storage_FlashETHShield24h_InheritanceOrderCorrect() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        address attackerImpl = address(new FlashETHShield24h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // FlashETHShield48h
    // ─────────────────────────────────────────────────────────────

    function test_Storage_FlashETHShield48h_PreservedAfterBasicUpgrade() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        s.createPolicy(_params(172800, "ETH"));
        uint256 tpBefore = s.totalPolicies();
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        assertEq(s.totalPolicies(), tpBefore);
    }

    function test_Storage_FlashETHShield48h_SlotLayout() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        _assertSlotLayout(address(s), address(oracle));
    }

    function test_Storage_FlashETHShield48h_MultipleUpgradesSequential() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        s.createPolicy(_params(172800, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        s.createPolicy(_params(172800, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        s.createPolicy(_params(172800, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        assertEq(s.totalPolicies(), 3);
    }

    function test_Storage_FlashETHShield48h_InheritanceOrderCorrect() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        address attackerImpl = address(new FlashETHShield48h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // MicroDepegShield (coverage/duration different; we rely only on router/oracle slots)
    // ─────────────────────────────────────────────────────────────

    function test_Storage_MicroDepegShield_PreservedAfterBasicUpgrade() public {
        MicroDepegShield s = ProxyDeployer.deployMicroDepegShield(address(this), address(oracle));
        s.upgradeToAndCall(address(new MicroDepegShield()), "");
        assertEq(s.router(), address(this));
        assertEq(s.oracle(), address(oracle));
    }

    function test_Storage_MicroDepegShield_SlotLayout() public {
        MicroDepegShield s = ProxyDeployer.deployMicroDepegShield(address(this), address(oracle));
        _assertSlotLayout(address(s), address(oracle));
    }

    function test_Storage_MicroDepegShield_MultipleUpgradesSequential() public {
        MicroDepegShield s = ProxyDeployer.deployMicroDepegShield(address(this), address(oracle));
        s.upgradeToAndCall(address(new MicroDepegShield()), "");
        s.upgradeToAndCall(address(new MicroDepegShield()), "");
        s.upgradeToAndCall(address(new MicroDepegShield()), "");
        assertEq(s.router(), address(this));
        assertEq(s.totalPolicies(), 0);
    }

    function test_Storage_MicroDepegShield_InheritanceOrderCorrect() public {
        MicroDepegShield s = ProxyDeployer.deployMicroDepegShield(address(this), address(oracle));
        assertEq(s.owner(), address(this));
        s.upgradeToAndCall(address(new MicroDepegShield()), "");
        address attackerImpl = address(new MicroDepegShield());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // RateShockShield (extra state: aavePool, usdc at slots 56, 57)
    // ─────────────────────────────────────────────────────────────

    function test_Storage_RateShockShield_PreservedAfterBasicUpgrade() public {
        RateShockShield s =
            ProxyDeployer.deployRateShockShield(address(this), address(oracle), address(aave), makeAddr("usdc"));
        s.upgradeToAndCall(address(new RateShockShield()), "");
        assertEq(s.router(), address(this));
        assertEq(s.oracle(), address(oracle));
        assertEq(address(s.aavePool()), address(aave));
        assertEq(s.usdc(), makeAddr("usdc"));
    }

    function test_Storage_RateShockShield_SlotLayout() public {
        RateShockShield s =
            ProxyDeployer.deployRateShockShield(address(this), address(oracle), address(aave), makeAddr("usdc"));
        _assertSlotLayout(address(s), address(oracle));
        // Child state begins right after BaseShield gap (slot 56 in the post-compile layout).
        // We only verify the exported getters match rather than guessing the exact slot,
        // because the compiler is free to merge/pack child state above gap_shield.
        assertEq(address(s.aavePool()), address(aave));
        assertEq(s.usdc(), makeAddr("usdc"));
    }

    function test_Storage_RateShockShield_MultipleUpgradesSequential() public {
        RateShockShield s =
            ProxyDeployer.deployRateShockShield(address(this), address(oracle), address(aave), makeAddr("usdc"));
        s.upgradeToAndCall(address(new RateShockShield()), "");
        s.upgradeToAndCall(address(new RateShockShield()), "");
        s.upgradeToAndCall(address(new RateShockShield()), "");
        assertEq(s.router(), address(this));
        assertEq(address(s.aavePool()), address(aave));
        assertEq(s.usdc(), makeAddr("usdc"));
    }

    function test_Storage_RateShockShield_InheritanceOrderCorrect() public {
        RateShockShield s =
            ProxyDeployer.deployRateShockShield(address(this), address(oracle), address(aave), makeAddr("usdc"));
        assertEq(s.owner(), address(this));
        s.upgradeToAndCall(address(new RateShockShield()), "");
        address attackerImpl = address(new RateShockShield());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // BaseShield gap region verification (via a concrete shield)
    // ─────────────────────────────────────────────────────────────

    /// @notice The BaseShield __gap covers slots 6..55. Reading these slots after state
    /// mutation must yield zero; a non-zero value would indicate the parent contract
    /// bled into the gap or a variable is mis-positioned.
    function test_Storage_BaseShieldGap_ViaFlashBTC1h_IsZero() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        s.createPolicy(_params(3600, "BTC"));
        for (uint256 i = 6; i < 56; i++) {
            bytes32 v = vm.load(address(s), bytes32(i));
            assertEq(uint256(v), 0, "BaseShield gap slot must be zero");
        }
    }
}
