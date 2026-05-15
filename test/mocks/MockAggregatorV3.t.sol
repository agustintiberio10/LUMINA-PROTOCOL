// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockAggregatorV3} from "src/mocks/MockAggregatorV3.sol";

contract MockAggregatorV3Test is Test {
    MockAggregatorV3 internal feed;

    address internal owner = address(this);
    address internal stranger = makeAddr("stranger");

    int256 internal constant INITIAL_PRICE = 60_000 * 1e8; // $60,000 8-dec
    uint8 internal constant DECIMALS = 8;
    string internal constant PAIR = "BTC / USD MOCK";

    function setUp() public {
        vm.chainId(8453);
        // Warp to a non-trivial timestamp so `block.timestamp - 1 days`
        // (used by `setStale(true)`) doesn't underflow.
        vm.warp(1_700_000_000);
        feed = new MockAggregatorV3(INITIAL_PRICE, DECIMALS, PAIR);
    }

    // ─────────────────── constructor + getters ───────────────────

    function test_constructor_setsOwnerToDeployer() public view {
        assertEq(feed.owner(), owner);
    }

    function test_constructor_setsInitialAnswer() public view {
        assertEq(feed.answer(), INITIAL_PRICE);
    }

    function test_decimals_returnsConfigured() public view {
        assertEq(feed.decimals(), DECIMALS);
    }

    function test_description_returnsPair() public view {
        assertEq(feed.description(), PAIR);
    }

    function test_latestRoundData_returnsCurrentPrice() public view {
        (uint80 rid, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        assertEq(rid, 1, "initial roundId");
        assertEq(ans, INITIAL_PRICE);
        assertEq(startedAt, updatedAt, "startedAt == updatedAt");
        assertEq(answeredInRound, 1);
    }

    // ─────────────────── setPrice ───────────────────

    function test_setPrice_updatesAnswerAndBumpsRound() public {
        feed.setPrice(70_000 * 1e8);
        assertEq(feed.answer(), 70_000 * 1e8);
        assertEq(feed.roundId(), 2, "roundId bumped");
    }

    function test_setPrice_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.setPrice(70_000 * 1e8);
    }

    function test_multiplePriceChanges_bumpRoundIdEachTime() public {
        feed.setPrice(70_000 * 1e8);
        feed.setPrice(80_000 * 1e8);
        feed.setPrice(90_000 * 1e8);
        assertEq(feed.answer(), 90_000 * 1e8);
        assertEq(feed.roundId(), 4, "1 (initial) + 3 (setPrice)");
    }

    function test_setPrice_refreshesUpdatedAtWhenNotStale() public {
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        feed.setPrice(70_000 * 1e8);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, t0 + 1 hours);
    }

    // ─────────────────── setStale ───────────────────

    function test_setStale_makesDataOld() public {
        feed.setStale(true);
        assertTrue(feed.stale());
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, block.timestamp - 1 days, "updatedAt -1 day");
    }

    function test_setStale_off_returnsToFresh() public {
        feed.setStale(true);
        feed.setStale(false);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, block.timestamp);
    }

    function test_setStale_priceUnchanged() public {
        feed.setStale(true);
        assertEq(feed.answer(), INITIAL_PRICE, "answer unchanged by stale toggle");
    }

    function test_setStale_setPriceUnderStale_keepsStaleWindow() public {
        feed.setStale(true);
        uint256 staleAt = block.timestamp - 1 days;
        feed.setPrice(70_000 * 1e8);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, staleAt, "stale window preserved across setPrice");
    }

    function test_setStale_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.setStale(true);
    }

    // ─────────────────── setRevert ───────────────────

    function test_setRevert_revertsOnLatestRoundData() public {
        feed.setRevert(true);
        vm.expectRevert(MockAggregatorV3.RevertSimulated.selector);
        feed.latestRoundData();
    }

    function test_setRevert_off_returnsNormally() public {
        feed.setRevert(true);
        feed.setRevert(false);
        (, int256 ans,,,) = feed.latestRoundData();
        assertEq(ans, INITIAL_PRICE);
    }

    function test_setRevert_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.setRevert(true);
    }

    // ─────────────────── setDecimals ───────────────────

    function test_setDecimals_updates() public {
        feed.setDecimals(18);
        assertEq(feed.decimals(), 18);
    }

    function test_setDecimals_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.setDecimals(18);
    }

    // ─────────────────── transferOwnership ───────────────────

    function test_transferOwnership_changesOwner() public {
        feed.transferOwnership(stranger);
        assertEq(feed.owner(), stranger);
    }

    function test_transferOwnership_zeroAddressReverts() public {
        vm.expectRevert("Zero address");
        feed.transferOwnership(address(0));
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(MockAggregatorV3.NotOwner.selector);
        feed.transferOwnership(stranger);
    }
}
