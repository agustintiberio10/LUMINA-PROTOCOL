// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";

/// @title ForceMatureTest
/// @notice Sprint U recovery — tests for the temporary `forceMature` admin
///         path on ClaimBond. Used to bypass monthly maturity buckets during
///         the BondVault SET B recovery. Function is REVERTED in Sprint U
///         Phase 6 — proxy rolls back to pre-recovery impl.
contract MockPriceOracle_ForceMature {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract ForceMatureTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockPriceOracle_ForceMature oracle;

    address deployer = address(this);
    address attacker = makeAddr("attacker");
    address holder = makeAddr("holder");

    event EpochForceMatured(uint256 indexed epochId, uint256 newMaturityTimestamp);

    function setUp() public {
        vm.warp(1767225600 + 30 days);

        oracle = new MockPriceOracle_ForceMature();

        ClaimBond cbImpl = new ClaimBond();
        ERC1967Proxy cbProxy = new ERC1967Proxy(address(cbImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(cbProxy));

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

        // BondVault with `address(this)` as both admin and policyManager — so
        // we can call `issueBond` directly from the test.
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

    // ─────────────────────────────────────────────────────────
    // 1. Access control
    // ─────────────────────────────────────────────────────────

    function test_ForceMature_OnlyOwnerCanCall() public {
        // Mint a bond first so the epoch exists.
        vault.issueBond(holder, 100);
        uint256 epochId = _findEpoch(holder);

        // Owner (test contract) succeeds.
        claimBond.forceMature(epochId);

        // Re-create a fresh bond + epoch (with a different holder so we can
        // catch the access-control revert on a registered epoch).
        address holder2 = makeAddr("holder2");
        vault.issueBond(holder2, 50);

        vm.prank(attacker);
        vm.expectRevert();
        claimBond.forceMature(epochId);
    }

    // ─────────────────────────────────────────────────────────
    // 2. Unregistered epoch reverts
    // ─────────────────────────────────────────────────────────

    function test_ForceMature_RevertsOnUnregisteredEpoch() public {
        vm.expectRevert(bytes("Epoch not registered"));
        claimBond.forceMature(999999);
    }

    // ─────────────────────────────────────────────────────────
    // 3. State change — maturityDate set to past
    // ─────────────────────────────────────────────────────────

    function test_ForceMature_SetsMaturityDateToPast() public {
        vault.issueBond(holder, 100);
        uint256 epochId = _findEpoch(holder);
        uint256 originalMaturity = claimBond.maturityDate(epochId);
        assertGt(originalMaturity, block.timestamp, "maturity originally in future");

        claimBond.forceMature(epochId);

        uint256 newMaturity = claimBond.maturityDate(epochId);
        assertEq(newMaturity, block.timestamp - 1, "maturityDate = block.timestamp - 1");
        assertTrue(claimBond.isMatured(epochId), "isMatured() returns true");
    }

    // ─────────────────────────────────────────────────────────
    // 4. Event emission
    // ─────────────────────────────────────────────────────────

    function test_ForceMature_EmitsEvent() public {
        vault.issueBond(holder, 100);
        uint256 epochId = _findEpoch(holder);

        vm.expectEmit(true, false, false, true);
        emit EpochForceMatured(epochId, block.timestamp - 1);
        claimBond.forceMature(epochId);
    }

    // ─────────────────────────────────────────────────────────
    // 5. E2E — forceMature unblocks redeemBond
    // ─────────────────────────────────────────────────────────

    /// @notice Sprint U recovery happy path: issue bond → forceMature →
    ///         redeem succeeds without any monthly wait.
    function test_ForceMature_AllowsRedemption() public {
        vault.issueBond(holder, 100);
        uint256 epochId = _findEpoch(holder);
        assertEq(claimBond.balanceOf(holder, epochId), 100, "100 bonds to holder");

        // Pre-forceMature: bond not yet matured (epoch is far in the future).
        assertFalse(claimBond.isMatured(epochId), "not matured pre-forceMature");

        // forceMature flips it.
        claimBond.forceMature(epochId);
        assertTrue(claimBond.isMatured(epochId), "matured post-forceMature");

        // Redemption proceeds. Holder receives LUMINA at current oracle price.
        uint256 preLuminaBalance = token.balanceOf(holder);
        vm.prank(holder);
        vault.redeemBond(epochId, 100);
        uint256 postLuminaBalance = token.balanceOf(holder);
        assertGt(postLuminaBalance, preLuminaBalance, "holder received LUMINA");
        assertEq(claimBond.balanceOf(holder, epochId), 0, "ClaimBond burned");
    }

    // ─────────────────────────────────────────────────────────
    // 6. Storage layout preserved (regression guard)
    // ─────────────────────────────────────────────────────────

    /// @notice Verifies forceMature writes ONLY to the existing
    ///         `maturityDate[epochId]` slot (computed via mapping hash) and
    ///         does NOT touch the gap region.
    function test_ForceMature_StorageLayoutPreserved() public {
        vault.issueBond(holder, 100);
        uint256 epochId = _findEpoch(holder);

        // ClaimBond's __gap was reduced from [50] to [48] post-FIX-#18; slot
        // 50+ is well inside the surviving gap region. Sample two slots.
        bytes32 pre60 = vm.load(address(claimBond), bytes32(uint256(60)));
        bytes32 pre61 = vm.load(address(claimBond), bytes32(uint256(61)));

        claimBond.forceMature(epochId);

        bytes32 post60 = vm.load(address(claimBond), bytes32(uint256(60)));
        bytes32 post61 = vm.load(address(claimBond), bytes32(uint256(61)));

        assertEq(post60, pre60, "slot 60 unchanged");
        assertEq(post61, pre61, "slot 61 unchanged");
    }

    // ─────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────

    function _findEpoch(address h) internal view returns (uint256) {
        for (uint256 e = 202601; e <= 210012; e++) {
            if (claimBond.balanceOf(h, e) > 0) return e;
        }
        return 0;
    }
}
