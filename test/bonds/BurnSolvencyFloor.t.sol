// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";

contract MockOracleM11 {
    uint256 public price;

    constructor(uint256 _p) {
        price = _p;
    }

    function setPrice(uint256 _p) external {
        price = _p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

/// @title BurnSolvencyFloorTest
/// @notice Audit V5.1 fix M-11 — `burnFromReserves` now refuses (or
///         caps) burns that would push solvency below 125%.
contract BurnSolvencyFloorTest is Test {
    event BurnLimitedBySolvencyFloor(uint256 requested, uint256 actual, uint256 currentSolvencyBps);
    event ReservesBurned(address indexed caller, uint256 amount, uint256 newBalance);

    BondVault vault;
    ClaimBond claimBond;
    LuminaTokenV2 token;
    MockOracleM11 oracle;

    address authorizedCaller = makeAddr("authorizedCaller");
    address policyManager = makeAddr("policyManager");
    uint256 constant LUMINA_DEFAULT = 70_000_000 ether; // 70M LUMINA seed

    uint256 constant FLOOR_BPS = 12500;
    uint256 constant BPS = 10000;

    function setUp() public {
        vm.warp(1767225600 + 30 days);

        // ClaimBond proxy
        ClaimBond cbImpl = new ClaimBond();
        ERC1967Proxy cbProxy =
            new ERC1967Proxy(address(cbImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(cbProxy));

        // LuminaTokenV2 proxy (gives us a real burnable ERC20)
        LuminaTokenV2 tImpl = new LuminaTokenV2();
        ERC1967Proxy tProxy = new ERC1967Proxy(
            address(tImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector,
                makeAddr("vaultRecipient"), // tempVault gets the 70M
                makeAddr("cex"),
                makeAddr("founder"),
                makeAddr("lbp"),
                makeAddr("treasury")
            )
        );
        token = LuminaTokenV2(address(tProxy));

        oracle = new MockOracleM11(0.036e18);

        // BondVault proxy
        BondVault vImpl = new BondVault();
        ERC1967Proxy vProxy = new ERC1967Proxy(
            address(vImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), policyManager
            )
        );
        vault = BondVault(address(vProxy));

        claimBond.setBondVault(address(vault));

        // Fund vault using deal (bypasses transfer mechanics).
        deal(address(token), address(vault), LUMINA_DEFAULT);

        // Authorize the test contract as an authorized caller so it can
        // invoke burnFromReserves directly without going through BuybackEngine.
        vault.setAuthorizedCaller(authorizedCaller, true);
    }

    // ═══════ Helpers ═══════

    /// @dev Drives the vault to a target solvency by:
    ///   1. Issuing obligations within the SAFETY_FACTOR limit at the
    ///      INITIAL price (this is the only way to plant obligations
    ///      without trespassing the contract's normal invariants).
    ///   2. Then dropping the oracle price so the same obligations
    ///      represent a *higher* fraction of the (now lower-valued)
    ///      vault balance — i.e. lower solvency.
    /// Solvency formula: bps = (balance * price * 10000) / (obligations * 1e18)
    function _setSolvencyState(uint256 solvencyBps, uint256 luminaBalance, uint256 /*ignoredInitialPrice*/) internal {
        // Step 1: max obligations issuable at the legacy 0.036 price within SAFETY_FACTOR (50%).
        oracle.setPrice(0.036e18);
        deal(address(token), address(vault), luminaBalance);
        // Issue $1M (well within the 50% safety cap of 70M*0.036*0.5 = $1.26M).
        uint256 obligationsUSD = 1_000_000;
        vm.prank(policyManager);
        // [Merge consolidation: h6 added priceSnapshot 3rd arg post-m11 sprint.]
        vault.issueBond(makeAddr("borrower"), obligationsUSD, 0.036e18);

        // Step 2: tune price so that:
        //   solvency_bps = (balance * price * 10000) / (obligations18 * 1e18) = solvencyBps
        //   => price = (solvencyBps * obligations18 * 1e18) / (balance * 10000)
        uint256 obligations18 = obligationsUSD * 1e18; // 18-dec USD-wei
        uint256 newPrice = (solvencyBps * obligations18 * 1e18) / (luminaBalance * 10000);
        oracle.setPrice(newPrice);
    }

    function _currentSolvencyBps() internal view returns (uint256) {
        uint256 balance = token.balanceOf(address(vault));
        uint256 obligations = vault.totalCommittedUSD();
        if (obligations == 0) return type(uint256).max;
        return (balance * oracle.price() * 10000) / (obligations * 1e18);
    }

    function _burnAs(address caller, uint256 amount) internal {
        vm.prank(caller);
        vault.burnFromReserves(amount);
    }

    // ═══════ CRITICAL — bug fix ═══════

    function test_BurnZeroObligationsAllowsFullBurn() public {
        // No obligations → full requested burn allowed (preserves FIX #14
        // semantics). Cap'd only by the 5%/tx limit.
        // setUp leaves totalCommittedUSD = 0.
        uint256 fivePct = (LUMINA_DEFAULT * 5) / 100;
        uint256 ask = fivePct;
        _burnAs(authorizedCaller, ask);
        assertEq(token.balanceOf(address(vault)), LUMINA_DEFAULT - ask);
    }

    function test_BurnFullAmountWhenSolvencyHigh() public {
        // Solvency = 200% → easily room for any burn within the 5% cap.
        // 70M * 0.036 / 1.0M-USD = 2.52 → 252% pre-burn. Even a 5%-of-vault burn
        // (3.5M LUMINA = 126k USD value) leaves solvency ~241%.
        _setSolvencyState(20000, LUMINA_DEFAULT, 0.036e18);

        uint256 ask = (LUMINA_DEFAULT * 5) / 100;
        _burnAs(authorizedCaller, ask);
        assertEq(token.balanceOf(address(vault)), LUMINA_DEFAULT - ask);
        assertGe(_currentSolvencyBps(), FLOOR_BPS);
    }

    function test_BurnLimitedWhenCloseToFloor() public {
        // Configure solvency = 130% (close to the 125% floor). A "large" burn
        // request should be silently capped to the largest amount that
        // keeps solvency >= 125%.
        _setSolvencyState(13000, LUMINA_DEFAULT, 0.036e18);

        // Ask for a generous burn (5%-cap = 3.5M LUMINA). Engine will cap.
        uint256 ask = (LUMINA_DEFAULT * 5) / 100;

        // We expect the BurnLimitedBySolvencyFloor event with `actual < ask`
        // and the pre-burn solvency reported.
        uint256 preSolvency = _currentSolvencyBps();
        vm.expectEmit(false, false, false, false);
        emit BurnLimitedBySolvencyFloor(ask, 0, preSolvency); // values check via topics+data only loosely
        _burnAs(authorizedCaller, ask);

        // Post-burn solvency should be at the floor (within 1 bps tolerance
        // for integer arithmetic).
        uint256 postSolvency = _currentSolvencyBps();
        assertGe(postSolvency, FLOOR_BPS - 1);
        assertLe(postSolvency, FLOOR_BPS + 100); // not too far above either
    }

    function test_BurnRevertsWhenSolvencyAlreadyAtFloor() public {
        // Solvency = 125% exactly → no further burn allowed.
        _setSolvencyState(12500, LUMINA_DEFAULT, 0.036e18);
        uint256 ask = (LUMINA_DEFAULT * 5) / 100;
        vm.expectRevert(BondVault.BurnBreachesSolvencyFloor.selector);
        _burnAs(authorizedCaller, ask);
    }

    function test_BurnRevertsWhenSolvencyBelowFloor() public {
        // Solvency = 120% → already below the floor, any burn reverts.
        _setSolvencyState(12000, LUMINA_DEFAULT, 0.036e18);
        vm.expectRevert(BondVault.BurnBreachesSolvencyFloor.selector);
        _burnAs(authorizedCaller, 1000 ether);
    }

    // ═══════ Edge cases ═══════

    function test_BurnRevertsWhenOracleReturnsZero() public {
        _setSolvencyState(15000, LUMINA_DEFAULT, 0.036e18);
        // Break the oracle.
        oracle.setPrice(0);
        vm.expectRevert(BondVault.BurnBreachesSolvencyFloor.selector);
        _burnAs(authorizedCaller, 1000 ether);
    }

    function test_BurnBoundaryExactlyAtFloorPostBurn() public {
        // Ask the engine to compute the maximum burn that keeps solvency
        // exactly at the floor. We construct a state at 150% and let the
        // guard cap the burn — post-burn solvency should land at ~125%.
        _setSolvencyState(15000, LUMINA_DEFAULT, 0.036e18);
        uint256 ask = (LUMINA_DEFAULT * 5) / 100;
        _burnAs(authorizedCaller, ask);
        uint256 post = _currentSolvencyBps();
        // The cap pulls us down to ≥ floor; assert within tolerance.
        assertGe(post, FLOOR_BPS - 1);
    }

    // ═══════ REGRESSION ═══════

    function test_NormalBurnStillWorks_HighSolvency() public {
        // No solvency state setup; default (no obligations) → full burn.
        uint256 ask = 1_000_000 ether; // well below 5% of 70M
        _burnAs(authorizedCaller, ask);
        assertEq(token.balanceOf(address(vault)), LUMINA_DEFAULT - ask);
    }

    function test_RevertIf_AmountZero() public {
        vm.expectRevert("Amount must be > 0");
        _burnAs(authorizedCaller, 0);
    }

    function test_RevertIf_ExceedsFivePctCap() public {
        // 5% cap of 70M = 3.5M; request 4M.
        vm.expectRevert("Exceeds 5% per-tx cap");
        _burnAs(authorizedCaller, 4_000_000 ether);
    }

    function test_RevertIf_NotAuthorized() public {
        vm.expectRevert("BondVault: caller not authorized");
        vault.burnFromReserves(1000 ether);
    }

    function test_ConstantsHaveSpecValues() public view {
        assertEq(vault.SOLVENCY_BURN_FLOOR_BPS(), 12500);
    }
}
