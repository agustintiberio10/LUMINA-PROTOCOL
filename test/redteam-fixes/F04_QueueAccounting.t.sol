// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

contract F04Oracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title F-04 — queued redemptions must not free committed capacity before pay.
contract F04_QueueAccountingTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    F04Oracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);

        oracle = new F04Oracle();

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
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(this)
            )
        );
        vault = BondVault(address(vaultProxy));

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);
    }

    function _epochPlus730d() internal view returns (uint256) {
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        return (2026 + monthsFromBase / 12) * 100 + (1 + monthsFromBase % 12);
    }

    /// Setup helper: drive `redeemedInEpoch` to the per-epoch cap using many
    /// distinct fillers (each within the F-10 per-user 10% throttle) so that the
    /// global cap is exhausted, then leave a fresh `user2` whose redemption is
    /// GUARANTEED to exceed the remaining cap (→ queued). Returns the bond epoch
    /// + the queued USD amount. All `user2` accounting assertions are delta-based
    /// so prior fillers that happened to queue do not perturb them.
    function _fillCapAndQueue() internal returns (uint256 epoch, uint256 queuedUSD) {
        uint256 cap = vault.maxRedeemThisEpoch();
        uint256 chunk = (cap * 5) / 100; // 5% of cap per filler (< per-user 10%)
        queuedUSD = (cap * 5) / 100; // user2 redeems 5% — under per-user, over the FULL cap

        epoch = _epochPlus730d();
        uint256 nFillers = 25;
        address[] memory fillers = new address[](nFillers);
        for (uint256 i = 0; i < nFillers; i++) {
            fillers[i] = makeAddr(string(abi.encodePacked("filler", vm.toString(i))));
            vault.issueBond(fillers[i], chunk);
        }
        vault.issueBond(user2, queuedUSD);

        vm.warp(claimBond.maturityDate(epoch) + 1);

        // Fill until the remaining headroom is below `queuedUSD`, so user2 is
        // forced to queue. Fillers that themselves overflow simply queue too.
        for (uint256 i = 0; i < nFillers; i++) {
            uint256 capNow = vault.maxRedeemThisEpoch();
            uint256 used = vault.redeemedInEpoch(vault.currentEpoch()) / 1e18;
            uint256 remaining = capNow > used ? capNow - used : 0;
            if (remaining < queuedUSD) break;
            vm.prank(fillers[i]);
            vault.redeemBond(epoch, chunk);
        }
    }

    function test_OverCapQueueDoesNotFreeCapacity() public {
        (uint256 epoch, uint256 queuedUSD) = _fillCapAndQueue();
        uint256 throttleEpoch = vault.currentEpoch();

        uint256 committedBefore = vault.totalCommittedUSD();
        uint256 queuedBefore = vault.totalQueuedUSD();
        uint256 qLenBefore = vault.queueLength(throttleEpoch + 1);

        // user2 redeems over cap → queued.
        vm.prank(user2);
        vault.redeemBond(epoch, queuedUSD);

        // Exactly one NEW queue entry from user2.
        assertEq(vault.queueLength(throttleEpoch + 1), qLenBefore + 1, "user2 should add one queue entry");
        // Committed dropped by the queued amount, but it moved into
        // totalQueuedUSD — NOT freed. Net used capacity is conserved.
        assertEq(
            vault.totalCommittedUSD() + vault.totalQueuedUSD(),
            committedBefore + queuedBefore,
            "committed+queued must be conserved on queue"
        );
        // The queued bucket increased by exactly user2's amount.
        assertEq(vault.totalQueuedUSD(), queuedBefore + queuedUSD * 1e18, "queued bucket not increased by user2 amount");
        // And committed dropped by exactly user2's amount.
        assertEq(vault.totalCommittedUSD(), committedBefore - queuedUSD * 1e18, "committed not reclassified");
    }

    function test_AvailableCapacityNotOverstatedDuringQueue() public {
        (uint256 epoch, uint256 queuedUSD) = _fillCapAndQueue();

        uint256 availBefore = vault.availableCapacityUSD();

        vm.prank(user2);
        vault.redeemBond(epoch, queuedUSD);

        // Available capacity must NOT increase due to a queued (unpaid)
        // redemption — the LUMINA backing has not left the vault yet.
        uint256 availAfter = vault.availableCapacityUSD();
        assertEq(availAfter, availBefore, "queued redemption must not free available capacity");
    }

    function test_ProcessQueueDecrementsOnPay() public {
        (uint256 epoch, uint256 queuedUSD) = _fillCapAndQueue();
        uint256 throttleEpoch = vault.currentEpoch();

        vm.prank(user2);
        vault.redeemBond(epoch, queuedUSD);

        uint256 queuedAfterEnqueue = vault.totalQueuedUSD();
        assertGe(queuedAfterEnqueue, queuedUSD * 1e18, "queued bucket should include user2");

        // Advance into next throttle-epoch and process the whole queue.
        vm.warp((throttleEpoch + 1) * 7 days + 1);
        uint256 u2Before = token.balanceOf(user2);
        uint256 queuedBeforeProcess = vault.totalQueuedUSD();
        uint256 committedBeforeProcess = vault.totalCommittedUSD();
        vault.processQueue();

        // [MR-L10 fix] user2 paid out. The paid obligations were already moved
        // committed -> queued at QUEUE time (see test_OverCapQueueDoesNotFreeCapacity),
        // so at PAY time they leave ONLY the `queued` bucket. `committed` must NOT
        // drop for the paid entries — the previous code's matching `committed`
        // decrement was a DOUBLE decrement that wiped OTHER holders' committed
        // obligations (overstating availableCapacityUSD). So: queued drains by the
        // paid amount, committed is unchanged.
        assertGt(token.balanceOf(user2), u2Before, "user2 not paid");
        uint256 queuedDrained = queuedBeforeProcess - vault.totalQueuedUSD();
        uint256 committedDrained = committedBeforeProcess - vault.totalCommittedUSD();
        assertGt(queuedDrained, 0, "queued bucket must decrease on pay");
        assertEq(committedDrained, 0, "[MR-L10] committed must NOT drop on pay (already reclassified at queue time)");
    }
}
