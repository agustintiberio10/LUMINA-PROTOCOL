// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

/// @notice Sprint Fix Audit Economic — Phase A (R2 verification).
/// @dev    Audit Economic V1 flagged R2 (CRITICAL) on uncertainty about
///         redeem semantics: would `redeemBond()` `transfer`, `burn`, or
///         `mint` LUMINA to the holder? Static analysis on line 313 of
///         BondVault.sol already showed `lumina.transfer(msg.sender, ...)` —
///         these tests are evidence that the live behavior matches the static
///         claim. R2 status: VERIFIED — no bug, semantics correct.
contract MockOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract BondVaultRedeemSemanticsTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockOracle oracle;

    address founder = makeAddr("founder");
    address lbp = makeAddr("lbp");
    address treasury = makeAddr("treasury");
    address user = address(0xBEEF);

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days); // past ClaimBond BASE_TIMESTAMP

        oracle = new MockOracle();

        ClaimBond cbImpl = new ClaimBond();
        ERC1967Proxy cbProxy = new ERC1967Proxy(address(cbImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(cbProxy));

        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, makeAddr("tmpVault"), makeAddr("cex"), founder, lbp, treasury
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        BondVault vImpl = new BondVault();
        ERC1967Proxy vProxy = new ERC1967Proxy(
            address(vImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(this)
            )
        );
        vault = BondVault(address(vProxy));

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);

        // Sepolia-style fast maturity so we can warp + redeem within the test.
        vault.setBondMaturitySeconds(60);
    }

    /// @dev Issue + warp to mature + return (epochId, usdAmount).
    function _setupMatureBond(address holder, uint256 usdAmount) internal returns (uint256 epochId) {
        vault.issueBond(holder, usdAmount);
        // The minted epochId is current-time + 60s converted to YYYYMM.
        epochId = _timestampToEpoch(block.timestamp + 60);
        vm.warp(block.timestamp + 61);
    }

    function _timestampToEpoch(uint256 ts) internal pure returns (uint256) {
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (ts - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }

    // ─── R2 evidence tests ───

    function test_RedeemTransfersCorrectAmountToUser() public {
        uint256 epochId = _setupMatureBond(user, 800);
        uint256 currentPrice = oracle.price();
        uint256 expectedLumina = (800 * 1e36) / currentPrice;

        uint256 userBefore = token.balanceOf(user);
        uint256 vaultBefore = token.balanceOf(address(vault));

        vm.prank(user);
        vault.redeemBond(epochId, 800);

        uint256 userAfter = token.balanceOf(user);
        uint256 vaultAfter = token.balanceOf(address(vault));

        assertGt(userAfter, userBefore, "User did not receive LUMINA");
        assertEq(userAfter - userBefore, expectedLumina, "Wrong LUMINA amount paid");
        assertEq(
            userAfter - userBefore, vaultBefore - vaultAfter, "Vault decrease != user increase (TRANSFER semantics)"
        );
        assertEq(claimBond.balanceOf(user, epochId), 0, "Bond not burned from holder");
    }

    function test_RedeemDoesNotBurnLumina() public {
        uint256 epochId = _setupMatureBond(user, 800);

        uint256 totalSupplyBefore = token.totalSupply();

        vm.prank(user);
        vault.redeemBond(epochId, 800);

        uint256 totalSupplyAfter = token.totalSupply();

        // CRITICAL invariant: total supply must NOT change in redeem (transfer-only).
        assertEq(totalSupplyBefore, totalSupplyAfter, "LUMINA was burned in redeem - should only transfer");
    }

    function test_RedeemDoesNotMintLumina() public {
        uint256 epochId = _setupMatureBond(user, 800);

        uint256 totalSupplyBefore = token.totalSupply();

        vm.prank(user);
        vault.redeemBond(epochId, 800);

        uint256 totalSupplyAfter = token.totalSupply();

        assertEq(totalSupplyAfter, totalSupplyBefore, "LUMINA was minted in redeem - should only transfer");
    }
}
