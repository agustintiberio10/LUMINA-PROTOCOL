// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";

/// @title SystemHandler
/// @notice Foundry invariant handler for system-wide invariant testing.
///         Performs random BondVault operations and tracks ghost variables.
contract SystemHandler is Test {
    // ═══════ Contracts ═══════
    LuminaTokenV2 public lumina;
    BondVault public bondVault;
    ClaimBond public claimBond;

    // ═══════ Mock oracle reference (for price manipulation) ═══════
    address public oracle;

    // ═══════ Tracking ═══════
    uint256 public initialSupply;
    uint256 public totalBurned;
    bool public allBurnsWithinCap = true;

    // Ghost counters
    uint256 public issueCalls;
    uint256 public redeemCalls;
    uint256 public burnCalls;
    uint256 public decreaseCalls;
    uint256 public advanceCalls;

    // Users for bond operations
    address[] public users;

    // Track issued epochs per user for redemption
    mapping(address => uint256[]) internal _userEpochs;

    constructor(LuminaTokenV2 _lumina, BondVault _bondVault, ClaimBond _claimBond, address _oracle) {
        lumina = _lumina;
        bondVault = _bondVault;
        claimBond = _claimBond;
        oracle = _oracle;
        initialSupply = _lumina.totalSupply();

        // Pre-create users
        for (uint256 i = 1; i <= 10; i++) {
            users.push(address(uint160(0x2000 + i)));
        }
    }

    // ═══════ HANDLER ACTIONS ═══════

    /// @notice Issue a bond to a random user with a bounded USD amount
    function issueBond(uint256 userIdx, uint256 amount) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        amount = bound(amount, 1, 50_000); // $1 to $50K bonds

        address user = users[userIdx];

        try bondVault.issueBond(user, amount, 0.036e18) {
            issueCalls++;
            // Track epoch for later redemption
            uint256 maturityTs = block.timestamp + 730 days;
            uint256 BASE_TS = 1767225600;
            uint256 mfb = (maturityTs - BASE_TS) / 2629746;
            uint256 epochId = (2026 + mfb / 12) * 100 + (1 + mfb % 12);
            _userEpochs[user].push(epochId);
        } catch {
            // Expected: capacity exhausted, paused, price floor, etc.
        }
    }

    /// @notice Redeem a matured bond for a random user
    function redeemBond(uint256 userIdx, uint256 amount) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        address user = users[userIdx];

        // Find an epoch with a balance
        uint256[] storage epochs = _userEpochs[user];
        if (epochs.length == 0) return;

        // Try the last epoch
        uint256 epochId = epochs[epochs.length - 1];
        uint256 bal = claimBond.balanceOf(user, epochId);
        if (bal == 0) return;

        amount = bound(amount, 1, bal);

        // Check maturity — warp if needed
        uint256 matDate = claimBond.maturityDate(epochId);
        if (matDate == 0) return;
        if (block.timestamp < matDate) {
            vm.warp(matDate + 1);
        }

        vm.prank(user);
        try bondVault.redeemBond(epochId, amount) {
            redeemCalls++;
        } catch {
            // Expected: insufficient reserve, price too low, etc.
        }
    }

    /// @notice Burn LUMINA from vault reserves (authorized caller path)
    function burnFromReserves(uint256 amount) external {
        uint256 vaultBalance = lumina.balanceOf(address(bondVault));
        if (vaultBalance == 0) return;

        // Cap to max 5% of vault balance (the contract enforces this too)
        uint256 maxBurn = (vaultBalance * 5) / 100;
        if (maxBurn == 0) return;
        amount = bound(amount, 1, maxBurn);

        uint256 supplyBefore = lumina.totalSupply();

        try bondVault.burnFromReserves(amount) {
            burnCalls++;
            uint256 actualBurned = supplyBefore - lumina.totalSupply();
            totalBurned += actualBurned;

            // Verify 5% cap: amount burned should not exceed 5% of balance before burn
            if (actualBurned > maxBurn) {
                allBurnsWithinCap = false;
            }
        } catch {
            // Expected: not authorized, insufficient reserves, etc.
        }
    }

    /// @notice Decrease obligations (authorized caller path)
    function decreaseObligations(uint256 amount) external {
        uint256 committed = bondVault.totalCommittedUSD();
        if (committed == 0) return;

        amount = bound(amount, 1, committed);

        try bondVault.decreaseObligations(amount) {
            decreaseCalls++;
        } catch {
            // Expected: not authorized, exceeds committed, etc.
        }
    }

    /// @notice Advance block.timestamp by a bounded number of seconds
    function advanceTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);
        advanceCalls++;
    }
}
