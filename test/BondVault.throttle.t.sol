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

    // [F-10] A single account may redeem at most MAX_USER_REDEEM_BPS (10%) of the
    // epoch cap. To exercise the EPOCH-level throttle these helpers spread a full
    // cap across 11 distinct users (10 × cap/10 + remainder), each within its
    // per-user limit. The aggregate epoch counter still lands exactly at `cap`.
    // Per-user redemption size: 9.5% of the epoch cap. Under the 10% per-user
    // limit with margin to survive the intra-epoch cap shrink (the cap is 1.08%
    // of the LIVE vault balance, which drops as redemptions drain it).
    function _perUser(uint256 cap) internal pure returns (uint256) {
        return (cap * 950) / 10_000;
    }

    function _capFillUsers() internal returns (address[] memory us) {
        us = new address[](16);
        for (uint256 i = 0; i < 16; i++) {
            us[i] = makeAddr(string(abi.encodePacked("capUser", vm.toString(i))));
        }
    }

    // Pre-issues bonds (before maturity warp) to 10 fill users + a few spare
    // users for queued entries. Each gets `_perUser(cap)` worth.
    function _issueCapAcrossUsers(uint256 cap) internal returns (address[] memory us) {
        us = _capFillUsers();
        uint256 pu = _perUser(cap);
        for (uint256 i = 0; i < 16; i++) {
            vault.issueBond(us[i], pu);
        }
    }

    // Redeems ~95% of the cap across the 10 fill users (no queue); returns the
    // total integer-USD redeemed so callers can assert the epoch counter.
    function _redeemCapAcrossUsers(uint256 epoch, uint256 cap, address[] memory us) internal returns (uint256 total) {
        uint256 pu = _perUser(cap);
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(us[i]);
            vault.redeemBond(epoch, pu);
            total += pu;
        }
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

        // [F-10] fill the epoch cap across 11 users (per-user limit = 10% of cap)
        address[] memory us = _issueCapAcrossUsers(cap);
        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpoch = vault.currentEpoch();

        // [F-10] The per-user limit is exactly 10% of the cap, and the cap is
        // 1.08% of the LIVE vault balance (shrinks intra-epoch as it drains), so
        // a single user can no longer take the whole cap. Fill ~95% across 10
        // users; the aggregate epoch counter equals that total and nothing queues.
        uint256 total = _redeemCapAcrossUsers(epoch, cap, us);

        assertEq(vault.redeemedInEpoch(throttleEpoch), total * 1e18, "counter should equal aggregate redeemed");
        assertEq(vault.queueLength(throttleEpoch + 1), 0, "should not queue below the cap");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 3. Over-the-limit: first redemption already fills cap; second one with
    //    the same caller gets queued and bonds are burned up-front.
    // ═══════════════════════════════════════════════════════════════════════
    function testRedemptionOverLimit_Queues() public {
        uint256 cap = vault.maxRedeemThisEpoch();

        // Fill ~95% of the cap across 10 users; us[10] is a spare (already
        // issued `_perUser(cap)` worth) that will tip over the cap and queue.
        address[] memory us = _issueCapAcrossUsers(cap);
        uint256 overCapAmount = _perUser(cap); // ~9.5% of cap, exceeds the ~5% headroom
        address overUser = us[10];

        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpoch = vault.currentEpoch();

        // Burn ~95% of the cap first — succeeds immediately.
        uint256 total = _redeemCapAcrossUsers(epoch, cap, us);

        // Now overUser redeems ~9.5% of cap → over the remaining headroom → queued.
        uint256 overUserBalanceBefore = token.balanceOf(overUser);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BondQueued(overUser, epoch, overCapAmount, throttleEpoch + 1);

        vm.prank(overUser);
        vault.redeemBond(epoch, overCapAmount);

        // Bond IS burned at queue time (custody-by-debt model).
        assertEq(claimBond.balanceOf(overUser, epoch), 0, "bond should be burned on queue");
        // But LUMINA was NOT paid.
        assertEq(token.balanceOf(overUser), overUserBalanceBefore, "LUMINA should not be paid until processed");
        // Queue contains exactly one entry for the next epoch.
        assertEq(vault.queueLength(throttleEpoch + 1), 1, "queue should hold one entry");
        // Throttle counter for the current epoch should NOT include the queued amount.
        assertEq(vault.redeemedInEpoch(throttleEpoch), total * 1e18, "counter should not include queued amount");
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
        // [F-10] Each epoch's drain is now spread across 11 users (each <= 10%
        // of the epoch cap). Issue each user enough to cover ~12 weeks at the
        // (shrinking) per-user cap. The per-epoch per-user allowance resets each
        // week so the same users can keep draining.
        address[] memory us = _capFillUsers();
        uint256 perUserBudget = (capWeek1 / 10) * 14; // 12 weeks + margin
        for (uint256 i = 0; i < 11; i++) {
            if (vault.availableCapacityUSD() < perUserBudget) break;
            vault.issueBond(us[i], perUserBudget);
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
            // Current-epoch cap shrinks as the vault drains, so re-read it.
            uint256 cap = vault.maxRedeemThisEpoch();
            if (cap == 0) break;
            // Stay under the 10%-of-cap per-user limit with margin for the
            // intra-epoch shrink as the 10 redemptions drain the vault.
            uint256 perUser = _perUser(cap);
            if (perUser == 0) break;

            uint256 throttleEpoch = vault.currentEpoch();
            uint256 capUSD18Before = _capUSD18();

            // 10 users redeem `perUser` each → ~95% of cap this epoch.
            uint256 redeemedThisWeek = 0;
            for (uint256 i = 0; i < 10; i++) {
                if (claimBond.balanceOf(us[i], epoch) < perUser) continue;
                vm.prank(us[i]);
                vault.redeemBond(epoch, perUser);
                redeemedThisWeek += perUser;
            }
            if (redeemedThisWeek == 0) break;

            // Cap MUST NOT be breached in this epoch (vs. pre-redemption cap).
            uint256 redeemedAfter = vault.redeemedInEpoch(throttleEpoch);
            assertLe(redeemedAfter, capUSD18Before, "epoch cap breached");

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

        // Fill the cap across 11 users (so all subsequent redemptions queue).
        address[] memory us = _issueCapAcrossUsers(cap);
        // Three queued candidates, distinct amounts (each above the post-fill
        // headroom so they queue, and below the 10% per-user cap so they don't
        // revert) so we can spot FIFO order.
        vault.issueBond(user2, 1500);
        vault.issueBond(user3, 1800);
        address user4 = makeAddr("user4");
        vault.issueBond(user4, 2100);

        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpoch = vault.currentEpoch();

        // Burn the cap.
        _redeemCapAcrossUsers(epoch, cap, us);

        // Queue 3 in order: user2 → user3 → user4.
        vm.prank(user2);
        vault.redeemBond(epoch, 1500);
        vm.prank(user3);
        vault.redeemBond(epoch, 1800);
        vm.prank(user4);
        vault.redeemBond(epoch, 2100);

        assertEq(vault.queueLength(throttleEpoch + 1), 3, "queue length wrong");

        // Sanity: queue[0] === user2 / queue[1] === user3 / queue[2] === user4.
        (address h0,, uint256 amt0,) = vault.queueByEpoch(throttleEpoch + 1, 0);
        (address h1,, uint256 amt1,) = vault.queueByEpoch(throttleEpoch + 1, 1);
        (address h2,, uint256 amt2,) = vault.queueByEpoch(throttleEpoch + 1, 2);
        assertEq(h0, user2, "FIFO[0] holder");
        assertEq(amt0, 1500, "FIFO[0] amount");
        assertEq(h1, user3, "FIFO[1] holder");
        assertEq(amt1, 1800, "FIFO[1] amount");
        assertEq(h2, user4, "FIFO[2] holder");
        assertEq(amt2, 2100, "FIFO[2] amount");

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

        address[] memory us = _issueCapAcrossUsers(cap);
        uint256 queuedAmount = 1500; // above post-fill headroom, below per-user cap
        vault.issueBond(user2, queuedAmount);

        uint256 epoch = _currentEpochPlus730d();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        uint256 throttleEpochN = vault.currentEpoch();

        // ~95% of cap filled across 10 users.
        uint256 total = _redeemCapAcrossUsers(epoch, cap, us);
        assertEq(vault.redeemedInEpoch(throttleEpochN), total * 1e18);

        // user2 redeems → queued to N+1.
        vm.prank(user2);
        vault.redeemBond(epoch, queuedAmount);
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
        assertEq(vault.redeemedInEpoch(throttleEpochN1), queuedAmount * 1e18, "N+1 counter wrong");
    }
}
