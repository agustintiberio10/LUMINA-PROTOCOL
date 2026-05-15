// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LuminaTokenV2} from "./LuminaTokenV2.sol";

/// @title LuminaTokenV2_PostRescueV2
/// @notice [Sprint Z.2 — post-rescue upgrade] Same storage layout as
///         LuminaTokenV2_RescueV1 (keeps `emergencyRecoverUsed` slot — no
///         shrink, no reorder) but drops the `emergencyRecover` function from
///         the public ABI so it can never be invoked again.
/// @dev    Storage MUST be a strict superset of LuminaTokenV2 RescueV1, in the same order.
contract LuminaTokenV2_PostRescueV2 is LuminaTokenV2 {
    /// @notice One-shot flag inherited from the RescueV1 storage layout.
    ///         Kept here so the slot is preserved; the value will be `true`
    ///         after the rescue tx executed under RescueV1.
    bool public emergencyRecoverUsed;
}
