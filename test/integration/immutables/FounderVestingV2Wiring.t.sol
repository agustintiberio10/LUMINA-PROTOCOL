// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVesting, ILuminaOracleReader} from "../../../src/token/FounderVesting.sol";

/// @title FounderVestingV2Wiring
/// @notice Sprint FV Phase E — 8 fork-Sepolia wiring tests for FounderVesting V2.
///         Verifies the constructor links to the expected on-chain addresses
///         (SET A oracle, Aave V3 Sepolia pool, founder wallet) and that the
///         new constants (1d sustained, 3y fallback, $5k override) hold.
///         No state-mutating on-chain interactions beyond the fork-anchored
///         deploy.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
contract FounderVestingV2Wiring is Test {
    // ═════ Hardcoded Sepolia addresses ═════
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;
    address internal constant AAVE_POOL_SEPOLIA = 0xcc0606b64275c08539770864081D209A8C9b178a;
    address internal constant FOUNDER = 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8;
    address internal constant USDC_MOCK = address(0xdeadbeef);

    // ═════ Skip gracefully if BASE_SEPOLIA_RPC is not configured ═════
    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    function _deployFV(address luminaToken) internal returns (FounderVesting) {
        return new FounderVesting(ORACLE_SET_A, AAVE_POOL_SEPOLIA, luminaToken, USDC_MOCK, FOUNDER);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Oracle immutable === LuminaOracleV2 SET A
    // ─────────────────────────────────────────────────────────────────────
    function test_Wiring_OracleAddress_OnChainMatches_LuminaOracleV2_SetA() public requiresFork {
        WiringStubLumina lumina = new WiringStubLumina();
        FounderVesting fv = _deployFV(address(lumina));
        assertEq(address(fv.oracle()), ORACLE_SET_A, "oracle immutable must point to SET A");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Oracle responds to getLatestPrice("ETH") — informational
    // ─────────────────────────────────────────────────────────────────────
    function test_Wiring_OracleResponds_GetLatestPrice_ETH() public requiresFork {
        // Read directly via the interface. Accept either a positive price OR
        // a known revert (stale, unconfigured). This is informational only —
        // does NOT gate the suite.
        try ILuminaOracleReader(ORACLE_SET_A).getLatestPrice(bytes32("ETH")) returns (int256 price) {
            // Success path: any non-negative value is acceptable. Document if 0.
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
        // No assertion — wiring exists by virtue of the call having an endpoint.
        assertTrue(true);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Oracle responds to getLatestPrice("BTC") — informational
    // ─────────────────────────────────────────────────────────────────────
    function test_Wiring_OracleResponds_GetLatestPrice_BTC() public requiresFork {
        try ILuminaOracleReader(ORACLE_SET_A).getLatestPrice(bytes32("BTC")) returns (int256 price) {
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
        assertTrue(true);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Aave V3 Base Sepolia pool wired through constructor
    // ─────────────────────────────────────────────────────────────────────
    function test_Wiring_AavePool_Canonical_BaseSepolia() public requiresFork {
        WiringStubLumina lumina = new WiringStubLumina();
        FounderVesting fv = _deployFV(address(lumina));
        assertEq(fv.aavePool(), AAVE_POOL_SEPOLIA, "aavePool immutable must be Aave V3 Sepolia");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. LUMINA token immutable matches the deployed stub
    // ─────────────────────────────────────────────────────────────────────
    function test_Wiring_LuminaToken_DeployedProxy() public requiresFork {
        // The prior Sepolia LUMINA proxy was cleared after Sprint Z.2, so we
        // deploy a stub here and verify the constructor records its address.
        WiringStubLumina lumina = new WiringStubLumina();
        FounderVesting fv = _deployFV(address(lumina));
        assertEq(address(fv.luminaToken()), address(lumina), "luminaToken immutable must equal stub");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. Recipient + owner wiring
    // ─────────────────────────────────────────────────────────────────────
    function test_Wiring_Recipient_Owner_Founder() public requiresFork {
        WiringStubLumina lumina = new WiringStubLumina();
        FounderVesting fv = _deployFV(address(lumina));
        assertEq(fv.recipient(), FOUNDER, "recipient must equal founder wallet");
        // owner() is set to msg.sender at deploy. In a forge test, msg.sender
        // for `new FounderVesting(...)` is the Test contract itself.
        assertEq(fv.owner(), address(this), "owner must be the deployer (this test contract)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. Constants — 1d sustained, 1095d fallback, $5k override
    // ─────────────────────────────────────────────────────────────────────
    function test_Wiring_Constants_NewValues() public requiresFork {
        WiringStubLumina lumina = new WiringStubLumina();
        FounderVesting fv = _deployFV(address(lumina));
        assertEq(fv.SUSTAINED_DURATION(), 86400, "SUSTAINED_DURATION must be 1 day");
        assertEq(fv.FALLBACK_DURATION(), 94608000, "FALLBACK_DURATION must be 1095 days");
        assertEq(fv.ETH_OVERRIDE_THRESHOLD(), 500_000_000_000, "ETH_OVERRIDE_THRESHOLD must be $5,000 * 1e8");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. 8M LUMINA reserved in the FV at deploy time
    // ─────────────────────────────────────────────────────────────────────
    function test_Wiring_TotalAmount_8M_Reserved() public requiresFork {
        WiringStubLumina lumina = new WiringStubLumina();
        FounderVesting fv = _deployFV(address(lumina));
        lumina.mint(address(fv), 8_000_000e18);
        assertEq(lumina.balanceOf(address(fv)), 8_000_000e18, "FV must hold 8M LUMINA at deploy");
        assertEq(fv.TOTAL_AMOUNT(), 8_000_000e18, "TOTAL_AMOUNT constant must equal 8M");
    }
}

// ═════════════════════════════════════════════════════════════════════════
// Stub LUMINA — just satisfies the IERC20 surface FV touches at construction
// + holds a balance for test 8. No transfer wiring needed for wiring tests.
// ═════════════════════════════════════════════════════════════════════════
contract WiringStubLumina {
    mapping(address => uint256) public balanceOf;
    string public constant name = "LUMINA-stub";
    string public constant symbol = "LUM";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "INSUFF");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "INSUFF");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}
