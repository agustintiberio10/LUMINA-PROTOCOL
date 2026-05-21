// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IShieldV2
/// @notice Minimal interface for Sprint T-30a shields with the
///         drop-from-purchase-price mechanic. Used by CoverRouterV2 and the
///         relayer/keeper that submits trigger verifications.
/// @dev    NOT a replacement for IShield (legacy products). New flash shields
///         only implement this slimmer surface; richer status/lifecycle is
///         handled by PolicyManagerV2 / off-chain components.
interface IShieldV2 {
    function createPolicy(
        uint256 policyId,
        address holder,
        uint256 coverage,
        uint64 startTimestamp,
        uint64 expiresAt
    ) external;

    function verifyAndCalculate(uint256 policyId)
        external
        returns (bool triggered, uint256 payout, address holder, bytes32 reason);

    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (
            address holder,
            uint256 coverage,
            uint256 strikePrice,
            uint64 startTimestamp,
            uint64 expiresAt,
            bool finalized
        );
}
