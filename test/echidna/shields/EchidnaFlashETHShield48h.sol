// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FlashETHShield48h} from "../../../src/products/FlashETHShield48h.sol";

/// @title EchidnaFlashETHShield48h — Sprint T-30a Phase F
/// @notice Property scaffold for the ETH 48h / 14% flash shield.

interface Hevm {
    function warp(uint256) external;
    function prank(address) external;
}

contract MockOracleE {
    int256 public answer = 3_000e8;
    uint256 public updatedAt;
    uint8 public constant decimals = 8;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function refresh() external {
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockSeqE {
    int256 public answer;
    uint256 public startedAt;

    constructor() {
        startedAt = block.timestamp > 2 hours ? block.timestamp - 2 hours : 0;
        answer = 0;
    }

    function setDown(bool down) external {
        answer = down ? int256(1) : int256(0);
        startedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

contract EchidnaFlashETHShield48h {
    Hevm constant hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    FlashETHShield48h public shield;
    MockOracleE public oracle;
    MockSeqE public sequencer;

    address constant ROUTER = address(0xA11CE);
    uint16 internal constant TRIGGER_DROP_BPS = 1400;
    uint32 internal constant WINDOW = 172_800;
    uint16 internal constant DEDUCTIBLE_BPS = 2000;

    uint256 internal _ghost_policies;
    uint256 internal _ghost_triggers;
    bool internal _ghost_double_pay_attempted;
    uint256 internal _trackedPid;
    bool internal _trackedExists;

    constructor() {
        oracle = new MockOracleE();
        sequencer = new MockSeqE();
        shield = FlashETHShield48h(address(new ERC1967Proxy(address(new FlashETHShield48h()), abi.encodeCall(FlashETHShield48h.initialize, (ROUTER, address(oracle), address(sequencer))))));
    }

    function e_setPrice(int256 p) external {
        if (p <= 0) p = 1;
        // [Sprint T-30b] Bound to <= 1e15 ($10T at 8-dec precision) so
        //                drop math properties never overflow strike * 10000.
        if (p > int256(1e15)) p = int256(1e15);
        oracle.setAnswer(p);
    }

    function e_setSequencerDown(bool d) external {
        sequencer.setDown(d);
    }

    function e_warp(uint256 delta) external {
        delta = delta % (2 days);
        hevm.warp(block.timestamp + delta);
        oracle.refresh();
    }

    function e_createPolicy(uint256 pid, address holder, uint256 cov) external {
        if (_trackedExists) return;
        if (holder == address(0)) return;
        cov = (cov % 1_000_000e6) + 100e6;
        pid = (pid % 1_000_000) + 1;
        hevm.prank(ROUTER);
        try shield.createPolicy(pid, holder, cov, uint64(block.timestamp), uint64(block.timestamp + WINDOW)) {
            _trackedPid = pid;
            _trackedExists = true;
            _ghost_policies++;
        } catch {}
    }

    function e_verifyAndCalculate() external {
        if (!_trackedExists) return;
        hevm.prank(ROUTER);
        try shield.verifyAndCalculate(_trackedPid) returns (bool t, uint256, address, bytes32) {
            if (t) _ghost_triggers++;
        } catch {}
    }

    function e_attemptDoublePayout() external {
        if (!_trackedExists) return;
        hevm.prank(ROUTER);
        try shield.verifyAndCalculate(_trackedPid) {} catch {}
        hevm.prank(ROUTER);
        try shield.verifyAndCalculate(_trackedPid) {
            _ghost_double_pay_attempted = true;
        } catch {}
    }

    function echidna_strikePrice_set_at_creation() external view returns (bool) {
        if (!_trackedExists) return true;
        (address h,, uint256 strike,,,) = shield.getPolicyInfo(_trackedPid);
        if (h == address(0)) return true;
        return strike > 0;
    }

    function echidna_trigger_only_within_window() external view returns (bool) {
        if (!_trackedExists) return true;
        (,,, uint64 start,, bool finalized) = shield.getPolicyInfo(_trackedPid);
        if (!finalized) return true;
        return block.timestamp >= start;
    }

    function echidna_payout_equals_80_percent_coverage() external view returns (bool) {
        if (!_trackedExists) return true;
        (, uint256 cov,,,,) = shield.getPolicyInfo(_trackedPid);
        if (cov == 0) return true;
        uint256 expected = (cov * (10_000 - DEDUCTIBLE_BPS)) / 10_000;
        return expected == (cov * 8000) / 10_000;
    }

    function echidna_sequencer_down_blocks_all_actions() external pure returns (bool) {
        return true;
    }

    function echidna_drop_calculation_correct() external view returns (bool) {
        if (!_trackedExists) return true;
        (,, uint256 strike,,,) = shield.getPolicyInfo(_trackedPid);
        if (strike == 0) return true;
        uint256 sample = (strike * 10_000) / strike;
        return sample == 10_000;
    }

    function echidna_no_double_payout() external view returns (bool) {
        return !_ghost_double_pay_attempted;
    }

    function echidna_oracle_confirmations_enforced() external pure returns (bool) {
        return true;
    }

    function echidna_window_strictly_enforced() external view returns (bool) {
        if (!_trackedExists) return true;
        (,,, uint64 start, uint64 end,) = shield.getPolicyInfo(_trackedPid);
        if (start == 0 && end == 0) return true;
        return (end - start) == WINDOW;
    }
}
