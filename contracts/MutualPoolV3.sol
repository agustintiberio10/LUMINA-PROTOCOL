// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MutualPoolV3
 * @author MutualBot Insurance Protocol
 * @notice Decentralized mutual insurance vault for AI agents on Base L2.
 *
 * @dev V3 changes from V1:
 *   - createPool() is ZERO-FUNDED: only oracle creates the pool structure (gas only).
 *   - fundPremium() and joinPool() are ROUTER-GATED: only the authorized Router
 *     contract can deposit funds. This enforces the MPOOLV3 token gateway.
 *   - withdraw() remains open to any participant after resolution.
 *   - All internal accounting is 100% USDC. The vault never touches MPOOLV3.
 *
 *   ┌─────────────────────────────────────────────────────────┐
 *   │ POOL LIFECYCLE                                          │
 *   │                                                         │
 *   │  createPool() ──► Pending (zero-funded, no USDC)        │
 *   │       │                                                 │
 *   │  fundPremium() via Router ──► Open (premium deposited)  │
 *   │       │                                                 │
 *   │  joinPool() via Router fills collateral                 │
 *   │    totalCollateral >= coverage ──► Active                │
 *   │                                                         │
 *   │  depositDeadline & underfunded:                         │
 *   │    cancelAndRefund() ──► Cancelled                      │
 *   │                                                         │
 *   │  deadline reached:                                      │
 *   │    resolvePool(oracle) ──► Resolved                     │
 *   │                                                         │
 *   │  deadline + 24h & oracle silent:                        │
 *   │    emergencyResolve(anyone) ──► Resolved (no claim)     │
 *   │                                                         │
 *   │  withdraw() ──► funds returned per accounting rules     │
 *   └─────────────────────────────────────────────────────────┘
 */
contract MutualPoolV3 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════
    // CONSTANTS
    // ══════════════════════════════════════════════════════════

    /// @notice Protocol treasury for fee collection.
    address public constant PROTOCOL_OWNER = 0x2b4D825417f568231e809E31B9332ED146760337;

    /// @notice Protocol fee: 3% (300 bps).
    uint256 public constant PROTOCOL_FEE_BPS = 300;

    /// @notice Minimum USDC contribution (10 USDC, 6 decimals).
    uint256 public constant MIN_CONTRIBUTION = 10e6;

    /// @notice Basis points denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Deposit window closes 2h before resolution deadline.
    uint256 public constant DEPOSIT_WINDOW_BUFFER = 2 hours;

    /// @notice Emergency resolve unlocks 24h after deadline.
    uint256 public constant EMERGENCY_RESOLVE_DELAY = 24 hours;

    // ══════════════════════════════════════════════════════════
    // STATE
    // ══════════════════════════════════════════════════════════

    IERC20 public immutable usdc;
    address public oracle;
    address public router; // Only the Router can call fundPremium/joinPool

    uint256 public nextPoolId;

    /// @notice V3 adds Pending state (pool created but no premium yet).
    enum PoolStatus { Pending, Open, Active, Resolved, Cancelled }

    struct PoolInfo {
        uint256 id;
        string description;
        string evidenceSource;
        uint256 coverageAmount;
        uint256 premiumRate;        // Basis points
        uint256 deadline;
        uint256 depositDeadline;
        address insured;            // Set when fundPremium() is called
        uint256 premiumPaid;
        uint256 totalCollateral;
        PoolStatus status;
        bool claimApproved;
        uint256 premiumAfterFee;
        uint256 protocolFee;
        address[] participants;
    }

    mapping(uint256 => PoolInfo) public pools;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(uint256 => mapping(address => bool)) public hasWithdrawn;
    mapping(uint256 => bool) public insuredWithdrawn;

    // ══════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════

    event PoolCreated(uint256 indexed poolId, string description, uint256 coverageAmount, uint256 premiumRate, uint256 deadline);
    event PremiumFunded(uint256 indexed poolId, address indexed insured, uint256 premiumAmount);
    event AgentJoined(uint256 indexed poolId, address indexed participant, uint256 amount);
    event PoolActivated(uint256 indexed poolId, uint256 totalCollateral);
    event PoolResolved(uint256 indexed poolId, bool claimApproved, uint256 totalCollateral, uint256 premiumAfterFee, uint256 protocolFee);
    event PoolCancelled(uint256 indexed poolId, uint256 totalCollateral, uint256 premiumRefunded);
    event EmergencyResolved(uint256 indexed poolId, address indexed triggeredBy);
    event FeeCollected(uint256 indexed poolId, uint256 feeAmount);
    event Withdrawn(uint256 indexed poolId, address indexed participant, uint256 amount);
    event RouterUpdated(address indexed newRouter);
    event OracleUpdated(address indexed newOracle);

    // ══════════════════════════════════════════════════════════
    // MODIFIERS
    // ══════════════════════════════════════════════════════════

    modifier onlyOracle() {
        require(msg.sender == oracle, "V3: not oracle");
        _;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "V3: not router");
        _;
    }

    modifier poolExists(uint256 poolId) {
        require(poolId < nextPoolId, "V3: pool does not exist");
        _;
    }

    // ══════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════

    constructor(address _usdc, address _oracle) Ownable(msg.sender) {
        require(_usdc != address(0), "V3: invalid USDC");
        require(_oracle != address(0), "V3: invalid oracle");
        usdc = IERC20(_usdc);
        oracle = _oracle;
    }

    // ══════════════════════════════════════════════════════════
    // POOL CREATION (Zero-funded — oracle/owner only)
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Create pool structure with zero funds. Only the oracle pays gas.
     * @dev Pool starts in Pending status. No USDC is transferred.
     *      fundPremium() must be called via Router to activate deposits.
     */
    function createPool(
        string calldata _description,
        string calldata _evidenceSource,
        uint256 _coverageAmount,
        uint256 _premiumRate,
        uint256 _deadline
    ) external onlyOracle returns (uint256 poolId) {
        require(_coverageAmount >= MIN_CONTRIBUTION, "V3: coverage too low");
        require(_premiumRate > 0 && _premiumRate < BPS_DENOMINATOR, "V3: invalid premium rate");
        require(_deadline > block.timestamp + DEPOSIT_WINDOW_BUFFER, "V3: deadline too soon");
        require(bytes(_description).length > 0, "V3: empty description");
        require(bytes(_evidenceSource).length > 0, "V3: empty evidence");

        poolId = nextPoolId++;

        PoolInfo storage pool = pools[poolId];
        pool.id = poolId;
        pool.description = _description;
        pool.evidenceSource = _evidenceSource;
        pool.coverageAmount = _coverageAmount;
        pool.premiumRate = _premiumRate;
        pool.deadline = _deadline;
        pool.depositDeadline = _deadline - DEPOSIT_WINDOW_BUFFER;
        pool.status = PoolStatus.Pending;
        // pool.insured is address(0) until fundPremium()

        emit PoolCreated(poolId, _description, _coverageAmount, _premiumRate, _deadline);
    }

    // ══════════════════════════════════════════════════════════
    // FUND PREMIUM (Router-gated)
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Fund the premium for a pending pool. Router-only.
     * @dev Transitions pool from Pending → Open. Sets the insured address.
     *      The Router already holds the USDC (swapped from MPOOLV3 or received directly).
     *
     * @param _poolId Pool to fund.
     * @param _insured Address that will receive the claim payout.
     */
    function fundPremium(uint256 _poolId, address _insured)
        external
        nonReentrant
        onlyRouter
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(pool.status == PoolStatus.Pending, "V3: pool not pending");
        require(_insured != address(0), "V3: invalid insured");
        require(block.timestamp < pool.depositDeadline, "V3: deposit window closed");

        uint256 premium = (pool.coverageAmount * pool.premiumRate) / BPS_DENOMINATOR;
        require(premium > 0, "V3: premium is zero");

        pool.insured = _insured;
        pool.premiumPaid = premium;
        pool.status = PoolStatus.Open;

        usdc.safeTransferFrom(msg.sender, address(this), premium);

        emit PremiumFunded(_poolId, _insured, premium);
    }

    // ══════════════════════════════════════════════════════════
    // JOIN POOL (Router-gated)
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Join a pool as collateral provider. Router-only.
     * @dev The Router already converted MPOOLV3→USDC if needed.
     *
     * @param _poolId Pool to join.
     * @param _amount USDC collateral amount (6 decimals).
     * @param _participant Address of the actual provider (not the Router).
     */
    function joinPool(uint256 _poolId, uint256 _amount, address _participant)
        external
        nonReentrant
        onlyRouter
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(pool.status == PoolStatus.Open, "V3: pool not open");
        require(block.timestamp < pool.depositDeadline, "V3: deposit window closed");
        require(_amount >= MIN_CONTRIBUTION, "V3: below minimum");
        require(_participant != pool.insured, "V3: insured cannot join");

        if (contributions[_poolId][_participant] == 0) {
            pool.participants.push(_participant);
        }
        contributions[_poolId][_participant] += _amount;
        pool.totalCollateral += _amount;

        usdc.safeTransferFrom(msg.sender, address(this), _amount);

        emit AgentJoined(_poolId, _participant, _amount);

        if (pool.totalCollateral >= pool.coverageAmount && pool.status == PoolStatus.Open) {
            pool.status = PoolStatus.Active;
            emit PoolActivated(_poolId, pool.totalCollateral);
        }
    }

    // ══════════════════════════════════════════════════════════
    // CANCELLATION
    // ══════════════════════════════════════════════════════════

    function cancelAndRefund(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(
            pool.status == PoolStatus.Open || pool.status == PoolStatus.Pending,
            "V3: not cancellable"
        );
        require(block.timestamp >= pool.depositDeadline, "V3: deposit window still open");

        // Pending pools with no premium can be cancelled immediately
        if (pool.status == PoolStatus.Open) {
            require(pool.totalCollateral < pool.coverageAmount, "V3: pool is funded");
        }

        pool.status = PoolStatus.Cancelled;

        // Refund premium to insured (if funded)
        if (pool.premiumPaid > 0 && pool.insured != address(0)) {
            usdc.safeTransfer(pool.insured, pool.premiumPaid);
        }

        emit PoolCancelled(_poolId, pool.totalCollateral, pool.premiumPaid);
    }

    // ══════════════════════════════════════════════════════════
    // ORACLE RESOLUTION
    // ══════════════════════════════════════════════════════════

    function resolvePool(uint256 _poolId, bool _claimApproved)
        external
        nonReentrant
        onlyOracle
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(
            pool.status == PoolStatus.Active || pool.status == PoolStatus.Open,
            "V3: not resolvable"
        );
        require(block.timestamp >= pool.deadline, "V3: deadline not reached");

        pool.status = PoolStatus.Resolved;
        pool.claimApproved = _claimApproved;

        uint256 fee = (pool.premiumPaid * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 netPremium = pool.premiumPaid - fee;

        pool.protocolFee = fee;
        pool.premiumAfterFee = netPremium;

        if (fee > 0) {
            usdc.safeTransfer(PROTOCOL_OWNER, fee);
            emit FeeCollected(_poolId, fee);
        }

        emit PoolResolved(_poolId, _claimApproved, pool.totalCollateral, netPremium, fee);
    }

    // ══════════════════════════════════════════════════════════
    // EMERGENCY RESOLUTION
    // ══════════════════════════════════════════════════════════

    function emergencyResolve(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(
            pool.status == PoolStatus.Active || pool.status == PoolStatus.Open,
            "V3: not resolvable"
        );
        require(
            block.timestamp >= pool.deadline + EMERGENCY_RESOLVE_DELAY,
            "V3: emergency not available"
        );

        pool.status = PoolStatus.Resolved;
        pool.claimApproved = false;

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
    // WITHDRAWAL (open to all participants)
    // ══════════════════════════════════════════════════════════

    function withdraw(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        PoolInfo storage pool = pools[_poolId];
        require(
            pool.status == PoolStatus.Resolved || pool.status == PoolStatus.Cancelled,
            "V3: not resolved/cancelled"
        );

        if (pool.status == PoolStatus.Cancelled) {
            require(msg.sender != pool.insured, "V3: insured already refunded");
            uint256 contribution = contributions[_poolId][msg.sender];
            require(contribution > 0, "V3: no contribution");
            require(!hasWithdrawn[_poolId][msg.sender], "V3: already withdrawn");
            hasWithdrawn[_poolId][msg.sender] = true;

            usdc.safeTransfer(msg.sender, contribution);
            emit Withdrawn(_poolId, msg.sender, contribution);
            return;
        }

        // RESOLVED
        uint256 premiumNet = pool.premiumAfterFee;

        if (pool.claimApproved) {
            if (msg.sender == pool.insured) {
                require(!insuredWithdrawn[_poolId], "V3: already withdrawn");
                insuredWithdrawn[_poolId] = true;

                uint256 payout = pool.coverageAmount;
                if (payout > pool.totalCollateral) payout = pool.totalCollateral;
                usdc.safeTransfer(msg.sender, payout);
                emit Withdrawn(_poolId, msg.sender, payout);
            } else {
                uint256 contribution = contributions[_poolId][msg.sender];
                require(contribution > 0, "V3: no contribution");
                require(!hasWithdrawn[_poolId][msg.sender], "V3: already withdrawn");
                hasWithdrawn[_poolId][msg.sender] = true;

                uint256 payout = 0;
                payout += (premiumNet * contribution) / pool.totalCollateral;
                if (pool.totalCollateral > pool.coverageAmount) {
                    uint256 excess = pool.totalCollateral - pool.coverageAmount;
                    payout += (excess * contribution) / pool.totalCollateral;
                }
                if (payout > 0) usdc.safeTransfer(msg.sender, payout);
                emit Withdrawn(_poolId, msg.sender, payout);
            }
        } else {
            require(msg.sender != pool.insured, "V3: no withdrawal when no claim");
            uint256 contribution = contributions[_poolId][msg.sender];
            require(contribution > 0, "V3: no contribution");
            require(!hasWithdrawn[_poolId][msg.sender], "V3: already withdrawn");
            hasWithdrawn[_poolId][msg.sender] = true;

            uint256 premiumShare = (premiumNet * contribution) / pool.totalCollateral;
            uint256 payout = contribution + premiumShare;
            usdc.safeTransfer(msg.sender, payout);
            emit Withdrawn(_poolId, msg.sender, payout);
        }
    }

    // ══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════

    function getPoolParticipants(uint256 _poolId) external view poolExists(_poolId) returns (address[] memory) {
        return pools[_poolId].participants;
    }

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
            pool.description, pool.evidenceSource, pool.coverageAmount,
            pool.premiumRate, pool.deadline, pool.depositDeadline,
            pool.insured, pool.premiumPaid, pool.totalCollateral,
            pool.status, pool.claimApproved, pool.participants.length
        );
    }

    function getContribution(uint256 _poolId, address _participant) external view poolExists(_poolId) returns (uint256) {
        return contributions[_poolId][_participant];
    }

    function getPoolAccounting(uint256 _poolId)
        external
        view
        poolExists(_poolId)
        returns (uint256 premiumAfterFee, uint256 protocolFee, uint256 totalCollateral)
    {
        PoolInfo storage pool = pools[_poolId];
        return (pool.premiumAfterFee, pool.protocolFee, pool.totalCollateral);
    }

    /// @notice Get the required premium amount for a pool (in USDC, 6 decimals).
    function getRequiredPremium(uint256 _poolId) external view poolExists(_poolId) returns (uint256) {
        PoolInfo storage pool = pools[_poolId];
        return (pool.coverageAmount * pool.premiumRate) / BPS_DENOMINATOR;
    }

    // ══════════════════════════════════════════════════════════
    // ADMIN
    // ══════════════════════════════════════════════════════════

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "V3: invalid router");
        router = _router;
        emit RouterUpdated(_router);
    }

    function setOracle(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "V3: invalid oracle");
        oracle = _newOracle;
        emit OracleUpdated(_newOracle);
    }
}
