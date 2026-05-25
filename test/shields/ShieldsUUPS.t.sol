// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {BaseFlashShield} from "../../src/shields/BaseFlashShield.sol";

/// @title ShieldsUUPS — Sprint Shields-UUPS verification
/// @notice Verifies the UUPS-converted flash shields: F-01 multi-block
///         confirmation + dwell are enforced, verify is router-gated, the proxy
///         is owner-upgradeable, and storage survives an upgrade.

contract SUMockAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint8 public constant decimals = 8;

    constructor(int256 _a, uint256 _u) {
        answer = _a;
        updatedAt = _u;
    }

    function setAnswer(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
        roundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

/// @notice Trivial upgrade target to prove UUPS upgradeability + storage layout.
contract FlashBTCShield1hV2 is FlashBTCShield1h {
    function shieldVersion() external pure returns (string memory) {
        return "V2";
    }
}

contract ShieldsUUPSTest is Test {
    FlashBTCShield1h shield;
    SUMockAggregator oracle;

    address router = address(this); // this contract acts as the router (CoverRouter/adapter)
    address holder = makeAddr("holder");
    address attacker = makeAddr("attacker");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6;
    uint32 constant WINDOW = 3600;
    uint16 constant TRIGGER_DROP_BPS = 250; // 2.5%

    function setUp() public {
        vm.warp(T0);
        oracle = new SUMockAggregator(STRIKE, T0);
        // Deploy shield as a UUPS proxy, initialized atomically (F-05 pattern).
        FlashBTCShield1h impl = new FlashBTCShield1h();
        bytes memory init = abi.encodeCall(FlashBTCShield1h.initialize, (router, address(oracle), address(0)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        shield = FlashBTCShield1h(address(proxy));
    }

    function _create(uint256 id) internal {
        shield.createPolicy(id, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    // ── F-01: trigger requires 3 spaced multi-block confirmations ──
    function test_MultiBlockConfirmationEnforced() public {
        _create(1);
        int256 dropped = (STRIKE * int256(uint256(10_000 - TRIGGER_DROP_BPS))) / 10_000;
        vm.warp(T0 + 5 minutes + 1); // past dwell

        // 1st observation: accrues, does NOT trigger.
        oracle.setAnswer(dropped, block.timestamp);
        (bool t1,,,) = shield.verifyAndCalculate(1);
        assertFalse(t1, "1st obs must not trigger");

        // Same-block / too-soon retry must revert (spacing enforced).
        oracle.setAnswer(dropped, block.timestamp);
        vm.expectRevert(bytes("SAME_BLOCK_OBSERVATION"));
        shield.verifyAndCalculate(1);

        // 2nd observation in a later block, >=60s later.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);
        oracle.setAnswer(dropped, block.timestamp);
        (bool t2,,,) = shield.verifyAndCalculate(1);
        assertFalse(t2, "2nd obs must not trigger");

        // 3rd observation → trigger.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);
        oracle.setAnswer(dropped, block.timestamp);
        (bool t3, uint256 payout,,) = shield.verifyAndCalculate(1);
        assertTrue(t3, "3rd confirmation triggers");
        assertEq(payout, (COVERAGE * 8000) / 10_000, "payout 80%");
    }

    // ── verify is router-gated (only the wired router/adapter may call) ──
    function test_SettleOnlyRouter() public {
        _create(2);
        vm.warp(T0 + 5 minutes + 1);
        oracle.setAnswer(STRIKE, block.timestamp);
        vm.prank(attacker);
        vm.expectRevert(bytes("NOT_ROUTER"));
        shield.verifyAndCalculate(2);
    }

    // ── F-01: dwell enforced (no trigger before start + 5min) ──
    function test_MinDwellEnforced() public {
        _create(3);
        int256 dropped = (STRIKE * int256(uint256(10_000 - TRIGGER_DROP_BPS))) / 10_000;
        oracle.setAnswer(dropped, T0 + 60);
        vm.warp(T0 + 60); // before dwell (5 min)
        vm.expectRevert(bytes("DWELL_NOT_ELAPSED"));
        shield.verifyAndCalculate(3);
    }

    // ── UUPS: only owner can upgrade ──
    function test_UUPSUpgradeableByOwner() public {
        FlashBTCShield1hV2 v2 = new FlashBTCShield1hV2();

        // Non-owner cannot upgrade.
        vm.prank(attacker);
        vm.expectRevert();
        shield.upgradeToAndCall(address(v2), "");

        // Owner (this contract — initialize set owner = msg.sender = this) can.
        shield.upgradeToAndCall(address(v2), "");
        assertEq(FlashBTCShield1hV2(address(shield)).shieldVersion(), "V2", "upgrade applied");
    }

    // ── Storage survives an upgrade ──
    function test_StorageLayoutCompatible() public {
        _create(4);
        (address h,, uint256 strike,,,) = shield.getPolicyInfo(4);
        assertEq(h, holder);
        assertEq(strike, uint256(STRIKE));

        FlashBTCShield1hV2 v2 = new FlashBTCShield1hV2();
        shield.upgradeToAndCall(address(v2), "");

        // Same policy + wiring readable post-upgrade.
        (address h2,, uint256 strike2,,,) = shield.getPolicyInfo(4);
        assertEq(h2, holder, "policy holder preserved");
        assertEq(strike2, uint256(STRIKE), "strike preserved");
        assertEq(shield.router(), router, "router preserved");
        assertEq(address(shield.priceFeed()), address(oracle), "priceFeed preserved");
    }
}
