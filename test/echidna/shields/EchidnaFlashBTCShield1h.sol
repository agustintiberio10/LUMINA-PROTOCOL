// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EchidnaFlashBTCShield1h
/// @notice Echidna property suite for FlashBTCShield1h (Sprint EE Phase B).
/// @dev Eight invariants over the BSS shield surface:
///      1. price_threshold_immutable      -- TRIGGER_DROP_BPS frozen at deploy.
///      2. window_immutable               -- MIN_DURATION == MAX_DURATION, frozen.
///      3. payout_bounded                 -- maxPayout == coverage * (BPS - DEDUCTIBLE_BPS) / BPS.
///      4. no_double_trigger_same_policy  -- once finalized, status is sticky.
///      5. trigger_only_in_window         -- PAID_OUT policies were settled in [waitingEndsAt, cleanupAt].
///      6. oracle_confirmation_required   -- bad signatures never produce a TRIGGERED outcome.
///      7. stale_oracle_fail_silent       -- proofs older than MAX_PROOF_AGE never trigger payout.
///      8. premium_collected_immutable    -- cp.premiumPaid set at create and never decremented.

import {FlashBTCShield1h} from "../../../src/products/FlashBTCShield1h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// -----------------------------------------------------------------------------
// Inline mocks (no forge/Test cheats imported)
// -----------------------------------------------------------------------------

contract MockOracleShield {
    int256 public priceBTC = 60_000 * 1e8;
    int256 public priceETH = 3_000 * 1e8;
    address public oracleKey;
    uint256 public sequencerDowntime;

    constructor() {
        oracleKey = address(this);
    }

    function setPrice(bytes32 asset, int256 p) external {
        if (asset == bytes32("BTC")) priceBTC = p;
        else if (asset == bytes32("ETH")) priceETH = p;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (asset == bytes32("BTC")) return priceBTC;
        if (asset == bytes32("ETH")) return priceETH;
        return 0;
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return sequencerDowntime;
    }

    function setDowntime(uint256 d) external {
        sequencerDowntime = d;
    }

    // V1 ECDSA verifier (unused in V2 shields, but satisfies interface)
    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return oracleKey;
    }

    /// @notice V2 EIP-712 proof verifier. Accepts ONLY when signature == bytes("VALID_SIG"),
    ///         enabling Echidna to fuzz the rejection path with any other input.
    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata signature)
        external
        view
        returns (address)
    {
        if (signature.length == 9 && keccak256(signature) == keccak256(bytes("VALID_SIG"))) {
            return oracleKey;
        }
        return address(0);
    }

    function verifyExploitGovProofEIP712(int256, int256, bytes32, uint256, bytes calldata)
        external
        pure
        returns (address)
    {
        return address(0);
    }

    function priceProofDigest(int256, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exploitReceiptProofDigest(bool, bool, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(0);
    }
}

interface IHEVM {
    function warp(uint256) external;
    function prank(address) external;
}

// -----------------------------------------------------------------------------
// Echidna harness
// -----------------------------------------------------------------------------
contract EchidnaFlashBTCShield1h {
    IHEVM constant HEVM = IHEVM(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    FlashBTCShield1h public shield;
    MockOracleShield public oracle;

    address public constant ROUTER = address(0xa0a0a0a0A0A0A0A0a0A0a0A0A0a0A0a0a0a0a0A0);
    address public constant BUYER1 = address(0xb0B0B0B0b0b0B0b0B0b0b0B0b0B0b0b0B0b0B001);
    address public constant BUYER2 = address(0xB0b0b0B0b0B0b0b0B0b0b0b0b0b0B0b0B0B0B002);
    bytes32 public constant ASSET = bytes32("BTC");

    // --- Ghost state ---
    uint256 internal _ghost_triggerDropBps;
    uint32 internal _ghost_minDuration;
    uint32 internal _ghost_maxDuration;
    uint256 internal _ghost_deductibleBps;
    uint256 internal _ghost_lastPolicyId;

    // policyId -> premium recorded at creation
    mapping(uint256 => uint256) internal _ghost_premium;

    // Invariant flags
    bool internal _inv_oracle_confirmation_required = true;
    bool internal _inv_stale_oracle_fail_silent = true;
    bool internal _inv_no_double_trigger = true;
    bool internal _inv_trigger_only_in_window = true;

    constructor() {
        oracle = new MockOracleShield();
        FlashBTCShield1h impl = new FlashBTCShield1h();
        bytes memory initData = abi.encodeWithSelector(FlashBTCShield1h.initialize.selector, ROUTER, address(oracle));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        shield = FlashBTCShield1h(address(proxy));

        _ghost_triggerDropBps = shield.TRIGGER_DROP_BPS();
        _ghost_minDuration = shield.MIN_DURATION();
        _ghost_maxDuration = shield.MAX_DURATION();
        _ghost_deductibleBps = shield.DEDUCTIBLE_BPS();
    }

    // =========================================================================
    //  Mutators
    // =========================================================================

    function e_createPolicy(uint96 coverageRaw, uint96 premiumRaw, bool useBuyer2) external {
        // Clamp coverage to [100e6, 1e15] (1e9 USDC)
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

    function e_setOraclePrice(int256 raw) external {
        // Clamp to sanity bounds [MIN_PRICE, MAX_PRICE]
        int256 minP = int256(shield.MIN_PRICE());
        int256 maxP = int256(shield.MAX_PRICE());
        int256 clamped = raw < minP ? minP : (raw > maxP ? maxP : raw);
        oracle.setPrice(ASSET, clamped);
    }

    function e_warp(uint256 delta) external {
        uint256 bounded = delta % (7 days);
        HEVM.warp(block.timestamp + bounded);
    }

    /// @dev Attempt verifyAndCalculate with a possibly-invalid signature.
    function e_verifyAndCalculate(uint256 pidSeed, int256 priceRaw, uint256 verifiedAtRaw, bytes calldata sig)
        external
    {
        uint256 pid = (_ghost_lastPolicyId == 0) ? 0 : (pidSeed % _ghost_lastPolicyId) + 1;
        if (pid == 0) return;

        int256 minP = int256(shield.MIN_PRICE());
        int256 maxP = int256(shield.MAX_PRICE());
        int256 price = priceRaw < minP ? minP : (priceRaw > maxP ? maxP : priceRaw);
        uint256 verifiedAt = verifiedAtRaw % (2 * block.timestamp + 1);

        bytes memory proof = abi.encode(price, ASSET, verifiedAt, sig);

        bool isValidSig = (sig.length == 9 && keccak256(sig) == keccak256(bytes("VALID_SIG")));
        bool isStale = (block.timestamp > verifiedAt + shield.MAX_PROOF_AGE());

        HEVM.prank(ROUTER);
        try shield.verifyAndCalculate(pid, proof) returns (IShield.PayoutResult memory result) {
            // Property #6: if signature was invalid, we must NOT have produced a triggered payout.
            if (!isValidSig && result.triggered) _inv_oracle_confirmation_required = false;
            // Property #7: stale proof must not trigger.
            if (isStale && result.triggered) _inv_stale_oracle_fail_silent = false;
            // Property #5: if triggered, verifiedAt was inside the coverage window.
            if (result.triggered) {
                try shield.getPolicyInfo(pid) returns (IShield.PolicyInfo memory info) {
                    if (verifiedAt < info.waitingEndsAt || verifiedAt > info.expiresAt) {
                        _inv_trigger_only_in_window = false;
                    }
                } catch {}
            }
        } catch {
            // Reverts on bad sig / stale proof are fine; the funds-draining variant is
            // structurally impossible because verifyAndCalculate is `view`-equivalent
            // outside markPaidOut. Property #7 holds trivially via revert.
        }
    }

    function e_markPaidOut(uint256 pidSeed) external {
        uint256 pid = (_ghost_lastPolicyId == 0) ? 0 : (pidSeed % _ghost_lastPolicyId) + 1;
        if (pid == 0) return;

        HEVM.prank(ROUTER);
        try shield.markPaidOut(pid) {
            // Property #4: a second markPaidOut on the same policy must revert.
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

    /// @notice 1. TRIGGER_DROP_BPS is a `constant` -- must match ghost snapshot forever.
    function echidna_price_threshold_immutable() public view returns (bool) {
        return shield.TRIGGER_DROP_BPS() == _ghost_triggerDropBps;
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

    /// @notice 5. Every successful triggered verify had `verifiedAt` in [waitingEndsAt, expiresAt].
    function echidna_trigger_only_in_window() public view returns (bool) {
        return _inv_trigger_only_in_window;
    }

    /// @notice 6. Invalid signatures never produce a triggered payout.
    function echidna_oracle_confirmation_required() public view returns (bool) {
        return _inv_oracle_confirmation_required;
    }

    /// @notice 7. Proofs older than MAX_PROOF_AGE never trigger a payout (either revert
    ///         or return non-triggered).
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
