// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";

contract MockPriceOracleUpgrade {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

/// @title UpgradePath
/// @notice End-to-end upgrade tests verifying state preservation.
contract UpgradePath is Test {
    function test_LuminaToken_upgradePreservesBalances() public {
        address bondVault = makeAddr("bondVault");
        address cexReserve = makeAddr("cexReserve");
        address founderVesting = makeAddr("founderVesting");
        address lbpDeposit = makeAddr("lbpDeposit");
        address treasuryVesting = makeAddr("treasuryVesting");

        LuminaTokenV2 token =
            ProxyDeployer.deployLuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);

        // Record state before upgrade
        uint256 balBondVault = token.balanceOf(bondVault);
        uint256 balCex = token.balanceOf(cexReserve);
        uint256 totalSupplyBefore = token.totalSupply();

        assertEq(balBondVault, 70_000_000 * 1e18);
        assertEq(totalSupplyBefore, 100_000_000 * 1e18);

        // Upgrade to new implementation
        LuminaTokenV2 newImpl = new LuminaTokenV2();
        token.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(token.balanceOf(bondVault), balBondVault);
        assertEq(token.balanceOf(cexReserve), balCex);
        assertEq(token.totalSupply(), totalSupplyBefore);
        assertEq(token.name(), "Lumina Protocol");
        assertEq(token.symbol(), "LUMINA");
    }

    function test_BondVault_upgradePreservesCommitments() public {
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

        // Issue a bond to create state
        vault.issueBond(makeAddr("user"), 1000);
        uint256 committedBefore = vault.totalCommittedUSD();
        assertEq(committedBefore, 1000 * 1e18);

        // Upgrade
        BondVault newImpl = new BondVault();
        vault.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(vault.totalCommittedUSD(), committedBefore);
        assertEq(address(vault.lumina()), address(token));
    }

    function test_ClaimBond_upgradePreservesBonds() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));

        // Mint some bonds
        cb.mint(makeAddr("user"), 202804, 500);
        assertEq(cb.balanceOf(makeAddr("user"), 202804), 500);
        assertTrue(cb.epochExists(202804));

        // Upgrade
        ClaimBond newImpl = new ClaimBond();
        cb.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(cb.balanceOf(makeAddr("user"), 202804), 500);
        assertTrue(cb.epochExists(202804));
        assertEq(cb.bondVault(), address(this));
    }

    function test_PolicyManager_upgradePreservesPolicies() public {
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
}
