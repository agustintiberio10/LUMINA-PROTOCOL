// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {RateShockShield} from "../../src/products/RateShockShield.sol";

/// @title UpgradeRateShockShield
/// @notice Sprint H Phase 4.5 — UUPS upgrade of the RateShockShield proxy on
///         Sepolia to add the new `setAavePool(address)` setter, then wires
///         the freshly-deployed `MockAavePool` (Sprint H deliverable) into
///         the live proxy.
/// @dev Required env vars:
///        - RATESHOCK_PROXY: the live RateShockShield proxy address.
///        - MOCK_AAVE_POOL:  the new MockAavePool address (Sprint H deploy).
///      Run with the deployer key (it owns the shield proxy):
///        forge script script/upgrade/UpgradeRateShockShield.s.sol \
///          --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_PRIVATE_KEY \
///          --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
contract UpgradeRateShockShield is Script {
    function run() external {
        address proxyAddr = vm.envAddress("RATESHOCK_PROXY");
        address newAavePool = vm.envAddress("MOCK_AAVE_POOL");

        // Snapshot pre-state for sanity check.
        RateShockShield proxy = RateShockShield(proxyAddr);
        address oldAavePool = address(proxy.aavePool());
        address oldUsdc = proxy.usdc();
        bytes32 oldProductId = proxy.productId();

        console.log("PRE-UPGRADE STATE");
        console.log("  proxy:         ", proxyAddr);
        console.log("  aavePool:      ", oldAavePool);
        console.log("  usdc:          ", oldUsdc);

        vm.startBroadcast();

        // 1. Deploy fresh impl (with setAavePool).
        RateShockShield newImpl = new RateShockShield();
        console.log("New impl deployed:", address(newImpl));

        // 2. Upgrade proxy. No initializer call needed — only adding a method,
        //    no new storage slots or migration.
        UUPSUpgradeable(proxyAddr).upgradeToAndCall(address(newImpl), "");
        console.log("Proxy upgraded to new impl.");

        // 3. Rotate the aavePool to the new MockAavePool.
        proxy.setAavePool(newAavePool);
        console.log("aavePool rotated to:", newAavePool);

        vm.stopBroadcast();

        // ─── Post-upgrade verification (storage preservation) ───
        require(proxy.usdc() == oldUsdc, "usdc lost in upgrade");
        require(proxy.productId() == oldProductId, "productId lost in upgrade");
        require(address(proxy.aavePool()) == newAavePool, "aavePool not rotated");

        console.log("POST-UPGRADE STATE (verified)");
        console.log("  aavePool: ", address(proxy.aavePool()));
        console.log("  usdc:     ", proxy.usdc());
        console.log("===== RATESHOCK SHIELD UPGRADED + WIRED =====");
    }
}
