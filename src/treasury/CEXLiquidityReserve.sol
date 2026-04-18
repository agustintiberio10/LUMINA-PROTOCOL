// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CEXLiquidityReserve is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    enum SubBucket {
        ImmediateUse,
        VestingLinear,
        StrategicReserve
    }
    enum Purpose {
        DEX_SECONDARY_POOL,
        CEX_LISTING_TIER_3,
        CEX_LISTING_TIER_2,
        CEX_LISTING_TIER_1,
        MARKET_MAKER_LOAN
    }

    struct Allocation {
        address recipient;
        uint256 amount;
        SubBucket subBucket;
        Purpose purpose;
        string description;
        uint256 timestamp;
        address allocator;
    }
    IERC20 public immutable lumina;
    uint256 public immutable deploymentTimestamp;
    uint256 public constant TOTAL_AMOUNT = 14_000_000 * 1e18;
    uint256 public constant IMMEDIATE_AMOUNT = 2_800_000 * 1e18;
    uint256 public constant VESTING_AMOUNT = 8_400_000 * 1e18;
    uint256 public constant STRATEGIC_AMOUNT = 2_800_000 * 1e18;
    uint256 public constant VESTING_DURATION = 730 days;
    uint256 public constant STRATEGIC_LOCK = 547 days;
    uint256 public constant MONTHLY_CAP = 1_000_000 * 1e18;
    uint256 public allocatedFromImmediate;
    uint256 public allocatedFromVesting;
    uint256 public allocatedFromStrategic;
    mapping(uint256 => uint256) public monthlyAllocations;
    Allocation[] public allocationHistory;
    event AllocationExecuted(
        uint256 indexed allocationId,
        address indexed recipient,
        uint256 amount,
        SubBucket subBucket,
        Purpose purpose,
        string description
    );
    event MonthlyCapWarning(uint256 month, uint256 spent, uint256 cap);

    constructor(address _lumina, address _multisigOwner) {
        require(_lumina != address(0), "Lumina zero address");
        require(_multisigOwner != address(0), "Multisig zero address");
        lumina = IERC20(_lumina);
        deploymentTimestamp = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, _multisigOwner);
        _grantRole(ALLOCATOR_ROLE, _multisigOwner);
    }

    function allocate(
        address recipient,
        uint256 amount,
        SubBucket subBucket,
        Purpose purpose,
        string calldata description
    ) external onlyRole(ALLOCATOR_ROLE) nonReentrant {
        require(recipient != address(0), "Recipient zero");
        require(amount > 0, "Amount zero");
        require(bytes(description).length > 0, "Description required");
        require(bytes(description).length <= 200, "Description too long");
        uint256 available = getAvailableInBucket(subBucket);
        require(amount <= available, "Insufficient in sub-bucket");
        uint256 currentMonth = getCurrentMonth();
        uint256 monthlySpent = monthlyAllocations[currentMonth];
        require(monthlySpent + amount <= MONTHLY_CAP, "Monthly cap exceeded");
        if (subBucket == SubBucket.ImmediateUse) allocatedFromImmediate += amount;
        else if (subBucket == SubBucket.VestingLinear) allocatedFromVesting += amount;
        else allocatedFromStrategic += amount;
        monthlyAllocations[currentMonth] += amount;
        uint256 allocationId = allocationHistory.length;
        allocationHistory.push(
            Allocation({
                recipient: recipient,
                amount: amount,
                subBucket: subBucket,
                purpose: purpose,
                description: description,
                timestamp: block.timestamp,
                allocator: msg.sender
            })
        );
        lumina.safeTransfer(recipient, amount);
        if (monthlyAllocations[currentMonth] > (MONTHLY_CAP * 80) / 100) {
            emit MonthlyCapWarning(currentMonth, monthlyAllocations[currentMonth], MONTHLY_CAP);
        }
        emit AllocationExecuted(allocationId, recipient, amount, subBucket, purpose, description);
    }

    function getAvailableInBucket(SubBucket subBucket) public view returns (uint256) {
        if (subBucket == SubBucket.ImmediateUse) {
            return IMMEDIATE_AMOUNT - allocatedFromImmediate;
        } else if (subBucket == SubBucket.VestingLinear) {
            uint256 vested = getVestedAmount();
            if (vested <= allocatedFromVesting) return 0;
            return vested - allocatedFromVesting;
        } else {
            if (block.timestamp < deploymentTimestamp + STRATEGIC_LOCK) return 0;
            return STRATEGIC_AMOUNT - allocatedFromStrategic;
        }
    }

    function getVestedAmount() public view returns (uint256) {
        uint256 elapsed = block.timestamp - deploymentTimestamp;
        if (elapsed >= VESTING_DURATION) return VESTING_AMOUNT;
        return (VESTING_AMOUNT * elapsed) / VESTING_DURATION;
    }

    function getTotalAllocated() external view returns (uint256) {
        return allocatedFromImmediate + allocatedFromVesting + allocatedFromStrategic;
    }

    function getAllocationHistoryLength() external view returns (uint256) {
        return allocationHistory.length;
    }

    function getCurrentMonth() public view returns (uint256) {
        return (block.timestamp - deploymentTimestamp) / 30 days;
    }

    function getMonthlyCapRemaining() external view returns (uint256) {
        uint256 spent = monthlyAllocations[getCurrentMonth()];
        if (spent >= MONTHLY_CAP) return 0;
        return MONTHLY_CAP - spent;
    }
}
