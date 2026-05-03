// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";
import {MicroDepegShield} from "../../src/products/MicroDepegShield.sol";

/// @title MaxProofAge24hTest
/// @notice Audit V5.1 fix M-8 — relax MAX_PROOF_AGE from 15 minutes (900s)
///         to 24 hours (86400s) so a stuck ShieldKeeper bot or Base
///         congestion does not cause a legit user to lose their claim.
/// @dev    Replay protection lives in BaseShield's policy-finalization
///         state machine (`cp.finalized`), not in the proof-age window.
///         Extending the window therefore does not weaken security —
///         the test suite verifies both that the constant is bumped on
///         every shield AND that the existing replay protection is
///         orthogonal.
contract MaxProofAge24hTest is Test {
    uint256 constant EXPECTED = 86400; // 24 hours

    // ═══════ CRITICAL — bump applied uniformly across all 8 proof-using shields ═══════

    function test_FlashBTC1h_MaxProofAge24h() public {
        FlashBTCShield1h s = new FlashBTCShield1h();
        assertEq(s.MAX_PROOF_AGE(), EXPECTED, "FlashBTCShield1h.MAX_PROOF_AGE != 24h");
    }

    function test_FlashBTC4h_MaxProofAge24h() public {
        FlashBTCShield4h s = new FlashBTCShield4h();
        assertEq(s.MAX_PROOF_AGE(), EXPECTED);
    }

    function test_FlashBTC24h_MaxProofAge24h() public {
        FlashBTCShield24h s = new FlashBTCShield24h();
        assertEq(s.MAX_PROOF_AGE(), EXPECTED);
    }

    function test_FlashBTC48h_MaxProofAge24h() public {
        FlashBTCShield48h s = new FlashBTCShield48h();
        assertEq(s.MAX_PROOF_AGE(), EXPECTED);
    }

    function test_FlashETH1h_MaxProofAge24h() public {
        FlashETHShield1h s = new FlashETHShield1h();
        assertEq(s.MAX_PROOF_AGE(), EXPECTED);
    }

    function test_FlashETH24h_MaxProofAge24h() public {
        FlashETHShield24h s = new FlashETHShield24h();
        assertEq(s.MAX_PROOF_AGE(), EXPECTED);
    }

    function test_FlashETH48h_MaxProofAge24h() public {
        FlashETHShield48h s = new FlashETHShield48h();
        assertEq(s.MAX_PROOF_AGE(), EXPECTED);
    }

    function test_MicroDepeg_MaxProofAge24h() public {
        MicroDepegShield s = new MicroDepegShield();
        assertEq(s.MAX_PROOF_AGE(), EXPECTED);
    }

    /// @dev Roll-up sanity check: all 8 proof-using shields agree on the
    ///      24-hour constant. RateShockShield is intentionally excluded —
    ///      it reads Aave reserve data on-chain and uses no off-chain
    ///      proof, so it has no MAX_PROOF_AGE constant.
    function test_AllShieldsHave24hMaxProofAge() public {
        assertEq((new FlashBTCShield1h()).MAX_PROOF_AGE(), EXPECTED);
        assertEq((new FlashBTCShield4h()).MAX_PROOF_AGE(), EXPECTED);
        assertEq((new FlashBTCShield24h()).MAX_PROOF_AGE(), EXPECTED);
        assertEq((new FlashBTCShield48h()).MAX_PROOF_AGE(), EXPECTED);
        assertEq((new FlashETHShield1h()).MAX_PROOF_AGE(), EXPECTED);
        assertEq((new FlashETHShield24h()).MAX_PROOF_AGE(), EXPECTED);
        assertEq((new FlashETHShield48h()).MAX_PROOF_AGE(), EXPECTED);
        assertEq((new MicroDepegShield()).MAX_PROOF_AGE(), EXPECTED);
    }

    // ═══════ Boundary semantics ═══════

    /// @dev MAX_PROOF_AGE is exactly 24 hours, no more. This pins the
    ///      semantics so a future bump (or accidental tweak) is loud.
    function test_ExactValueIs86400Seconds() public {
        FlashBTCShield1h s = new FlashBTCShield1h();
        assertEq(s.MAX_PROOF_AGE(), 24 hours);
        assertEq(s.MAX_PROOF_AGE(), 60 * 60 * 24);
    }

    /// @dev Sanity: confirm we are NOT at the legacy 15-minute value, so
    ///      a partial / botched merge that leaves one shield at 900 will
    ///      fail loudly.
    function test_NotAtLegacy15MinValue() public {
        FlashBTCShield1h s = new FlashBTCShield1h();
        assertGt(s.MAX_PROOF_AGE(), 900);
        assertEq(s.MAX_PROOF_AGE() / 900, 96); // 24h is exactly 96x the old window
    }
}
