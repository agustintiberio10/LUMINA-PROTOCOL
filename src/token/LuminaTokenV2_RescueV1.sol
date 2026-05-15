// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LuminaTokenV2} from "./LuminaTokenV2.sol";

/// @title LuminaTokenV2_RescueV1
/// @notice [Sprint Z.2 — temporary upgrade] Adds a one-shot emergencyRecover()
///         used exclusively to move the 8M LUMINA from the legacy
///         FounderVesting (0xa3e7…E876, wired to the wrong oracle) to the new
///         FounderVestingV2. After the recover tx, the proxy is upgraded to
///         LuminaTokenV2_PostRescueV2 which drops the function from the public ABI.
/// @dev    Storage layout extends LuminaTokenV2 (which ends in `uint256[50] __gap`).
///         The new `emergencyRecoverUsed` bool occupies slot (V2.end + 50 + 0) — i.e.
///         immediately after V2's gap. PostRescueV2 keeps the same slot so a future
///         downgrade in this proxy does not corrupt state.
///         Authorization uses LuminaTokenV2's existing AccessControl
///         (`DEFAULT_ADMIN_ROLE`) rather than introducing a new Ownable parent.
contract LuminaTokenV2_RescueV1 is LuminaTokenV2 {
    /// @notice One-shot flag — once true, emergencyRecover always reverts.
    bool public emergencyRecoverUsed;

    event EmergencyRescueExecuted(address indexed from, address indexed to, uint256 amount);

    /// @notice Force-move `amount` tokens from `from` to `to`. Bypasses allowance.
    ///         Callable exactly once by the admin (founder via Gnosis or EOA).
    function emergencyRecover(address from, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!emergencyRecoverUsed, "Rescue already used");
        require(from != address(0), "Zero from");
        require(to != address(0), "Zero to");
        emergencyRecoverUsed = true;
        _transfer(from, to, amount);
        emit EmergencyRescueExecuted(from, to, amount);
    }
}
