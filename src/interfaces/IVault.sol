// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVault
 * @author Lumina Protocol
 * @notice Mega Pool Vault interface — Cooldown pattern, Soulbound shares.
 * 
 * 🔴 INMUTABLE — Changing this requires redeploying all vaults.
 * 
 * DESIGN (post-pivot):
 *   - 4 vaults: VolatileShort(30d), VolatileLong(90d), StableShort(90d), StableLong(365d)
 *   - LP deposits indefinitely — no lock from deposit time
 *   - LP calls requestWithdrawal() → cooldown starts → completeWithdrawal() after cooldown
 *   - Shares are SOULBOUND (non-transferable) to prevent desyncing from withdrawal state
 *   - Each vault has its own share price — primas go ONLY to the vault that backed the policy
 *   - PolicyManager does ALM check: policy duration ≤ LP's remaining cooldown time
 *   - During cooldown, LP capital degrades (backs shorter and shorter policies)
 *   - After cooldown, LP capital backs nothing new and can be withdrawn
 *
 * COOLDOWN vs LOCK:
 *   Lock (old): LP enters → locked for X days → exits day X+1. Problem: day 2, can only back X-2 day policies.
 *   Cooldown (new): LP enters → stays indefinitely → requests exit → cooldown X days → exits. Always backs X day policies until exit requested.
 */
interface IVault {

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    /// @notice Withdrawal request state for an LP
    struct WithdrawalRequest {
        uint256 shares;             // How many shares the LP wants to withdraw
        uint256 cooldownEnd;        // Timestamp when cooldown expires (0 = no active request)
    }

    /// @notice Vault state snapshot
    struct VaultState {
        uint256 totalAssets;        // Total USDY in vault (USD value)
        uint256 allocatedAssets;    // Locked backing active policies
        uint256 freeAssets;         // Available for new policies or withdrawals
        uint256 totalShares;        // Total shares outstanding
        uint256 utilizationBps;     // (allocated / total) × 10000
        uint32 cooldownDuration;    // This vault's cooldown in seconds
    }

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event Deposited(address indexed lp, uint256 assets, uint256 shares);
    event WithdrawalRequested(address indexed lp, uint256 shares, uint256 cooldownEnd);
    event WithdrawalCancelled(address indexed lp, uint256 shares);
    event WithdrawalCompleted(address indexed lp, uint256 assets, uint256 shares);
    event CollateralLocked(uint256 amount, bytes32 indexed productId, uint256 indexed policyId);
    event CollateralUnlocked(uint256 amount, bytes32 indexed productId, uint256 indexed policyId);
    event PayoutExecuted(address indexed recipient, uint256 amount, bytes32 indexed productId, uint256 indexed policyId);
    event PremiumReceived(uint256 amount, bytes32 indexed productId, uint256 indexed policyId);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error InsufficientLiquidity(uint256 requested, uint256 available);
    error CooldownNotExpired(address lp, uint256 cooldownEnd, uint256 currentTime);
    error NoActiveWithdrawalRequest(address lp);
    error WithdrawalAlreadyRequested(address lp);
    error InsufficientShares(uint256 requested, uint256 available);
    error UtilizationTooHigh(uint256 currentBps, uint256 afterBps, uint256 maxBps);
    error OnlyPolicyManager();
    error OnlyRouter();
    error ZeroAmount();
    error ZeroAddress();
    error SharesNotTransferable();
    error TooManyWithdrawalRequests(address lp);

    // ═══════════════════════════════════════════════════════════
    //  LP OPERATIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Deposit USDY into the vault. Capital stays indefinitely until withdrawal requested.
     * @param assets Amount of USDY to deposit
     * @param receiver Address that receives the soulbound shares
     * @return shares Amount of shares minted
     */
    function depositAssets(uint256 assets, address receiver) external returns (uint256 shares);

    /**
     * @notice Request withdrawal — starts the cooldown timer.
     * @dev During cooldown, LP capital still backs active policies but
     *      PolicyManager won't assign NEW policies to this capital.
     *      Cooldown = vault's configured duration (30d/90d/365d).
     * @param shares Number of shares to withdraw
     */
    function requestWithdrawal(uint256 shares) external;

    /**
     * @notice Cancel a pending withdrawal request. Capital returns to full availability.
     */
    function cancelWithdrawal() external;

    /**
     * @notice Complete withdrawal after cooldown expires. Burns shares, returns USDY.
     * @param receiver Address that receives the USDY
     * @return assets Amount of USDY returned (principal + yield)
     */
    function completeWithdrawal(address receiver) external returns (uint256 assets);

    // ═══════════════════════════════════════════════════════════
    //  COLLATERAL MANAGEMENT (only PolicyManager)
    // ═══════════════════════════════════════════════════════════

    function lockCollateral(uint256 amount, bytes32 productId, uint256 policyId) external returns (bool);
    function unlockCollateral(uint256 amount, bytes32 productId, uint256 policyId) external returns (bool);

    // ═══════════════════════════════════════════════════════════
    //  PAYOUT + PREMIUM (only CoverRouter)
    // ═══════════════════════════════════════════════════════════

    function executePayout(address recipient, uint256 amount, bytes32 productId, uint256 policyId) external returns (bool);
    function receivePremium(uint256 amount, bytes32 productId, uint256 policyId) external returns (bool);

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    function getVaultState() external view returns (VaultState memory);
    function freeAssets() external view returns (uint256);
    function allocatedAssets() external view returns (uint256);
    function utilizationBps() external view returns (uint256 bps);
    function cooldownDuration() external view returns (uint32);
    function getWithdrawalRequest(address lp) external view returns (WithdrawalRequest memory);
    function getWithdrawalQueue(address lp) external view returns (WithdrawalRequest[] memory);
    function availableCapacity(uint256 policyDurationSeconds) external view returns (uint256);
}
