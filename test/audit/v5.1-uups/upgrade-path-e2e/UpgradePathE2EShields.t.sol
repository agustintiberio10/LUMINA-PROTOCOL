// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../../src/products/FlashETHShield48h.sol";
import {RateShockShield} from "../../../../src/products/RateShockShield.sol";
import {IShield} from "../../../../src/interfaces/IShield.sol";

contract MockOracleShieldE2E {
    function getLatestPrice(bytes32 asset) external pure returns (int256) {
        if (asset == "BTC") return 60_000e8;
        if (asset == "ETH") return 3_000e8;
        return 100e8;
    }
}

/**
 * @title UpgradePathE2EShields
 * @notice E2E upgrade tests for the 7 concrete Shield products.
 *
 * Each shield:
 *   (A) Deploy V1, createPolicy × 2, upgrade, verify state + create more policies
 *   (B) V1→V2→V3 with policies created between each step
 *   (C) Post-upgrade: ensure createPolicy + read paths still work.
 */
contract UpgradePathE2EShields is Test {
    MockOracleShieldE2E oracle;
    address constant AAVE = address(0xD1);
    address constant USDC = address(0xD2);

    function setUp() public {
        vm.chainId(8453);
        oracle = new MockOracleShieldE2E();
    }

    function _p(uint32 d, bytes32 a) internal returns (IShield.CreatePolicyParams memory p) {
        p.buyer = makeAddr("buyer");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = d;
        p.asset = a;
    }

    // FlashBTCShield1h
    function test_UpgradeE2E_FlashBTCShield1h_WithActiveState() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        s.createPolicy(_p(3600, "BTC"));
        s.createPolicy(_p(3600, "BTC"));
        uint256 activeBefore = s.activePolicies();

        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");

        assertEq(s.activePolicies(), activeBefore);
        s.createPolicy(_p(3600, "BTC"));
        assertEq(s.totalPolicies(), 3);
    }

    function test_UpgradeE2E_FlashBTCShield1h_SequentialUpgrades() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        s.createPolicy(_p(3600, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");
        s.createPolicy(_p(3600, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");
        s.createPolicy(_p(3600, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");
        assertEq(s.totalPolicies(), 3);
    }

    function test_UpgradeE2E_FlashBTCShield1h_PostUpgradeOperationsWork() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashBTCShield1h()), "");
        uint256 pid = s.createPolicy(_p(3600, "BTC"));
        FlashBTCShield1h.BSSData memory data = s.getBSSData(pid);
        assertGt(data.strikePrice, 0);
        assertEq(s.totalPolicies(), 1);
    }

    // FlashBTCShield24h
    function test_UpgradeE2E_FlashBTCShield24h_WithActiveState() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        s.createPolicy(_p(86400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        assertEq(s.totalPolicies(), 1);
        s.createPolicy(_p(86400, "BTC"));
        assertEq(s.totalPolicies(), 2);
    }

    function test_UpgradeE2E_FlashBTCShield24h_SequentialUpgrades() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        s.createPolicy(_p(86400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        s.createPolicy(_p(86400, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        s.createPolicy(_p(86400, "BTC"));
        assertEq(s.totalPolicies(), 3);
    }

    function test_UpgradeE2E_FlashBTCShield24h_PostUpgradeOperationsWork() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashBTCShield24h()), "");
        s.createPolicy(_p(86400, "BTC"));
        assertEq(s.totalPolicies(), 1);
    }

    // FlashBTCShield48h
    function test_UpgradeE2E_FlashBTCShield48h_WithActiveState() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        s.createPolicy(_p(172800, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        assertEq(s.totalPolicies(), 1);
    }

    function test_UpgradeE2E_FlashBTCShield48h_SequentialUpgrades() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        s.createPolicy(_p(172800, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        s.createPolicy(_p(172800, "BTC"));
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        assertEq(s.totalPolicies(), 2);
    }

    function test_UpgradeE2E_FlashBTCShield48h_PostUpgradeOperationsWork() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashBTCShield48h()), "");
        s.createPolicy(_p(172800, "BTC"));
        assertEq(s.totalPolicies(), 1);
    }

    // FlashETHShield1h
    function test_UpgradeE2E_FlashETHShield1h_WithActiveState() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.createPolicy(_p(3600, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        assertEq(s.totalPolicies(), 1);
    }

    function test_UpgradeE2E_FlashETHShield1h_SequentialUpgrades() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.createPolicy(_p(3600, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        s.createPolicy(_p(3600, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        assertEq(s.totalPolicies(), 2);
    }

    function test_UpgradeE2E_FlashETHShield1h_PostUpgradeOperationsWork() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashETHShield1h()), "");
        s.createPolicy(_p(3600, "ETH"));
        assertEq(s.totalPolicies(), 1);
    }

    // FlashETHShield24h
    function test_UpgradeE2E_FlashETHShield24h_WithActiveState() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        s.createPolicy(_p(86400, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        assertEq(s.totalPolicies(), 1);
    }

    function test_UpgradeE2E_FlashETHShield24h_SequentialUpgrades() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        s.createPolicy(_p(86400, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        s.createPolicy(_p(86400, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        assertEq(s.totalPolicies(), 2);
    }

    function test_UpgradeE2E_FlashETHShield24h_PostUpgradeOperationsWork() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashETHShield24h()), "");
        s.createPolicy(_p(86400, "ETH"));
        assertEq(s.totalPolicies(), 1);
    }

    // FlashETHShield48h
    function test_UpgradeE2E_FlashETHShield48h_WithActiveState() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        s.createPolicy(_p(172800, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        assertEq(s.totalPolicies(), 1);
    }

    function test_UpgradeE2E_FlashETHShield48h_SequentialUpgrades() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        s.createPolicy(_p(172800, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        s.createPolicy(_p(172800, "ETH"));
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        assertEq(s.totalPolicies(), 2);
    }

    function test_UpgradeE2E_FlashETHShield48h_PostUpgradeOperationsWork() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
        s.upgradeToAndCall(address(new FlashETHShield48h()), "");
        s.createPolicy(_p(172800, "ETH"));
        assertEq(s.totalPolicies(), 1);
    }

    // RateShockShield
    function test_UpgradeE2E_RateShockShield_WithActiveState() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(address(this), address(oracle), AAVE, USDC);
        s.upgradeToAndCall(address(new RateShockShield()), "");
        assertEq(s.router(), address(this));
        assertEq(address(s.aavePool()), AAVE);
        assertEq(s.usdc(), USDC);
    }

    function test_UpgradeE2E_RateShockShield_SequentialUpgrades() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(address(this), address(oracle), AAVE, USDC);
        s.upgradeToAndCall(address(new RateShockShield()), "");
        s.upgradeToAndCall(address(new RateShockShield()), "");
        s.upgradeToAndCall(address(new RateShockShield()), "");
        assertEq(address(s.aavePool()), AAVE);
    }

    function test_UpgradeE2E_RateShockShield_PostUpgradeOperationsWork() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(address(this), address(oracle), AAVE, USDC);
        s.upgradeToAndCall(address(new RateShockShield()), "");
        assertEq(s.owner(), address(this));
        assertEq(s.usdc(), USDC);
    }
}
