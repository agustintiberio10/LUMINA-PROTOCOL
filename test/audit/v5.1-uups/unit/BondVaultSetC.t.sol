// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";

/// @title BondVaultSetC
/// @notice Sprint T (ADR-009) — exhaustive tests for the parameterized
///         `bondMaturitySeconds` storage var in BondVault. Covers default,
///         setter access control, bounds, event emission, custom-maturity
///         redemption flow, and storage-layout preservation under UUPS upgrade.
contract MockPriceOracle_SetC {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract BondVaultSetC is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockPriceOracle_SetC oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");

    event BondMaturityUpdated(uint256 oldValue, uint256 newValue);

    function setUp() public {
        // Warp past ClaimBond.BASE_TIMESTAMP (Jan 1 2026 UTC).
        vm.warp(1767225600 + 30 days);

        oracle = new MockPriceOracle_SetC();

        // ClaimBond proxy.
        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(claimBondProxy));

        // LuminaTokenV2 proxy.
        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector, makeAddr("tempVault"), makeAddr("cex"), founder, lbp, treasury
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        // BondVault proxy — `address(this)` is granted DEFAULT_ADMIN_ROLE in
        // initialize() and acts as the policyManager for tests.
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
    // 1. Default value post-initialize
    // ─────────────────────────────────────────────────────────
    function test_BondMaturity_DefaultIs730Days_PostInitialize() public view {
        assertEq(vault.bondMaturitySeconds(), 730 days, "default 730 days");
        assertEq(vault.MIN_BOND_MATURITY_SECONDS(), 1 minutes);
        assertEq(vault.MAX_BOND_MATURITY_SECONDS(), 10 * 365 days);
    }

    // ─────────────────────────────────────────────────────────
    // 2. Setter access control
    // ─────────────────────────────────────────────────────────
    function test_BondMaturity_SetByAdmin_Success() public {
        vault.setBondMaturitySeconds(60);
        assertEq(vault.bondMaturitySeconds(), 60);
    }

    function test_BondMaturity_SetByAdmin_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BondMaturityUpdated(730 days, 3600);
        vault.setBondMaturitySeconds(3600);
    }

    function test_BondMaturity_SetByNonAdmin_Reverts() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        vault.setBondMaturitySeconds(60);
    }

    // ─────────────────────────────────────────────────────────
    // 3. Bounds
    // ─────────────────────────────────────────────────────────
    function test_BondMaturity_BelowMin_Reverts() public {
        vm.expectRevert(bytes("Below min maturity"));
        vault.setBondMaturitySeconds(59);
    }

    function test_BondMaturity_AboveMax_Reverts() public {
        vm.expectRevert(bytes("Above max maturity"));
        vault.setBondMaturitySeconds(10 * 365 days + 1);
    }

    function test_BondMaturity_AtMin_Success() public {
        vault.setBondMaturitySeconds(60);
        assertEq(vault.bondMaturitySeconds(), 60);
    }

    function test_BondMaturity_AtMax_Success() public {
        vault.setBondMaturitySeconds(10 * 365 days);
        assertEq(vault.bondMaturitySeconds(), 10 * 365 days);
    }

    // ─────────────────────────────────────────────────────────
    // 4. Custom maturity respected E2E
    // ─────────────────────────────────────────────────────────
    /// @notice Verifica que el setter cambia la maturity efectiva del bond.
    /// @dev    [Sprint T finding] El epoch en BondVault es month-precision —
    ///         `_timestampToEpoch` mapea cualquier timestamp a YYYYMM y
    ///         `ClaimBond.maturityDate` lo fija al START del mes. Por eso un
    ///         valor de 60s no da maturity efectiva de 60s — el bond cae en
    ///         el mes actual y es redeemable de inmediato. Test usa 31 days
    ///         para garantizar cross-month boundary y ejercitar el flujo real.
    function test_BondMaturity_RedeemRespectsCustomMaturity() public {
        vault.setBondMaturitySeconds(31 days);

        uint256 issueTs = block.timestamp;
        vault.issueBond(user, 100);
        uint256 epochId = _findUserEpoch(user);
        assertGt(epochId, 0);
        assertGt(claimBond.balanceOf(user, epochId), 0);

        vm.warp(issueTs + 1 hours);
        assertFalse(claimBond.isMatured(epochId), "not matured 1h post-issue");

        vm.warp(issueTs + 32 days);
        assertTrue(claimBond.isMatured(epochId), "matured 32 days post-issue");
    }

    // ─────────────────────────────────────────────────────────
    // 5. Storage layout preserved under UUPS upgrade
    // ─────────────────────────────────────────────────────────
    /// @notice Verifica que post-upgrade la storage var `bondMaturitySeconds`
    ///         queda en el mismo slot (8) y que el resto del estado se
    ///         preserva. Esencial pre-mainnet (regla ADR-005 storage layout).
    function test_BondMaturity_StorageLayoutPreserved() public {
        vault.setBondMaturitySeconds(120);
        vault.issueBond(user, 50);

        uint256 preCommitted = vault.totalCommittedUSD();
        uint256 preMaturity = vault.bondMaturitySeconds();
        uint256 preBalance = token.balanceOf(address(vault));

        BondVault newImpl = new BondVault();
        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(vault.bondMaturitySeconds(), preMaturity, "maturity preserved");
        assertEq(vault.totalCommittedUSD(), preCommitted, "committed preserved");
        assertEq(token.balanceOf(address(vault)), preBalance, "reserve preserved");

        // Verify slot 8 (= bondMaturitySeconds) directly via vm.load.
        bytes32 slot8 = vm.load(address(vault), bytes32(uint256(8)));
        assertEq(uint256(slot8), preMaturity, "slot 8 = bondMaturitySeconds");

        // Setter still works post-upgrade.
        vault.setBondMaturitySeconds(180);
        assertEq(vault.bondMaturitySeconds(), 180);
    }

    // ─────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────

    /// @dev Linear scan for the single epoch of `holder` (test issues bonds one at a time).
    function _findUserEpoch(address holder) internal view returns (uint256) {
        for (uint256 e = 202601; e <= 210012; e++) {
            if (claimBond.balanceOf(holder, e) > 0) return e;
        }
        return 0;
    }
}
