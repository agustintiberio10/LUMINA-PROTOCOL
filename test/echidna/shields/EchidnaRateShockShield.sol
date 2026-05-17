// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EchidnaRateShockShield
/// @notice Echidna property suite for RateShockShield (Sprint EE Phase B).
/// @dev Eight invariants over the RATE shield surface. RateShock is structurally
///      distinct from the BSS family:
///        - No signed oracle proofs; trigger reads Aave V3 borrow rate on-chain.
///        - `oracle_confirmation_required` instead asserts that no manipulation
///          pathway is exposed: the only way to flip the trigger is to mutate
///          the bound Aave pool, which is set by owner and read directly.
///        - `stale_oracle_fail_silent` is reinterpreted as: when the Aave pool
///          call reverts (e.g. unknown reserve), settlement reverts without
///          fund movement.
///      1. price_threshold_immutable      -- TRIGGER_RATE frozen at deploy.
///      2. window_immutable               -- MIN_DURATION == MAX_DURATION, frozen.
///      3. payout_bounded                 -- maxPayout == coverage * (BPS - DEDUCTIBLE_BPS) / BPS.
///      4. no_double_trigger_same_policy  -- once finalized, status is sticky.
///      5. trigger_only_in_window         -- PAID_OUT policies were settled in [waitingEndsAt, cleanupAt].
///      6. oracle_confirmation_required   -- only owner-set Aave pool drives trigger; no signature pathway.
///      7. stale_oracle_fail_silent       -- pool revert (unknown asset) does not produce a trigger.
///      8. premium_collected_immutable    -- cp.premiumPaid set at create and never decremented.

import {RateShockShield, IAaveV3Pool} from "../../../src/products/RateShockShield.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// -----------------------------------------------------------------------------
// Mocks
// -----------------------------------------------------------------------------

contract MockOracleRate {
    address public oracleKey;
    uint256 public sequencerDowntime;

    constructor() {
        oracleKey = address(this);
    }

    function getLatestPrice(bytes32) external pure returns (int256) {
        return 1e8; // unused by RateShock
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return sequencerDowntime;
    }

    function setDowntime(uint256 d) external {
        sequencerDowntime = d;
    }

    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return oracleKey;
    }
}

contract MockAavePoolRate {
    uint128 public borrowRate = 5e25; // 5% in RAY, below the 10% trigger
    bool public revertOnRead;
    address public knownAsset;

    function setBorrowRate(uint128 r) external {
        borrowRate = r;
    }

    function setRevertOnRead(bool b) external {
        revertOnRead = b;
    }

    function setKnownAsset(address a) external {
        knownAsset = a;
    }

    function getReserveData(address asset) external view returns (IAaveV3Pool.ReserveData memory data) {
        require(!revertOnRead, "AAVE_DOWN");
        // Mirror the "unknown reserve" path: revert when asset is not our registered USDC.
        if (knownAsset != address(0) && asset != knownAsset) {
            revert("UNKNOWN_RESERVE");
        }
        data.currentVariableBorrowRate = borrowRate;
    }
}

interface IHEVM {
    function warp(uint256) external;
    function prank(address) external;
}

// -----------------------------------------------------------------------------
// Echidna harness
// -----------------------------------------------------------------------------
contract EchidnaRateShockShield {
    IHEVM constant HEVM = IHEVM(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    RateShockShield public shield;
    MockOracleRate public oracle;
    MockAavePoolRate public aave;

    address public constant ROUTER = address(0xa0a0a0a0A0A0A0A0a0A0a0A0A0a0A0a0a0a0a0A0);
    address public constant BUYER1 = address(0xb0B0B0B0b0b0B0b0B0b0b0B0b0B0b0b0B0b0B001);
    address public constant BUYER2 = address(0xB0b0b0B0b0B0b0b0B0b0b0b0b0b0B0b0B0B0B002);
    address public constant USDC = address(0x0000000000000000000000000000000000DC0DC0);
    bytes32 public constant ASSET = bytes32("USDC");

    uint256 internal _ghost_triggerRate;
    uint32 internal _ghost_minDuration;
    uint32 internal _ghost_maxDuration;
    uint256 internal _ghost_deductibleBps;
    uint256 internal _ghost_lastPolicyId;
    address internal _ghost_aavePoolInit;

    mapping(uint256 => uint256) internal _ghost_premium;

    bool internal _inv_oracle_confirmation_required = true;
    bool internal _inv_stale_oracle_fail_silent = true;
    bool internal _inv_no_double_trigger = true;
    bool internal _inv_trigger_only_in_window = true;

    constructor() {
        oracle = new MockOracleRate();
        aave = new MockAavePoolRate();
        aave.setKnownAsset(USDC);

        RateShockShield impl = new RateShockShield();
        bytes memory initData = abi.encodeWithSelector(
            RateShockShield.initialize.selector, ROUTER, address(oracle), address(aave), USDC
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        shield = RateShockShield(address(proxy));

        _ghost_triggerRate = shield.TRIGGER_RATE();
        _ghost_minDuration = shield.MIN_DURATION();
        _ghost_maxDuration = shield.MAX_DURATION();
        _ghost_deductibleBps = shield.DEDUCTIBLE_BPS();
        _ghost_aavePoolInit = address(shield.aavePool());
    }

    // =========================================================================
    //  Mutators
    // =========================================================================

    function e_createPolicy(uint96 coverageRaw, uint96 premiumRaw, bool useBuyer2) external {
        uint256 coverage = uint256(coverageRaw);
        if (coverage < 100e6) coverage = 100e6;
        if (coverage > 1e15) coverage = 1e15;
        uint256 premium = uint256(premiumRaw) % (1e12 + 1);
        address buyer = useBuyer2 ? BUYER2 : BUYER1;

        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: coverage,
            premiumAmount: premium,
            durationSeconds: _ghost_minDuration,
            asset: ASSET,
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });

        HEVM.prank(ROUTER);
        try shield.createPolicy(params) returns (uint256 pid) {
            _ghost_lastPolicyId = pid;
            _ghost_premium[pid] = premium;
        } catch {}
    }

    function e_setBorrowRate(uint128 raw) external {
        // Clamp to [0, 1e27] (0-100% APY in RAY)
        uint128 clamped = raw > uint128(1e27) ? uint128(1e27) : raw;
        aave.setBorrowRate(clamped);
    }

    function e_setAaveRevert(bool b) external {
        aave.setRevertOnRead(b);
    }

    function e_warp(uint256 delta) external {
        uint256 bounded = delta % (30 days);
        HEVM.warp(block.timestamp + bounded);
    }

    /// @dev RateShock ignores oracleProof entirely; we still fuzz this path because
    ///      property #6 must hold regardless of bytes provided.
    function e_verifyAndCalculate(uint256 pidSeed, bytes calldata sig) external {
        uint256 pid = (_ghost_lastPolicyId == 0) ? 0 : (pidSeed % _ghost_lastPolicyId) + 1;
        if (pid == 0) return;

        bool aaveDown = aave.revertOnRead();
        uint256 rateBefore = uint256(aave.borrowRate());

        HEVM.prank(ROUTER);
        try shield.verifyAndCalculate(pid, sig) returns (IShield.PayoutResult memory result) {
            // Property #6: no signature-controlled pathway. The trigger must reflect the
            // on-chain Aave rate; we cannot influence it via `sig`.
            if (result.triggered && rateBefore <= _ghost_triggerRate) {
                _inv_oracle_confirmation_required = false;
            }
            // Property #7: when Aave reverts, we must NOT have produced a triggered payout.
            if (aaveDown && result.triggered) _inv_stale_oracle_fail_silent = false;
            // Property #5: triggered settlement only inside the active coverage window.
            //              RateShock uses live block.timestamp (no off-chain proof).
            if (result.triggered) {
                try shield.getPolicyInfo(pid) returns (IShield.PolicyInfo memory info) {
                    if (block.timestamp < info.waitingEndsAt || block.timestamp > info.expiresAt) {
                        _inv_trigger_only_in_window = false;
                    }
                } catch {}
            }
        } catch {
            // Revert is acceptable for both bad-window and aave-down paths.
        }
    }

    function e_markPaidOut(uint256 pidSeed) external {
        uint256 pid = (_ghost_lastPolicyId == 0) ? 0 : (pidSeed % _ghost_lastPolicyId) + 1;
        if (pid == 0) return;

        HEVM.prank(ROUTER);
        try shield.markPaidOut(pid) {
            HEVM.prank(ROUTER);
            try shield.markPaidOut(pid) {
                _inv_no_double_trigger = false;
            } catch {}
        } catch {}
    }

    function e_markExpired(uint256 pidSeed) external {
        uint256 pid = (_ghost_lastPolicyId == 0) ? 0 : (pidSeed % _ghost_lastPolicyId) + 1;
        if (pid == 0) return;

        HEVM.prank(ROUTER);
        try shield.markExpired(pid) {
            HEVM.prank(ROUTER);
            try shield.markExpired(pid) {
                _inv_no_double_trigger = false;
            } catch {}
        } catch {}
    }

    // =========================================================================
    //  Properties
    // =========================================================================

    /// @notice 1. TRIGGER_RATE is `constant` -- must match ghost snapshot forever.
    function echidna_price_threshold_immutable() public view returns (bool) {
        return shield.TRIGGER_RATE() == _ghost_triggerRate;
    }

    /// @notice 2. Duration window is fixed (MIN == MAX) and unchanged.
    function echidna_window_immutable() public view returns (bool) {
        (uint32 minD, uint32 maxD) = shield.durationRange();
        return minD == maxD && minD == _ghost_minDuration && maxD == _ghost_maxDuration;
    }

    /// @notice 3. For every policy created, maxPayout = coverage * (BPS - DEDUCTIBLE_BPS) / BPS.
    function echidna_payout_bounded() public view returns (bool) {
        if (_ghost_lastPolicyId == 0) return true;
        for (uint256 i = 1; i <= _ghost_lastPolicyId; i++) {
            try shield.getPolicyInfo(i) returns (IShield.PolicyInfo memory info) {
                uint256 expected = (info.coverageAmount * (10_000 - _ghost_deductibleBps)) / 10_000;
                if (info.maxPayout != expected) return false;
            } catch {}
        }
        return true;
    }

    /// @notice 4. Idempotent finalization: a second mark on the same policy reverts.
    function echidna_no_double_trigger_same_policy() public view returns (bool) {
        return _inv_no_double_trigger;
    }

    /// @notice 5. Every successful triggered settlement happened inside [waitingEndsAt, expiresAt].
    function echidna_trigger_only_in_window() public view returns (bool) {
        return _inv_trigger_only_in_window;
    }

    /// @notice 6. Trigger only follows on-chain Aave reads; no proof bytes can flip it
    ///         while the current rate is at or below TRIGGER_RATE.
    function echidna_oracle_confirmation_required() public view returns (bool) {
        return _inv_oracle_confirmation_required;
    }

    /// @notice 7. When Aave reverts (stale/unknown-reserve analogue), no payout triggers.
    function echidna_stale_oracle_fail_silent() public view returns (bool) {
        return _inv_stale_oracle_fail_silent;
    }

    /// @notice 8. premiumPaid is set at createPolicy and never decremented.
    function echidna_premium_collected_immutable() public view returns (bool) {
        if (_ghost_lastPolicyId == 0) return true;
        for (uint256 i = 1; i <= _ghost_lastPolicyId; i++) {
            try shield.getPolicyInfo(i) returns (IShield.PolicyInfo memory info) {
                if (info.premiumPaid != _ghost_premium[i]) return false;
            } catch {}
        }
        return true;
    }
}
