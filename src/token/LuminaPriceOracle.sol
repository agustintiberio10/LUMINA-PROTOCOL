// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

contract LuminaPriceOracle is Ownable {
    // ═══════ Phase 1: Manual Price ═══════
    uint256 public manualPrice; // Price in USDC with 6 decimals (e.g. 40000 = $0.04)
    bool public useManualPrice;

    // ═══════ Phase 2: Uniswap V3 TWAP ═══════
    address public pool; // LUMINA/USDC pool address
    uint32 public twapInterval; // Seconds for TWAP (default 1800 = 30 min)
    bool public isToken0; // true if LUMINA is token0 in the pool

    constructor(uint256 _initialPrice) Ownable(msg.sender) {
        manualPrice = _initialPrice;
        useManualPrice = true;
        twapInterval = 1800;
    }

    // ═══════ GETTERS ═══════

    function getPrice() public view returns (uint256) {
        if (useManualPrice) {
            require(manualPrice > 0, "Manual price not set");
            return manualPrice;
        }
        return _getTwapPrice();
    }

    /// @notice Convert USD amount (6 decimals) to LUMINA (18 decimals)
    function usdToLumina(uint256 usdAmount6dec) external view returns (uint256) {
        uint256 price = getPrice();
        require(price > 0, "Price is zero");
        return usdAmount6dec * 1e18 / price;
    }

    /// @notice Convert LUMINA amount (18 decimals) to USD (6 decimals)
    function luminaToUsd(uint256 luminaAmount) external view returns (uint256) {
        uint256 price = getPrice();
        return luminaAmount * price / 1e18;
    }

    // ═══════ ADMIN: Phase 1 ═══════

    function setManualPrice(uint256 _price) external onlyOwner {
        require(useManualPrice, "TWAP mode active, cannot set manual");
        require(_price > 0, "Price must be > 0");
        manualPrice = _price;
        emit ManualPriceUpdated(_price);
    }

    // ═══════ ADMIN: Switch to Phase 2 ═══════

    function enableTwap(address _pool, bool _isToken0) external onlyOwner {
        require(_pool != address(0), "Zero pool");
        pool = _pool;
        isToken0 = _isToken0;
        useManualPrice = false;
        emit TwapEnabled(_pool, twapInterval);
    }

    function setTwapInterval(uint32 _interval) external onlyOwner {
        require(_interval >= 300 && _interval <= 7200, "5min to 2h");
        twapInterval = _interval;
    }

    // ═══════ ADMIN: Emergency revert to manual ═══════

    function revertToManual(uint256 _price) external onlyOwner {
        require(_price > 0, "Price must be > 0");
        useManualPrice = true;
        manualPrice = _price;
        emit RevertedToManual(_price);
    }

    // ═══════ TWAP Implementation ═══════

    function _getTwapPrice() internal view returns (uint256) {
        require(pool != address(0), "Pool not set");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(twapInterval)));

        // Convert tick to price
        // price = 1.0001^tick
        // For LUMINA(18 dec)/USDC(6 dec):
        //   If LUMINA is token0: price of token0 in token1 = 1.0001^tick * 10^(decimals0-decimals1)
        //     priceInUSDC6dec = 1.0001^tick * 10^(18-6) → but we want USDC per LUMINA in 6 dec
        //   If LUMINA is token1: invert
        uint256 absTick =
            arithmeticMeanTick < 0 ? uint256(uint24(-arithmeticMeanTick)) : uint256(uint24(arithmeticMeanTick));
        // Use the ratio approach: sqrtPriceX96 = sqrt(1.0001^tick) * 2^96
        // price = (sqrtPriceX96)^2 / 2^192
        // For precision, compute using exponentiation by squaring of 1.0001
        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
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

        if (arithmeticMeanTick > 0) ratio = type(uint256).max / ratio;

        // ratio is Q128.128 representation of 1.0001^tick
        // For Uniswap V3: price of token0 in terms of token1 = 1.0001^tick * 10^(decimals1 - decimals0)
        // LUMINA = 18 dec, USDC = 6 dec
        // We want: USDC per LUMINA (6 decimals result)

        uint256 priceUSDC6dec;
        if (isToken0) {
            // LUMINA is token0 → price = 1.0001^tick gives token1/token0 = USDC/LUMINA
            // But tick price is in raw units, need to adjust for decimals
            // raw_price = ratio / 2^128
            // actual_price = raw_price * 10^(decimals0 - decimals1) = raw_price * 10^12
            // We want result in 6 decimals of USDC:
            // priceUSDC6dec = ratio * 10^6 / 2^128
            priceUSDC6dec = (ratio * 1e6) >> 128;
        } else {
            // LUMINA is token1 → price of token0/token1 = 1.0001^tick
            // We want token0(USDC) per token1(LUMINA) = 1 / (1.0001^tick)
            // priceUSDC6dec = 2^128 * 10^6 / ratio * 10^(decimals1 - decimals0)
            // = 2^128 * 10^6 * 10^12 / ratio = 2^128 * 10^18 / ratio
            priceUSDC6dec = (uint256(1) << 128) * 1e18 / ratio;
        }

        return priceUSDC6dec;
    }

    // ═══════ EVENTS ═══════

    event ManualPriceUpdated(uint256 newPrice);
    event TwapEnabled(address pool, uint32 interval);
    event RevertedToManual(uint256 fallbackPrice);
}
