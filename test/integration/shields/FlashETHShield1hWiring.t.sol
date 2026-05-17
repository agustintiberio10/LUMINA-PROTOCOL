// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield1h} from "../../../src/products/FlashETHShield1h.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashETHShield1hWiring
/// @notice Sprint EE Phase F -- 8 fork-Sepolia wiring tests for FlashETHShield1h.
///         Verifies that the freshly deployed UUPS proxy points to SET A oracle,
///         honors product metadata (PRODUCT_ID, RISK_TYPE, duration, deductible,
///         trigger drop, sanity bounds), and that SET A actually responds to
///         getLatestPrice("ETH") on the live fork (informational).
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
contract FlashETHShield1hWiring is Test {
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    function _deploy(address router_) internal returns (FlashETHShield1h) {
        return ProxyDeployer.deployFlashETHShield1h(router_, ORACLE_SET_A);
    }

    // ---------------------------------------------------------------------
    // W1. Router + oracle immutables bound at initialize
    // ---------------------------------------------------------------------
    function test_Wiring_W1_RouterAndOracleAddresses() public requiresFork {
        address router = makeAddr("policyManagerV2");
        FlashETHShield1h shield = _deploy(router);
        assertEq(shield.router(), router, "router must equal initializer arg");
        assertEq(shield.oracle(), ORACLE_SET_A, "oracle must equal SET A");
    }

    // ---------------------------------------------------------------------
    // W2. SET A responds to getLatestPrice("ETH") (informational)
    // ---------------------------------------------------------------------
    function test_Wiring_W2_SetA_GetLatestPrice_ETH() public requiresFork {
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
        assertTrue(true);
    }

    // ---------------------------------------------------------------------
    // W3. PRODUCT_ID + RISK_TYPE
    // ---------------------------------------------------------------------
    function test_Wiring_W3_ProductIdAndRiskType() public requiresFork {
        FlashETHShield1h shield = _deploy(address(this));
        assertEq(shield.productId(), keccak256("FLASHETH1H-001"));
        assertEq(shield.riskType(), keccak256("VOLATILE"));
    }

    // ---------------------------------------------------------------------
    // W4. Duration is fixed at 1h
    // ---------------------------------------------------------------------
    function test_Wiring_W4_DurationFixed_1h() public requiresFork {
        FlashETHShield1h shield = _deploy(address(this));
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, 3600, "MIN_DURATION must be 3600");
        assertEq(mx, 3600, "MAX_DURATION must be 3600");
        assertEq(shield.waitingPeriod(), 0, "WAITING_PERIOD must be 0");
    }

    // ---------------------------------------------------------------------
    // W5. Trigger drop = 7% and deductible = 20%
    // ---------------------------------------------------------------------
    function test_Wiring_W5_TriggerDropAndDeductible() public requiresFork {
        FlashETHShield1h shield = _deploy(address(this));
        assertEq(shield.TRIGGER_DROP_BPS(), 700, "TRIGGER_DROP_BPS must be 700 (7%)");
        assertEq(shield.DEDUCTIBLE_BPS(), 2000, "DEDUCTIBLE_BPS must be 2000 (20%)");
    }

    // ---------------------------------------------------------------------
    // W6. Sanity bounds [$500, $50,000] in 8-dec
    // ---------------------------------------------------------------------
    function test_Wiring_W6_SanityBounds_ETH() public requiresFork {
        FlashETHShield1h shield = _deploy(address(this));
        assertEq(shield.MIN_PRICE(), 500 * 1e8, "MIN_PRICE must be $500");
        assertEq(shield.MAX_PRICE(), 50_000 * 1e8, "MAX_PRICE must be $50,000");
    }

    // ---------------------------------------------------------------------
    // W7. MAX_PROOF_AGE = 900s (15 min) and MAX_ALLOCATION_BPS = 30%
    // ---------------------------------------------------------------------
    function test_Wiring_W7_ProofAgeAndMaxAllocation() public requiresFork {
        FlashETHShield1h shield = _deploy(address(this));
        assertEq(shield.MAX_PROOF_AGE(), 900, "MAX_PROOF_AGE must be 900s");
        assertEq(shield.maxAllocationBps(), 3000, "MAX_ALLOCATION_BPS must be 3000 (30%)");
    }

    // ---------------------------------------------------------------------
    // W8. UUPS proxy: implementation is non-zero and distinct from proxy
    // ---------------------------------------------------------------------
    function test_Wiring_W8_UUPS_ProxyDistinctFromImpl() public requiresFork {
        FlashETHShield1h shield = _deploy(address(this));
        // ERC-1967 implementation slot.
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 raw = vm.load(address(shield), implSlot);
        address impl = address(uint160(uint256(raw)));
        assertTrue(impl != address(0), "ERC-1967 impl must be set");
        assertTrue(impl != address(shield), "Proxy and impl must be distinct");
    }
}
