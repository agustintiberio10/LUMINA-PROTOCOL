// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlexAggregator, FlexSequencer} from "./helpers/FlexAggregator.sol";

/// @title F-08 adapter-auth tests (red-team fix)
/// @notice createPolicy / verifyAndCalculate on FlashShieldAdapter must be
///         callable ONLY by the wired PolicyManagerV2 (onlyPolicyManager).
contract F08_AdapterAuth is Test {
    FlashShieldAdapter adapter;
    FlashBTCShield1h shield;
    FlexAggregator oracle;
    FlexSequencer seq;

    address pm = makeAddr("pm");
    address attacker = makeAddr("attacker");
    address holder = makeAddr("holder");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6;
    uint32 constant WINDOW = 3600;

    function setUp() public {
        vm.warp(T0);
        oracle = new FlexAggregator(STRIKE, T0);
        seq = new FlexSequencer();

        FlashShieldAdapter impl = new FlashShieldAdapter();
        // Predict the PROXY address: after this point we deploy `shield`
        // (consumes the current nonce) and THEN the proxy (nonce + 1).
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        shield = new FlashBTCShield1h(predicted, address(oracle), address(seq));
        bytes memory initData = abi.encodeCall(FlashShieldAdapter.initialize, (address(shield), bytes32("P")));
        adapter = FlashShieldAdapter(address(new ERC1967Proxy(address(impl), initData)));
        require(address(adapter) == predicted, "proxy addr mismatch");

        adapter.setPolicyManager(pm);
    }

    function _params() internal view returns (FlashShieldAdapter.LegacyCreatePolicyParams memory p) {
        p.buyer = holder;
        p.coverageAmount = COVERAGE;
        p.durationSeconds = WINDOW;
    }

    /// createPolicy reverts for non-PM callers.
    function test_CreatePolicyOnlyPM() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("ONLY_PM"));
        adapter.createPolicy(_params());

        // PM succeeds.
        vm.prank(pm);
        uint256 pid = adapter.createPolicy(_params());
        assertEq(pid, 1, "PM can create");
    }

    /// verifyAndCalculate reverts for non-PM callers.
    function test_VerifyOnlyPM() public {
        vm.prank(pm);
        uint256 pid = adapter.createPolicy(_params());

        vm.prank(attacker);
        vm.expectRevert(bytes("ONLY_PM"));
        adapter.verifyAndCalculate(pid, "");
    }
}
