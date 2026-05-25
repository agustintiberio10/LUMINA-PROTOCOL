// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

contract MRL10Oracle {
    uint256 public price = 0.036e18;
    function getLuminaPrice() external view returns (uint256) { return price; }
}

/// @title MR-L10 fix — processQueue no longer double-decrements totalCommittedUSD.
/// @notice Before the fix, paying a queued obligation decremented BOTH
///         `totalQueuedUSD` and `totalCommittedUSD`, even though the obligation
///         had already been moved out of `committed` at queue time. With a second
///         holder's obligation present, that wrongly wiped THEIR committed value,
///         understating `totalUsed` and overstating `availableCapacityUSD`.
///         This test keeps a second holder (B) committed throughout an A
///         queue→pay cycle and asserts B's committed obligation survives.
contract MRL10_CommittedConservationTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MRL10Oracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address A = makeAddr("A");
    address B = makeAddr("B");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);
        oracle = new MRL10Oracle();

        ClaimBond cbImpl = new ClaimBond();
        claimBond = ClaimBond(address(new ERC1967Proxy(address(cbImpl), abi.encodeWithSelector(ClaimBond.initialize.selector))));

        LuminaTokenV2 tImpl = new LuminaTokenV2();
        token = LuminaTokenV2(address(new ERC1967Proxy(address(tImpl),
            abi.encodeWithSelector(LuminaTokenV2.initialize.selector, makeAddr("tv"), makeAddr("cex"), founder, lbp, treasury))));

        BondVault vImpl = new BondVault();
        vault = BondVault(address(new ERC1967Proxy(address(vImpl),
            abi.encodeWithSelector(BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(this)))));

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);
    }

    function _bondEpoch() internal view returns (uint256) {
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 m = (matTs - BASE_TS) / 2629746;
        return (2026 + m / 12) * 100 + (1 + m % 12);
    }

    function test_OtherHoldersCommittedSurvivesQueuePayout() public {
        uint256 cap = vault.maxRedeemThisEpoch();
        uint256 chunk = (cap * 5) / 100; // 5% of cap (under per-user 10% throttle)
        uint256 queuedUSD = (cap * 5) / 100; // A's redemption — over the FULL cap
        uint256 bondEpoch = _bondEpoch();

        // B holds a committed obligation that must survive A's queue→pay cycle.
        uint256 bUSD = (cap * 5) / 100;
        uint256 bUSD18 = bUSD * 1e18;
        vault.issueBond(B, bUSD); // B never redeems

        // A's bond + 25 fillers (mirrors F-04's proven _fillCapAndQueue).
        vault.issueBond(A, queuedUSD);
        uint256 nFillers = 25;
        address[] memory fillers = new address[](nFillers);
        for (uint256 i = 0; i < nFillers; i++) {
            fillers[i] = makeAddr(string(abi.encodePacked("f", vm.toString(i))));
            vault.issueBond(fillers[i], chunk);
        }

        vm.warp(claimBond.maturityDate(bondEpoch) + 1);
        uint256 epochN = vault.currentEpoch();
        for (uint256 i = 0; i < nFillers; i++) {
            uint256 capNow = vault.maxRedeemThisEpoch();
            uint256 used = vault.redeemedInEpoch(vault.currentEpoch()) / 1e18;
            uint256 remaining = capNow > used ? capNow - used : 0;
            if (remaining < queuedUSD) break;
            vm.prank(fillers[i]);
            vault.redeemBond(bondEpoch, chunk);
        }

        // A redeems → over cap → queued to N+1.
        vm.prank(A);
        vault.redeemBond(bondEpoch, queuedUSD);
        uint256 target = epochN + 1;
        assertGe(vault.queueLength(target), 1, "A must be queued");

        // B's committed obligation is present before processing.
        uint256 committedBefore = vault.totalCommittedUSD();
        assertGe(committedBefore, bUSD18, "B committed present pre-process");

        // Process the queue in N+1 (pays A and any queued fillers).
        vm.warp(target * 7 days + 1);
        vault.processQueue();

        // [MR-L10] B's committed obligation MUST survive: the paid queued entries
        // already left `committed` at queue time, so pay-time touches only
        // `queued`. Pre-fix, the double `committed` decrement would have eaten into
        // B's committed value. Assert B's obligation is intact.
        assertGe(
            vault.totalCommittedUSD(),
            bUSD18,
            "[MR-L10] committed obligation of a non-queued holder was wiped (double-decrement regression)"
        );
    }
}
