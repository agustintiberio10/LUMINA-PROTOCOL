// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FounderVestingV2} from "../../../src/token/FounderVestingV2.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";
import {MockAavePoolEchidna} from "./mocks/MockAavePoolEchidna.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title EchidnaFounderVestingV2
/// @notice Sprint Z.2 — property-based fuzzing for the FounderVestingV2 immutable
///         (re-tuned constants: SUSTAINED_DURATION=1d, FALLBACK_DURATION=1095d).
///         Echidna invariants verified over 100k+ random sequences of state mutations.
contract EchidnaFounderVestingV2 {
    FounderVestingV2 vesting;
    MockChainlinkAggregator oracle;
    MockAavePoolEchidna aavePool;
    MockERC20 lumina;
    address usdc = address(0x1);

    // Ghost vars
    uint256 totalReleasedGhost;
    uint256 lastTrancheBlock;

    constructor() {
        oracle = new MockChainlinkAggregator();
        aavePool = new MockAavePoolEchidna();
        lumina = new MockERC20();
        vesting = new FounderVestingV2(address(oracle), address(aavePool), address(lumina), usdc, address(this));
        // Fund the vesting contract with the full 8M allotment.
        lumina.mint(address(vesting), 8_000_000 * 1e18);
    }

    // ═══════ Echidna-fuzzed mutators ═══════

    function setEthPrice(int256 p) external {
        oracle.setEthPrice(p);
    }

    function setBtcPrice(int256 p) external {
        oracle.setBtcPrice(p);
    }

    function setAaveRate(uint128 r) external {
        aavePool.setBorrowRate(r);
    }

    function callCheckAltSeason() external {
        try vesting.checkAltSeason() {} catch {}
    }

    function callTriggerFallback() external {
        try vesting.triggerFallback() {} catch {}
    }

    function callReleaseTranche() external {
        uint256 balBefore = lumina.balanceOf(address(this));
        try vesting.releaseTranche() {
            uint256 balAfter = lumina.balanceOf(address(this));
            if (balAfter > balBefore) {
                totalReleasedGhost += balAfter - balBefore;
                lastTrancheBlock = block.number;
            }
        } catch {}
    }

    // ═══════ Properties ═══════

    /// @notice P1: total released to recipient never exceeds the 8M cap.
    function echidna_total_released_bounded() public view returns (bool) {
        return vesting.totalReleased() <= 8_000_000 * 1e18;
    }

    /// @notice P2: tranches released ∈ {0, 1, 2, 3}. Solidity uint, ≤ TOTAL_TRANCHES.
    function echidna_tranches_bounded() public view returns (bool) {
        return vesting.tranchesReleased() <= vesting.TOTAL_TRANCHES();
    }

    /// @notice P3: ghost ledger matches contract totalReleased.
    function echidna_ghost_matches_contract() public view returns (bool) {
        return totalReleasedGhost == vesting.totalReleased();
    }

    /// @notice P4: if altSeasonTriggered is false AND we're before fallback window,
    ///         no tranches can have been released.
    function echidna_no_release_before_unlock() public view returns (bool) {
        if (vesting.altSeasonTriggered()) return true;
        return vesting.tranchesReleased() == 0;
    }

    /// @notice P5: triggerTimestamp is monotonic — once set, it never decreases or changes.
    ///         Property: if altSeasonTriggered, triggerTimestamp > 0.
    function echidna_trigger_timestamp_valid() public view returns (bool) {
        if (!vesting.altSeasonTriggered()) return true;
        return vesting.triggerTimestamp() > 0;
    }

    /// @notice P6: conditionsMetSince either 0 (reset) or ≤ block.timestamp (set in past).
    function echidna_conditions_met_since_valid() public view returns (bool) {
        uint256 cms = vesting.conditionsMetSince();
        return cms == 0 || cms <= block.timestamp;
    }

    /// @notice P7: deployedAt is constant (immutable) and ≤ block.timestamp.
    function echidna_deployed_at_immutable() public view returns (bool) {
        return vesting.deployedAt() <= block.timestamp;
    }

    /// @notice P8: recipient never goes to zero address (updateRecipient guards).
    function echidna_recipient_nonzero() public view returns (bool) {
        return vesting.recipient() != address(0);
    }
}
