// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FounderVestingV2, IAaveV3PoolReader} from "../../../src/token/FounderVestingV2.sol";

contract FVE2E_Lumina is ERC20 {
    constructor() ERC20("LUMINA", "LUM") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @title FounderVestingV2E2EFlows
/// @notice Sprint Z.2 Phase D — 7 E2E flow scenarios for FounderVestingV2 using
///         vm.mockCall over the real LuminaOracleV2 SET A address and the canonical
///         Aave V3 Sepolia pool to simulate realistic oracle wiring without a fork.
contract FounderVestingV2E2EFlowsTest is Test {
    // ─── Real-network addresses (used to ensure mocks intercept on the correct target) ───
    address constant LUMINA_ORACLE_V2_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;
    address constant AAVE_POOL_SEPOLIA = 0xcc0606b64275c08539770864081D209A8C9b178a;

    FounderVestingV2 vesting;
    FVE2E_Lumina lumina;
    address usdc = address(0xDEAD);
    address founder = makeAddr("founder");

    function setUp() public {
        vm.chainId(8453);
        lumina = new FVE2E_Lumina();
        // Etch dummy bytecode on the oracle + aave pool addresses so the FV V2 constructor's
        // address(0) check passes and external calls land on a contract with code, allowing
        // vm.mockCall to intercept reliably under via_ir.
        vm.etch(LUMINA_ORACLE_V2_SET_A, hex"6080");
        vm.etch(AAVE_POOL_SEPOLIA, hex"6080");
        vesting = new FounderVestingV2(
            LUMINA_ORACLE_V2_SET_A, AAVE_POOL_SEPOLIA, address(lumina), usdc, founder
        );
        lumina.mint(address(vesting), 8_000_000 * 1e18);
    }

    // ─── Helpers ───

    function _mockOracleETHBTC(int256 ethPrice, int256 btcPrice) internal {
        vm.mockCall(
            LUMINA_ORACLE_V2_SET_A,
            abi.encodeWithSelector(bytes4(keccak256("getLatestPrice(bytes32)")), bytes32("ETH")),
            abi.encode(ethPrice)
        );
        vm.mockCall(
            LUMINA_ORACLE_V2_SET_A,
            abi.encodeWithSelector(bytes4(keccak256("getLatestPrice(bytes32)")), bytes32("BTC")),
            abi.encode(btcPrice)
        );
    }

    function _mockAaveRate(uint128 rate) internal {
        IAaveV3PoolReader.ReserveData memory data;
        data.currentVariableBorrowRate = rate;
        vm.mockCall(
            AAVE_POOL_SEPOLIA,
            abi.encodeWithSelector(bytes4(keccak256("getReserveData(address)")), usdc),
            abi.encode(data)
        );
    }

    // ═══════ Tests ═══════

    /// @notice E2E-1: Full happy path with realistic keeper loop polling every 6 hours.
    ///         At hour 24+1 the sustained period elapses (>= 1 day) and the trigger fires.
    function test_E2E_OracleActivation_RealLuminaOracleV2_FullFlow() public {
        // ETH=$5000 (8 dec), BTC=$80,000 (8 dec) → ratio = 0.0625 > 0.05 ✓
        // ETH > $4000 ✓
        _mockOracleETHBTC(int256(5_000 * 1e8), int256(80_000 * 1e8));
        _mockAaveRate(uint128(8e25)); // > 7e25 ✓

        // Pin t0 to a constant via vm.warp so the via_ir optimizer cannot inline
        // `t0 = block.timestamp` and re-read TIMESTAMP at every use site.
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        vesting.checkAltSeason(); // counter starts at t0
        assertEq(vesting.conditionsMetSince(), t0);

        vm.warp(t0 + 6 hours);
        vesting.checkAltSeason();
        vm.warp(t0 + 12 hours);
        vesting.checkAltSeason();
        vm.warp(t0 + 18 hours);
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered(), "must not trigger before 1 day");

        vm.warp(t0 + 1 days + 1);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered(), "must trigger after 1 day sustained");

        // Release the 3 tranches over absolute warps (via_ir caches block.timestamp).
        uint256 trig = vesting.triggerTimestamp();
        vesting.releaseTranche();
        vm.warp(trig + 31 days);
        vesting.releaseTranche();
        vm.warp(trig + 62 days);
        vesting.releaseTranche();

        assertEq(vesting.tranchesReleased(), 3);
        assertEq(lumina.balanceOf(founder), 8_000_000 * 1e18, "founder holds full 8M");
    }

    /// @notice E2E-2: 3-year fallback path — nobody calls checkAltSeason, anyone can
    ///         eventually call triggerFallback() to unlock the 8M.
    function test_E2E_FallbackActivation_AfterThreeYears() public {
        uint256 t0 = vesting.deployedAt() + 1095 days + 1;
        vm.warp(t0);
        vesting.triggerFallback();
        assertTrue(vesting.altSeasonTriggered());

        uint256 trig = vesting.triggerTimestamp();
        vesting.releaseTranche();
        vm.warp(trig + 31 days);
        vesting.releaseTranche();
        vm.warp(trig + 62 days);
        vesting.releaseTranche();

        assertEq(vesting.tranchesReleased(), 3);
        assertEq(lumina.balanceOf(founder), 8_000_000 * 1e18);
    }

    /// @notice E2E-3: Conditions are met on-chain but no keeper polls the contract.
    ///         altSeason never triggers, conditionsMetSince stays 0, tokens stay stuck.
    function test_E2E_NoKeeper_NobodyCalls_TokensRemainStuck() public {
        _mockOracleETHBTC(int256(5_000 * 1e8), int256(80_000 * 1e8));
        _mockAaveRate(uint128(8e25));

        uint256 t0 = 1_000_000;
        vm.warp(t0);
        vm.warp(t0 + 30 days);
        // Nobody called checkAltSeason. State is pristine.
        assertFalse(vesting.altSeasonTriggered(), "no keeper => no trigger");
        assertEq(vesting.conditionsMetSince(), 0, "no keeper => no counter");

        // releaseTranche must revert without a trigger.
        vm.expectRevert(bytes("Not triggered"));
        vesting.releaseTranche();
    }

    /// @notice E2E-4: Manual keeper polls at hour 0 (starts counter) and hour 25
    ///         (>1 day later) — second call triggers.
    function test_E2E_ManualCallsCheckAltSeason_TriggersAfter1Day() public {
        _mockOracleETHBTC(int256(5_000 * 1e8), int256(80_000 * 1e8));
        _mockAaveRate(uint128(8e25));

        uint256 t0 = 1_000_000;
        vm.warp(t0);
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), t0, "counter set at hour 0");
        assertFalse(vesting.altSeasonTriggered());

        vm.warp(t0 + 25 hours);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered(), "must trigger at hour 25 (> 1 day)");
        assertEq(vesting.triggerTimestamp(), t0 + 25 hours);
    }

    /// @notice E2E-5: Flicker scenario — conditions met at hour 0, break at hour 14,
    ///         re-met at hour 16 (counter resets to hour 16), trigger at hour 40 (24h later).
    function test_E2E_FlickerScenario_ConditionsBreakResetCounter() public {
        _mockOracleETHBTC(int256(5_000 * 1e8), int256(80_000 * 1e8));
        _mockAaveRate(uint128(8e25));

        uint256 t0 = 1_000_000;
        vm.warp(t0);
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), t0, "counter set at hour 0");

        // Hour 14: conditions break (ETH=0). With ETH=0 we lose condA AND condB; aave still good ⇒ metCount=1.
        vm.warp(t0 + 14 hours);
        _mockOracleETHBTC(int256(0), int256(80_000 * 1e8));
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0, "counter resets when conditions drop");

        // Hour 16: conditions restored.
        vm.warp(t0 + 16 hours);
        _mockOracleETHBTC(int256(5_000 * 1e8), int256(80_000 * 1e8));
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), t0 + 16 hours, "counter restarts at hour 16");
        assertFalse(vesting.altSeasonTriggered());

        // Hour 40: 24h since hour 16 → trigger.
        vm.warp(t0 + 40 hours);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered(), "triggers 24h after restart");
    }

    /// @notice E2E-6: Oracle reverts on every call → metCount can only come from Aave
    ///         (max 1) → never reaches 2 → conditionsMetSince stays 0, no trigger.
    function test_E2E_OracleRevert_CountersDoNotAdvance() public {
        vm.mockCallRevert(
            LUMINA_ORACLE_V2_SET_A,
            abi.encodeWithSelector(bytes4(keccak256("getLatestPrice(bytes32)")), bytes32("ETH")),
            bytes("ORACLE_DOWN")
        );
        vm.mockCallRevert(
            LUMINA_ORACLE_V2_SET_A,
            abi.encodeWithSelector(bytes4(keccak256("getLatestPrice(bytes32)")), bytes32("BTC")),
            bytes("ORACLE_DOWN")
        );
        _mockAaveRate(uint128(8e25)); // condC ok, but alone => metCount=1

        uint256 t0 = 1_000_000;
        vm.warp(t0);
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0, "metCount=1 cannot start counter");
        assertFalse(vesting.altSeasonTriggered());

        vm.warp(t0 + 1 days + 1);
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0, "still no counter after a day");
        assertFalse(vesting.altSeasonTriggered(), "no trigger when oracle is down");
    }

    /// @notice E2E-7: Owner updates recipient between tranches. Tranche 1 goes to original
    ///         recipient, tranches 2+3 go to the new one. Verifies the recipient update is
    ///         honored by subsequent releaseTranche calls.
    function test_E2E_UpdateRecipient_BetweenTranches() public {
        // Trigger via fallback for deterministic timing.
        uint256 t0 = vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1;
        vm.warp(t0);
        vesting.triggerFallback();
        uint256 trig = vesting.triggerTimestamp();

        // T1 to original founder (X).
        vesting.releaseTranche();
        uint256 xBalanceAfterT1 = lumina.balanceOf(founder);
        assertEq(xBalanceAfterT1, vesting.TRANCHE_AMOUNT(), "X gets tranche 1");

        // Owner is address(this) (deployer = test contract); rotate recipient to Y.
        address newRecipient = makeAddr("newRecipient");
        vesting.updateRecipient(newRecipient);

        // T2 → Y.
        vm.warp(trig + 31 days);
        vesting.releaseTranche();
        assertEq(lumina.balanceOf(newRecipient), vesting.TRANCHE_AMOUNT(), "Y gets tranche 2");

        // T3 → Y (gets remainder).
        vm.warp(trig + 62 days);
        vesting.releaseTranche();
        // After all releases: X balance == TRANCHE_AMOUNT, Y == 8M - TRANCHE_AMOUNT.
        assertEq(lumina.balanceOf(founder), vesting.TRANCHE_AMOUNT(), "X retains exactly tranche 1");
        assertEq(
            lumina.balanceOf(newRecipient),
            8_000_000 * 1e18 - vesting.TRANCHE_AMOUNT(),
            "Y gets remaining 8M - TRANCHE_AMOUNT"
        );
        assertEq(vesting.totalReleased(), 8_000_000 * 1e18);
    }
}
