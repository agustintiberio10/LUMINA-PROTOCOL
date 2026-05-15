// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";

contract MockPriceOracleUpgrade {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

// Dummy non-UUPS contract
contract NonUUPSImpl {
    uint256 public x;
}

/// @title UpgradePath
/// @notice End-to-end upgrade tests verifying state preservation.
contract UpgradePath is Test {
    function test_PolicyManager_upgradePreservesPolicies() public {
        vm.chainId(8453);
        address mockVault = makeAddr("vault");
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(mockVault);
        pm.setRouter(address(this));

        address shield = makeAddr("shield");
        bytes32 pid = keccak256("TEST-001");
        pm.registerProduct(pid, shield);

        // Mock the shield's createPolicy call
        vm.mockCall(
            shield,
            abi.encodeWithSelector(
                bytes4(keccak256("createPolicy((address,uint256,uint256,uint32,bytes32,bytes32,address,bytes))"))
            ),
            abi.encode(uint256(1))
        );
        // Also mock BondVault calls
        vm.mockCall(
            mockVault,
            abi.encodeWithSelector(bytes4(keccak256("availableCapacityUSD()"))),
            abi.encode(uint256(1_000_000))
        );
        vm.mockCall(mockVault, abi.encodeWithSelector(bytes4(keccak256("reserveCapacity(uint256)"))), "");

        pm.recordPolicy(pid, makeAddr("buyer"), 1000e6, 2e6, 3600, "BTC");

        uint256 totalBefore = pm.totalPolicies();
        assertEq(totalBefore, 1);

        // Upgrade
        PolicyManagerV2 newImpl = new PolicyManagerV2();
        pm.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(pm.totalPolicies(), totalBefore);
        assertTrue(pm.productActive(pid));
        assertEq(pm.productShield(pid), shield);
    }

    function test_UpgradeToNonUUPS_Reverts() public {
        vm.chainId(8453);
        NonUUPSImpl dummy = new NonUUPSImpl();

        // ── BondVault ──
        {
            MockPriceOracleUpgrade oracle = new MockPriceOracleUpgrade();
            ClaimBond cb = ProxyDeployer.deployClaimBond();
            LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
                makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
            );
            BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));

            vm.expectRevert();
            vault.upgradeToAndCall(address(dummy), "");
        }

        // ── CoverRouterV2 ──
        {
            CoverRouterV2 router =
                ProxyDeployer.deployCoverRouterV2(makeAddr("usdc"), makeAddr("pm"), makeAddr("burner"));

            vm.expectRevert();
            router.upgradeToAndCall(address(dummy), "");
        }

        // ── TWAPBurner ──
        {
            TWAPBurner burner = ProxyDeployer.deployTWAPBurner(makeAddr("usdc"), makeAddr("lumina"), makeAddr("dex"));

            vm.expectRevert();
            burner.upgradeToAndCall(address(dummy), "");
        }
    }

    function test_Upgrade_MultiHop_V1_V2_V3_StatePreserved() public {
        vm.chainId(8453);
        MockPriceOracleUpgrade oracle = new MockPriceOracleUpgrade();
        ClaimBond cb = ProxyDeployer.deployClaimBond();

        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));

        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);

        // Warp to valid epoch
        vm.warp(1767225600 + 30 days);

        // ── V1 state: issue first bond ──
        vault.issueBond(makeAddr("user1"), 1000);
        uint256 committedAfterV1 = vault.totalCommittedUSD();
        assertEq(committedAfterV1, 1000 * 1e18);

        // ── Upgrade to V2 ──
        BondVault implV2 = new BondVault();
        vault.upgradeToAndCall(address(implV2), "");

        // Verify V1 state preserved
        assertEq(vault.totalCommittedUSD(), committedAfterV1);
        assertEq(address(vault.lumina()), address(token));

        // ── V2 state: issue more bonds ──
        vault.issueBond(makeAddr("user2"), 2000);
        uint256 committedAfterV2 = vault.totalCommittedUSD();
        assertEq(committedAfterV2, 3000 * 1e18);

        // ── Upgrade to V3 ──
        BondVault implV3 = new BondVault();
        vault.upgradeToAndCall(address(implV3), "");

        // Verify all state preserved (V1 + V2 bonds)
        assertEq(vault.totalCommittedUSD(), committedAfterV2);
        assertEq(address(vault.lumina()), address(token));
        assertEq(address(vault.claimBond()), address(cb));
        assertEq(address(vault.priceOracle()), address(oracle));
    }
}
