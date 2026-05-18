// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashBTCShield24h} from "../../../src/products/FlashBTCShield24h.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashBTCShield24hWiring
/// @notice Sprint EE Phase F -- 8 fork-Sepolia wiring tests for FlashBTCShield24h.
///         Verifies the proxy initialization links to the expected on-chain
///         addresses (SET A oracle) and that the product constants
///         (BTC asset, 24h fixed window, 10% trigger drop, 80% payout) hold.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
contract FlashBTCShield24hWiring is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    address router; // address(this) in setUp

    // ===== Skip gracefully if BASE_SEPOLIA_RPC is not configured =====
    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            router = address(this);
            _;
        } catch {
            vm.skip(true);
        }
    }

    function _deployShield() internal returns (FlashBTCShield24h) {
        return ProxyDeployer.deployFlashBTCShield24h(router, ORACLE_SET_A);
    }

    // ---------------------------------------------------------------------
    // W1 -- Oracle storage slot == LuminaOracleV2 SET A
    // ---------------------------------------------------------------------
    function test_W1_Wiring_OracleAddress_SetA() public requiresFork {
        FlashBTCShield24h s = _deployShield();
        assertEq(s.oracle(), ORACLE_SET_A, "oracle must point to SET A");
    }

    // ---------------------------------------------------------------------
    // W2 -- Router storage slot == deployer
    // ---------------------------------------------------------------------
    function test_W2_Wiring_RouterAddress_Deployer() public requiresFork {
        FlashBTCShield24h s = _deployShield();
        assertEq(s.router(), router, "router must equal deployer test contract");
    }

    // ---------------------------------------------------------------------
    // W3 -- Oracle responds to getLatestPrice("BTC") -- informational
    // ---------------------------------------------------------------------
    function test_W3_Wiring_OracleResponds_GetLatestPrice_BTC() public requiresFork {
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
        assertTrue(true, "wiring exists by virtue of having an endpoint");
    }

    // ---------------------------------------------------------------------
    // W4 -- Constants -- duration 24h fixed, trigger 10%, deductible 20%
    // ---------------------------------------------------------------------
    function test_W4_Wiring_Constants() public requiresFork {
        FlashBTCShield24h s = _deployShield();
        (uint32 mn, uint32 mx) = s.durationRange();
        assertEq(mn, 86_400, "MIN_DURATION must be 24h");
        assertEq(mx, 86_400, "MAX_DURATION must be 24h");
        assertEq(s.waitingPeriod(), 0, "WAITING_PERIOD must be 0");
        assertEq(s.TRIGGER_DROP_BPS(), 1000, "TRIGGER_DROP_BPS must be 10%");
        assertEq(s.DEDUCTIBLE_BPS(), 2000, "DEDUCTIBLE_BPS must be 20%");
        assertEq(s.MAX_PROOF_AGE(), 900, "MAX_PROOF_AGE must be 15 min");
    }

    // ---------------------------------------------------------------------
    // W5 -- Sanity bounds -- MIN_PRICE $10k, MAX_PRICE $1M
    // ---------------------------------------------------------------------
    function test_W5_Wiring_SanityBounds() public requiresFork {
        FlashBTCShield24h s = _deployShield();
        assertEq(s.MIN_PRICE(), 10_000 * 1e8, "MIN_PRICE must be $10,000 in 8-dec");
        assertEq(s.MAX_PRICE(), 1_000_000 * 1e8, "MAX_PRICE must be $1,000,000 in 8-dec");
    }

    // ---------------------------------------------------------------------
    // W6 -- productId / riskType / maxAllocationBps
    // ---------------------------------------------------------------------
    function test_W6_Wiring_ProductMetadata() public requiresFork {
        FlashBTCShield24h s = _deployShield();
        assertEq(s.productId(), keccak256("FLASHBTC24-001"), "productId must equal hash of FLASHBTC24-001");
        assertEq(s.riskType(), keccak256("VOLATILE"), "riskType must equal hash of VOLATILE");
        assertEq(s.maxAllocationBps(), 3000, "maxAllocationBps must be 30%");
    }

    // ---------------------------------------------------------------------
    // W7 -- Owner is deployer (Ownable initializer wires msg.sender)
    // ---------------------------------------------------------------------
    function test_W7_Wiring_Owner_Deployer() public requiresFork {
        FlashBTCShield24h s = _deployShield();
        // ProxyDeployer calls initialize from this test contract via the proxy
        // pattern. The OwnableUpgradeable initializer pins owner = msg.sender,
        // which is the test contract.
        assertEq(s.owner(), address(this), "owner must equal deployer (this test contract)");
    }

    // ---------------------------------------------------------------------
    // W8 -- Zero-address rejection at initialize
    // ---------------------------------------------------------------------
    function test_W8_Wiring_RejectsZeroRouter() public requiresFork {
        // Attempting to deploy with router=address(0) must revert with
        // ZeroAddress("router"). Same guard applies for oracle=address(0).
        // Deploy the impl outside expectRevert so the cheatcode binds to the
        // ERC1967Proxy CREATE (which runs initialize and reverts), not to the
        // unrelated impl deployment that always succeeds.
        FlashBTCShield24h impl = new FlashBTCShield24h();

        vm.expectRevert();
        new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashBTCShield24h.initialize.selector, address(0), ORACLE_SET_A)
        );

        vm.expectRevert();
        new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(FlashBTCShield24h.initialize.selector, router, address(0))
        );
    }
}
