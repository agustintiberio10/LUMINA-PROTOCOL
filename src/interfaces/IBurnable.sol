// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IBurnable
/// @notice Canonical interface for tokens that expose a `burn(uint256)` function.
/// @dev Sprint X.1 (Aderyn H-5): dedupes the prior local declarations in
///      `src/bonds/BondVault.sol` and `src/core/TWAPBurner.sol`. Both had
///      identical signatures; centralising here avoids the "Contract Name
///      Reused" finding under tooling that resolves contracts by name
///      (Truffle and similar).
interface IBurnable {
    function burn(uint256 amount) external;
}
