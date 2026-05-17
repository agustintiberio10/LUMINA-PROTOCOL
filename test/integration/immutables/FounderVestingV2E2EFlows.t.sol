// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVesting, ILuminaOracleReader, IAaveV3PoolReader} from "../../../src/token/FounderVesting.sol";

/// @title FounderVestingV2E2EFlows
/// @notice Sprint FV Phase E -- 10 fork-Sepolia E2E tests for FounderVesting V2.
///         Validates PATH 1 / PATH 2 / PATH 3 full flows + race / flicker /
///         oracle-revert / recipient-update / 3-method balance verification.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
///
///         The on-chain LUMINA token was bricked + cleared after Sprint Z.2,
///         so every test deploys a fresh ERC20 mock + fresh FV in setUp.
///         The SET A oracle (0x8cAbC4...D194) is mocked at the call site via
///         vm.mockCall -- we do not depend on its live price values.
contract FounderVestingV2E2EFlows is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;
    address internal constant AAVE_POOL_SEPOLIA = 0xcc0606b64275c08539770864081D209A8C9b178a;
    address internal constant FOUNDER = 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8;

    // USDC mock address -- only needed by the FV constructor + aave reserve key.
    // The Aave call itself is mocked via vm.mockCall keyed on the FV's `usdc()`
    // immutable, so we use an arbitrary non-zero address here.
    address internal constant USDC_MOCK = address(0xdeadbeef);

    // Mirror FounderVesting events for vm.expectEmit
    event AltSeasonTriggered(uint256 timestamp);
    event OverrideConditionMet(uint256 indexed ethPrice, uint256 timestamp);
    event OverrideConditionLost(uint256 indexed ethPrice, uint256 timestamp);
    event OverrideTriggered(uint256 indexed ethPrice, uint256 timestamp);
    event SustainedPeriodReset(uint256 timestamp);
    event TrancheReleased(uint256 trancheNumber, uint256 amount, address recipient);
    event FallbackTriggered(uint256 timestamp);

    // ===== Skip gracefully if BASE_SEPOLIA_RPC is not configured =====
    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    // ===== Helpers =====
    function _deployFV() internal returns (FounderVesting fv, MockERC20 lumina) {
        lumina = new MockERC20("LUMINA", "LUM");
        fv = new FounderVesting(ORACLE_SET_A, AAVE_POOL_SEPOLIA, address(lumina), USDC_MOCK, FOUNDER);
        lumina.mint(address(fv), 8_000_000e18);
    }

    function _mockPrices(int256 ethPrice, int256 btcPrice) internal {
        vm.mockCall(
            ORACLE_SET_A,
            abi.encodeWithSelector(ILuminaOracleReader.getLatestPrice.selector, bytes32("ETH")),
            abi.encode(ethPrice)
        );
        vm.mockCall(
            ORACLE_SET_A,
            abi.encodeWithSelector(ILuminaOracleReader.getLatestPrice.selector, bytes32("BTC")),
            abi.encode(btcPrice)
        );
    }

    function _mockBorrowRate(uint128 rate) internal {
        IAaveV3PoolReader.ReserveData memory data;
        data.currentVariableBorrowRate = rate;
        vm.mockCall(
            AAVE_POOL_SEPOLIA,
            abi.encodeWithSelector(IAaveV3PoolReader.getReserveData.selector, USDC_MOCK),
            abi.encode(data)
        );
    }

    // ---------------------------------------------------------------------
    // 1. PATH 1 full flow -- real-oracle 2-of-3 sustained 1 day, 3 tranches
    // ---------------------------------------------------------------------
    function test_E2E_Path1_FullFlow_RealOracle_2of3_Sustained1Day() public requiresFork {
        (FounderVesting fv, MockERC20 lumina) = _deployFV();
        // ETH=$4,500, BTC=$90,000 -> ratio = 0.05 exactly (NOT > threshold).
        // Bump ETH so condA satisfied: 4500/90000 = 0.05 -> use 4600/90000 = 0.0511
        _mockPrices(4600e8, 90_000e8);
        _mockBorrowRate(8e25); // 8% > 7% threshold (condC)

        uint256 t0 = block.timestamp;

        // Hour 0: opens sustained period (metCount=3 >= 2; condA/B/C all true)
        fv.checkAltSeason();
        assertGt(fv.conditionsMetSince(), 0, "PATH 1 not armed");
        assertFalse(fv.altSeasonTriggered(), "Should NOT trigger before 1 day");

        // Hour 25: trigger
        vm.warp(t0 + 25 hours);
        vm.expectEmit(false, false, false, false);
        emit AltSeasonTriggered(0);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered(), "PATH 1 should trigger after 1d sustained");

        // Tranche 1 -- immediately at triggerTimestamp + 0
        uint256 tts = fv.triggerTimestamp();
        fv.releaseTranche();
        assertEq(fv.tranchesReleased(), 1);

        // Tranche 2 -- +31d
        vm.warp(tts + 31 days);
        fv.releaseTranche();
        assertEq(fv.tranchesReleased(), 2);

        // Tranche 3 -- +62d
        vm.warp(tts + 62 days);
        fv.releaseTranche();
        assertEq(fv.tranchesReleased(), 3);

        assertEq(lumina.balanceOf(FOUNDER), 8_000_000e18, "Recipient balance must equal 8M exact");
        assertEq(lumina.balanceOf(address(fv)), 0, "FV must be drained");
    }

    // ---------------------------------------------------------------------
    // 2. PATH 2 full flow -- ETH override $5,001 sustained 1 day
    // ---------------------------------------------------------------------
    function test_E2E_Path2_FullFlow_ETHOverride_5001() public requiresFork {
        (FounderVesting fv, MockERC20 lumina) = _deployFV();
        // ETH=$5,001 -> above override threshold ($5,000). Force BTC very high
        // so PATH 1 condA fails (5001/200000 ~ 0.025 < 0.05) and condB also
        // would be true ($5001 > $4000) but condC=false -> metCount=1 -> PATH 1 inactive.
        _mockPrices(5001e8, 200_000e8);
        _mockBorrowRate(5e25); // 5% < 7% -> condC=false

        uint256 t0 = block.timestamp;

        // Hour 0: arms override
        vm.expectEmit(true, false, false, false);
        emit OverrideConditionMet(5001e8, 0);
        fv.checkAltSeason();
        assertGt(fv.overrideMetSince(), 0, "PATH 2 not armed");
        assertEq(fv.conditionsMetSince(), 0, "PATH 1 should NOT arm at metCount=1");
        assertFalse(fv.altSeasonTriggered());

        // Hour 25: PATH 2 trigger
        vm.warp(t0 + 25 hours);
        vm.expectEmit(true, false, false, false);
        emit OverrideTriggered(5001e8, 0);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());

        uint256 tts = fv.triggerTimestamp();
        fv.releaseTranche();
        vm.warp(tts + 31 days);
        fv.releaseTranche();
        vm.warp(tts + 62 days);
        fv.releaseTranche();

        assertEq(lumina.balanceOf(FOUNDER), 8_000_000e18);
    }

    // ---------------------------------------------------------------------
    // 3. PATH 3 fallback -- 3 years + 1s, callable by anyone
    // ---------------------------------------------------------------------
    function test_E2E_Path3_Fallback_3Years() public requiresFork {
        (FounderVesting fv, MockERC20 lumina) = _deployFV();
        uint256 deployedAt = fv.deployedAt();

        // Warp past FALLBACK_DURATION (1095 days = 94608000 s)
        vm.warp(deployedAt + 1095 days + 1);

        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        vm.expectEmit(false, false, false, false);
        emit FallbackTriggered(0);
        fv.triggerFallback();
        assertTrue(fv.altSeasonTriggered(), "Fallback must trigger");

        uint256 tts = fv.triggerTimestamp();
        fv.releaseTranche();
        vm.warp(tts + 31 days);
        fv.releaseTranche();
        vm.warp(tts + 62 days);
        fv.releaseTranche();

        assertEq(lumina.balanceOf(FOUNDER), 8_000_000e18);
    }

    // ---------------------------------------------------------------------
    // 4. PATH 1 vs PATH 2 race -- PATH 1 wins (evaluated first in code order)
    // ---------------------------------------------------------------------
    function test_E2E_Path1_And_Path2_Race() public requiresFork {
        (FounderVesting fv,) = _deployFV();
        // ETH=$5,500, BTC=$100,000 -> ratio 0.055 > 0.05 (condA), ETH>$4000 (condB),
        // borrow 8e25 (condC). PATH 2 override also satisfied ($5500 > $5000).
        _mockPrices(5500e8, 100_000e8);
        _mockBorrowRate(8e25);

        uint256 t0 = block.timestamp;

        // Hour 0: both conditionsMetSince + overrideMetSince should be set
        fv.checkAltSeason();
        assertGt(fv.conditionsMetSince(), 0, "PATH 1 armed");
        assertGt(fv.overrideMetSince(), 0, "PATH 2 armed");

        // Hour 25: PATH 1 evaluated first per checkAltSeason() source order ->
        // AltSeasonTriggered fires (and `return` short-circuits PATH 2 block).
        vm.warp(t0 + 25 hours);
        vm.recordLogs();
        fv.checkAltSeason();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 altSig = keccak256("AltSeasonTriggered(uint256)");
        bytes32 ovrSig = keccak256("OverrideTriggered(uint256,uint256)");
        bool sawAlt;
        bool sawOverrideTrigger;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == altSig) sawAlt = true;
            if (entries[i].topics[0] == ovrSig) sawOverrideTrigger = true;
        }
        assertTrue(sawAlt, "PATH 1 AltSeasonTriggered must fire (evaluated first)");
        assertFalse(sawOverrideTrigger, "PATH 2 must NOT fire when PATH 1 wins the race");
        assertTrue(fv.altSeasonTriggered());
    }

    // ---------------------------------------------------------------------
    // 5. No calls to checkAltSeason -> never triggers despite met conditions
    // ---------------------------------------------------------------------
    function test_E2E_NoCalls_TokensStuck() public requiresFork {
        (FounderVesting fv,) = _deployFV();
        _mockPrices(5500e8, 100_000e8);
        _mockBorrowRate(8e25);

        // 30 days pass -- no one calls checkAltSeason
        vm.warp(block.timestamp + 30 days);
        assertFalse(fv.altSeasonTriggered(), "Trigger requires explicit call");
        assertEq(fv.conditionsMetSince(), 0, "Counter never advances without call");
    }

    // ---------------------------------------------------------------------
    // 6. PATH 1 flicker -- drop condC, reset, re-arm, trigger at 40h
    // ---------------------------------------------------------------------
    function test_E2E_Flicker_PATH1_ResetsCounter() public requiresFork {
        (FounderVesting fv,) = _deployFV();
        uint256 t0 = block.timestamp;

        // Hour 0: 2-of-3 met (condA + condB + condC all true)
        _mockPrices(4600e8, 90_000e8);
        _mockBorrowRate(8e25);
        fv.checkAltSeason();
        uint256 firstMetSince = fv.conditionsMetSince();
        assertEq(firstMetSince, t0, "First arm at hour 0");

        // Hour 14: drop condC to 6e25 (below 7%) -> metCount=2 still (condA+condB)
        // So 2-of-3 still met -> counter SHOULD NOT reset. To force a reset we
        // need to break TWO conditions. Drop BTC to make ratio fail AND borrow.
        // Per the spec: "drop condC to 6e25, conditionsMetSince = 0".
        // For that to be the trigger reset, we must also break condA OR condB.
        // We choose: keep prices, drop oracle so ratio undefined -> condA=condB=false,
        // then metCount=0 + condC=false -> reset fires.
        // ----- Re-read of spec: it says "Hour 14: drop condC to 6e25 ...
        //       call checkAltSeason -> SustainedPeriodReset event, conditionsMetSince=0".
        //       That assumes metCount<2 after the drop. With condA+condB still true
        //       (4600/90000=0.0511, ETH>$4000), metCount=2 even with condC=false.
        //       So we must also break condB. Set ETH=$3000 to break condB AND
        //       break condA (3000/90000=0.033 < 0.05). Plus drop borrow.
        vm.warp(t0 + 14 hours);
        _mockPrices(3000e8, 90_000e8);
        _mockBorrowRate(6e25);
        vm.expectEmit(false, false, false, false);
        emit SustainedPeriodReset(0);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0, "Counter must reset");

        // Hour 16: re-arm with all conditions
        vm.warp(t0 + 16 hours);
        _mockPrices(4600e8, 90_000e8);
        _mockBorrowRate(8e25);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), t0 + 16 hours, "Counter re-armed at hour 16");

        // Hour 40 (= 16+24): triggers
        vm.warp(t0 + 40 hours);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered(), "PATH 1 must trigger after re-arm + 24h");
    }

    // ---------------------------------------------------------------------
    // 7. PATH 2 flicker -- drop ETH below override, reset, re-arm, trigger
    // ---------------------------------------------------------------------
    function test_E2E_Flicker_PATH2_ResetsOverride() public requiresFork {
        (FounderVesting fv,) = _deployFV();
        // Force PATH 1 to never arm: make borrow rate low + BTC very high so
        // metCount<2 throughout.
        _mockBorrowRate(2e25);
        uint256 t0 = block.timestamp;

        // Hour 0: ETH=$5100 (override met)
        _mockPrices(5100e8, 1_000_000e8); // ratio 0.0051 -> condA=false
        vm.expectEmit(true, false, false, false);
        emit OverrideConditionMet(5100e8, 0);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), t0, "PATH 2 armed at hour 0");

        // Hour 14: ETH=$4900 (override lost)
        vm.warp(t0 + 14 hours);
        _mockPrices(4900e8, 1_000_000e8);
        vm.expectEmit(true, false, false, false);
        emit OverrideConditionLost(4900e8, 0);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), 0, "PATH 2 must reset");

        // Hour 16: ETH=$5100 again
        vm.warp(t0 + 16 hours);
        _mockPrices(5100e8, 1_000_000e8);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), t0 + 16 hours, "PATH 2 re-armed");

        // Hour 40: triggers
        vm.warp(t0 + 40 hours);
        vm.expectEmit(true, false, false, false);
        emit OverrideTriggered(5100e8, 0);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
    }

    // ---------------------------------------------------------------------
    // 8. Oracle revert -- try/catch swallows it, neither counter advances
    // ---------------------------------------------------------------------
    function test_E2E_OracleRevert_NoAdvance() public requiresFork {
        (FounderVesting fv,) = _deployFV();
        // Make oracle revert on ETH + BTC queries
        vm.mockCallRevert(
            ORACLE_SET_A,
            abi.encodeWithSelector(ILuminaOracleReader.getLatestPrice.selector, bytes32("ETH")),
            "oracle-down"
        );
        vm.mockCallRevert(
            ORACLE_SET_A,
            abi.encodeWithSelector(ILuminaOracleReader.getLatestPrice.selector, bytes32("BTC")),
            "oracle-down"
        );
        // Also break Aave so condC=false and we know metCount=0.
        vm.mockCallRevert(
            AAVE_POOL_SEPOLIA, abi.encodeWithSelector(IAaveV3PoolReader.getReserveData.selector, USDC_MOCK), "aave-down"
        );

        uint256 t0 = block.timestamp;
        fv.checkAltSeason();
        vm.warp(t0 + 12 hours);
        fv.checkAltSeason();
        vm.warp(t0 + 30 hours);
        fv.checkAltSeason();

        assertEq(fv.conditionsMetSince(), 0, "PATH 1 never advances when oracle reverts");
        assertEq(fv.overrideMetSince(), 0, "PATH 2 never advances when oracle reverts");
        assertFalse(fv.altSeasonTriggered());
    }

    // ---------------------------------------------------------------------
    // 9. Update recipient between tranches -- tranche 2/3 go to wallet Y
    // ---------------------------------------------------------------------
    function test_E2E_UpdateRecipient_BetweenTranches() public requiresFork {
        (FounderVesting fv, MockERC20 lumina) = _deployFV();
        _mockPrices(4600e8, 90_000e8);
        _mockBorrowRate(8e25);

        uint256 t0 = block.timestamp;
        fv.checkAltSeason();
        vm.warp(t0 + 25 hours);
        fv.checkAltSeason();
        uint256 tts = fv.triggerTimestamp();

        // Tranche 1 -> founder (recipient at deploy time)
        fv.releaseTranche();
        uint256 trancheAmt = fv.TRANCHE_AMOUNT();
        assertEq(lumina.balanceOf(FOUNDER), trancheAmt, "Tranche 1 goes to founder");

        // Owner updates recipient to walletY
        address walletY = makeAddr("walletY");
        fv.updateRecipient(walletY);

        // Tranche 2 -> walletY
        vm.warp(tts + 31 days);
        fv.releaseTranche();
        assertEq(lumina.balanceOf(walletY), trancheAmt);

        // Tranche 3 -> walletY (gets the remainder for rounding-dust accounting)
        vm.warp(tts + 62 days);
        fv.releaseTranche();

        uint256 expectedY = 8_000_000e18 - trancheAmt;
        assertEq(lumina.balanceOf(FOUNDER), trancheAmt, "Founder keeps tranche 1 only");
        assertEq(lumina.balanceOf(walletY), expectedY, "WalletY gets tranche 2+3 (incl. dust)");
    }

    // ---------------------------------------------------------------------
    // 10. Triple balance check -- balanceOf, getStatus(), 3 TrancheReleased events
    // ---------------------------------------------------------------------
    function test_E2E_BalanceCheck_3Methods() public requiresFork {
        (FounderVesting fv, MockERC20 lumina) = _deployFV();
        _mockPrices(4600e8, 90_000e8);
        _mockBorrowRate(8e25);

        uint256 t0 = block.timestamp;
        fv.checkAltSeason();
        vm.warp(t0 + 25 hours);
        fv.checkAltSeason();
        uint256 tts = fv.triggerTimestamp();

        uint256 trancheAmt = fv.TRANCHE_AMOUNT();
        uint256 totalAmt = fv.TOTAL_AMOUNT();
        uint256 lastTrancheAmt = totalAmt - 2 * trancheAmt;

        // Tranche 1
        vm.expectEmit(true, true, true, true);
        emit TrancheReleased(1, trancheAmt, FOUNDER);
        fv.releaseTranche();

        // Tranche 2
        vm.warp(tts + 31 days);
        vm.expectEmit(true, true, true, true);
        emit TrancheReleased(2, trancheAmt, FOUNDER);
        fv.releaseTranche();

        // Tranche 3 (gets the remainder)
        vm.warp(tts + 62 days);
        vm.expectEmit(true, true, true, true);
        emit TrancheReleased(3, lastTrancheAmt, FOUNDER);
        fv.releaseTranche();

        // Method 1: balanceOf
        assertEq(lumina.balanceOf(FOUNDER), totalAmt, "balanceOf must equal 8M");

        // Method 2: getStatus()
        (,, uint256 _tranchesReleased, uint256 _totalReleased,,,,) = fv.getStatus();
        assertEq(_tranchesReleased, 3, "getStatus tranchesReleased=3");
        assertEq(_totalReleased, totalAmt, "getStatus totalReleased=8M");
    }
}

// =========================================================================
// Minimal ERC20 mock -- only the bits FounderVesting touches (transfer + balanceOf).
// We avoid using LuminaTokenV2 because (a) it requires proxy init + role wiring,
// and (b) the on-chain LUMINA proxy was bricked + blanked after Sprint Z.2.
// =========================================================================
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "INSUFF");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "INSUFF");
        require(allowance[from][msg.sender] >= amount, "ALLOW");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
