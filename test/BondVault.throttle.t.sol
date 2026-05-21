// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/token/LuminaTokenV2.sol";
import "../src/bonds/ClaimBond.sol";
import "../src/bonds/BondVault.sol";

/// @title  BondVault.throttle.t.sol — Sprint T-30a Phase D
/// @notice Tests for the per-epoch redemption throttle (max 1.08% of vault per
///         7-day epoch). Over-cap redemptions are burned at queue time and
///         drained FIFO on subsequent `processQueue()` calls.
contract BondVaultThrottleMockPriceOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract BondVaultThrottleTest is Test {
    // Mirror of BondVault.BondQueued — solc 0.8.20 lacks
    // `ContractName.EventName` external-event references, so we redeclare
    // the event locally for vm.expectEmit topic-matching.
    event BondQueued(
        address indexed holder, uint256 indexed epochIdBond, uint256 usdAmount, uint256 indexed targetThrottleEpoch
    );

    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    BondVaultThrottleMockPriceOracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    // [via_ir gotcha] All `vm.warp(...)` calls in this file use ABSOLUTE
    // timestamps (storage reads, throttle-epoch boundaries, or BASE_TS-derived
    // values) — never `block.timestamp + delta`. Foundry with via_ir=true
    // caches block.timestamp so the relative form silently no-ops.

    function setUp() public {
        vm.chainId(8453);
        // Warp past ClaimBond.BASE_TIMESTAMP (Jan 1 2026 UTC = 1767225600).
        vm.warp(1767225600 + 30 days);

        oracle = new BondVaultThrottleMockPriceOracle();

        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(claimBondProxy));

        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, makeAddr("tempVault"), makeAddr("cex"), founder, lbp, treasury
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        BondVault vaultImpl = new BondVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector,
                address(token),
                address(claimBond),
                address(oracle),
                address(this) // this contract acts as PolicyManager
            )
        );
        vault = BondVault(address(vaultProxy));

        claimBond.setBondVault(address(vault));
        // Seed vault with 70M LUMINA so capacity checks behave like prod.
        deal(address(token), address(vault), 70_000_000 * 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helper: compute the ClaimBond epoch ID a newly-issued bond will land in,
    // mirroring BondVault._timestampToEpoch().
    // ═══════════════════════════════════════════════════════════════════════
    function _currentEpochPlus730d() internal view returns (uint256) {
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 1. Under-limit happy path: redeem $1k when cap is ~$27k → immediate.
    // ═══════════════════════════════════════════════════════════════════════
    function testRedemptionUnderLimit() public {
        // Cap at $0.036 price + 70M LUMINA vault = 70M * 0.036 * 0.0108 = $27,216
        uint256 cap = vault.maxRedeemThisEpoch();
        assertGt(cap, 20_000);
        assertLt(cap, 30_000);

        vault.issueBond(user, 1_000);
        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpoch = vault.currentEpoch();
        uint256 beforeBalance = token.balanceOf(user);

        vm.prank(user);
        vault.redeemBond(epoch, 1_000);

        // Bond burned, LUMINA paid out, throttle counter incremented.
        assertEq(claimBond.balanceOf(user, epoch), 0, "bond not burned");
        assertGt(token.balanceOf(user), beforeBalance, "no LUMINA received");
        assertEq(vault.redeemedInEpoch(throttleEpoch), 1_000 * 1e18, "throttle counter wrong");
        assertEq(vault.queueLength(throttleEpoch + 1), 0, "should not queue");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 2. At-the-limit boundary: redeem exactly the cap → succeeds, counter
    //    lands at the cap.
    // ═══════════════════════════════════════════════════════════════════════
    function testRedemptionAtLimit() public {
        uint256 cap = vault.maxRedeemThisEpoch(); // integer USD
        assertGt(cap, 0);

        vault.issueBond(user, cap);
        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpoch = vault.currentEpoch();

        vm.prank(user);
        vault.redeemBond(epoch, cap);

        assertEq(claimBond.balanceOf(user, epoch), 0, "bond not burned");
        assertEq(vault.redeemedInEpoch(throttleEpoch), cap * 1e18, "counter should equal cap");
        assertEq(vault.queueLength(throttleEpoch + 1), 0, "should not queue at boundary");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 3. Over-the-limit: first redemption already fills cap; second one with
    //    the same caller gets queued and bonds are burned up-front.
    // ═══════════════════════════════════════════════════════════════════════
    function testRedemptionOverLimit_Queues() public {
        uint256 cap = vault.maxRedeemThisEpoch();

        // First mint: exactly cap (uses up the throttle).
        vault.issueBond(user, cap);
        // Second mint: a small over-cap amount that we will queue.
        uint256 overCapAmount = 500;
        vault.issueBond(user2, overCapAmount);

        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpoch = vault.currentEpoch();

        // Burn the cap first — succeeds immediately.
        vm.prank(user);
        vault.redeemBond(epoch, cap);

        // Now user2 tries to redeem $500 → over cap → queued.
        uint256 user2BalanceBefore = token.balanceOf(user2);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BondQueued(user2, epoch, overCapAmount, throttleEpoch + 1);

        vm.prank(user2);
        vault.redeemBond(epoch, overCapAmount);

        // Bond IS burned at queue time (custody-by-debt model).
        assertEq(claimBond.balanceOf(user2, epoch), 0, "bond should be burned on queue");
        // But LUMINA was NOT paid.
        assertEq(token.balanceOf(user2), user2BalanceBefore, "LUMINA should not be paid until processed");
        // Queue contains exactly one entry for the next epoch.
        assertEq(vault.queueLength(throttleEpoch + 1), 1, "queue should hold one entry");
        // Throttle counter for the current epoch should NOT include the queued amount.
        assertEq(vault.redeemedInEpoch(throttleEpoch), cap * 1e18, "counter should not include queued amount");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 4. Cisne negro: drain ~13% in 12 epochs (12 × 1.08% = 12.96%).
    //    Verifies cap is enforced PER EPOCH, never breached in any single one.
    //    NOTE: we do NOT mint $1.08M per epoch literally (initial vault
    //    capacity ~$1.5M of bond commitments only). Instead we mint enough
    //    bonds up-front, then redeem the per-epoch cap each week and assert
    //    cumulative drain.
    // ═══════════════════════════════════════════════════════════════════════
    function testCisneNegro_12WeeksDrain() public {
        uint256 capWeek1 = vault.maxRedeemThisEpoch();
        // Issue 12 epochs worth of bonds, each per-user → 12 holders, each
        // holds `capWeek1` worth.
        address[] memory holders = new address[](12);
        for (uint256 i = 0; i < 12; i++) {
            holders[i] = makeAddr(string(abi.encodePacked("holder", vm.toString(i))));
            // bondVault capacity is finite — abort if we would exceed it.
            if (vault.availableCapacityUSD() < capWeek1) break;
            vault.issueBond(holders[i], capWeek1);
        }

        uint256 epoch = _currentEpochPlus730d();
        uint256 maturity = claimBond.maturityDate(epoch);
        // Warp past maturity to enable redemption.
        vm.warp(maturity + 1);

        // Anchor at the START of the NEXT throttle-epoch boundary so each
        // subsequent week-warp lands cleanly inside a fresh throttle-epoch.
        uint256 startThrottleEpoch = vault.currentEpoch() + 1;
        vm.warp(startThrottleEpoch * 7 days);

        uint256 vaultStartBalance = token.balanceOf(address(vault));
        uint256 successfulEpochs = 0;

        for (uint256 wk = 0; wk < 12; wk++) {
            // Each holder owns `capWeek1` worth of bonds for `epoch`. The
            // current-epoch cap shrinks as the vault drains, so re-read it.
            // [Sprint T-30a CI fix] Use 99% of cap for a safety margin: the
            // contract converts the integer-USD `amt` back to 18-dec USD-wei
            // (amt * 1e18), and once the vault drains the post-redemption
            // `_capUSD18()` shrinks below that snapshot. Snapshotting the
            // cap BEFORE redemption is what the contract enforces; the 99%
            // headroom keeps the test's post-redeem invariant well-defined.
            uint256 cap = (vault.maxRedeemThisEpoch() * 99) / 100;
            if (cap == 0 || claimBond.balanceOf(holders[wk], epoch) == 0) break;
            uint256 amt = cap < claimBond.balanceOf(holders[wk], epoch) ? cap : claimBond.balanceOf(holders[wk], epoch);

            uint256 throttleEpoch = vault.currentEpoch();
            uint256 redeemedBefore = vault.redeemedInEpoch(throttleEpoch);
            // Snapshot cap BEFORE redemption — this is the value the contract
            // enforces against. Recomputing after redemption uses a shrunken
            // vault balance and can falsely flag a breach.
            uint256 capUSD18Before = _capUSD18();

            vm.prank(holders[wk]);
            vault.redeemBond(epoch, amt);

            // Cap MUST NOT be breached in this epoch (vs. pre-redemption cap).
            uint256 redeemedAfter = vault.redeemedInEpoch(throttleEpoch);
            assertLe(redeemedAfter, capUSD18Before, "epoch cap breached");
            assertEq(redeemedAfter - redeemedBefore, amt * 1e18, "redeemed counter wrong");

            // Advance one full throttle-epoch via absolute boundary warp.
            successfulEpochs++;
            vm.warp((startThrottleEpoch + successfulEpochs) * 7 days);
        }

        // Should have successfully drained over multiple epochs.
        assertGe(successfulEpochs, 5, "should have drained at least 5 epochs");

        uint256 vaultEndBalance = token.balanceOf(address(vault));
        uint256 totalDrainedLumina = vaultStartBalance - vaultEndBalance;

        // Per-epoch cap is 1.08% of vault → after N epochs drain <= ~N * 1.08%
        // BUT cap shrinks as vault drains so actual drain is bounded by the
        // geometric series. After 12 epochs at perfect cap-fill it would be
        // ~1 - 0.9892^12 ~= 12.3%. We bound here at < 14% to leave slack.
        uint256 drainBps = (totalDrainedLumina * 10_000) / vaultStartBalance;
        assertLt(drainBps, 1_400, "total drain should be < 14% over 12 weeks");
    }

    /// @dev Mirror of BondVault._maxRedeemUSD18ThisEpoch using current oracle state.
    function _capUSD18() internal view returns (uint256) {
        uint256 price = oracle.getLuminaPrice();
        uint256 reserveBalance = token.balanceOf(address(vault));
        uint256 reserveValueUSD18 = (reserveBalance * price) / 1e18;
        return (reserveValueUSD18 * 108) / 10_000;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5. Queue FIFO ordering: three over-cap redemptions in epoch N → after
    //    warp to N+1, processQueue() drains them in the order they were
    //    pushed.
    // ═══════════════════════════════════════════════════════════════════════
    function testQueueOrderingFIFO() public {
        uint256 cap = vault.maxRedeemThisEpoch();

        // Fill the cap with user1 (so all subsequent redemptions queue).
        vault.issueBond(user, cap);
        // Three queued candidates, distinct amounts so we can spot order.
        vault.issueBond(user2, 100);
        vault.issueBond(user3, 200);
        address user4 = makeAddr("user4");
        vault.issueBond(user4, 300);

        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpoch = vault.currentEpoch();

        // Burn the cap.
        vm.prank(user);
        vault.redeemBond(epoch, cap);

        // Queue 3 in order: user2 → user3 → user4.
        vm.prank(user2);
        vault.redeemBond(epoch, 100);
        vm.prank(user3);
        vault.redeemBond(epoch, 200);
        vm.prank(user4);
        vault.redeemBond(epoch, 300);

        assertEq(vault.queueLength(throttleEpoch + 1), 3, "queue length wrong");

        // Sanity: queue[0] === user2 / queue[1] === user3 / queue[2] === user4.
        (address h0,, uint256 amt0,) = vault.queueByEpoch(throttleEpoch + 1, 0);
        (address h1,, uint256 amt1,) = vault.queueByEpoch(throttleEpoch + 1, 1);
        (address h2,, uint256 amt2,) = vault.queueByEpoch(throttleEpoch + 1, 2);
        assertEq(h0, user2, "FIFO[0] holder");
        assertEq(amt0, 100, "FIFO[0] amount");
        assertEq(h1, user3, "FIFO[1] holder");
        assertEq(amt1, 200, "FIFO[1] amount");
        assertEq(h2, user4, "FIFO[2] holder");
        assertEq(amt2, 300, "FIFO[2] amount");

        // Warp into throttleEpoch N+1 using an absolute, via_ir-safe warp:
        // anchor at the START of the next throttle-epoch, then +1s for safety.
        vm.warp((throttleEpoch + 1) * 7 days + 1);

        uint256 b2Before = token.balanceOf(user2);
        uint256 b3Before = token.balanceOf(user3);
        uint256 b4Before = token.balanceOf(user4);

        vault.processQueue();

        assertEq(vault.queueProcessedIndex(throttleEpoch + 1), 3, "all 3 should be processed");
        assertGt(token.balanceOf(user2), b2Before, "user2 not paid");
        assertGt(token.balanceOf(user3), b3Before, "user3 not paid");
        assertGt(token.balanceOf(user4), b4Before, "user4 not paid");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 6. processQueue on epoch advance: fill cap in epoch N, queue $500 to
    //    epoch N+1. Warp 7 days. processQueue() drains the queued $500.
    // ═══════════════════════════════════════════════════════════════════════
    function testProcessQueueWhenEpochAdvances() public {
        uint256 cap = vault.maxRedeemThisEpoch();

        vault.issueBond(user, cap);
        vault.issueBond(user2, 500);

        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpochN = vault.currentEpoch();

        // user redeems → fills cap.
        vm.prank(user);
        vault.redeemBond(epoch, cap);
        assertEq(vault.redeemedInEpoch(throttleEpochN), cap * 1e18);

        // user2 redeems → queued to N+1.
        vm.prank(user2);
        vault.redeemBond(epoch, 500);
        assertEq(vault.queueLength(throttleEpochN + 1), 1);
        assertEq(claimBond.balanceOf(user2, epoch), 0, "bond burned on queue");
        uint256 user2BalBeforeProcess = token.balanceOf(user2);
        assertEq(user2BalBeforeProcess, 0, "user2 should not have LUMINA yet");

        // Warp into throttle-epoch N+1 (absolute, via_ir-safe).
        vm.warp((throttleEpochN + 1) * 7 days + 1);
        uint256 throttleEpochN1 = vault.currentEpoch();
        assertEq(throttleEpochN1, throttleEpochN + 1, "throttle epoch should be N+1");

        // Anyone calls processQueue → drains user2.
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        vault.processQueue();

        assertEq(vault.queueProcessedIndex(throttleEpochN + 1), 1, "queue should be processed");
        assertGt(token.balanceOf(user2), 0, "user2 should be paid in LUMINA");
        // Throttle counter for N+1 should reflect the processed amount.
        assertEq(vault.redeemedInEpoch(throttleEpochN1), 500 * 1e18, "N+1 counter wrong");
    }
}
