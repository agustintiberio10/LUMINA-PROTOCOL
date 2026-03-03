// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MutualPool
 * @author MutualBot Insurance Protocol
 * @notice Decentralized mutual insurance protocol for AI agents on Base L2.
 *
 * @dev Architecture (M2M-readable):
 *
 *   ┌─────────────────────────────────────────────────────────┐
 *   │ POOL LIFECYCLE                                          │
 *   │                                                         │
 *   │  createPool() ──► Open ──► joinPool() fills collateral  │
 *   │                    │        totalCollateral >= coverage  │
 *   │                    │        ──► Active                   │
 *   │                    │                                     │
 *   │  depositDeadline reached & underfunded:                  │
 *   │    cancelAndRefund() ──► Cancelled (all refunded)        │
 *   │                                                          │
 *   │  deadline reached:                                       │
 *   │    resolvePool(oracle) ──► Resolved                      │
 *   │                                                          │
 *   │  deadline + 24h & oracle silent:                         │
 *   │    emergencyResolve(anyone) ──► Resolved (no claim)      │
 *   │                                                          │
 *   │  withdraw() ──► funds returned per accounting rules      │
 *   └─────────────────────────────────────────────────────────┘
 *
 *   Fund Segregation:
 *     premiumPool  = premiumPaid - protocolFee   (earned by providers)
 *     collateralPool = totalCollateral            (returned or paid to insured)
 *
 *   Withdrawal Math (per provider with contribution C, totalCollateral T):
 *     claimApproved == false:
 *       payout = C + (C × premiumAfterFee / T)
 *     claimApproved == true:
 *       payout = (C × premiumAfterFee / T) + (C × excess / T)
 *       where excess = max(T - coverageAmount, 0)
 *       insured receives: min(coverageAmount, T)
 *
 *   Protocol fee (3%) is ONLY charged on successful resolution, not cancellation.
 */
contract MutualPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════
    // CONSTANTS
    // ══════════════════════════════════════════════════════════

    /// @notice Protocol treasury address for fee collection.
    address public constant PROTOCOL_OWNER = 0x2b4D825417f568231e809E31B9332ED146760337;

    /// @notice Protocol fee in basis points (3% = 300 bps).
    uint256 public constant PROTOCOL_FEE_BPS = 300;

    /// @notice Minimum USDC contribution (10 USDC with 6 decimals).
    uint256 public constant MIN_CONTRIBUTION = 10e6;

    /// @notice Basis points denominator (10000 = 100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Deposit window closes this many seconds before the resolution deadline.
    /// @dev Prevents front-running: no deposits allowed within 2 hours of deadline.
    uint256 public constant DEPOSIT_WINDOW_BUFFER = 2 hours;

    /// @notice Grace period after deadline for oracle to resolve before emergency resolve unlocks.
    uint256 public constant EMERGENCY_RESOLVE_DELAY = 24 hours;

    // ══════════════════════════════════════════════════════════
    // STATE
    // ══════════════════════════════════════════════════════════

    /// @notice USDC token contract (immutable, set at deployment).
    IERC20 public immutable usdc;

    /// @notice Oracle address — only this address can call resolvePool().
    address public oracle;

    /// @notice Auto-incrementing pool ID counter.
    uint256 public nextPoolId;

    /// @notice Pool lifecycle states.
    enum PoolStatus { Open, Active, Resolved, Cancelled }

    /// @notice Core pool data structure.
    /// @dev All monetary values in USDC (6 decimals).
    struct PoolInfo {
        uint256 id;
        string description;
        string evidenceSource;
        uint256 coverageAmount;       // Target coverage in USDC
        uint256 premiumRate;          // Basis points (e.g., 500 = 5%)
        uint256 deadline;             // Unix timestamp — resolution window opens
        uint256 depositDeadline;      // Unix timestamp — deposit window closes (deadline - 2h)
        address insured;              // Address that pays premium and receives claim
        uint256 premiumPaid;          // Actual USDC premium transferred
        uint256 totalCollateral;      // Sum of all provider contributions
        PoolStatus status;
        bool claimApproved;           // True if oracle confirmed the insured event
        uint256 premiumAfterFee;      // Segregated: premium minus protocol fee (set on resolve)
        uint256 protocolFee;          // Segregated: protocol fee (set on resolve)
        address[] participants;
    }

    /// @dev Pool ID => PoolInfo
    mapping(uint256 => PoolInfo) public pools;

    /// @dev Pool ID => participant address => contribution amount
    mapping(uint256 => mapping(address => uint256)) public contributions;

    /// @dev Pool ID => participant address => withdrawn flag
    mapping(uint256 => mapping(address => bool)) public hasWithdrawn;

    /// @dev Pool ID => insured withdrawn flag
    mapping(uint256 => bool) public insuredWithdrawn;

    // ══════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════

    event PoolCreated(
        uint256 indexed poolId,
        address indexed insured,
        string description,
        uint256 coverageAmount,
        uint256 premiumRate,
        uint256 deadline,
        uint256 depositDeadline
    );

    event AgentJoined(
        uint256 indexed poolId,
        address indexed participant,
        uint256 amount
    );

    event PoolActivated(uint256 indexed poolId, uint256 totalCollateral);

    event PoolResolved(
        uint256 indexed poolId,
        bool claimApproved,
        uint256 totalCollateral,
        uint256 premiumAfterFee,
        uint256 protocolFee
    );

    event PoolCancelled(uint256 indexed poolId, uint256 totalCollateral, uint256 premiumRefunded);

    event EmergencyResolved(uint256 indexed poolId, address indexed triggeredBy);

    event FeeCollected(uint256 indexed poolId, uint256 feeAmount);

    event Withdrawn(
        uint256 indexed poolId,
        address indexed participant,
        uint256 amount
    );

    // ══════════════════════════════════════════════════════════
    // MODIFIERS
    // ══════════════════════════════════════════════════════════

    modifier onlyOracle() {
        require(msg.sender == oracle, "MutualPool: caller is not the oracle");
        _;
    }

    modifier poolExists(uint256 poolId) {
        require(poolId < nextPoolId, "MutualPool: pool does not exist");
        _;
    }

    // ══════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════

    /**
     * @param _usdc Address of the USDC token contract on this chain.
     * @param _oracle Address of the oracle agent wallet that resolves pools.
     */
    constructor(address _usdc, address _oracle) Ownable(msg.sender) {
        require(_usdc != address(0), "MutualPool: invalid USDC address");
        require(_oracle != address(0), "MutualPool: invalid oracle address");
        usdc = IERC20(_usdc);
        oracle = _oracle;
    }

    // ══════════════════════════════════════════════════════════
    // POOL CREATION
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Create a new insurance pool. Caller becomes the insured and pays the premium upfront.
     * @dev depositDeadline = deadline - DEPOSIT_WINDOW_BUFFER (2h).
     *      Requires deadline > now + DEPOSIT_WINDOW_BUFFER so there is a valid deposit window.
     *
     * @param _description  Human-readable description of the covered event.
     * @param _evidenceSource  Public URL to verify the outcome (e.g., status page).
     * @param _coverageAmount  USDC amount that covers the claim (6 decimals).
     * @param _premiumRate  Premium rate in basis points (e.g., 500 = 5% of coverageAmount).
     * @param _deadline  Unix timestamp when the pool can be resolved by the oracle.
     * @return poolId  The ID of the newly created pool.
     */
    function createPool(
        string calldata _description,
        string calldata _evidenceSource,
        uint256 _coverageAmount,
        uint256 _premiumRate,
        uint256 _deadline
    ) external nonReentrant returns (uint256 poolId) {
        require(_coverageAmount >= MIN_CONTRIBUTION, "MutualPool: coverage too low");
        require(_premiumRate > 0 && _premiumRate < BPS_DENOMINATOR, "MutualPool: invalid premium rate");
        require(_deadline > block.timestamp + DEPOSIT_WINDOW_BUFFER, "MutualPool: deadline too soon");
        require(bytes(_description).length > 0, "MutualPool: empty description");
        require(bytes(_evidenceSource).length > 0, "MutualPool: empty evidence source");

        uint256 premium = (_coverageAmount * _premiumRate) / BPS_DENOMINATOR;
        require(premium > 0, "MutualPool: premium is zero");

        poolId = nextPoolId++;

        PoolInfo storage pool = pools[poolId];
        pool.id = poolId;
        pool.description = _description;
        pool.evidenceSource = _evidenceSource;
        pool.coverageAmount = _coverageAmount;
        pool.premiumRate = _premiumRate;
        pool.deadline = _deadline;
        pool.depositDeadline = _deadline - DEPOSIT_WINDOW_BUFFER;
        pool.insured = msg.sender;
        pool.premiumPaid = premium;
        pool.status = PoolStatus.Open;

        usdc.safeTransferFrom(msg.sender, address(this), premium);

        emit PoolCreated(poolId, msg.sender, _description, _coverageAmount, _premiumRate, _deadline, pool.depositDeadline);
    }

    // ══════════════════════════════════════════════════════════
    // JOINING A POOL
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Join a pool by contributing USDC as collateral.
     * @dev Reverts if block.timestamp >= depositDeadline (anti front-running).
     *      Auto-activates pool when totalCollateral >= coverageAmount.
     *
     * @param _poolId  The pool to join.
     * @param _amount  USDC amount to contribute (6 decimals, >= MIN_CONTRIBUTION).
     */
    function joinPool(uint256 _poolId, uint256 _amount)
        external
        nonReentrant
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(pool.status == PoolStatus.Open, "MutualPool: pool is not open");
        require(block.timestamp < pool.depositDeadline, "MutualPool: deposit window closed");
        require(_amount >= MIN_CONTRIBUTION, "MutualPool: below minimum contribution");
        require(msg.sender != pool.insured, "MutualPool: insured cannot join as participant");

        if (contributions[_poolId][msg.sender] == 0) {
            pool.participants.push(msg.sender);
        }
        contributions[_poolId][msg.sender] += _amount;
        pool.totalCollateral += _amount;

        usdc.safeTransferFrom(msg.sender, address(this), _amount);

        emit AgentJoined(_poolId, msg.sender, _amount);

        // Auto-activate when collateral reaches coverage amount
        if (pool.totalCollateral >= pool.coverageAmount && pool.status == PoolStatus.Open) {
            pool.status = PoolStatus.Active;
            emit PoolActivated(_poolId, pool.totalCollateral);
        }
    }

    // ══════════════════════════════════════════════════════════
    // CANCELLATION (Underfunded pools)
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Cancel and refund an underfunded pool after the deposit deadline passes.
     * @dev Anyone can call this. Conditions:
     *      - block.timestamp >= depositDeadline
     *      - totalCollateral < coverageAmount (pool never activated)
     *      - Pool status is still Open
     *
     *      Refunds premium to insured, allows providers to withdraw their collateral
     *      via withdraw(). No protocol fee is charged on cancellation.
     *
     * @param _poolId  The pool to cancel.
     */
    function cancelAndRefund(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(pool.status == PoolStatus.Open, "MutualPool: pool is not open");
        require(block.timestamp >= pool.depositDeadline, "MutualPool: deposit window still open");
        require(pool.totalCollateral < pool.coverageAmount, "MutualPool: pool is fully funded");

        pool.status = PoolStatus.Cancelled;

        // Refund premium to insured — no fee on cancellation
        if (pool.premiumPaid > 0) {
            usdc.safeTransfer(pool.insured, pool.premiumPaid);
        }

        emit PoolCancelled(_poolId, pool.totalCollateral, pool.premiumPaid);
    }

    // ══════════════════════════════════════════════════════════
    // ORACLE RESOLUTION
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Resolve a pool. Only callable by the oracle after the deadline.
     * @dev Segregates funds into premiumAfterFee and protocolFee.
     *      Protocol fee (3%) is ONLY charged on successful resolution, not cancellation.
     *
     * @param _poolId  The pool to resolve.
     * @param _claimApproved  true if the insured event occurred, false otherwise.
     */
    function resolvePool(uint256 _poolId, bool _claimApproved)
        external
        nonReentrant
        onlyOracle
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(
            pool.status == PoolStatus.Active || pool.status == PoolStatus.Open,
            "MutualPool: pool not resolvable"
        );
        require(block.timestamp >= pool.deadline, "MutualPool: deadline not reached");

        pool.status = PoolStatus.Resolved;
        pool.claimApproved = _claimApproved;

        // Segregate funds: calculate fee and net premium
        uint256 fee = (pool.premiumPaid * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netPremium = pool.premiumPaid - fee;

        pool.protocolFee = fee;
        pool.premiumAfterFee = netPremium;

        // Transfer protocol fee
        if (fee > 0) {
            usdc.safeTransfer(PROTOCOL_OWNER, fee);
            emit FeeCollected(_poolId, fee);
        }

        emit PoolResolved(_poolId, _claimApproved, pool.totalCollateral, netPremium, fee);
    }

    // ══════════════════════════════════════════════════════════
    // EMERGENCY RESOLUTION (Oracle timeout)
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Emergency resolve a pool when the oracle fails to act within 24h of deadline.
     * @dev Anyone can call this after deadline + EMERGENCY_RESOLVE_DELAY (24h).
     *      Defaults to claimApproved = false (providers keep collateral).
     *      This is a safety mechanism against oracle liveness failures.
     *
     * @param _poolId  The pool to emergency-resolve.
     */
    function emergencyResolve(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(
            pool.status == PoolStatus.Active || pool.status == PoolStatus.Open,
            "MutualPool: pool not resolvable"
        );
        require(
            block.timestamp >= pool.deadline + EMERGENCY_RESOLVE_DELAY,
            "MutualPool: emergency resolve not yet available"
        );

        pool.status = PoolStatus.Resolved;
        pool.claimApproved = false; // Safety default: no claim

        // Segregate funds
        uint256 fee = (pool.premiumPaid * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netPremium = pool.premiumPaid - fee;

        pool.protocolFee = fee;
        pool.premiumAfterFee = netPremium;

        if (fee > 0) {
            usdc.safeTransfer(PROTOCOL_OWNER, fee);
            emit FeeCollected(_poolId, fee);
        }

        emit EmergencyResolved(_poolId, msg.sender);
        emit PoolResolved(_poolId, false, pool.totalCollateral, netPremium, fee);
    }

    // ══════════════════════════════════════════════════════════
    // WITHDRAWAL
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Withdraw funds after a pool has been resolved or cancelled.
     *
     * @dev Accounting rules with segregated fund pools:
     *
     *   RESOLVED (claimApproved == false):
     *     Provider payout = contribution + (contribution × premiumAfterFee / totalCollateral)
     *     Insured payout  = 0 (premium was the cost of protection)
     *
     *   RESOLVED (claimApproved == true):
     *     Insured payout  = min(coverageAmount, totalCollateral)
     *     Provider payout = (contribution × premiumAfterFee / totalCollateral)
     *                     + (contribution × excess / totalCollateral)
     *     where excess    = max(totalCollateral - coverageAmount, 0)
     *
     *   CANCELLED:
     *     Provider payout = contribution (full refund, premium already returned to insured)
     *     Insured payout  = 0 (premium was already refunded in cancelAndRefund)
     *
     * @param _poolId  The pool to withdraw from.
     */
    function withdraw(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(
            pool.status == PoolStatus.Resolved || pool.status == PoolStatus.Cancelled,
            "MutualPool: pool not resolved or cancelled"
        );

        // ── CANCELLED: providers get full collateral back ──
        if (pool.status == PoolStatus.Cancelled) {
            require(msg.sender != pool.insured, "MutualPool: insured already refunded on cancel");

            uint256 contribution = contributions[_poolId][msg.sender];
            require(contribution > 0, "MutualPool: no contribution");
            require(!hasWithdrawn[_poolId][msg.sender], "MutualPool: already withdrawn");
            hasWithdrawn[_poolId][msg.sender] = true;

            usdc.safeTransfer(msg.sender, contribution);
            emit Withdrawn(_poolId, msg.sender, contribution);
            return;
        }

        // ── RESOLVED ──
        uint256 premiumNet = pool.premiumAfterFee;

        if (pool.claimApproved) {
            // ── Claim approved: insured gets coverage, providers get premium share + excess ──
            if (msg.sender == pool.insured) {
                require(!insuredWithdrawn[_poolId], "MutualPool: already withdrawn");
                insuredWithdrawn[_poolId] = true;

                uint256 payout = pool.coverageAmount;
                if (payout > pool.totalCollateral) {
                    payout = pool.totalCollateral;
                }
                usdc.safeTransfer(msg.sender, payout);
                emit Withdrawn(_poolId, msg.sender, payout);
            } else {
                uint256 contribution = contributions[_poolId][msg.sender];
                require(contribution > 0, "MutualPool: no contribution");
                require(!hasWithdrawn[_poolId][msg.sender], "MutualPool: already withdrawn");
                hasWithdrawn[_poolId][msg.sender] = true;

                // Provider gets: proportional premium share + proportional excess collateral
                uint256 payout = 0;

                // Premium share (always available for providers)
                payout += (premiumNet * contribution) / pool.totalCollateral;

                // Excess collateral share (if totalCollateral > coverageAmount)
                if (pool.totalCollateral > pool.coverageAmount) {
                    uint256 excess = pool.totalCollateral - pool.coverageAmount;
                    payout += (excess * contribution) / pool.totalCollateral;
                }

                if (payout > 0) {
                    usdc.safeTransfer(msg.sender, payout);
                }
                emit Withdrawn(_poolId, msg.sender, payout);
            }
        } else {
            // ── No claim: providers get collateral back + premium share ──
            if (msg.sender == pool.insured) {
                revert("MutualPool: insured has no withdrawal when no claim");
            }

            uint256 contribution = contributions[_poolId][msg.sender];
            require(contribution > 0, "MutualPool: no contribution");
            require(!hasWithdrawn[_poolId][msg.sender], "MutualPool: already withdrawn");
            hasWithdrawn[_poolId][msg.sender] = true;

            // Provider gets: full collateral + proportional premium share
            uint256 premiumShare = (premiumNet * contribution) / pool.totalCollateral;
            uint256 payout = contribution + premiumShare;

            usdc.safeTransfer(msg.sender, payout);
            emit Withdrawn(_poolId, msg.sender, payout);
        }
    }

    // ══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Get participants of a pool.
     */
    function getPoolParticipants(uint256 _poolId)
        external
        view
        poolExists(_poolId)
        returns (address[] memory)
    {
        return pools[_poolId].participants;
    }

    /**
     * @notice Get full pool info (ABI-readable by other agents).
     */
    function getPool(uint256 _poolId)
        external
        view
        poolExists(_poolId)
        returns (
            string memory description,
            string memory evidenceSource,
            uint256 coverageAmount,
            uint256 premiumRate,
            uint256 deadline,
            uint256 depositDeadline,
            address insured,
            uint256 premiumPaid,
            uint256 totalCollateral,
            PoolStatus status,
            bool claimApproved,
            uint256 participantCount
        )
    {
        PoolInfo storage pool = pools[_poolId];
        return (
            pool.description,
            pool.evidenceSource,
            pool.coverageAmount,
            pool.premiumRate,
            pool.deadline,
            pool.depositDeadline,
            pool.insured,
            pool.premiumPaid,
            pool.totalCollateral,
            pool.status,
            pool.claimApproved,
            pool.participants.length
        );
    }

    /**
     * @notice Get the contribution of a specific participant in a pool.
     */
    function getContribution(uint256 _poolId, address _participant)
        external
        view
        poolExists(_poolId)
        returns (uint256)
    {
        return contributions[_poolId][_participant];
    }

    /**
     * @notice Get segregated accounting info for a resolved pool.
     * @return premiumAfterFee  Net premium available to providers.
     * @return protocolFee  Fee collected by protocol.
     * @return totalCollateral  Total collateral in the pool.
     */
    function getPoolAccounting(uint256 _poolId)
        external
        view
        poolExists(_poolId)
        returns (uint256 premiumAfterFee, uint256 protocolFee, uint256 totalCollateral)
    {
        PoolInfo storage pool = pools[_poolId];
        return (pool.premiumAfterFee, pool.protocolFee, pool.totalCollateral);
    }

    // ══════════════════════════════════════════════════════════
    // ADMIN
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Update the oracle address. Only callable by the contract owner.
     */
    function setOracle(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "MutualPool: invalid oracle address");
        oracle = _newOracle;
    }
}
