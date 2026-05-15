// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ChainGuard
/// @notice Sprint CC — restrict critical contract calls to the allowed chain IDs.
/// @dev Allowed chains:
///       - Base mainnet (8453)  — production
///       - Base Sepolia (84532) — testnet
///      Any other chain reverts with `InvalidChainId`.
///      Pure library (no storage). Used as `ChainGuard.requireValidChain()` inside
///      modifiers or at the top of guarded functions.
library ChainGuard {
    error InvalidChainId(uint256 actual, uint256 expected);

    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;

    function requireValidChain() internal view {
        uint256 cid = block.chainid;
        if (cid != BASE_MAINNET && cid != BASE_SEPOLIA) {
            revert InvalidChainId(cid, BASE_MAINNET);
        }
    }
}
