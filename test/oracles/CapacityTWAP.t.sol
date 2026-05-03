// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {MockCapacityOracleV5} from "../mocks/MockCapacityOracleV5.sol";

/// @title CapacityTWAPTest
/// @notice Audit V5.1 fix M-6 - availableCapacityUSD must use 1h TWAP
///         instead of spot to resist intra-block / single-hour dumps.
contract CapacityTWAPTest is Test {
    // Mirrored events for vm.expectEmit
    event OracleFailure(string indexed source, string reason);
    event CapacityHealthPinged(uint256 capacity, uint256 priceUsed, bool usedFallback);

    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockCapacityOracleV5 oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address policyManager = makeAddr("policyManager");

    uint256 constant SPOT_NORMAL = 0.036e18;
    uint256 constant TWAP_NORMAL = 0.036e18;
    uint256 constant LUMINA_RESERVE = 70_000_000 ether; // 70M LUMINA
    uint256 constant SAFETY_FACTOR_BPS = 5000;

    function setUp() public {
        vm.warp(1767225600 + 30 days);

        oracle = new MockCapacityOracleV5();
        oracle.setPrice(SPOT_NORMAL);
        oracle.setTwapPrice(TWAP_NORMAL);

        // Deploy ClaimBond proxy (only needed because BondVault initializer wires it)
        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(claimBondProxy));

        // Deploy LuminaTokenV2 proxy
        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, makeAddr("tempVault"), makeAddr("cex"), founder, lbp, treasury
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        // Deploy BondVault proxy
        BondVault vaultImpl = new BondVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), policyManager
            )
        );
        vault = BondVault(address(vaultProxy));

        // Stock the vault with the canonical 70M LUMINA reserve. `deal`
        // bypasses the supply-cap check the protocol enforces in init -
        // we just need a controllable balance for capacity arithmetic.
        deal(address(token), address(vault), 70_000_000 ether);
    }

    // ═══════ Helper: expected capacity for a given price + 0 committed ═══════

    function _expectedCap(uint256 price) internal view returns (uint256) {
        uint256 reserve = token.balanceOf(address(vault));
        uint256 reserveValueUSD18 = (reserve * price) / 1e18;
        uint256 maxCommitUSD18 = (reserveValueUSD18 * SAFETY_FACTOR_BPS) / 10000;
        // No commits / reservations in setUp, so totalUsed == 0.
        return maxCommitUSD18 / 1e18;
    }

    // ═══════ CRITICAL — bug fix ═══════

    function test_CapacityUsesTWAPNotSpot() public {
        // TWAP normal, spot dumps to 0.018e18 (50% drop). Capacity should
        // track TWAP (= 0.036e18), NOT spot.
        oracle.setPrice(0.018e18); // spot dumps
        oracle.setTwapPrice(0.036e18); // TWAP unchanged

        uint256 cap = vault.availableCapacityUSD();
        assertEq(cap, _expectedCap(0.036e18), "capacity tracked spot, not TWAP");
        // Sanity: spot-based capacity would be exactly half.
        assertGt(cap, _expectedCap(0.018e18), "TWAP must protect against spot dumps");
    }

    function test_CapacityStableDuringPriceDump() public {
        // Spot crashes 50% in 1 minute, TWAP barely moves (it's a 1h average).
        // Initially: spot = TWAP = 0.036.
        uint256 capBefore = vault.availableCapacityUSD();

        // Simulate the dump: spot tanks, TWAP barely budges.
        oracle.setPrice(0.018e18);
        oracle.setTwapPrice(0.0355e18); // TWAP felt 1.4% of the dump

        uint256 capAfter = vault.availableCapacityUSD();

        // Capacity should drop only ~1.4% (proportional to TWAP), not 50%.
        // Tolerance: capAfter must be > 95% of capBefore.
        assertGt(capAfter * 100, capBefore * 95, "capacity dropped too much during spot dump");
    }

    function test_CapacityRespondsToSustainedPriceDrop() public {
        // Sustained drop: TWAP catches up to the new (lower) reality.
        oracle.setPrice(0.018e18);
        oracle.setTwapPrice(0.018e18); // 1h sustained = TWAP also down 50%

        uint256 cap = vault.availableCapacityUSD();
        // Capacity should drop ~50% from baseline.
        assertEq(cap, _expectedCap(0.018e18), "sustained drop not reflected");
    }

    function test_CapacityFallbackToSpotWhenTWAPFails() public {
        // TWAP reverts, spot is healthy. Capacity should still compute
        // (using spot), and pingCapacityHealth should emit OracleFailure.
        oracle.setRevertOnTwap(true);
        oracle.setPrice(SPOT_NORMAL);

        uint256 cap = vault.availableCapacityUSD();
        assertEq(cap, _expectedCap(SPOT_NORMAL), "fallback didn't use spot");

        // Non-view path must emit the event.
        vm.expectEmit(true, false, false, false);
        emit OracleFailure("CapacityTWAP", "");
        (uint256 cap2, uint256 priceUsed, bool usedFallback) = vault.pingCapacityHealth();
        assertEq(cap2, cap);
        assertEq(priceUsed, SPOT_NORMAL);
        assertTrue(usedFallback, "ping must report fallback=true");
    }

    function test_CapacityFloorBelow1Cent() public {
        // TWAP returns absurdly low value (below MIN_REDEEM_PRICE = 0.001e18).
        // Should fall back to spot rather than use the corrupt TWAP.
        oracle.setPrice(SPOT_NORMAL);
        oracle.setTwapPrice(1e14); // 0.0001 USD - below the 0.001 floor

        uint256 cap = vault.availableCapacityUSD();
        // Expect fallback to spot.
        assertEq(cap, _expectedCap(SPOT_NORMAL), "floor breach didn't fall back");

        (, uint256 priceUsed, bool usedFallback) = vault.pingCapacityHealth();
        assertEq(priceUsed, SPOT_NORMAL);
        assertTrue(usedFallback);
    }

    function test_CapacityFloorAtExactlyMinRedeem() public {
        // TWAP exactly at MIN_REDEEM_PRICE (0.001e18) - should be ACCEPTED
        // (the floor is `>=`, not `>`), no fallback.
        uint256 floor = vault.MIN_REDEEM_PRICE();
        oracle.setPrice(SPOT_NORMAL);
        oracle.setTwapPrice(floor);

        uint256 cap = vault.availableCapacityUSD();
        assertEq(cap, _expectedCap(floor), "boundary floor must be accepted");

        (,, bool usedFallback) = vault.pingCapacityHealth();
        assertFalse(usedFallback, "exact floor must NOT trigger fallback");
    }

    // ═══════ Spot-only fallback path ═══════

    function test_BothTWAPAndSpotRevert_PostC3Reverts() public {
        // [Merge consolidation: c3 removed the try/catch from _getSafePrice
        //  so a broken oracle now makes pricing unavailable instead of
        //  silently using MIN_REDEEM_PRICE. Pre-c3 + m6 (m6 alone), this
        //  test expected the floor; post-merge the correct behavior is to
        //  revert. M-6's m6 narrative explicitly stated "if both fail,
        //  fall back to floor" — that contract was overridden by c3's
        //  stricter no-silent-fallback policy.]
        oracle.setRevertOnTwap(true);
        oracle.setRevertOnPrice(true);

        vm.expectRevert("Mock: price revert");
        vault.availableCapacityUSD();
    }

    function test_PingEmitsCapacityHealthPingedAlways() public {
        // Even on the happy TWAP path, pingCapacityHealth emits
        // CapacityHealthPinged for monitoring tools.
        oracle.setPrice(SPOT_NORMAL);
        oracle.setTwapPrice(TWAP_NORMAL);

        vm.expectEmit(false, false, false, true);
        emit CapacityHealthPinged(_expectedCap(TWAP_NORMAL), TWAP_NORMAL, false);
        vault.pingCapacityHealth();
    }

    // ═══════ REGRESSION ═══════

    function test_AvailableCapacityNormalScenario() public view {
        // Spot == TWAP, no manipulation. Capacity matches the legacy formula.
        uint256 cap = vault.availableCapacityUSD();
        assertEq(cap, _expectedCap(SPOT_NORMAL));
    }

    function test_NoBreakingChangesToSignature() public view {
        // Compile-time check: the function still exists with the
        // legacy `view returns (uint256)` signature. If anyone
        // accidentally promotes it to non-view this test stops compiling
        // (we explicitly call from a `view` test function).
        uint256 cap = vault.availableCapacityUSD();
        cap; // silence "unused"
    }

    function test_ConstantTWAPCapacitySecondsIs1Hour() public view {
        assertEq(uint256(vault.TWAP_CAPACITY_SECONDS()), 3600, "TWAP window must be 1 hour");
    }
}
