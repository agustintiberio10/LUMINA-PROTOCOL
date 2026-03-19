// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "../interfaces/IVault.sol";

/**
 * @title BaseVault
 * @author Lumina Protocol
 * @notice ERC-4626 Vault with Cooldown withdrawal and Soulbound shares.
 *         Inherited by VolatileShort, VolatileLong, StableShort, StableLong.
 * 
 * @dev FINAL VERSION — All audit findings from Claude Code + Gemini fixed:
 *
 *   [CC-1] CRITICAL: redeem() overridden → blocks cooldown bypass
 *   [CC-2] CRITICAL: executePayout does NOT touch _allocatedAssets (prevents double decrement)
 *   [CC-3] HIGH: deposit() overridden with MIN_DEPOSIT guard
 *   [CC-5] MEDIUM: availableCapacity accounts for pending withdrawals
 *   [GM-1] CRITICAL: _pendingWithdrawalSHARES (not assets) — prevents drift when share price changes
 *          Converted to assets in real-time via convertToAssets() in _freeAssets()
 *
 *   CoverRouter fixes (CC-4: address(0) guard) are in CoverRouter.sol, not here.
 */
abstract contract BaseVault is
    IVault,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  STORAGE — 🔴 NEVER reorder. Only APPEND.
    // ═══════════════════════════════════════════════════════════

    address internal _router;
    address internal _policyManager;
    uint256 internal _allocatedAssets;
    uint32 internal _cooldownDuration;

    mapping(address => WithdrawalRequest) internal _withdrawalRequests;

    /// @notice [GM-1] Shares pending withdrawal — tracked as SHARES not assets.
    ///         Converted to assets in real-time in _freeAssets() via convertToAssets().
    ///         This prevents drift when share price changes between request and withdrawal.
    uint256 internal _pendingWithdrawalShares;

    // ═══ V2: Multi-withdrawal queue ═══
    mapping(address => WithdrawalRequest[]) internal _withdrawalQueue;
    uint256 internal _pendingQueueShares;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_UTILIZATION_BPS = 9_500;
    uint256 internal constant MIN_DEPOSIT = 100e6; // $100 USDC (anti-DoS, 6 decimals)

    // ═══════════════════════════════════════════════════════════
    //  INITIALIZER
    // ═══════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function __BaseVault_init(
        address owner_,
        address asset_,
        string memory name_,
        string memory symbol_,
        address router_,
        address policyManager_,
        uint32 cooldownDuration_
    ) internal onlyInitializing {
        if (owner_ == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();
        if (router_ == address(0)) revert ZeroAddress();
        if (policyManager_ == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(asset_));
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _router = router_;
        _policyManager = policyManager_;
        _cooldownDuration = cooldownDuration_;
    }

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyRouter() {
        if (msg.sender != _router) revert OnlyRouter();
        _;
    }

    modifier onlyPolicyManager() {
        if (msg.sender != _policyManager) revert OnlyPolicyManager();
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  SOULBOUND: Non-transferable shares
    // ═══════════════════════════════════════════════════════════

    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        if (from != address(0) && to != address(0)) {
            revert SharesNotTransferable();
        }
        super._update(from, to, value);
    }

    // ═══════════════════════════════════════════════════════════
    //  ERC-4626 INFLATION PROTECTION
    // ═══════════════════════════════════════════════════════════

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    // ═══════════════════════════════════════════════════════════
    //  LP OPERATIONS
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IVault
    function depositAssets(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets < MIN_DEPOSIT) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        shares = deposit(assets, receiver);

        emit Deposited(receiver, assets, shares);
    }

    /// @inheritdoc IVault
    function requestWithdrawal(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares(shares, balanceOf(msg.sender));
        if (_withdrawalRequests[msg.sender].cooldownEnd != 0) revert WithdrawalAlreadyRequested(msg.sender);

        uint256 cooldownEnd = block.timestamp + _cooldownDuration;

        _withdrawalRequests[msg.sender] = WithdrawalRequest({
            shares: shares,
            cooldownEnd: cooldownEnd
        });

        // [GM-1] Track pending as SHARES — value computed in real-time in _freeAssets()
        _pendingWithdrawalShares += shares;

        emit WithdrawalRequested(msg.sender, shares, cooldownEnd);
    }

    /// @inheritdoc IVault
    function cancelWithdrawal() external nonReentrant {
        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        if (req.cooldownEnd == 0) revert NoActiveWithdrawalRequest(msg.sender);

        uint256 shares = req.shares;

        // [GM-1] Simple subtraction — no drift because we track shares, not assets
        _pendingWithdrawalShares -= shares;

        delete _withdrawalRequests[msg.sender];

        emit WithdrawalCancelled(msg.sender, shares);
    }

    /// @inheritdoc IVault
    function completeWithdrawal(address receiver) external nonReentrant returns (uint256 assets) {
        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        if (req.cooldownEnd == 0) revert NoActiveWithdrawalRequest(msg.sender);
        if (block.timestamp < req.cooldownEnd) revert CooldownNotExpired(msg.sender, req.cooldownEnd, block.timestamp);

        uint256 shares = req.shares;
        if (balanceOf(msg.sender) < shares) revert InsufficientShares(shares, balanceOf(msg.sender));

        assets = convertToAssets(shares);

        // Check: enough non-allocated USDC to pay this withdrawal?
        // We use totalAssets - _allocatedAssets (NOT _freeAssets) because
        // _freeAssets also subtracts pending withdrawals — including THIS LP's own.
        // That would make it impossible for the LP to withdraw their own capital.
        // _freeAssets() is for PolicyManager (policy allocation).
        // This check is for LP withdrawals (different constraint).
        uint256 nonAllocated = totalAssets() > _allocatedAssets
            ? totalAssets() - _allocatedAssets
            : 0;
        if (assets > nonAllocated) revert InsufficientLiquidity(assets, nonAllocated);

        // [GM-1] Reduce pending shares counter
        _pendingWithdrawalShares -= shares;

        // Clear request BEFORE external calls (CEI)
        delete _withdrawalRequests[msg.sender];

        // [CC-1] Use super.redeem() to bypass our override that blocks direct redeem()
        super.redeem(shares, receiver, msg.sender);

        emit WithdrawalCompleted(msg.sender, assets, shares);
    }

    // ═══════════════════════════════════════════════════════════
    //  V2: MULTI-WITHDRAWAL QUEUE
    // ═══════════════════════════════════════════════════════════

    function requestWithdrawalV2(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (_withdrawalQueue[msg.sender].length >= 10) revert TooManyWithdrawalRequests(msg.sender);
        if (balanceOf(msg.sender) < shares) revert InsufficientShares(shares, balanceOf(msg.sender));

        uint256 totalPending = _getPendingShares(msg.sender);
        if (totalPending + shares > balanceOf(msg.sender))
            revert InsufficientShares(shares, balanceOf(msg.sender) - totalPending);

        uint256 cooldownEnd = block.timestamp + _cooldownDuration;
        _withdrawalQueue[msg.sender].push(WithdrawalRequest({ shares: shares, cooldownEnd: cooldownEnd }));
        _pendingQueueShares += shares;

        emit WithdrawalRequested(msg.sender, shares, cooldownEnd);
    }

    function completeWithdrawalV2(address receiver) external nonReentrant returns (uint256 assets) {
        WithdrawalRequest[] storage queue = _withdrawalQueue[msg.sender];
        if (queue.length == 0) revert NoActiveWithdrawalRequest(msg.sender);

        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < queue.length; i++) {
            if (block.timestamp >= queue[i].cooldownEnd) {
                idx = i;
                break;
            }
        }
        if (idx == type(uint256).max) revert CooldownNotExpired(msg.sender, queue[0].cooldownEnd, block.timestamp);

        uint256 shares = queue[idx].shares;
        if (balanceOf(msg.sender) < shares) revert InsufficientShares(shares, balanceOf(msg.sender));

        assets = convertToAssets(shares);
        uint256 nonAllocated = totalAssets() > _allocatedAssets ? totalAssets() - _allocatedAssets : 0;
        if (assets > nonAllocated) revert InsufficientLiquidity(assets, nonAllocated);

        _pendingQueueShares -= shares;

        queue[idx] = queue[queue.length - 1];
        queue.pop();

        super.redeem(shares, receiver, msg.sender);
        emit WithdrawalCompleted(msg.sender, assets, shares);
    }

    function cancelWithdrawalV2(uint256 index) external nonReentrant {
        WithdrawalRequest[] storage queue = _withdrawalQueue[msg.sender];
        if (index >= queue.length) revert NoActiveWithdrawalRequest(msg.sender);

        uint256 shares = queue[index].shares;
        _pendingQueueShares -= shares;

        queue[index] = queue[queue.length - 1];
        queue.pop();

        emit WithdrawalCancelled(msg.sender, shares);
    }

    /// @inheritdoc IVault
    function getWithdrawalQueue(address lp) external view returns (WithdrawalRequest[] memory) {
        return _withdrawalQueue[lp];
    }

    function _getPendingShares(address lp) internal view returns (uint256 total) {
        // V1 pending
        if (_withdrawalRequests[lp].cooldownEnd != 0) {
            total += _withdrawalRequests[lp].shares;
        }
        // V2 pending
        for (uint256 i = 0; i < _withdrawalQueue[lp].length; i++) {
            total += _withdrawalQueue[lp][i].shares;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  COLLATERAL MANAGEMENT (only PolicyManager)
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IVault
    function lockCollateral(
        uint256 amount,
        bytes32 productId,
        uint256 policyId
    ) external onlyPolicyManager returns (bool) {
        if (amount == 0) revert ZeroAmount();

        uint256 total = totalAssets();
        if (total == 0) revert InsufficientLiquidity(amount, 0);

        uint256 free = _freeAssets();
        if (amount > free) revert InsufficientLiquidity(amount, free);

        uint256 newUtilBps = ((_allocatedAssets + amount) * BPS) / total;
        if (newUtilBps > MAX_UTILIZATION_BPS) {
            revert UtilizationTooHigh(
                (_allocatedAssets * BPS) / total,
                newUtilBps,
                MAX_UTILIZATION_BPS
            );
        }

        _allocatedAssets += amount;

        emit CollateralLocked(amount, productId, policyId);
        return true;
    }

    /// @inheritdoc IVault
    function unlockCollateral(
        uint256 amount,
        bytes32 productId,
        uint256 policyId
    ) external onlyPolicyManager returns (bool) {
        if (amount > _allocatedAssets) {
            amount = _allocatedAssets;
        }
        _allocatedAssets -= amount;

        emit CollateralUnlocked(amount, productId, policyId);
        return true;
    }

    // ═══════════════════════════════════════════════════════════
    //  PAYOUT + PREMIUM (only CoverRouter)
    // ═══════════════════════════════════════════════════════════

    /**
     * @inheritdoc IVault
     * @dev [CC-2] ONLY transfers USDC. Does NOT touch _allocatedAssets.
     *      Allocation accounting is handled by unlockCollateral (called by PolicyManager
     *      via releaseAllocation BEFORE this function).
     */
    function executePayout(
        address recipient,
        uint256 amount,
        bytes32 productId,
        uint256 policyId
    ) external onlyRouter nonReentrant returns (bool) {
        if (amount == 0) return true;
        if (recipient == address(0)) revert ZeroAddress();

        IERC20(asset()).safeTransfer(recipient, amount);

        emit PayoutExecuted(recipient, amount, productId, policyId);
        return true;
    }

    /// @inheritdoc IVault
    function receivePremium(
        uint256 amount,
        bytes32 productId,
        uint256 policyId
    ) external onlyRouter returns (bool) {
        if (amount == 0) return true;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        emit PremiumReceived(amount, productId, policyId);
        return true;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IVault
    function getVaultState() external view returns (VaultState memory) {
        uint256 total = totalAssets();
        return VaultState({
            totalAssets: total,
            allocatedAssets: _allocatedAssets,
            freeAssets: _freeAssets(),
            totalShares: totalSupply(),
            utilizationBps: total > 0 ? (_allocatedAssets * BPS) / total : 0,
            cooldownDuration: _cooldownDuration
        });
    }

    /// @inheritdoc IVault
    function freeAssets() external view returns (uint256) {
        return _freeAssets();
    }

    /// @inheritdoc IVault
    function allocatedAssets() external view returns (uint256) {
        return _allocatedAssets;
    }

    /// @inheritdoc IVault
    function utilizationBps() external view returns (uint256 bps) {
        uint256 total = totalAssets();
        if (total == 0) return 0;
        bps = (_allocatedAssets * BPS) / total;
    }

    /// @inheritdoc IVault
    function cooldownDuration() external view returns (uint32) {
        return _cooldownDuration;
    }

    /// @inheritdoc IVault
    function getWithdrawalRequest(address lp) external view returns (WithdrawalRequest memory) {
        return _withdrawalRequests[lp];
    }

    /// @inheritdoc IVault
    function availableCapacity(uint256 policyDurationSeconds) external view returns (uint256) {
        if (policyDurationSeconds > _cooldownDuration) return 0;
        return _freeAssets(); // Already accounts for allocated + pending (via shares conversion)
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN
    // ═══════════════════════════════════════════════════════════

    function setRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        _router = newRouter;
    }

    function setPolicyManager(address newPolicyManager) external onlyOwner {
        if (newPolicyManager == address(0)) revert ZeroAddress();
        _policyManager = newPolicyManager;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Free assets = total - allocated - pending withdrawals (in real-time value)
     * @dev [GM-1] Pending withdrawals tracked as SHARES, converted to assets here.
     *      This way, if share price changes (premiums accrue, payouts reduce),
     *      the pending value automatically adjusts. No drift, no griefing.
     */
    function _freeAssets() internal view returns (uint256) {
        uint256 total = totalAssets();
        uint256 pendingAssets = convertToAssets(_pendingWithdrawalShares);
        uint256 unavailable = _allocatedAssets + pendingAssets;
        if (unavailable >= total) return 0;
        return total - unavailable;
    }

    function _authorizeUpgrade(address /* newImplementation */) internal override onlyOwner {}

    // ═══════════════════════════════════════════════════════════
    //  ERC-4626 OVERRIDES — Lock down all direct entry/exit
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice [CC-3] Override deposit with MIN_DEPOSIT guard.
     * @dev No nonReentrant here — depositAssets() already has it.
     *      Direct callers also get MIN_DEPOSIT protection.
     */
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (assets < MIN_DEPOSIT) revert ZeroAmount();
        return super.deposit(assets, receiver);
    }

    /// @notice Disable standard withdraw
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("Use requestWithdrawal");
    }

    /// @notice Disable standard mint
    function mint(uint256, address) public pure override returns (uint256) {
        revert("Use depositAssets");
    }

    /**
     * @notice [CC-1] Override redeem to block direct calls.
     * @dev Without this, any LP could call redeem() directly and skip cooldown entirely.
     *      Only completeWithdrawal() can redeem via super.redeem().
     */
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("Use requestWithdrawal");
    }
}
