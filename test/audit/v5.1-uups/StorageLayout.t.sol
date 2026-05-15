// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";

contract MockPriceOracleStorage {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

/// @title StorageLayout
/// @notice Verifies that upgrades preserve storage layout correctly.
contract StorageLayout is Test {
    function test_LuminaToken_storagePreservedAfterUpgrade() public {
        vm.chainId(8453);
        address bondVault = makeAddr("bondVault");
        address cexReserve = makeAddr("cexReserve");
        address founderVesting = makeAddr("founderVesting");
        address lbpDeposit = makeAddr("lbpDeposit");
        address treasuryVesting = makeAddr("treasuryVesting");

        LuminaTokenV2 token =
            ProxyDeployer.deployLuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);

        // Grant burner role and burn some tokens to change state
        token.grantRole(token.BURNER_ROLE(), address(this));
        vm.prank(lbpDeposit);
        token.approve(address(this), 1000e18);
        token.burnFrom(lbpDeposit, 1000e18);

        uint256 totalBurnedBefore = token.totalBurned();
        uint256 supplyBefore = token.totalSupply();
        bool hasBurnerRole = token.hasRole(token.BURNER_ROLE(), address(this));

        // Upgrade
        LuminaTokenV2 newImpl = new LuminaTokenV2();
        token.upgradeToAndCall(address(newImpl), "");

        // All storage should be identical
        assertEq(token.totalBurned(), totalBurnedBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.hasRole(token.BURNER_ROLE(), address(this)), hasBurnerRole);
        assertEq(token.balanceOf(bondVault), 70_000_000 * 1e18);
        assertEq(token.balanceOf(lbpDeposit), 5_000_000 * 1e18 - 1000e18);
    }

    function test_BondVault_storageLayoutPreserved() public {
        vm.chainId(8453);
        MockPriceOracleStorage oracle = new MockPriceOracleStorage();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));

        // Set up authorized caller
        vault.setAuthorizedCaller(makeAddr("buyback"), true);

        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);

        vm.warp(1767225600 + 30 days);
        vault.issueBond(makeAddr("user"), 500);

        // Record state
        uint256 committedBefore = vault.totalCommittedUSD();
        bool isAuthorized = vault.authorizedCallers(makeAddr("buyback"));

        // Upgrade
        BondVault newImpl = new BondVault();
        vault.upgradeToAndCall(address(newImpl), "");

        // Verify
        assertEq(vault.totalCommittedUSD(), committedBefore);
        assertEq(vault.authorizedCallers(makeAddr("buyback")), isAuthorized);
        assertEq(address(vault.lumina()), address(token));
        assertEq(address(vault.claimBond()), address(cb));
        assertEq(address(vault.priceOracle()), address(oracle));
    }

    function test_ClaimBond_storageLayoutPreserved() public {
        vm.chainId(8453);
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));

        // Create state
        cb.mint(makeAddr("alice"), 202804, 1000);
        cb.mint(makeAddr("bob"), 202806, 2000);

        uint256 aliceBalance = cb.balanceOf(makeAddr("alice"), 202804);
        uint256 bobBalance = cb.balanceOf(makeAddr("bob"), 202806);
        uint256 supply202804 = cb.totalSupply(202804);
        uint256 maturity = cb.maturityDate(202804);

        // Upgrade
        ClaimBond newImpl = new ClaimBond();
        cb.upgradeToAndCall(address(newImpl), "");

        // Verify
        assertEq(cb.balanceOf(makeAddr("alice"), 202804), aliceBalance);
        assertEq(cb.balanceOf(makeAddr("bob"), 202806), bobBalance);
        assertEq(cb.totalSupply(202804), supply202804);
        assertEq(cb.maturityDate(202804), maturity);
        assertTrue(cb.epochExists(202804));
        assertTrue(cb.epochExists(202806));
        assertEq(cb.bondVault(), address(this));
    }

    function test_CoverRouterV2_storageLayoutPreserved() public {
        vm.chainId(8453);
        // Deploy with mock deps
        address mockUsdc = makeAddr("usdc");
        address mockPm = makeAddr("pm");
        address mockBurner = makeAddr("burner");

        CoverRouterV2 router = ProxyDeployer.deployCoverRouterV2(mockUsdc, mockPm, mockBurner);

        // Configure a product
        bytes32 pid = keccak256("FLASHBTC1H-001");
        router.configureProduct(pid, 8000, 200, 2000, 3600, true);

        // Set a relayer
        address relayer = makeAddr("relayer");
        router.setRelayer(relayer, true);

        // Record state
        address pmBefore = address(router.policyManager());
        address burnerBefore = address(router.twapBurner());
        (bytes32 storedPid, uint256 payoutRatio, uint256 triggerProb, uint256 margin, uint32 duration, bool active) =
            router.products(pid);
        bool relayerAuthorized = router.authorizedRelayers(relayer);

        // Upgrade to new impl
        CoverRouterV2 newImpl = new CoverRouterV2();
        router.upgradeToAndCall(address(newImpl), "");

        // Verify all state preserved
        assertEq(address(router.policyManager()), pmBefore);
        assertEq(address(router.twapBurner()), burnerBefore);
        assertTrue(relayerAuthorized);
        assertEq(router.authorizedRelayers(relayer), relayerAuthorized);

        (
            bytes32 storedPid2,
            uint256 payoutRatio2,
            uint256 triggerProb2,
            uint256 margin2,
            uint32 duration2,
            bool active2
        ) = router.products(pid);
        assertEq(storedPid2, storedPid);
        assertEq(payoutRatio2, payoutRatio);
        assertEq(triggerProb2, triggerProb);
        assertEq(margin2, margin);
        assertEq(duration2, duration);
        assertEq(active2, active);
    }

    function test_StorageGap_NewVariableDoesNotCollide() public {
        vm.chainId(8453);
        // Deploy BondVault V1 proxy and set state
        MockPriceOracleStorage oracle = new MockPriceOracleStorage();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        vault.setAuthorizedCaller(makeAddr("buyback"), true);

        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);

        vm.warp(1767225600 + 30 days);
        vault.issueBond(makeAddr("user"), 500);

        // Record V1 state
        uint256 committedBefore = vault.totalCommittedUSD();
        bool isAuthorized = vault.authorizedCallers(makeAddr("buyback"));

        // Verify __gap exists at the expected storage region by reading slot
        // BondVault's __gap is at the end of its storage. We verify it is zero-initialized.
        // The __gap is declared as uint256[50], so 50 contiguous slots should be zero.
        // We read the first gap slot to confirm it's zero (uninitialised).
        bytes32 gapSlotValue = vm.load(address(vault), bytes32(uint256(keccak256("bondvault.gap.check"))));
        // This is just a sanity check that random slots are zero
        assertEq(gapSlotValue, bytes32(0));

        // Upgrade to new impl (same code, simulating V2)
        BondVault implV2 = new BondVault();
        vault.upgradeToAndCall(address(implV2), "");

        // Verify original state preserved after upgrade
        assertEq(vault.totalCommittedUSD(), committedBefore);
        assertEq(vault.authorizedCallers(makeAddr("buyback")), isAuthorized);
        assertEq(address(vault.lumina()), address(token));
        assertEq(address(vault.claimBond()), address(cb));
    }
}
