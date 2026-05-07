// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal price oracle mock for testing TWAPBurner's slippage backstop.
///         TWAPBurner.capacityOracle is queried via `getLuminaPrice()` and the
///         returned value is interpreted as LUMINA price in USDC scaled to 1e18
///         (i.e. $0.0364 → 36_400_000_000_000_000).
contract MockPriceOracle {
    mapping(address => uint256) public priceByToken;
    address public lumina;

    /// @param token  ERC20 address whose price is being set.
    /// @param priceUsdcPer1e18  Price expressed as USDC per 1 token, scaled by 1e18.
    function setPrice(address token, uint256 priceUsdcPer1e18) external {
        priceByToken[token] = priceUsdcPer1e18;
    }

    function getPrice(address token) external view returns (uint256) {
        return priceByToken[token];
    }

    /// @dev Set the LUMINA token address used by `getLuminaPrice()`.
    function setLumina(address _lumina) external {
        lumina = _lumina;
    }

    /// @notice TWAPBurner.IPriceOracle interface — returns the configured LUMINA price.
    function getLuminaPrice() external view returns (uint256) {
        return priceByToken[lumina];
    }
}
