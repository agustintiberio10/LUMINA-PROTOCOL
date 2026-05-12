// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceOracle
/// @notice Canonical interface for the LUMINA price oracle used by BondVault
///         (redeem path) and TWAPBurner (slippage protection in executeBurn).
/// @dev Sprint X.1 (Aderyn H-5): dedupes the prior local declarations in
///      `src/bonds/BondVault.sol` and `src/core/TWAPBurner.sol`.
interface IPriceOracle {
    /// @notice Current $LUMINA price in USD with 18 decimals.
    /// @return price e.g., 36000000000000000 = $0.036
    function getLuminaPrice() external view returns (uint256 price);
}
