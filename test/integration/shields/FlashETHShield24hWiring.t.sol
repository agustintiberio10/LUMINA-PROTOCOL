// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield24h} from "../../../src/products/FlashETHShield24h.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// +============================================================================+
// | Sprint EE -- Phase F: 8 fork-Sepolia wiring tests for FlashETHShield24h.   |
// |                                                                            |
// | Verifies the proxy + initializer correctly link to the expected on-chain   |
// | SET A oracle and that all product constants hold (FLASHETH24-001, 24h      |
// | duration, 12% trigger drop, 20% deductible, $500-$50k sanity bounds, 15m   |
// | proof age, 30% max allocation).                                            |
// |                                                                            |
// | Fork target: Base Sepolia (alias `base_sepolia` resolved from              |
// | BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.          |
// +============================================================================+

contract FlashETHShield24hWiring is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    // ===== Skip gracefully if BASE_SEPOLIA_RPC is not configured =====
    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    function _deploy(address routerAddr) internal returns (FlashETHShield24h) {
        return ProxyDeployer.deployFlashETHShield24h(routerAddr, ORACLE_SET_A);
    }

    // ---------------------------------------------------------------------
    // 1. Oracle storage slot === SET A address
    // ---------------------------------------------------------------------
    function test_Wiring_OracleAddress_OnChainMatches_LuminaOracleV2_SetA() public requiresFork {
        FlashETHShield24h s = _deploy(address(this));
        assertEq(s.oracle(), ORACLE_SET_A, "oracle must equal SET A");
    }

    // ---------------------------------------------------------------------
    // 2. Router storage slot === passed router address
    // ---------------------------------------------------------------------
    function test_Wiring_RouterAddress_RecordedCorrectly() public requiresFork {
        address routerMock = makeAddr("policyManagerV2");
        FlashETHShield24h s = _deploy(routerMock);
        assertEq(s.router(), routerMock, "router must equal init arg (PolicyManagerV2 in prod)");
    }

    // ---------------------------------------------------------------------
    // 3. Product metadata constants
    // ---------------------------------------------------------------------
    function test_Wiring_ProductMetadata_Constants() public requiresFork {
        FlashETHShield24h s = _deploy(address(this));
        assertEq(s.productId(), keccak256("FLASHETH24-001"), "productId");
        assertEq(s.riskType(), keccak256("VOLATILE"), "riskType");
        assertEq(s.maxAllocationBps(), 3000, "maxAllocationBps must be 30%");
        assertEq(uint256(s.waitingPeriod()), 0, "waitingPeriod must be 0");
    }

    // ---------------------------------------------------------------------
    // 4. Duration range = 24h exactly (min == max)
    // ---------------------------------------------------------------------
    function test_Wiring_DurationRange_Exact24h() public requiresFork {
        FlashETHShield24h s = _deploy(address(this));
        (uint32 mn, uint32 mx) = s.durationRange();
        assertEq(uint256(mn), 86400, "MIN_DURATION must be 24h");
        assertEq(uint256(mx), 86400, "MAX_DURATION must be 24h");
    }

    // ---------------------------------------------------------------------
    // 5. Economic constants: 12% trigger drop, 20% deductible
    // ---------------------------------------------------------------------
    function test_Wiring_EconomicConstants_TriggerAndDeductible() public requiresFork {
        FlashETHShield24h s = _deploy(address(this));
        assertEq(s.TRIGGER_DROP_BPS(), 1200, "TRIGGER_DROP_BPS must be 12%");
        assertEq(s.DEDUCTIBLE_BPS(), 2000, "DEDUCTIBLE_BPS must be 20%");
    }

    // ---------------------------------------------------------------------
    // 6. Sanity bounds: MIN_PRICE = $500, MAX_PRICE = $50,000 (Chainlink 8-dec)
    // ---------------------------------------------------------------------
    function test_Wiring_SanityBounds_ETH_500_50000() public requiresFork {
        FlashETHShield24h s = _deploy(address(this));
        assertEq(s.MIN_PRICE(), uint256(500) * 1e8, "MIN_PRICE = $500");
        assertEq(s.MAX_PRICE(), uint256(50_000) * 1e8, "MAX_PRICE = $50,000");
    }

    // ---------------------------------------------------------------------
    // 7. MAX_PROOF_AGE = 15 minutes
    // ---------------------------------------------------------------------
    function test_Wiring_MaxProofAge_15min() public requiresFork {
        FlashETHShield24h s = _deploy(address(this));
        assertEq(s.MAX_PROOF_AGE(), 900, "MAX_PROOF_AGE must be 15 minutes");
    }

    // ---------------------------------------------------------------------
    // 8. Oracle endpoint responds (informational, mirrors FV pattern)
    // ---------------------------------------------------------------------
    function test_Wiring_OracleResponds_GetLatestPrice_ETH() public requiresFork {
        // Read directly via the interface. Accept either a positive price OR
        // a known revert (stale, unconfigured). This is informational only --
        // does NOT gate the suite.
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
}
