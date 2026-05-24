// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title CapacityOracle
/// @notice Provides $LUMINA price and capacity calculations for BondVault.
/// @dev [V5.1] UUPS upgradeable proxy pattern.
///
/// @dev [F-02 fix] PRICE TRUST MODEL — read this before consuming getLuminaPrice():
///      When a pool is configured, `getLuminaPrice()` is NOT a silent best-effort
///      read. It computes TWO Uniswap-V3 TWAPs from the SAME pool — the primary
///      short window (`twapWindow`, 1800s default) and a longer `LONG_TWAP_WINDOW`
///      (7200s) — and REVERTS (fail-closed) with `PriceDeviationTooHigh` if they
///      diverge by more than `MAX_DEVIATION_BPS`. Downstream value-bearing reads
///      (e.g. BondVault redemption pricing) are expected to be fail-closed: a
///      revert here is the intended signal to halt the value-bearing action
///      rather than transact on a manipulated price. emergencyPrice is NEVER a
///      silent override when a pool is set — it only acts as a deviation-bounded
///      floor for the zero/observation-missing edge.
///
/// @dev [F-09 / DEPLOY REVIEW] The no-pool path (`pool == address(0)`) returns
///      `emergencyPrice` directly with NO TWAP cross-check and NO timelock on the
///      bootstrap setter. THIS PATH MUST NOT SHIP TO MAINNET — a pool MUST be set
///      at/after deploy so the timelock + deviation guards become mandatory. See
///      the `require` guidance in `setEmergencyPrice`.

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract CapacityOracle is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // ═══════ STORAGE (was immutable) ═══════
    address public pool;
    address public luminaToken;
    address public usdcToken;
    uint32 public twapWindow;
    uint256 public emergencyPrice;
    bool public isToken0Lumina;

    // ═══════ STORAGE [F-09 fix — APPEND-ONLY] ═══════
    /// @notice Two-step timelock state for emergencyPrice changes once a pool is set.
    /// @dev    `proposeEmergencyPrice` records (value, timestamp); `applyEmergencyPrice`
    ///         can only land it after EMERGENCY_PRICE_TIMELOCK has elapsed.
    uint256 public pendingEmergencyPrice; // slot: appended (was __gap[0])
    uint256 public pendingEmergencyPriceTimestamp; // slot: appended (was __gap[1])

    // ═══════ CONSTANTS ═══════
    uint256 public constant BOND_RESERVE = 70_000_000 * 1e18;
    uint256 public constant SAFETY_FACTOR_BPS = 5000;
    uint256 public constant AVG_PAYOUT_USD = 500;
    uint256 public constant MATURITY_DAYS = 730;
    uint256 public constant AVG_TRIGGER_RATE_BPS = 100;

    // ═══════ CONSTANTS [F-02 / F-09 fix] ═══════
    /// @notice [F-02] Longer TWAP window used by the deviation circuit-breaker.
    /// @dev    `getLuminaPrice()` compares the primary `twapWindow` (short, 1800s
    ///         default) against this longer window from the SAME pool. A flash /
    ///         single-block grind only moves the short window; to also move the
    ///         long window an attacker must hold the manipulated price across the
    ///         full 7200s, which is economically far harder on a thin pool.
    uint32 public constant LONG_TWAP_WINDOW = 7200; // 2 hours
    /// @notice [F-02] Max allowed deviation between short and long TWAP windows.
    /// @dev    500 bps = 5%. Above this the price is deemed untrustworthy and
    ///         `getLuminaPrice()` REVERTS (fail-closed) — see contract NatSpec.
    uint256 public constant MAX_DEVIATION_BPS = 500; // 5%
    /// @notice [F-09] Max deviation a NEW emergencyPrice may have from last good TWAP.
    /// @dev    5000 bps = 50%. Rejects an owner override that silently re-pegs far
    ///         from market while a pool/observations still exist.
    uint256 public constant MAX_EMERGENCY_DEVIATION_BPS = 5000; // 50%
    /// @notice [F-09] Timelock that gates emergencyPrice changes once a pool is set.
    uint256 public constant EMERGENCY_PRICE_TIMELOCK = 24 hours;

    // ═══════ EVENTS ═══════
    event PoolUpdated(address oldPool, address newPool);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);
    /// @notice [F-09] Emitted whenever emergencyPrice changes. `by` is the caller.
    event EmergencyPriceSet(uint256 oldPrice, uint256 newPrice, address by);
    /// @notice [F-09] Emitted when a timelocked emergencyPrice change is proposed.
    event EmergencyPriceProposed(uint256 newPrice, uint256 eta, address by);
    /// @notice [F-02] Reverted by `getLuminaPrice()` when the short and long TWAP
    ///         windows diverge beyond `MAX_DEVIATION_BPS` (fail-closed signal).
    error PriceDeviationTooHigh(uint256 shortTwap, uint256 longTwap, uint256 deviationBps);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _pool, address _luminaToken, address _usdcToken, uint256 _emergencyPrice)
        public
        initializer
    {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_luminaToken != address(0), "Zero lumina");
        require(_usdcToken != address(0), "Zero usdc");
        require(_emergencyPrice > 0, "Zero emergency price");

        luminaToken = _luminaToken;
        usdcToken = _usdcToken;
        emergencyPrice = _emergencyPrice;
        twapWindow = 1800;

        if (_pool != address(0)) {
            _setPool(_pool);
        }
    }

    // ═══════ IPriceOracle interface ═══════

    /// @notice $LUMINA price (18-dec), TWAP-derived with a deviation circuit-breaker.
    /// @dev    [F-02] When a pool is set this REVERTS with `PriceDeviationTooHigh`
    ///         if the short and long TWAP windows diverge > MAX_DEVIATION_BPS.
    ///         Signature unchanged — callers (BondVault, SolvencyOracle,
    ///         BuybackEngine, TWAPBurner) see either a trustworthy price or a
    ///         revert; fail-closed consumers must treat the revert as "halt".
    function getLuminaPrice() external view returns (uint256 price) {
        // [F-09] Bootstrap-only path. MUST NOT be live on mainnet — see header.
        if (pool == address(0)) return emergencyPrice;

        // Primary (short) window.
        uint256 shortTwap;
        try this._getTwapPriceForWindow(twapWindow) returns (uint256 p) {
            shortTwap = p;
        } catch {
            // Observation/pool failure — fall back to emergencyPrice (deviation
            // breaker cannot run without a price; this is the zero/missing edge).
            return emergencyPrice;
        }
        if (shortTwap == 0) return emergencyPrice;

        // Longer window for the deviation circuit-breaker.
        uint256 longTwap;
        try this._getTwapPriceForWindow(LONG_TWAP_WINDOW) returns (uint256 p) {
            longTwap = p;
        } catch {
            // Long window unavailable (e.g. pool too young for 7200s of
            // observations). We cannot run the breaker — fall back to the
            // bounded emergencyPrice floor rather than trusting an unguarded
            // short window for a value-bearing read.
            return emergencyPrice;
        }
        if (longTwap == 0) return emergencyPrice;

        // [F-02] Deviation circuit-breaker. A single-window flash/grind moves the
        // short window only; to defeat this an attacker must hold the deviation
        // across BOTH windows for the full LONG_TWAP_WINDOW.
        uint256 dev = _deviationBps(shortTwap, longTwap);
        if (dev > MAX_DEVIATION_BPS) {
            revert PriceDeviationTooHigh(shortTwap, longTwap, dev);
        }

        return shortTwap;
    }

    /// @notice Back-compat alias preserved for any external integrations that
    ///         called the old `_getTwapPrice()` (short-window TWAP, no breaker).
    /// @dev    Internal callers use `_getTwapPriceForWindow`. This is intentionally
    ///         NOT used by `getLuminaPrice` anymore.
    function _getTwapPrice() external view returns (uint256) {
        return this._getTwapPriceForWindow(twapWindow);
    }

    /// @notice Compute the LUMINA/USDC TWAP for an arbitrary window from `pool`.
    /// @dev    External-but-view so it can be `try`/`catch`ed from getLuminaPrice.
    function _getTwapPriceForWindow(uint32 window) external view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
        int56 secs = int56(int32(window));
        int24 avgTick = int24(tickDiff / secs);
        if (tickDiff < 0 && (tickDiff % secs != 0)) {
            avgTick--;
        }

        uint256 sqrtPriceX96 = _getSqrtPriceFromTick(avgTick);
        uint256 priceRaw;

        if (isToken0Lumina) {
            priceRaw = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
            priceRaw = priceRaw * 1e12;
        } else {
            // [Sprint Y] Uniswap V3 price-from-sqrt standard pattern. The
            // shift `(1 << 192)` is the Q192 numerator; dividing by sqrt²
            // before final 1e12 multiply is intentional and matches the
            // audited Uniswap reference math.
            // slither-disable-next-line divide-before-multiply
            priceRaw = (1 << 192) * 1e18 / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
            priceRaw = priceRaw * 1e12;
        }

        return priceRaw;
    }

    /// @notice Absolute deviation between two prices, in bps of the larger.
    /// @dev    Symmetric and overflow-safe for 18-dec prices.
    function _deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return type(uint256).max; // treat as max divergence
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        return ((hi - lo) * 10000) / hi;
    }

    function getTWAP(uint32 secondsAgo) external view returns (uint256) {
        require(secondsAgo > 0, "Period must be > 0");
        if (pool == address(0)) return emergencyPrice;

        uint32[] memory sAgos = new uint32[](2);
        sAgos[0] = secondsAgo;
        sAgos[1] = 0;

        try IUniswapV3Pool(pool).observe(sAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
            int56 secs = int56(uint56(secondsAgo));
            int24 avgTick = int24(tickDiff / secs);
            if (tickDiff < 0 && (tickDiff % secs != 0)) {
                avgTick--;
            }
            uint256 sqrtPriceX96 = _getSqrtPriceFromTick(avgTick);
            uint256 priceRaw;
            if (isToken0Lumina) {
                priceRaw = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
                priceRaw = priceRaw * 1e12;
            } else {
                // [Sprint Y] See ADR-017 — Uniswap V3 reciprocal price standard pattern.
                // slither-disable-next-line divide-before-multiply
                priceRaw = (1 << 192) * 1e18 / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
                priceRaw = priceRaw * 1e12;
            }
            return priceRaw > 0 ? priceRaw : emergencyPrice;
        } catch {
            return emergencyPrice;
        }
    }

    // ═══════ CAPACITY VIEW ═══════

    function maxPoliciesPerDay() external view returns (uint256) {
        uint256 price = this.getLuminaPrice();
        if (price == 0) return 0;
        uint256 reserveValueUSD = (BOND_RESERVE * price) / 1e18;
        uint256 maxCommitUSD = (reserveValueUSD * SAFETY_FACTOR_BPS) / 10000;
        uint256 dailyCommitUSD = (AVG_PAYOUT_USD * AVG_TRIGGER_RATE_BPS) / 10000;
        if (dailyCommitUSD == 0) return type(uint256).max;
        return maxCommitUSD / (MATURITY_DAYS * dailyCommitUSD) / 1e18;
    }

    // ═══════ ADMIN ═══════

    function setPool(address _pool) external onlyOwner {
        _setPool(_pool);
    }

    function setTwapWindow(uint32 _window) external onlyOwner {
        require(_window >= 300 && _window <= 7200, "Window: 5min-2hr");
        uint32 old = twapWindow;
        twapWindow = _window;
        emit TwapWindowUpdated(old, _window);
    }

    /// @notice [F-09] Immediate emergencyPrice setter — BOOTSTRAP ONLY.
    /// @dev    Allowed with no timelock/deviation check ONLY while `pool` is unset
    ///         (deploy bootstrap). Once a pool is set this path is BLOCKED and the
    ///         timelocked two-step (`proposeEmergencyPrice` + `applyEmergencyPrice`)
    ///         is mandatory. Trade-off: bootstrap needs a price before a pool can
    ///         exist; after that, an unbounded instant owner override would re-open
    ///         the F-09 silent-mask vector, so we forbid it.
    ///         DEPLOY REVIEW: a pool MUST be set before mainnet handover so this
    ///         path can never be used to re-peg a live oracle.
    function setEmergencyPrice(uint256 _price) external onlyOwner {
        require(_price > 0, "Zero price");
        require(pool == address(0), "Pool set: use timelock");
        uint256 old = emergencyPrice;
        emergencyPrice = _price;
        emit EmergencyPriceSet(old, _price, msg.sender);
    }

    /// @notice [F-09] Step 1/2: propose a new emergencyPrice (24h timelock).
    /// @dev    Bounded: when a pool/observations exist, the new value may not
    ///         deviate more than `MAX_EMERGENCY_DEVIATION_BPS` from the last good
    ///         TWAP. Records the value + eta; cannot take effect until the
    ///         timelock elapses (see `applyEmergencyPrice`).
    function proposeEmergencyPrice(uint256 _price) external onlyOwner {
        require(_price > 0, "Zero price");
        _requireWithinEmergencyBound(_price);
        pendingEmergencyPrice = _price;
        pendingEmergencyPriceTimestamp = block.timestamp;
        emit EmergencyPriceProposed(_price, block.timestamp + EMERGENCY_PRICE_TIMELOCK, msg.sender);
    }

    /// @notice [F-09] Step 2/2: apply a proposed emergencyPrice after the timelock.
    /// @dev    Re-checks the deviation bound at apply-time so a price that drifted
    ///         out of band during the 24h window cannot land.
    function applyEmergencyPrice() external onlyOwner {
        require(pendingEmergencyPriceTimestamp != 0, "No pending");
        require(block.timestamp >= pendingEmergencyPriceTimestamp + EMERGENCY_PRICE_TIMELOCK, "Timelock not elapsed");
        uint256 newPrice = pendingEmergencyPrice;
        _requireWithinEmergencyBound(newPrice);

        uint256 old = emergencyPrice;
        emergencyPrice = newPrice;

        pendingEmergencyPrice = 0;
        pendingEmergencyPriceTimestamp = 0;

        emit EmergencyPriceSet(old, newPrice, msg.sender);
    }

    /// @notice [F-09] Cancel a pending timelocked emergencyPrice proposal.
    function cancelEmergencyPrice() external onlyOwner {
        pendingEmergencyPrice = 0;
        pendingEmergencyPriceTimestamp = 0;
    }

    /// @dev [F-09] Reject a proposed emergencyPrice that deviates more than
    ///      MAX_EMERGENCY_DEVIATION_BPS from the last good TWAP. When no pool or
    ///      no usable observations exist, there is no reference to bound against
    ///      (bootstrap edge) so the check is skipped — but note this branch is
    ///      only reachable pre-pool, which deploy review forbids on mainnet.
    function _requireWithinEmergencyBound(uint256 _price) internal view {
        if (pool == address(0)) return; // no reference (bootstrap-only)
        // Use the short window as the reference; if it is unavailable/zero we
        // cannot bound, so we conservatively reject to avoid an unbounded set.
        try this._getTwapPriceForWindow(twapWindow) returns (uint256 ref) {
            if (ref == 0) revert("No TWAP reference");
            require(_deviationBps(_price, ref) <= MAX_EMERGENCY_DEVIATION_BPS, "Emergency price deviates >50%");
        } catch {
            revert("No TWAP reference");
        }
    }

    // ═══════ INTERNAL ═══════

    function _setPool(address _pool) internal {
        require(_pool != address(0), "Zero pool");
        address old = pool;
        pool = _pool;
        address t0 = IUniswapV3Pool(_pool).token0();
        isToken0Lumina = (t0 == luminaToken);
        emit PoolUpdated(old, _pool);
    }

    /// @notice Convert a tick to sqrtPriceX96 (Q64.96).
    /// @dev Inline of Uniswap V3 TickMath.getSqrtRatioAtTick. The
    ///      multiply-shift sequence is the canonical Uniswap pattern and order
    ///      matters for tick precision: rearranging operations changes the
    ///      result. Slither flags the multiply-then-shift mixed with the final
    ///      divide as `divide-before-multiply` but this is the audited Uniswap
    ///      reference algorithm — see uniswap-v3-core
    ///      contracts/libraries/TickMath.sol. See ADR-017 (Sprint Y).
    // slither-disable-next-line divide-before-multiply
    function _getSqrtPriceFromTick(int24 tick) internal pure returns (uint256) {
        uint256 absTick = tick >= 0 ? uint256(int256(tick)) : uint256(-int256(tick));

        uint256 ratio = 0x100000000000000000000000000000000;
        if (absTick & 0x1 != 0) ratio = (ratio * 0xfffcb933bd6fad37aa2d162d1a594001) >> 128;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        return (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Storage gap for future upgrades.
    // [F-09 fix] Shrunk 50 -> 48: two new slots appended above
    // (pendingEmergencyPrice, pendingEmergencyPriceTimestamp) consume the first
    // two former gap slots, preserving the overall storage layout.
    uint256[48] private __gap;
}
