// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

contract MRM02Oracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title MR-M02 fix — per-user throttle is NOT diluted across the queue epoch.
/// @notice After the fix, `processQueue` attributes the paid queued amount to the
///         holder's per-user counter for the PROCESSING epoch. So a whale that
///         queued in epoch N cannot also draw a fresh full per-user amount in N+1:
///         their fresh-redeem headroom in N+1 is reduced by the queued payout.
contract MRM02_ThrottleNoDilutionTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MRM02Oracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address whale = makeAddr("whale");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);

        oracle = new MRM02Oracle();

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

    /// MR-M02 fix: the queued payout is attributed to the holder's per-user
    /// counter for the PROCESSING epoch (N+1). Pre-fix, that counter stayed 0 in
    /// N+1 — letting the whale draw a fresh full per-user amount on top of the
    /// queued payout (~2x the intended per-user share). We assert the counter is
    /// charged by exactly the queued payout (the core invariant of the fix).
    function test_QueuedPayoutChargesPerUserCounterInProcessingEpoch() public {
        (uint256 bondEpoch, uint256 queuedUSD) = _fillCapAndQueueWhale();
        uint256 epochN = vault.currentEpoch();

        vm.prank(whale);
        vault.redeemBond(bondEpoch, queuedUSD); // over full cap → queued to N+1
        uint256 targetEpoch = epochN + 1;
        assertGe(vault.queueLength(targetEpoch), 1, "whale must be queued");

        // Pre-pay: whale has consumed no per-user allowance in N+1 yet.
        assertEq(vault.redeemedByUserInEpoch(targetEpoch, whale), 0, "no N+1 charge before processing");

        // Epoch N+1: pay the queue. MR-M02 charges the per-user counter for the
        // processing epoch by exactly the queued payout.
        vm.warp(targetEpoch * 7 days + 1);
        assertEq(vault.currentEpoch(), targetEpoch, "should be in processing epoch");
        vault.processQueue();

        assertEq(
            vault.redeemedByUserInEpoch(targetEpoch, whale),
            queuedUSD * 1e18,
            "[MR-M02] queued payout must be attributed to N+1 per-user counter"
        );
    }

    /// Mirrors F-04's proven `_fillCapAndQueue` (5%-of-cap fillers, each under the
    /// per-user 10% throttle) so the global cap is exhausted and a fresh whale
    /// redemption is forced to queue.
    function _fillCapAndQueueWhale() internal returns (uint256 epoch, uint256 queuedUSD) {
        uint256 cap = vault.maxRedeemThisEpoch();
        uint256 chunk = (cap * 5) / 100;
        queuedUSD = (cap * 5) / 100;

        epoch = _epochPlus730d();
        uint256 nFillers = 25;
        address[] memory fillers = new address[](nFillers);
        for (uint256 i = 0; i < nFillers; i++) {
            fillers[i] = makeAddr(string(abi.encodePacked("filler", vm.toString(i))));
            vault.issueBond(fillers[i], chunk);
        }
        vault.issueBond(whale, queuedUSD);

        vm.warp(claimBond.maturityDate(epoch) + 1);
        for (uint256 i = 0; i < nFillers; i++) {
            uint256 capNow = vault.maxRedeemThisEpoch();
            uint256 used = vault.redeemedInEpoch(vault.currentEpoch()) / 1e18;
            uint256 remaining = capNow > used ? capNow - used : 0;
            if (remaining < queuedUSD) break;
            vm.prank(fillers[i]);
            vault.redeemBond(epoch, chunk);
        }
    }
}
