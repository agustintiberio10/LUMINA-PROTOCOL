// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PolicyManagerV2, IShieldV2} from "../../src/core/PolicyManagerV2.sol";

contract F03MockBondVault {
    uint256 public cap = 1_000_000;
    uint256 public totalReserved;
    uint256 public released;

    function availableCapacityUSD() external view returns (uint256) {
        uint256 reservedDollars = totalReserved / 1e18;
        if (cap <= reservedDollars) return 0;
        return cap - reservedDollars;
    }

    function issueBond(address, uint256) external {}

    function reserveCapacity(uint256 amount) external {
        totalReserved += amount;
    }

    function releaseReservation(uint256 amount) external {
        totalReserved -= amount;
        released += amount;
    }

    function commitReservation(uint256 amount) external {
        totalReserved -= amount;
    }
}

/// Mock shield speaking PolicyManagerV2's IShieldV2 surface.
contract F03MockShield {
    enum Mode {
        NoTrigger,
        Triggered,
        OracleUnavailable,
        OtherRevert,
        CustomError
    }

    Mode public mode;
    uint256 public nextId = 1;

    error SomeCustomError();

    function setMode(Mode m) external {
        mode = m;
    }

    function productId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function createPolicy(IShieldV2.CreatePolicyParams calldata) external returns (uint256) {
        return nextId++;
    }

    function getPolicyInfo(uint256) external pure returns (address, uint256, uint256, uint256, uint256, uint8) {
        return (address(0), 0, 0, 0, 0, 0);
    }

    function verifyAndCalculate(uint256, bytes calldata) external view returns (IShieldV2.PayoutResult memory r) {
        if (mode == Mode.OracleUnavailable) revert("ORACLE_UNAVAILABLE");
        if (mode == Mode.OtherRevert) revert("SOME_OTHER_REASON");
        if (mode == Mode.CustomError) revert SomeCustomError();
        if (mode == Mode.Triggered) {
            return IShieldV2.PayoutResult({triggered: true, payoutAmount: 1, recipient: address(1), reason: "X"});
        }
        return IShieldV2.PayoutResult({triggered: false, payoutAmount: 0, recipient: address(0), reason: "NONE"});
    }
}

/// @notice F-03: markExpired must NOT finalize-untriggered when a fresh shield
///         evaluation reverts oracle-unavailable.
contract F03MarkExpiredOracleGateTest is Test {
    PolicyManagerV2 internal pm;
    F03MockBondVault internal vault;
    F03MockShield internal shield;

    bytes32 internal constant PID = keccak256("FLASH-1");
    address internal constant BUYER = address(0xB1);

    function setUp() public {
        vm.chainId(8453);
        vault = new F03MockBondVault();
        shield = new F03MockShield();

        PolicyManagerV2 impl = new PolicyManagerV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(PolicyManagerV2.initialize.selector, address(vault))
        );
        pm = PolicyManagerV2(address(proxy));
        pm.setRouter(address(this));
        pm.registerProduct(PID, address(shield));
    }

    function _newPolicy() internal returns (uint256 policyId) {
        // 1000 USDC coverage, 1h duration.
        policyId = pm.recordPolicy(PID, BUYER, 1000e6, 2e6, 3600, "BTC");
    }

    function test_MarkExpiredRevertsWhenOracleUnavailable() external {
        uint256 id = _newPolicy();
        vm.warp(block.timestamp + 3601); // past expiry

        shield.setMode(F03MockShield.Mode.OracleUnavailable);
        vm.expectRevert(abi.encodeWithSelector(PolicyManagerV2.OracleUnavailableRetry.selector, PID, id));
        pm.markExpired(PID, id);

        // Policy stays pending (not expired), reservation still held.
        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(PID, id);
        assertFalse(rec.expired, "policy must stay pending");
        assertEq(vault.released(), 0, "no reservation released");
    }

    function test_MarkExpiredSucceedsWhenOracleEvaluableNoTrigger() external {
        uint256 id = _newPolicy();
        vm.warp(block.timestamp + 3601);

        shield.setMode(F03MockShield.Mode.NoTrigger);
        pm.markExpired(PID, id);

        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(PID, id);
        assertTrue(rec.expired, "policy expired after clean no-trigger eval");
        assertGt(vault.released(), 0, "reservation released");
    }

    function test_MarkExpiredRevertsWhenTriggerable() external {
        uint256 id = _newPolicy();
        vm.warp(block.timestamp + 3601);

        shield.setMode(F03MockShield.Mode.Triggered);
        vm.expectRevert(abi.encodeWithSelector(PolicyManagerV2.PolicyTriggerable.selector, PID, id));
        pm.markExpired(PID, id);

        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(PID, id);
        assertFalse(rec.expired, "must not expire a triggerable policy");
    }

    function test_MarkExpiredCustomErrorLeavesPending() external {
        uint256 id = _newPolicy();
        vm.warp(block.timestamp + 3601);

        shield.setMode(F03MockShield.Mode.CustomError);
        vm.expectRevert(abi.encodeWithSelector(PolicyManagerV2.OracleUnavailableRetry.selector, PID, id));
        pm.markExpired(PID, id);
    }

    function test_MarkExpiredOtherStringRevertBubbles() external {
        uint256 id = _newPolicy();
        vm.warp(block.timestamp + 3601);

        shield.setMode(F03MockShield.Mode.OtherRevert);
        vm.expectRevert(bytes("SOME_OTHER_REASON"));
        pm.markExpired(PID, id);
    }

    function test_MarkExpiredStillRequiresWindowElapsed() external {
        uint256 id = _newPolicy();
        shield.setMode(F03MockShield.Mode.NoTrigger);
        vm.expectRevert(bytes("Not expired yet"));
        pm.markExpired(PID, id);
    }
}
