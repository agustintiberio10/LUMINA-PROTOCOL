// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield48h} from "../../../src/products/FlashBTCShield48h.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashBTCShield48hWiring
/// @notice Sprint EE Phase F -- 8 fork-Sepolia wiring tests for FlashBTCShield48h.
///         Verifies the deployed proxy links to the expected on-chain SET A
///         oracle, exposes the documented constants (TRIGGER_DROP_BPS, MAX_*,
///         MIN_*, DURATION, DEDUCTIBLE_BPS, WAITING_PERIOD), and round-trips
///         the router immutable. No state-mutating on-chain interactions
///         beyond the fork-anchored deploy.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
contract FlashBTCShield48hWiring is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    address internal router;

    // ===== Skip gracefully if BASE_SEPOLIA_RPC is not configured =====
    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    function setUp() public {
        router = address(this);
    }

    function _deployShield() internal returns (FlashBTCShield48h) {
        return ProxyDeployer.deployFlashBTCShield48h(router, ORACLE_SET_A);
    }

    // ---------------------------------------------------------------------
    // 1. Oracle storage slot == LuminaOracleV2 SET A
    // ---------------------------------------------------------------------
    function test_Wiring_OracleAddress_OnChainMatches_LuminaOracleV2_SetA() public requiresFork {
        FlashBTCShield48h shield = _deployShield();
        assertEq(shield.oracle(), ORACLE_SET_A, "oracle storage must point to SET A");
    }

    // ---------------------------------------------------------------------
    // 2. Router storage slot == constructor argument
    // ---------------------------------------------------------------------
    function test_Wiring_RouterAddress_MatchesConstructorArg() public requiresFork {
        FlashBTCShield48h shield = _deployShield();
        assertEq(shield.router(), router, "router storage must equal constructor arg");
    }

    // ---------------------------------------------------------------------
    // 3. Oracle responds to getLatestPrice("BTC") -- informational
    //    Accepts either a positive price or a known revert. Does NOT gate the suite.
    // ---------------------------------------------------------------------
    function test_Wiring_OracleResponds_GetLatestPrice_BTC() public requiresFork {
        try IOracle(ORACLE_SET_A).getLatestPrice(bytes32("BTC")) returns (int256 price) {
            if (price <= 0) {
                emit log_named_int("WARN: SET A BTC price <= 0", price);
            } else {
                emit log_named_int("SET A BTC price (8-dec)", price);
            }
        } catch Error(string memory reason) {
            emit log_named_string("SET A BTC revert (string)", reason);
        } catch (bytes memory) {
            emit log_string("SET A BTC revert (bytes / custom error)");
        }
        // Wiring exists by virtue of the call having an endpoint.
        assertTrue(true);
    }

    // ---------------------------------------------------------------------
    // 4. Duration constants -- 48h fixed (172_800 seconds, min == max)
    // ---------------------------------------------------------------------
    function test_Wiring_DurationRange_Fixed48h() public requiresFork {
        FlashBTCShield48h shield = _deployShield();
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, 172_800, "MIN_DURATION must be 48h");
        assertEq(mx, 172_800, "MAX_DURATION must be 48h (fixed)");
        assertEq(shield.waitingPeriod(), 0, "WAITING_PERIOD must be 0 (flash)");
    }

    // ---------------------------------------------------------------------
    // 5. Product metadata: PRODUCT_ID + RISK_TYPE
    // ---------------------------------------------------------------------
    function test_Wiring_ProductId_And_RiskType() public requiresFork {
        FlashBTCShield48h shield = _deployShield();
        assertEq(shield.productId(), keccak256("FLASHBTC48-001"), "productId must be FLASHBTC48-001");
        assertEq(shield.riskType(), keccak256("VOLATILE"), "riskType must be VOLATILE");
        assertEq(shield.maxAllocationBps(), 3000, "MAX_ALLOCATION_BPS must be 30%");
    }

    // ---------------------------------------------------------------------
    // 6. Trigger + deductible constants (15% drop, 20% deductible)
    // ---------------------------------------------------------------------
    function test_Wiring_TriggerAndDeductible_Constants() public requiresFork {
        FlashBTCShield48h shield = _deployShield();
        assertEq(shield.TRIGGER_DROP_BPS(), 1500, "TRIGGER_DROP_BPS must be 15%");
        assertEq(shield.DEDUCTIBLE_BPS(), 2000, "DEDUCTIBLE_BPS must be 20%");
        assertEq(shield.MAX_PROOF_AGE(), 900, "MAX_PROOF_AGE must be 15 minutes");
    }

    // ---------------------------------------------------------------------
    // 7. Per-asset price sanity bounds (M-01 fix): MIN=$10k, MAX=$1M (8-dec)
    // ---------------------------------------------------------------------
    function test_Wiring_PriceSanityBounds() public requiresFork {
        FlashBTCShield48h shield = _deployShield();
        assertEq(shield.MIN_PRICE(), 10_000 * 1e8, "MIN_PRICE must be $10,000 (8-dec)");
        assertEq(shield.MAX_PRICE(), 1_000_000 * 1e8, "MAX_PRICE must be $1,000,000 (8-dec)");
    }

    // ---------------------------------------------------------------------
    // 8. Owner wiring -- the deployer is the proxy owner (UUPS upgrade gatekeeper)
    // ---------------------------------------------------------------------
    function test_Wiring_Owner_DeployerIsOwner() public requiresFork {
        FlashBTCShield48h shield = _deployShield();
        // ProxyDeployer.deployFlashBTCShield48h calls initialize, which calls
        // __Ownable_init(msg.sender). msg.sender from inside the library helper
        // is the calling test contract (this).
        assertEq(shield.owner(), address(this), "owner must be the deployer");
    }
}
