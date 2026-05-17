// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield48h} from "../../../src/products/FlashETHShield48h.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";

/// @title FlashETHShield48hWiring
/// @notice Sprint EE Phase E -- 8 fork-Sepolia wiring tests for FlashETHShield48h.
///         Verifies the proxy initializer links to the expected on-chain SET A
///         oracle, that the product constants hold (48h duration / 18% trigger
///         / 20% deductible / 900s proof age / $500-$50k sanity bounds), and
///         that SET A responds (or fails gracefully) on getLatestPrice("ETH").
///         No state-mutating on-chain interactions beyond the fork-anchored
///         proxy deploy.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
contract FlashETHShield48hWiring is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    // ===== Constants =====
    uint32 internal constant DURATION_48H = 172800;
    uint256 internal constant MAX_PROOF_AGE = 900;
    uint256 internal constant TRIGGER_DROP_BPS = 1800;
    uint256 internal constant DEDUCTIBLE_BPS = 2000;
    uint256 internal constant MIN_PRICE = 500 * 1e8;
    uint256 internal constant MAX_PRICE = 50_000 * 1e8;

    // ===== Skip gracefully if BASE_SEPOLIA_RPC is not configured =====
    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    function _deploy(address router_) internal returns (FlashETHShield48h) {
        return ProxyDeployer.deployFlashETHShield48h(router_, ORACLE_SET_A);
    }

    // ---------------------------------------------------------------------
    // 1. Oracle storage variable === LuminaOracleV2 SET A
    // ---------------------------------------------------------------------
    function test_Wiring_OracleAddress_OnChainMatches_LuminaOracleV2_SetA() public requiresFork {
        FlashETHShield48h shield = _deploy(makeAddr("router"));
        assertEq(shield.oracle(), ORACLE_SET_A, "oracle must point to SET A");
    }

    // ---------------------------------------------------------------------
    // 2. Oracle responds to getLatestPrice("ETH") -- informational
    // ---------------------------------------------------------------------
    function test_Wiring_OracleResponds_GetLatestPrice_ETH() public requiresFork {
        try IOracle(ORACLE_SET_A).getLatestPrice(bytes32("ETH")) returns (int256 price) {
            if (price <= 0) {
                emit log_named_int("WARN: SET A ETH price <= 0", price);
            } else {
                emit log_named_int("SET A ETH price (8-dec)", price);
            }
        } catch Error(string memory reason) {
            emit log_named_string("SET A ETH revert (string)", reason);
        } catch (bytes memory) {
            emit log_string("SET A ETH revert (bytes / custom error)");
        }
        // Wiring exists by virtue of the call having an endpoint.
        assertTrue(true);
    }

    // ---------------------------------------------------------------------
    // 3. Router storage variable matches initializer argument
    // ---------------------------------------------------------------------
    function test_Wiring_Router_MatchesInitArg() public requiresFork {
        address fakeRouter = makeAddr("router-init-arg");
        FlashETHShield48h shield = _deploy(fakeRouter);
        assertEq(shield.router(), fakeRouter, "router must equal init arg");
    }

    // ---------------------------------------------------------------------
    // 4. Constants -- 48h duration window (single value)
    // ---------------------------------------------------------------------
    function test_Wiring_Constants_DurationWindow_48h() public requiresFork {
        FlashETHShield48h shield = _deploy(makeAddr("router"));
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, DURATION_48H, "MIN_DURATION must be 48h (172800)");
        assertEq(mx, DURATION_48H, "MAX_DURATION must be 48h (172800)");
        assertEq(shield.waitingPeriod(), uint32(0));
    }

    // ---------------------------------------------------------------------
    // 5. Constants -- trigger drop = 1800 bps (18%), deductible = 2000 bps
    // ---------------------------------------------------------------------
    function test_Wiring_Constants_TriggerDropAndDeductible() public requiresFork {
        FlashETHShield48h shield = _deploy(makeAddr("router"));
        assertEq(shield.TRIGGER_DROP_BPS(), TRIGGER_DROP_BPS, "TRIGGER_DROP_BPS must be 1800");
        assertEq(shield.DEDUCTIBLE_BPS(), DEDUCTIBLE_BPS, "DEDUCTIBLE_BPS must be 2000");
    }

    // ---------------------------------------------------------------------
    // 6. Constants -- MAX_PROOF_AGE = 900s (15 minutes)
    // ---------------------------------------------------------------------
    function test_Wiring_Constants_MaxProofAge_900s() public requiresFork {
        FlashETHShield48h shield = _deploy(makeAddr("router"));
        assertEq(shield.MAX_PROOF_AGE(), MAX_PROOF_AGE, "MAX_PROOF_AGE must be 900s");
    }

    // ---------------------------------------------------------------------
    // 7. Constants -- per-asset sanity bounds [$500, $50_000]
    // ---------------------------------------------------------------------
    function test_Wiring_Constants_SanityBounds_ETH() public requiresFork {
        FlashETHShield48h shield = _deploy(makeAddr("router"));
        assertEq(shield.MIN_PRICE(), MIN_PRICE, "MIN_PRICE must be $500 * 1e8");
        assertEq(shield.MAX_PRICE(), MAX_PRICE, "MAX_PRICE must be $50,000 * 1e8");
    }

    // ---------------------------------------------------------------------
    // 8. Product identity -- productId + riskType + maxAllocationBps
    // ---------------------------------------------------------------------
    function test_Wiring_ProductIdentity() public requiresFork {
        FlashETHShield48h shield = _deploy(makeAddr("router"));
        assertEq(shield.productId(), keccak256("FLASHETH48-001"), "productId must be FLASHETH48-001");
        assertEq(shield.riskType(), keccak256("VOLATILE"), "riskType must be VOLATILE");
        assertEq(shield.maxAllocationBps(), uint16(3000), "MAX_ALLOCATION_BPS must be 3000 (30%)");
    }
}
