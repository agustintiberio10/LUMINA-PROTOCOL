// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

/// @title MR-M02 PoC — per-user redemption throttle diluted across the queue epoch
/// @notice Sprint 7.3 Manual Review. The F-10 per-user cap is enforced and
///         incremented ONLY in `redeemBond`, keyed on the throttle epoch at QUEUE
///         time. When `processQueue` later pays a carried-over entry (in epoch N+1)
///         it adds to the GLOBAL `redeemedInEpoch[N+1]` but never to
///         `redeemedByUserInEpoch[N+1][holder]`. So one account can occupy up to
///         2x the per-user share of a single epoch's actual LUMINA outflow:
///         (queued-from-N, paid in N+1) + (fresh per-user cap in N+1).
///
///         The GLOBAL epoch cap is NOT broken (processQueue gates each pay with
///         `already + need > cap`), so this dilutes per-user FAIRNESS, not vault
///         solvency — hence Medium. NOT run on testnet; local forge only.
contract MR_M02_ThrottleDilution_PoC is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockOracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address whale = makeAddr("whale");
    address smallHolder = makeAddr("smallHolder");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);

        oracle = new MockOracle();

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

    /// MR-M02: the whale captures ~2x the per-user share that the throttle is
    /// supposed to guarantee, across the N -> N+1 queue boundary, while an
    /// equivalent small holder is limited to exactly the per-user cap in N+1.
    function test_PerUserThrottleDilutedAcrossQueueBoundary() public {
        uint256 cap = vault.maxRedeemThisEpoch();
        uint256 perUser = (cap * vault.MAX_USER_REDEEM_BPS()) / 10_000;
        uint256 bondEpoch = _epochPlus730d();

        // Whale holds enough to redeem multiple per-user chunks.
        vault.issueBond(whale, perUser * 4);
        vault.issueBond(smallHolder, perUser * 2);

        // ---- Epoch N: fill the global cap so the whale's request is QUEUED. ----
        vm.warp(claimBond.maturityDate(bondEpoch) + 1);
        uint256 epochN = vault.currentEpoch();

        // Fillers drain epoch N's global cap up to just under `perUser` of headroom.
        _fillEpochToNearlyFull(bondEpoch, epochN, perUser);

        // Whale redeems `perUser` — over remaining cap => queued to N+1.
        vm.prank(whale);
        vault.redeemBond(bondEpoch, perUser);
        uint256 targetEpoch = epochN + 1;
        assertGe(vault.queueLength(targetEpoch), 1, "whale request must be queued to N+1");

        uint256 whaleBalAfterQueue = token.balanceOf(whale);

        // ---- Epoch N+1 ----
        vm.warp(targetEpoch * 7 days + 1);

        // (a) processQueue pays the whale's carried-over `perUser` — this consumes
        //     N+1 GLOBAL cap but does NOT touch redeemedByUserInEpoch[N+1][whale].
        vault.processQueue();
        uint256 whalePaidFromQueue = token.balanceOf(whale) - whaleBalAfterQueue;
        assertGt(whalePaidFromQueue, 0, "queue should have paid the whale in N+1");

        // (b) The whale ALSO redeems a FRESH `perUser` immediately in N+1. Because
        //     their per-user counter for N+1 is still 0, this does NOT revert —
        //     even though they already drew `perUser` of N+1's outflow via (a).
        vm.prank(whale);
        vault.redeemBond(bondEpoch, perUser); // must NOT revert "User epoch limit"
        uint256 whaleTotalInNPlus1 = (token.balanceOf(whale) - whaleBalAfterQueue);

        // (c) A small holder that did NOT pre-queue is capped at exactly `perUser`
        //     of N+1 outflow: a second per-user redeem reverts.
        vm.prank(smallHolder);
        vault.redeemBond(bondEpoch, perUser);
        vm.prank(smallHolder);
        vm.expectRevert(bytes("User epoch limit"));
        vault.redeemBond(bondEpoch, 1);

        // The whale extracted ~2x the per-user share of N+1's outflow that the
        // throttle is designed to guarantee to any single account.
        assertGt(
            whaleTotalInNPlus1,
            (token.balanceOf(smallHolder) - 0) , // small holder's single per-user draw
            "MR-M02: whale exceeded the per-user share within epoch N+1 outflow"
        );
    }

    /// Helper: redeem with fillers until epoch N's headroom is just under `perUser`,
    /// keeping every filler within its own per-user cap (no queuing during fill).
    function _fillEpochToNearlyFull(uint256 bondEpoch, uint256 epochN, uint256 perUser) internal {
        for (uint256 i = 0; i < 40; i++) {
            uint256 capNow = vault.maxRedeemThisEpoch();
            uint256 used = vault.redeemedInEpoch(epochN) / 1e18;
            uint256 remaining = capNow > used ? capNow - used : 0;
            if (remaining < perUser) break;
            uint256 perUserNow = (capNow * vault.MAX_USER_REDEEM_BPS()) / 10_000;
            uint256 amt = perUserNow;
            if (amt >= remaining) amt = remaining > perUser ? remaining - (perUser / 2) : remaining;
            if (amt == 0) break;
            address f = makeAddr(string(abi.encodePacked("filler", vm.toString(i))));
            vault.issueBond(f, amt);
            vm.prank(f);
            vault.redeemBond(bondEpoch, amt);
        }
    }
}

contract MockOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}
