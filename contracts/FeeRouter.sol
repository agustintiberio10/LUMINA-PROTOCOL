// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FeeRouter
 * @notice Routes protocol fees from MutualPool to three destinations:
 *   70% → MPOOL Staking (real yield in USDC for stakers)
 *   20% → Protocol Treasury
 *   10% → Buyback wallet (used to buy & burn MPOOL)
 *
 * DESIGN:
 * - The existing MutualPool contract sends fees to PROTOCOL_OWNER wallet.
 * - The owner/bot periodically calls routeFees() to split accumulated USDC.
 * - USDC is transferred FROM the caller (must be pre-approved).
 * - Staking rewards are forwarded to MPOOLStaking.notifyRewardAmount().
 * - Buyback USDC accumulates in buybackWallet; bot swaps on Fluid DEX and burns.
 *
 * INVARIANTS:
 * - All yield is in USDC (exogenous), never in MPOOL.
 * - Fee splits are immutable (set at construction, no admin override).
 * - No MPOOL is ever created — only bought back and burned.
 */
contract FeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Fee split (basis points, total = 10000)
    uint256 public constant STAKING_BPS = 7000;    // 70%
    uint256 public constant TREASURY_BPS = 2000;    // 20%
    uint256 public constant BUYBACK_BPS = 1000;     // 10%
    uint256 public constant BPS_DENOMINATOR = 10000;

    IERC20 public immutable usdc;

    address public immutable stakingContract;   // MPOOLStaking address
    address public immutable treasury;           // Treasury wallet
    address public immutable buybackWallet;      // Buyback wallet (bot buys MPOOL & burns)

    address public owner;

    // Stats
    uint256 public totalFeesRouted;
    uint256 public totalToStaking;
    uint256 public totalToTreasury;
    uint256 public totalToBuyback;

    // Events
    event FeesRouted(
        uint256 totalAmount,
        uint256 toStaking,
        uint256 toTreasury,
        uint256 toBuyback
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        address _usdc,
        address _stakingContract,
        address _treasury,
        address _buybackWallet
    ) {
        require(_usdc != address(0), "Invalid USDC");
        require(_stakingContract != address(0), "Invalid staking");
        require(_treasury != address(0), "Invalid treasury");
        require(_buybackWallet != address(0), "Invalid buyback");

        usdc = IERC20(_usdc);
        stakingContract = _stakingContract;
        treasury = _treasury;
        buybackWallet = _buybackWallet;
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════
    // CORE: Route Fees
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Route USDC fees to staking (70%), treasury (20%), buyback (10%).
     * @param amount Total USDC to route. Must be pre-approved by caller.
     */
    function routeFees(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");

        // Pull USDC from caller
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 toStaking = (amount * STAKING_BPS) / BPS_DENOMINATOR;
        uint256 toTreasury = (amount * TREASURY_BPS) / BPS_DENOMINATOR;
        uint256 toBuyback = amount - toStaking - toTreasury; // Remainder to avoid rounding loss

        // 70% → Staking: approve and notify
        if (toStaking > 0) {
            usdc.safeIncreaseAllowance(stakingContract, toStaking);
            // Call notifyRewardAmount on staking contract
            (bool success,) = stakingContract.call(
                abi.encodeWithSignature("notifyRewardAmount(uint256)", toStaking)
            );
            require(success, "Staking notification failed");
        }

        // 20% → Treasury
        if (toTreasury > 0) {
            usdc.safeTransfer(treasury, toTreasury);
        }

        // 10% → Buyback wallet
        if (toBuyback > 0) {
            usdc.safeTransfer(buybackWallet, toBuyback);
        }

        // Update stats
        totalFeesRouted += amount;
        totalToStaking += toStaking;
        totalToTreasury += toTreasury;
        totalToBuyback += toBuyback;

        emit FeesRouted(amount, toStaking, toTreasury, toBuyback);
    }

    /**
     * @notice Route all USDC balance held by this contract.
     *         Useful if USDC was sent directly to this contract.
     */
    function routeBalance() external nonReentrant {
        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "No balance to route");

        uint256 toStaking = (balance * STAKING_BPS) / BPS_DENOMINATOR;
        uint256 toTreasury = (balance * TREASURY_BPS) / BPS_DENOMINATOR;
        uint256 toBuyback = balance - toStaking - toTreasury;

        if (toStaking > 0) {
            usdc.safeIncreaseAllowance(stakingContract, toStaking);
            (bool success,) = stakingContract.call(
                abi.encodeWithSignature("notifyRewardAmount(uint256)", toStaking)
            );
            require(success, "Staking notification failed");
        }

        if (toTreasury > 0) {
            usdc.safeTransfer(treasury, toTreasury);
        }

        if (toBuyback > 0) {
            usdc.safeTransfer(buybackWallet, toBuyback);
        }

        totalFeesRouted += balance;
        totalToStaking += toStaking;
        totalToTreasury += toTreasury;
        totalToBuyback += toBuyback;

        emit FeesRouted(balance, toStaking, toTreasury, toBuyback);
    }

    // ═══════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════

    function getStats() external view returns (
        uint256 _totalFeesRouted,
        uint256 _totalToStaking,
        uint256 _totalToTreasury,
        uint256 _totalToBuyback
    ) {
        return (totalFeesRouted, totalToStaking, totalToTreasury, totalToBuyback);
    }

    /**
     * @notice Preview fee split for a given amount.
     */
    function previewSplit(uint256 amount) external pure returns (
        uint256 toStaking,
        uint256 toTreasury,
        uint256 toBuyback
    ) {
        toStaking = (amount * STAKING_BPS) / BPS_DENOMINATOR;
        toTreasury = (amount * TREASURY_BPS) / BPS_DENOMINATOR;
        toBuyback = amount - toStaking - toTreasury;
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @notice Emergency: recover tokens accidentally sent to this contract.
     *         Cannot recover USDC (use routeBalance instead).
     */
    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(usdc), "Use routeBalance for USDC");
        IERC20(token).safeTransfer(owner, amount);
    }
}
