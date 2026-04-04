// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IVault} from "../interfaces/IVault.sol";
import {EmergencyPause} from "../core/EmergencyPause.sol";

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
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
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

    // ═══ Aave V3 integration ═══
    IAavePool public aavePool;
    IERC20 public aToken; // aBasUSDC

    // ═══ Pending queues (Aave liquidity fallback) ═══
    mapping(address => uint256) public pendingPayouts;
    mapping(address => uint256) public pendingWithdrawals;

    // ═══ Security controls ═══
    bool public depositsPaused;
    bool public withdrawalsPaused;
    uint256 public maxTotalDeposit;
    uint256 public maxDepositPerUser;
    mapping(address => uint256) public userDeposits;
    uint256 public maxPayoutPerTx;
    uint256 public dailyWithdrawLimit; // basis points of TVL
    uint256 public dailyWithdrawn;
    uint256 public lastWithdrawReset;
    uint256 public dailyWithdrawSnapshot; // [M-1] totalAssets at start of day

    /// @dev Storage gap for future upgrades (reduced from 50 to 46: 4 slots used post-gap)
    uint256[46] private __gap;

    // ═══ Oracle Mitigation: Payout-specific pause ═══
    bool public payoutsPaused;

    // ═══ Performance Fee (3% on positive yield at withdrawal) ═══
    uint16 public performanceFeeBps;         // 300 = 3%
    address public feeReceiver;
    mapping(address => uint256) public userCostBasisPerShare; // WAD precision (1e18)

    /// @notice Global emergency pause contract (APPENDED — UUPS-safe)
    address public emergencyPause;

    // ═══ Events ═══
    event PerformanceFeeCollected(address indexed user, uint256 fee, uint256 profit);
    event PayoutQueued(address indexed beneficiary, uint256 amount);
    event WithdrawalQueued(address indexed user, uint256 amount);
    event PendingPayoutClaimed(address indexed beneficiary, uint256 amount);
    event PendingWithdrawalClaimed(address indexed user, uint256 amount);
    event EmergencyWithdraw(uint256 amount);
    event DepositsPaused(bool paused);
    event WithdrawalsPaused(bool paused);
    event MaxTotalDepositUpdated(uint256 newMax);
    event MaxDepositPerUserUpdated(uint256 newMax);
    event MaxPayoutPerTxUpdated(uint256 newMax);
    event DailyWithdrawLimitUpdated(uint256 newBps);
    event PayoutsPaused(address indexed by);
    event PayoutsUnpaused(address indexed by);

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
        uint32 cooldownDuration_,
        address aavePool_,
        address aToken_
    ) internal onlyInitializing {
        if (owner_ == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();
        if (router_ == address(0)) revert ZeroAddress();
        if (policyManager_ == address(0)) revert ZeroAddress();
        if (aavePool_ == address(0)) revert ZeroAddress();
        if (aToken_ == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(asset_));
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _router = router_;
        _policyManager = policyManager_;
        _cooldownDuration = cooldownDuration_;
        aavePool = IAavePool(aavePool_);
        aToken = IERC20(aToken_);

        // Performance fee: 3% on positive yield at withdrawal
        performanceFeeBps = 300;
        feeReceiver = owner_;
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

    modifier whenProtocolNotPaused() {
        if (emergencyPause != address(0) && EmergencyPause(emergencyPause).protocolPaused()) {
            revert("Protocol emergency paused");
        }
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
    function depositAssets(uint256 assets, address receiver) external nonReentrant whenProtocolNotPaused returns (uint256 shares) {
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
        revert("CooldownIrrevocable");
    }

    /// @inheritdoc IVault
    function completeWithdrawal(address receiver) external nonReentrant whenProtocolNotPaused returns (uint256 assets) {
        require(!withdrawalsPaused, "Withdrawals paused");

        WithdrawalRequest storage req = _withdrawalRequests[msg.sender];
        if (req.cooldownEnd == 0) revert NoActiveWithdrawalRequest(msg.sender);
        if (block.timestamp < req.cooldownEnd) revert CooldownNotExpired(msg.sender, req.cooldownEnd, block.timestamp);

        uint256 shares = req.shares;
        if (balanceOf(msg.sender) < shares) revert InsufficientShares(shares, balanceOf(msg.sender));

        assets = convertToAssets(shares);

        // Check: enough non-allocated USDC to pay this withdrawal?
        uint256 nonAllocated = totalAssets() > _allocatedAssets
            ? totalAssets() - _allocatedAssets
            : 0;
        if (assets > nonAllocated) revert InsufficientLiquidity(assets, nonAllocated);

        // Daily withdraw limit
        if (dailyWithdrawLimit > 0) {
            if (block.timestamp > lastWithdrawReset + 1 days) {
                dailyWithdrawn = 0;
                lastWithdrawReset = block.timestamp;
                dailyWithdrawSnapshot = totalAssets();
            }
            uint256 base = dailyWithdrawSnapshot > 0 ? dailyWithdrawSnapshot : totalAssets();
            require(dailyWithdrawn + assets <= (base * dailyWithdrawLimit) / 10000, "Daily limit reached");
            dailyWithdrawn += assets;
        }

        // [C-1/C-2 FIX] Burn shares FIRST to prevent double-withdrawal
        _pendingWithdrawalShares -= shares;
        delete _withdrawalRequests[msg.sender];
        _burn(msg.sender, shares);

        // [FIX M-2] Decrement userDeposits so LP can re-deposit after withdrawal
        if (assets >= userDeposits[msg.sender]) {
            userDeposits[msg.sender] = 0;
        } else {
            userDeposits[msg.sender] -= assets;
        }

        // ═══ Performance Fee: 3% on positive yield ═══
        uint256 perfFee = 0;
        if (performanceFeeBps > 0 && feeReceiver != address(0) && userCostBasisPerShare[msg.sender] > 0) {
            uint256 costBasis = (shares * userCostBasisPerShare[msg.sender]) / 1e18;
            if (assets > costBasis) {
                uint256 profit = assets - costBasis;
                perfFee = (profit * performanceFeeBps) / BPS;
                emit PerformanceFeeCollected(msg.sender, perfFee, profit);
            }
        }
        // Update cost basis if user still has shares
        if (balanceOf(msg.sender) == 0) {
            delete userCostBasisPerShare[msg.sender];
        }

        uint256 grossAssets = assets;
        assets = assets - perfFee; // return net amount

        // Try to withdraw from Aave and deliver USDC
        try aavePool.withdraw(asset(), grossAssets, address(this)) {
            if (perfFee > 0) {
                IERC20(asset()).safeTransfer(feeReceiver, perfFee);
            }
            IERC20(asset()).safeTransfer(receiver, assets);
            emit WithdrawalCompleted(msg.sender, assets, shares);
        } catch {
            // Shares already burned; queue USDC for later claim
            pendingWithdrawals[receiver] += assets;
            emit WithdrawalQueued(receiver, assets);
            // [FIX QA-5] Queue performance fee so it's not lost
            if (perfFee > 0) {
                pendingWithdrawals[feeReceiver] += perfFee;
                emit WithdrawalQueued(feeReceiver, perfFee);
            }
        }
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

    function completeWithdrawalV2(address receiver) external nonReentrant whenProtocolNotPaused returns (uint256 assets) {
        require(!withdrawalsPaused, "Withdrawals paused"); // [H-2]

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

        // [C-1/C-2 FIX] Burn shares FIRST to prevent double-withdrawal
        _pendingQueueShares -= shares;
        queue[idx] = queue[queue.length - 1];
        queue.pop();
        _burn(msg.sender, shares);

        // [FIX M-2] Decrement userDeposits so LP can re-deposit after withdrawal
        if (assets >= userDeposits[msg.sender]) {
            userDeposits[msg.sender] = 0;
        } else {
            userDeposits[msg.sender] -= assets;
        }

        // ═══ Performance Fee: 3% on positive yield ═══
        uint256 perfFee = 0;
        if (performanceFeeBps > 0 && feeReceiver != address(0) && userCostBasisPerShare[msg.sender] > 0) {
            uint256 costBasis = (shares * userCostBasisPerShare[msg.sender]) / 1e18;
            if (assets > costBasis) {
                uint256 profit = assets - costBasis;
                perfFee = (profit * performanceFeeBps) / BPS;
                emit PerformanceFeeCollected(msg.sender, perfFee, profit);
            }
        }
        if (balanceOf(msg.sender) == 0) {
            delete userCostBasisPerShare[msg.sender];
        }

        uint256 grossAssets = assets;
        assets = assets - perfFee; // return net amount

        // Try to withdraw from Aave and deliver USDC
        try aavePool.withdraw(asset(), grossAssets, address(this)) {
            if (perfFee > 0) {
                IERC20(asset()).safeTransfer(feeReceiver, perfFee);
            }
            IERC20(asset()).safeTransfer(receiver, assets);
            emit WithdrawalCompleted(msg.sender, assets, shares);
        } catch {
            // Shares already burned; queue USDC for later claim (net of fee)
            pendingWithdrawals[receiver] += assets;
            emit WithdrawalQueued(receiver, assets);
            // [FIX QA-5] Queue performance fee so it's not lost
            if (perfFee > 0) {
                pendingWithdrawals[feeReceiver] += perfFee;
                emit WithdrawalQueued(feeReceiver, perfFee);
            }
        }
    }

    function cancelWithdrawalV2(uint256 index) external nonReentrant {
        revert("CooldownIrrevocable");
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
    /**
     * @inheritdoc IVault
     * @dev [C-3 FIX] Added beneficiary parameter. On success, USDC goes to recipient (Router
     *      for fee split). On Aave failure, pendingPayouts is keyed by beneficiary (the actual
     *      agent) so they can claim later via claimPendingPayout().
     */
    function executePayout(
        address recipient,
        uint256 amount,
        bytes32 productId,
        uint256 policyId,
        address beneficiary
    ) external onlyRouter nonReentrant whenNotPaused returns (bool) {
        require(!payoutsPaused, "Payouts paused");
        if (amount == 0) return true;
        if (recipient == address(0)) revert ZeroAddress();
        if (beneficiary == address(0)) revert ZeroAddress();
        require(maxPayoutPerTx == 0 || amount <= maxPayoutPerTx, "Payout exceeds max");

        try aavePool.withdraw(asset(), amount, address(this)) {
            IERC20(asset()).safeTransfer(recipient, amount);
        } catch {
            // [C-3] Queue for the actual beneficiary, not the Router
            pendingPayouts[beneficiary] += amount;
            emit PayoutQueued(beneficiary, amount);
        }

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

        if (_aaveHealthCheck()) {
            IERC20(asset()).approve(address(aavePool), 0);
            IERC20(asset()).approve(address(aavePool), amount);
            aavePool.supply(asset(), amount, address(this), 0);
        }

        emit PremiumReceived(amount, productId, policyId);
        return true;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this)) + IERC20(asset()).balanceOf(address(this));
    }

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

    function setEmergencyPause(address _emergencyPause) external onlyOwner {
        emergencyPause = _emergencyPause;
    }

    function setPolicyManager(address newPolicyManager) external onlyOwner {
        if (newPolicyManager == address(0)) revert ZeroAddress();
        _policyManager = newPolicyManager;
    }

    /// @notice Update cooldown duration (actuarial adjustment)
    /// @dev Only callable by owner (TimelockController). Cannot set below 7 days.
    function setCooldownDuration(uint32 newCooldown) external onlyOwner {
        require(newCooldown >= 7 days, "Cooldown too short");
        _cooldownDuration = newCooldown;
    }

    // ═══ Security Admin ═══
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function pauseDeposits() external onlyOwner { depositsPaused = true; emit DepositsPaused(true); }
    function unpauseDeposits() external onlyOwner { depositsPaused = false; emit DepositsPaused(false); }
    function pauseWithdrawals() external onlyOwner { withdrawalsPaused = true; emit WithdrawalsPaused(true); }
    function unpauseWithdrawals() external onlyOwner { withdrawalsPaused = false; emit WithdrawalsPaused(false); }
    function setMaxTotalDeposit(uint256 _max) external onlyOwner { maxTotalDeposit = _max; emit MaxTotalDepositUpdated(_max); }
    function setMaxDepositPerUser(uint256 _max) external onlyOwner { maxDepositPerUser = _max; emit MaxDepositPerUserUpdated(_max); }
    function setMaxPayoutPerTx(uint256 _max) external onlyOwner { maxPayoutPerTx = _max; emit MaxPayoutPerTxUpdated(_max); }
    function setDailyWithdrawLimit(uint256 _bps) external onlyOwner { dailyWithdrawLimit = _bps; emit DailyWithdrawLimitUpdated(_bps); }
    function setPerformanceFee(uint16 _bps) external onlyOwner { require(_bps <= 1000, "Max 10%"); performanceFeeBps = _bps; }
    function setFeeReceiver(address _receiver) external onlyOwner { require(_receiver != address(0), "Zero address"); feeReceiver = _receiver; }
    function pausePayouts() external onlyOwner { payoutsPaused = true; emit PayoutsPaused(msg.sender); }
    function unpausePayouts() external onlyOwner { payoutsPaused = false; emit PayoutsUnpaused(msg.sender); }

    function emergencyWithdrawFromAave() external onlyOwner nonReentrant {
        uint256 aBalance = aToken.balanceOf(address(this));
        if (aBalance > 0) {
            aavePool.withdraw(asset(), type(uint256).max, address(this));
        }
        emit EmergencyWithdraw(aBalance);
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
        uint256 pendingAssets = convertToAssets(_pendingWithdrawalShares + _pendingQueueShares);
        uint256 unavailable = _allocatedAssets + pendingAssets;
        if (unavailable >= total) return 0;
        return total - unavailable;
    }

    function _authorizeUpgrade(address /* newImplementation */) internal override onlyOwner {}

    function _aaveHealthCheck() internal view returns (bool) {
        try aToken.balanceOf(address(this)) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  CLAIM PENDING
    // ═══════════════════════════════════════════════════════════

    function claimPendingPayout() external nonReentrant whenProtocolNotPaused {
        uint256 amount = pendingPayouts[msg.sender];
        require(amount > 0, "No pending payout");
        pendingPayouts[msg.sender] = 0;
        aavePool.withdraw(asset(), amount, address(this));
        IERC20(asset()).safeTransfer(msg.sender, amount);
        emit PendingPayoutClaimed(msg.sender, amount);
    }

    function claimPendingWithdrawal() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No pending withdrawal");
        pendingWithdrawals[msg.sender] = 0;
        aavePool.withdraw(asset(), amount, address(this));
        IERC20(asset()).safeTransfer(msg.sender, amount);
        emit PendingWithdrawalClaimed(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  ERC-4626 OVERRIDES — Lock down all direct entry/exit
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice [CC-3] Override deposit with MIN_DEPOSIT guard.
     * @dev No nonReentrant here — depositAssets() already has it.
     *      Direct callers also get MIN_DEPOSIT protection.
     */
    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256) {
        if (assets < MIN_DEPOSIT) revert ZeroAmount();
        require(!depositsPaused, "Deposits paused");
        require(totalAssets() + assets <= maxTotalDeposit || maxTotalDeposit == 0, "Vault cap reached");
        require(userDeposits[receiver] + assets <= maxDepositPerUser || maxDepositPerUser == 0, "User cap reached");

        userDeposits[receiver] += assets;

        // Track cost basis for performance fee (weighted average price per share)
        uint256 existingShares = balanceOf(receiver);
        uint256 shares = super.deposit(assets, receiver);
        uint256 newShares = shares;
        if (existingShares == 0) {
            // First deposit: cost basis = assets per share (WAD precision)
            userCostBasisPerShare[receiver] = (assets * 1e18) / newShares;
        } else {
            // Weighted average: (oldBasis * oldShares + newAssets * 1e18) / totalShares
            uint256 oldValue = userCostBasisPerShare[receiver] * existingShares;
            uint256 newValue = assets * 1e18;
            userCostBasisPerShare[receiver] = (oldValue + newValue) / (existingShares + newShares);
        }

        // Supply to Aave if healthy
        if (_aaveHealthCheck()) {
            IERC20(asset()).approve(address(aavePool), 0);
            IERC20(asset()).approve(address(aavePool), assets);
            aavePool.supply(asset(), assets, address(this), 0);
        }

        return shares;
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
