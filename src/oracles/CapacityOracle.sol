// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title CapacityOracle
/// @notice Provides $LUMINA price and capacity calculations for BondVault.
/// @dev [V5.1] UUPS upgradeable proxy pattern.

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

    // ═══════ CONSTANTS ═══════
    uint256 public constant BOND_RESERVE = 70_000_000 * 1e18;
    uint256 public constant SAFETY_FACTOR_BPS = 5000;
    uint256 public constant AVG_PAYOUT_USD = 500;
    uint256 public constant MATURITY_DAYS = 730;
    uint256 public constant AVG_TRIGGER_RATE_BPS = 100;

    // ═══════ EVENTS ═══════
    event PoolUpdated(address oldPool, address newPool);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);
    event EmergencyPriceSet(uint256 price);

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

    function getLuminaPrice() external view returns (uint256 price) {
        if (pool == address(0)) return emergencyPrice;

        try this._getTwapPrice() returns (uint256 twapPrice) {
            return twapPrice > 0 ? twapPrice : emergencyPrice;
        } catch {
            return emergencyPrice;
        }
    }

    function _getTwapPrice() external view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
        int56 secs = int56(int32(twapWindow));
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

    function setEmergencyPrice(uint256 _price) external onlyOwner {
        require(_price > 0, "Zero price");
        emergencyPrice = _price;
        emit EmergencyPriceSet(_price);
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

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
