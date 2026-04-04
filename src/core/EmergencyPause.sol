// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title EmergencyPause
 * @author Lumina Protocol
 * @notice Global protocol circuit breaker. When activated, ALL purchases,
 *         deposits, and withdrawals across the entire protocol are halted.
 *
 * @dev Separate from per-contract Pausable and per-product freeze.
 *      Designed for catastrophic scenarios (oracle compromise, exploit detected).
 *
 *      EMERGENCY_ROLE holders can pause instantly without Timelock delay.
 *      Only owner (TimelockController) can grant/revoke EMERGENCY_ROLE.
 *
 *      Non-upgradeable by design — a circuit breaker should be immutable.
 */
contract EmergencyPause is Ownable {

    /// @notice True if the entire protocol is paused
    bool public protocolPaused;

    /// @notice Addresses with EMERGENCY_ROLE can pause/unpause
    mapping(address => bool) public hasEmergencyRole;

    /// @notice Minimum seconds between unpause and next pause (anti-spam)
    uint256 public unpauseCooldown;

    /// @notice Timestamp of last unpause (for cooldown enforcement)
    uint256 public lastUnpauseAt;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event ProtocolPaused(address indexed by);
    event ProtocolUnpaused(address indexed by);
    event EmergencyRoleGranted(address indexed account);
    event EmergencyRoleRevoked(address indexed account);
    event UnpauseCooldownUpdated(uint256 newCooldown);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error NotEmergencyRole();
    error AlreadyPaused();
    error NotPaused();
    error CooldownNotElapsed(uint256 remainingSeconds);

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor(address owner_, uint256 unpauseCooldown_) Ownable(owner_) {
        unpauseCooldown = unpauseCooldown_;
    }

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyEmergencyRole() {
        if (!hasEmergencyRole[msg.sender]) revert NotEmergencyRole();
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  EMERGENCY ACTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Pause the entire protocol — ALWAYS instant, no cooldown
    /// @dev [FIX H-1] Cooldown moved to unpause. Pausing must always be instant.
    function emergencyPauseAll() external onlyEmergencyRole {
        if (protocolPaused) revert AlreadyPaused();
        protocolPaused = true;
        emit ProtocolPaused(msg.sender);
    }

    /// @notice Unpause the entire protocol — cooldown prevents rapid unpause/re-unpause
    /// @dev [FIX H-1] Cooldown on unpause prevents attacker from rapidly unpausing
    function emergencyUnpauseAll() external onlyEmergencyRole {
        if (!protocolPaused) revert NotPaused();
        if (lastUnpauseAt > 0 && block.timestamp < lastUnpauseAt + unpauseCooldown) {
            revert CooldownNotElapsed(lastUnpauseAt + unpauseCooldown - block.timestamp);
        }
        protocolPaused = false;
        lastUnpauseAt = block.timestamp;
        emit ProtocolUnpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN (owner only — TimelockController)
    // ═══════════════════════════════════════════════════════════

    function grantEmergencyRole(address account) external onlyOwner {
        hasEmergencyRole[account] = true;
        emit EmergencyRoleGranted(account);
    }

    function revokeEmergencyRole(address account) external onlyOwner {
        hasEmergencyRole[account] = false;
        emit EmergencyRoleRevoked(account);
    }

    function setUnpauseCooldown(uint256 newCooldown) external onlyOwner {
        unpauseCooldown = newCooldown;
        emit UnpauseCooldownUpdated(newCooldown);
    }
}
