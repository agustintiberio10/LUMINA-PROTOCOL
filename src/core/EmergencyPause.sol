// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracle} from "../interfaces/IOracle.sol";

/**
 * @title EmergencyPause
 * @author Lumina Protocol
 * @notice Global protocol circuit breaker. When activated, ALL purchases,
 *         deposits, and withdrawals across the entire protocol are halted.
 *
 * @dev Separate from per-contract Pausable and per-product freeze.
 *      EMERGENCY_ROLE holders can pause instantly without Timelock delay.
 *      Non-upgradeable by design — a circuit breaker should be immutable.
 *
 * PAUSE SCENARIOS:
 *   a) USDC Depeg: USDC < $0.95 for +24h → admin pauses → unpauses when 1:1 restored
 *   b) Aave V3 Issue: Aave paused/exploited → admin pauses → unpauses when Aave resolves
 *   c) Protocol Emergency: exploit detected → admin pauses → unpauses post-fix
 *
 * DURING PAUSE:
 *   - Note: Policy expiration timestamps continue during protocol pause. The sequencer
 *     downtime extension provides protection for network outages but not for admin pauses.
 *   - Pending payouts remain in PENDING state (not lost, not expired)
 *   - LPs cannot withdraw (funds protected from bank run)
 *   - No new purchases or deposits allowed
 *   - triggerPayout and cleanupExpiredPolicy still work (claims must always be processable)
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

    /// @notice Oracle for USDC/USD price check
    IOracle public oracle;
    bytes32 public constant USDC_ASSET = "USDC";
    uint256 public constant DEPEG_THRESHOLD = 95_000_000; // $0.95 in 8 decimals
    uint256 public constant DEPEG_DURATION = 24 hours;

    /// @notice Timestamp when USDC first went below threshold (0 if not depegged)
    uint256 public depegStartedAt;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event ProtocolPaused(address indexed by);
    event ProtocolUnpaused(address indexed by);
    event EmergencyRoleGranted(address indexed account);
    event EmergencyRoleRevoked(address indexed account);
    event UnpauseCooldownUpdated(uint256 newCooldown);
    event USDCDepegAlert(uint256 price, uint256 duration);

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

    function setOracle(address oracle_) external onlyOwner {
        oracle = IOracle(oracle_);
    }

    // ═══════════════════════════════════════════════════════════
    //  USDC DEPEG MONITORING
    // ═══════════════════════════════════════════════════════════

    /// @notice Check USDC depeg status. Call periodically from backend.
    /// @return isDepegged True if USDC < $0.95 for > 24h
    /// @return currentPrice Current USDC price (8 decimals)
    /// @return depegDuration How long USDC has been below threshold (0 if not)
    function checkUSDCDepeg() external returns (bool isDepegged, uint256 currentPrice, uint256 depegDuration) {
        if (address(oracle) == address(0)) return (false, 100_000_000, 0);

        try oracle.getLatestPrice(USDC_ASSET) returns (int256 rawPrice) {
            if (rawPrice <= 0) return (false, 0, 0);
            currentPrice = uint256(rawPrice);

            if (currentPrice < DEPEG_THRESHOLD) {
                if (depegStartedAt == 0) {
                    depegStartedAt = block.timestamp;
                }
                depegDuration = block.timestamp - depegStartedAt;

                if (depegDuration >= DEPEG_DURATION) {
                    isDepegged = true;
                    emit USDCDepegAlert(currentPrice, depegDuration);
                }
            } else {
                depegStartedAt = 0;
            }
        } catch {
            // Oracle failed — cannot determine depeg
            return (false, 0, 0);
        }
    }
}
