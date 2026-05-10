// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";

/// @title AdminIssueBond
/// @notice Sprint U recovery — tests for the temporary `adminIssueBond` admin
///         path on PolicyManagerV2. Used to drain the upgrade-locked BondVault
///         SET B by issuing bonds directly to the founder wallet, then
///         force-maturing + redeeming. Function is REVERTED in Sprint U Phase 6.
contract MockPriceOracle_AdminIssue {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract AdminIssueBondTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    PolicyManagerV2 pm;
    MockPriceOracle_AdminIssue oracle;

    address deployer = address(this);
    address founder = makeAddr("founder");
    address attacker = makeAddr("attacker");

    event AdminBondIssued(address indexed to, uint256 usdPayout);

    function setUp() public {
        // Past ClaimBond.BASE_TIMESTAMP (Jan 1 2026 UTC).
        vm.warp(1767225600 + 30 days);

        oracle = new MockPriceOracle_AdminIssue();

        // ClaimBond proxy.
        ClaimBond cbImpl = new ClaimBond();
        ERC1967Proxy cbProxy = new ERC1967Proxy(address(cbImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(cbProxy));

        // LuminaTokenV2 proxy.
        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector,
                makeAddr("tempVault"),
                makeAddr("cex"),
                makeAddr("founderVesting"),
                makeAddr("lbp"),
                makeAddr("treasury")
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        // BondVault proxy — PolicyManager wired in next step.
        BondVault vaultImpl = new BondVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), address(0)
            )
        );
        vault = BondVault(address(vaultProxy));

        // PolicyManagerV2 proxy — initialized with bondVault.
        PolicyManagerV2 pmImpl = new PolicyManagerV2();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl), abi.encodeWithSelector(PolicyManagerV2.initialize.selector, address(vault))
        );
        pm = PolicyManagerV2(address(pmProxy));

        // Wire BondVault <-> PolicyManager (one-shot setter).
        vault.setPolicyManager(address(pm));

        // Wire ClaimBond -> BondVault (one-shot setter).
        claimBond.setBondVault(address(vault));

        // Fund the vault so issueBond doesn't revert on capacity.
        deal(address(token), address(vault), 70_000_000 * 1e18);
    }

    // ─────────────────────────────────────────────────────────
    // 1. Access control
    // ─────────────────────────────────────────────────────────

    function test_AdminIssueBond_OnlyOwnerCanCall() public {
        // deployer is owner per setUp.
        pm.adminIssueBond(founder, 100);

        // attacker should NOT be able to call.
        vm.prank(attacker);
        vm.expectRevert();
        pm.adminIssueBond(founder, 100);
    }

    // ─────────────────────────────────────────────────────────
    // 2. Input validation
    // ─────────────────────────────────────────────────────────

    function test_AdminIssueBond_RevertsOnZeroAddress() public {
        vm.expectRevert(bytes("Zero receiver"));
        pm.adminIssueBond(address(0), 100);
    }

    function test_AdminIssueBond_RevertsOnZeroPayout() public {
        vm.expectRevert(bytes("Zero payout"));
        pm.adminIssueBond(founder, 0);
    }

    // ─────────────────────────────────────────────────────────
    // 3. Event emission
    // ─────────────────────────────────────────────────────────

    function test_AdminIssueBond_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AdminBondIssued(founder, 500);
        pm.adminIssueBond(founder, 500);
    }

    // ─────────────────────────────────────────────────────────
    // 4. State change — bond minted to receiver
    // ─────────────────────────────────────────────────────────

    function test_AdminIssueBond_MintsClaimBondToReceiver() public {
        uint256 preCommitted = vault.totalCommittedUSD();
        pm.adminIssueBond(founder, 1_000);

        // Scan for the epoch the bond landed in (single mint in test).
        uint256 epochId = _findEpoch(founder);
        assertGt(epochId, 0, "epoch issued");
        assertEq(claimBond.balanceOf(founder, epochId), 1_000, "1000 bond units to founder");

        // BondVault commitment increased by usdPayout * 1e18.
        assertEq(vault.totalCommittedUSD() - preCommitted, 1_000 * 1e18, "commitment +1000 USD");
    }

    // ─────────────────────────────────────────────────────────
    // 5. Storage layout preserved (regression guard)
    // ─────────────────────────────────────────────────────────

    /// @notice The temporary adminIssueBond function MUST NOT consume storage
    ///         slots beyond the existing __gap layout. Verifies that slots
    ///         post-existing-state remain zero after the call (no accidental
    ///         storage write from the new function).
    function test_AdminIssueBond_StorageLayoutPreserved() public {
        // Snapshot pre-call slot values in the gap region.
        // PolicyManagerV2 has ~14 state slots (bondVault, router, productIds[],
        // policies mapping, etc.) — exact count varies but slot 50 is well into
        // the gap area for both old and new layouts.
        bytes32 pre50 = vm.load(address(pm), bytes32(uint256(50)));
        bytes32 pre51 = vm.load(address(pm), bytes32(uint256(51)));

        pm.adminIssueBond(founder, 100);

        bytes32 post50 = vm.load(address(pm), bytes32(uint256(50)));
        bytes32 post51 = vm.load(address(pm), bytes32(uint256(51)));

        assertEq(post50, pre50, "slot 50 unchanged by adminIssueBond");
        assertEq(post51, pre51, "slot 51 unchanged by adminIssueBond");
    }

    // ─────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────

    function _findEpoch(address holder) internal view returns (uint256) {
        for (uint256 e = 202601; e <= 210012; e++) {
            if (claimBond.balanceOf(holder, e) > 0) return e;
        }
        return 0;
    }
}
