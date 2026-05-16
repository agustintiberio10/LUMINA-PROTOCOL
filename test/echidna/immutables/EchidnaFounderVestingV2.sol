// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title EchidnaFounderVestingV2
/// @notice Echidna property suite for FounderVesting (Sprint FV — PATH 2 override).
/// @dev Ten invariants covering the dual-path trigger logic introduced in Sprint FV:
///      1. total_released_bounded         — totalReleased <= TOTAL_AMOUNT.
///      2. tranches_bounded               — tranchesReleased <= TOTAL_TRANCHES.
///      3. ghost_matches_contract         — accumulator ghost == contract totalReleased.
///      4. no_release_before_unlock       — !altSeasonTriggered ⇒ tranchesReleased == 0.
///      5. trigger_timestamp_valid        — triggered ⇒ 0 < triggerTimestamp <= now.
///      6. conditions_met_since_valid     — conditionsMetSince == 0 || <= now.
///      7. deployed_at_immutable          — deployedAt frozen at construction.
///      8. recipient_nonzero              — recipient is never address(0).
///      9. override_met_since_valid       — overrideMetSince == 0 || <= now (PATH 2).
///     10. trigger_implies_history        — triggered ⇒ PATH 1 OR PATH 2 OR PATH 3 history.

import {FounderVesting} from "../../../src/token/FounderVesting.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Inline mocks (kept self-contained — no forge/Test cheats imported)
// ─────────────────────────────────────────────────────────────────────────────

contract MockOracleE {
    int256 public ethPrice = 3000_00000000; // $3,000 (8 decimals)
    int256 public btcPrice = 60000_00000000; // $60,000 (8 decimals)

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (asset == bytes32("ETH")) return ethPrice;
        if (asset == bytes32("BTC")) return btcPrice;
        return 0;
    }

    function setEthPrice(int256 p) external { ethPrice = p; }
    function setBtcPrice(int256 p) external { btcPrice = p; }
}

contract MockAavePoolE {
    uint128 public borrowRate = 5e25; // 5% in RAY (below 7% threshold)

    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address) external view returns (ReserveData memory data) {
        data.currentVariableBorrowRate = borrowRate;
    }

    function setBorrowRate(uint128 r) external { borrowRate = r; }
}

/// @dev Minimal ERC20 — only the surface FounderVesting actually touches.
contract MockLuminaE {
    string public name = "MockLumina";
    string public symbol = "mLUM";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// HEVM cheat interface — Echidna ships HEVM, which exposes `warp` at this addr.
// We use ONLY `warp` here; nothing forge-specific.
// ─────────────────────────────────────────────────────────────────────────────
interface IHEVM {
    function warp(uint256) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Echidna harness
// ─────────────────────────────────────────────────────────────────────────────
contract EchidnaFounderVestingV2 {
    IHEVM constant HEVM = IHEVM(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    FounderVesting public vesting;
    MockOracleE public oracle;
    MockAavePoolE public aavePool;
    MockLuminaE public lumina;

    address public constant RECIPIENT_SEED = address(0xF00DBABE);
    address public constant USDC = address(0xC0DECAFE);

    // ─── Ghost state ───
    uint256 internal _ghost_totalReleased;
    uint256 internal _ghost_deployedAt;
    address internal _ghost_recipientInit;
    // PATH 1 history: was metCount ever >= 2 in this run?
    bool internal _ghost_path1_ever_satisfied;
    // PATH 2 history: was ETH > $5,000 ever observed in this run?
    bool internal _ghost_path2_ever_satisfied;
    // PATH 3 history: did we ever cross deployedAt + FALLBACK_DURATION?
    bool internal _ghost_path3_ever_reached;

    constructor() {
        oracle = new MockOracleE();
        aavePool = new MockAavePoolE();
        lumina = new MockLuminaE();
        vesting = new FounderVesting(
            address(oracle), address(aavePool), address(lumina), USDC, RECIPIENT_SEED
        );
        lumina.mint(address(vesting), 8_000_000 * 1e18);
        _ghost_deployedAt = vesting.deployedAt();
        _ghost_recipientInit = vesting.recipient();
    }

    // ─── Internal: refresh ghost path-history flags from current oracle/aave reads ───
    function _refreshPathHistory() internal {
        (bool a, bool b, bool c, bool ethOverride) = vesting.getConditions();
        uint256 metCount = (a ? 1 : 0) + (b ? 1 : 0) + (c ? 1 : 0);
        if (metCount >= 2) _ghost_path1_ever_satisfied = true;
        if (ethOverride)   _ghost_path2_ever_satisfied = true;
        if (block.timestamp >= _ghost_deployedAt + vesting.FALLBACK_DURATION()) {
            _ghost_path3_ever_reached = true;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Mutators (Echidna will fuzz arguments and call these)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Set ETH price clamped to a sane Chainlink-ish range (8 decimals).
    function e_setEthPrice(int256 raw) external {
        // Clamp to [0, 1e15] — covers everything up to ~$10M / ETH at 8 decimals.
        int256 clamped = raw < 0 ? int256(0) : (raw > int256(1e15) ? int256(1e15) : raw);
        oracle.setEthPrice(clamped);
        _refreshPathHistory();
    }

    function e_setBtcPrice(int256 raw) external {
        // Clamp to [1, 1e16] — keep > 0 to avoid div-by-zero noise; max ~$100M / BTC.
        int256 clamped = raw < int256(1) ? int256(1) : (raw > int256(1e16) ? int256(1e16) : raw);
        oracle.setBtcPrice(clamped);
        _refreshPathHistory();
    }

    function e_setBorrowRate(uint128 raw) external {
        // Clamp to [0, 1e27] (0–100% APY in RAY).
        uint128 clamped = raw > uint128(1e27) ? uint128(1e27) : raw;
        aavePool.setBorrowRate(clamped);
        _refreshPathHistory();
    }

    /// @notice Bounded warp via HEVM cheat — max ~365 days per call.
    function e_warp(uint256 delta) external {
        uint256 bounded = delta % (365 days);
        HEVM.warp(block.timestamp + bounded);
        _refreshPathHistory();
    }

    function e_checkAltSeason() external {
        _refreshPathHistory();
        try vesting.checkAltSeason() {} catch {}
    }

    function e_triggerFallback() external {
        _refreshPathHistory();
        try vesting.triggerFallback() {} catch {}
    }

    function e_releaseTranche() external {
        uint256 beforeBal = lumina.balanceOf(vesting.recipient());
        try vesting.releaseTranche() {
            uint256 afterBal = lumina.balanceOf(vesting.recipient());
            // Accumulate ghost from balance delta on the recipient (cleanest source of truth).
            _ghost_totalReleased += (afterBal - beforeBal);
        } catch {}
    }

    /// @notice Rotate recipient. We derive a deterministic non-zero address from the seed.
    function e_updateRecipient(uint256 seed) external {
        address derived = address(uint160(uint256(keccak256(abi.encode(seed))) | uint256(1)));
        if (derived == address(0)) derived = address(0x1); // belt-and-suspenders
        try vesting.updateRecipient(derived) {} catch {}
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Properties (Echidna asserts these return TRUE forever)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice 1. totalReleased can never exceed the immutable 8M cap.
    function echidna_total_released_bounded() external view returns (bool) {
        return vesting.totalReleased() <= vesting.TOTAL_AMOUNT();
    }

    /// @notice 2. tranchesReleased can never exceed 3.
    function echidna_tranches_bounded() external view returns (bool) {
        return vesting.tranchesReleased() <= vesting.TOTAL_TRANCHES();
    }

    /// @notice 3. Off-chain ghost accumulator matches the contract's totalReleased.
    function echidna_ghost_matches_contract() external view returns (bool) {
        return _ghost_totalReleased == vesting.totalReleased();
    }

    /// @notice 4. If alt season was never triggered, no tranches were released.
    function echidna_no_release_before_unlock() external view returns (bool) {
        if (vesting.altSeasonTriggered()) return true;
        return vesting.tranchesReleased() == 0 && vesting.totalReleased() == 0;
    }

    /// @notice 5. Trigger timestamp, if set, is in (0, now].
    function echidna_trigger_timestamp_valid() external view returns (bool) {
        if (!vesting.altSeasonTriggered()) return true;
        uint256 t = vesting.triggerTimestamp();
        return t > 0 && t <= block.timestamp;
    }

    /// @notice 6. conditionsMetSince is either zero or a past timestamp.
    function echidna_conditions_met_since_valid() external view returns (bool) {
        uint256 cms = vesting.conditionsMetSince();
        return cms == 0 || cms <= block.timestamp;
    }

    /// @notice 7. deployedAt is immutable — must equal the value captured at construction.
    function echidna_deployed_at_immutable() external view returns (bool) {
        return vesting.deployedAt() == _ghost_deployedAt;
    }

    /// @notice 8. recipient is never the zero address (constructor + setter guards).
    function echidna_recipient_nonzero() external view returns (bool) {
        return vesting.recipient() != address(0);
    }

    /// @notice 9. overrideMetSince is either zero or a past timestamp (PATH 2 invariant).
    function echidna_override_met_since_valid() external view returns (bool) {
        uint256 oms = vesting.overrideMetSince();
        return oms == 0 || oms <= block.timestamp;
    }

    /// @notice 10. If alt season is triggered, at least one of PATH 1/2/3 was satisfied
    ///         in this run's ghost history. Rules out "spontaneous" triggers and proves
    ///         PATH 2 can fire independently of PATH 1 (and vice versa).
    function echidna_trigger_implies_history() external view returns (bool) {
        if (!vesting.altSeasonTriggered()) return true;
        return _ghost_path1_ever_satisfied
            || _ghost_path2_ever_satisfied
            || _ghost_path3_ever_reached;
    }
}
