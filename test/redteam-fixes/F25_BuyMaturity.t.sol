// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaBondMarketplace} from "../../src/marketplace/LuminaBondMarketplace.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockClaimBond, MockBlacklistUSDC} from "./F14_PullPayment.t.sol";

contract F25_BuyMaturity is Test {
    LuminaBondMarketplace market;
    MockClaimBond claimBond;
    MockBlacklistUSDC usdc;

    address admin = makeAddr("admin");
    address twapBurner = makeAddr("twapBurner");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    uint256 constant EPOCH = 7;
    uint256 constant AMOUNT = 10;
    uint256 constant PRICE = 100e6;

    function setUp() public {
        claimBond = new MockClaimBond();
        usdc = new MockBlacklistUSDC();

        LuminaBondMarketplace impl = new LuminaBondMarketplace();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                LuminaBondMarketplace.initialize.selector, address(claimBond), address(usdc), twapBurner, admin
            )
        );
        market = LuminaBondMarketplace(address(proxy));

        // Maturity 100 days out; list while valid.
        claimBond.setMaturity(EPOCH, block.timestamp + 100 days);
        claimBond.mint(seller, EPOCH, AMOUNT);
        vm.prank(seller);
        market.list(EPOCH, AMOUNT, PRICE);

        uint256 buyerFee = (PRICE * 150) / 10000;
        usdc.mint(buyer, PRICE + buyerFee);
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);
    }

    function test_ExecuteBuyRevertsAfterMaturity() public {
        // Warp past maturity (use absolute time per via_ir warp caveat).
        vm.warp(block.timestamp + 101 days);

        vm.prank(buyer);
        vm.expectRevert(bytes("BOND_MATURED"));
        market.executeBuy(0);
    }

    function test_ExecuteBuySucceedsBeforeMaturity() public {
        vm.warp(block.timestamp + 50 days);
        vm.prank(buyer);
        market.executeBuy(0);
        assertEq(claimBond.balanceOf(buyer, EPOCH), AMOUNT);
    }
}
