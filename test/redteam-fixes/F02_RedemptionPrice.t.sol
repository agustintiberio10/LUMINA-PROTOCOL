// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

/// @notice Mock price oracle that can return a healthy price, zero, or revert.
contract MockToggleOracle {
    uint256 public price;
    bool public doRevert;

    constructor(uint256 p) {
        price = p;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function setRevert(bool r) external {
        doRevert = r;
    }

    function getLuminaPrice() external view returns (uint256) {
        require(!doRevert, "oracle down");
        return price;
    }
}

/// @title F-02 — redemption price floor + fail-closed semantics.
contract F02_RedemptionPriceTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockToggleOracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);

        oracle = new MockToggleOracle(0.036e18);

        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(claimBondProxy));

        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, makeAddr("tempVault"), makeAddr("cex"), founder, lbp, treasury
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        BondVault vaultImpl = new BondVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(this)
            )
        );
        vault = BondVault(address(vaultProxy));

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);
    }

    function _issueAndMature(address to, uint256 usd) internal returns (uint256 epoch) {
        vault.issueBond(to, usd);
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        epoch = (2026 + monthsFromBase / 12) * 100 + (1 + monthsFromBase % 12);
        vm.warp(claimBond.maturityDate(epoch) + 1);
    }

    /// Floor constant must be raised to 0.005e18.
    function test_FloorRaisedTo005() public view {
        assertEq(vault.MIN_REDEEM_PRICE(), 0.005e18, "floor not raised to 0.005e18");
    }

    /// Oracle revert OR zero must fail closed (revert), not floor-and-redeem.
    function test_RedeemRevertsWhenOracleUnavailable() public {
        uint256 epoch = _issueAndMature(user, 1_000);

        // (a) Oracle reverts.
        oracle.setRevert(true);
        vm.prank(user);
        vm.expectRevert(BondVault.ORACLE_UNAVAILABLE.selector);
        vault.redeemBond(epoch, 1_000);

        // (b) Oracle returns zero.
        oracle.setRevert(false);
        oracle.setPrice(0);
        vm.prank(user);
        vm.expectRevert(BondVault.ORACLE_UNAVAILABLE.selector);
        vault.redeemBond(epoch, 1_000);
    }

    /// A price exactly at the floor must NOT be a settleable value (strict >).
    function test_CannotRedeemAtFloor() public {
        uint256 epoch = _issueAndMature(user, 1_000);

        // Price pinned exactly at the floor → must revert (fail closed, since
        // p <= MIN_REDEEM_PRICE triggers ORACLE_UNAVAILABLE).
        oracle.setPrice(vault.MIN_REDEEM_PRICE());
        vm.prank(user);
        vm.expectRevert(BondVault.ORACLE_UNAVAILABLE.selector);
        vault.redeemBond(epoch, 1_000);

        // Just below the floor → also revert.
        oracle.setPrice(vault.MIN_REDEEM_PRICE() - 1);
        vm.prank(user);
        vm.expectRevert(BondVault.ORACLE_UNAVAILABLE.selector);
        vault.redeemBond(epoch, 1_000);

        // A healthy price comfortably above the floor → succeeds (sanity that
        // the gate is at the floor, and that a normal price settles). We use a
        // small $10 amount to stay under the F-10 per-user epoch cap.
        oracle.setPrice(0.036e18);
        uint256 balBefore = token.balanceOf(user);
        vm.prank(user);
        vault.redeemBond(epoch, 10);
        assertGt(token.balanceOf(user), balBefore, "above-floor redemption should pay out");
    }
}
