// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ISwapHandler.sol";

/**
 * @title MutualPoolRouter
 * @author MutualBot Insurance Protocol
 * @notice Gateway contract that sits between users and MutualPoolV3.
 *         Handles two deposit modes:
 *
 *   MODE A — Direct USDC:
 *     User sends USDC → Router approves V3 → calls fundPremium/joinPool.
 *
 *   MODE B — MPOOLV3 token → swap → USDC:
 *     User sends MPOOLV3 → Router swaps via ISwapHandler → gets USDC → deposits.
 *
 *   The Mogra wallet integration (Mode C) is OFF-CHAIN: the bot constructs
 *   the tx payload and Mogra signs + submits it. The on-chain flow is still
 *   Mode A or B — the Router doesn't know or care about Mogra.
 *
 *   ┌──────────┐     ┌─────────────────┐     ┌───────────────┐
 *   │  User /  │────►│ MutualPoolRouter │────►│ MutualPoolV3  │
 *   │  Agent   │     │  (this contract) │     │  (insurance)  │
 *   └──────────┘     └────────┬────────┘     └───────────────┘
 *                             │
 *                    ┌────────▼────────┐
 *                    │  ISwapHandler   │
 *                    │  (Fluid DEX)    │
 *                    └─────────────────┘
 */
contract MutualPoolRouter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════
    // IMMUTABLES
    // ══════════════════════════════════════════════════════════

    /// @notice USDC token on Base.
    IERC20 public immutable usdc;

    /// @notice MutualPoolV3 vault contract.
    address public immutable vault;

    // ══════════════════════════════════════════════════════════
    // MUTABLE STATE
    // ══════════════════════════════════════════════════════════

    /// @notice MPOOLV3 token (set after token launch, can be address(0) initially).
    IERC20 public mpoolToken;

    /// @notice Pluggable DEX adapter for MPOOLV3 → USDC swaps.
    ISwapHandler public swapHandler;

    /// @notice Default slippage tolerance in basis points (e.g. 300 = 3%).
    uint256 public defaultSlippageBps;

    /// @notice Pause state — blocks all deposits when true.
    bool public paused;

    // ══════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════

    event PremiumFundedViaUSDC(uint256 indexed poolId, address indexed insured, uint256 usdcAmount);
    event PremiumFundedViaMPOOL(uint256 indexed poolId, address indexed insured, uint256 mpoolIn, uint256 usdcOut);
    event JoinedViaUSDC(uint256 indexed poolId, address indexed participant, uint256 usdcAmount);
    event JoinedViaMPOOL(uint256 indexed poolId, address indexed participant, uint256 mpoolIn, uint256 usdcOut);
    event SwapHandlerUpdated(address indexed newHandler);
    event MpoolTokenUpdated(address indexed newToken);
    event SlippageUpdated(uint256 newBps);
    event Paused(bool state);

    // ══════════════════════════════════════════════════════════
    // ERRORS
    // ══════════════════════════════════════════════════════════

    error RouterPaused();
    error ZeroAmount();
    error MpoolTokenNotSet();
    error SwapHandlerNotSet();
    error SlippageTooHigh();

    // ══════════════════════════════════════════════════════════
    // MODIFIERS
    // ══════════════════════════════════════════════════════════

    modifier whenNotPaused() {
        if (paused) revert RouterPaused();
        _;
    }

    // ══════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════

    /**
     * @param _usdc   USDC address on Base.
     * @param _vault  MutualPoolV3 address.
     */
    constructor(address _usdc, address _vault) Ownable(msg.sender) {
        require(_usdc != address(0), "Router: invalid USDC");
        require(_vault != address(0), "Router: invalid vault");
        usdc = IERC20(_usdc);
        vault = _vault;
        defaultSlippageBps = 300; // 3% default slippage
    }

    // ══════════════════════════════════════════════════════════
    // MODE A: Direct USDC Deposits
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Fund a pool's premium with USDC directly.
     * @dev User must approve this Router for the premium amount first.
     *      Router pulls USDC from user → approves V3 → calls V3.fundPremium().
     *
     * @param poolId Pool ID on MutualPoolV3.
     * @param amount USDC amount (6 decimals). Must match pool's required premium.
     */
    function fundPremiumWithUSDC(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Pull USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Approve V3 vault to pull from Router
        usdc.safeIncreaseAllowance(vault, amount);

        // Call V3.fundPremium(poolId, insured=msg.sender)
        (bool success,) = vault.call(
            abi.encodeWithSignature("fundPremium(uint256,address)", poolId, msg.sender)
        );
        require(success, "Router: fundPremium failed");

        emit PremiumFundedViaUSDC(poolId, msg.sender, amount);
    }

    /**
     * @notice Join a pool as collateral provider with USDC directly.
     * @dev User must approve this Router for the amount first.
     *
     * @param poolId Pool ID on MutualPoolV3.
     * @param amount USDC collateral amount (6 decimals).
     */
    function joinPoolWithUSDC(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Pull USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Approve V3 vault
        usdc.safeIncreaseAllowance(vault, amount);

        // Call V3.joinPool(poolId, amount, participant=msg.sender)
        (bool success,) = vault.call(
            abi.encodeWithSignature("joinPool(uint256,uint256,address)", poolId, amount, msg.sender)
        );
        require(success, "Router: joinPool failed");

        emit JoinedViaUSDC(poolId, msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════
    // MODE B: MPOOLV3 → Swap → USDC → Deposit
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Fund a pool's premium using MPOOLV3 tokens.
     * @dev User approves Router for MPOOLV3 → Router swaps to USDC via handler → deposits.
     *
     * @param poolId     Pool ID on MutualPoolV3.
     * @param mpoolAmount MPOOLV3 token amount (18 decimals).
     * @param minUsdcOut  Minimum USDC output after swap (slippage protection).
     */
    function fundPremiumWithMPOOL(uint256 poolId, uint256 mpoolAmount, uint256 minUsdcOut)
        external
        nonReentrant
        whenNotPaused
    {
        if (mpoolAmount == 0) revert ZeroAmount();
        if (address(mpoolToken) == address(0)) revert MpoolTokenNotSet();
        if (address(swapHandler) == address(0)) revert SwapHandlerNotSet();

        // Pull MPOOLV3 from user
        mpoolToken.safeTransferFrom(msg.sender, address(this), mpoolAmount);

        // Swap MPOOLV3 → USDC via handler
        mpoolToken.safeIncreaseAllowance(address(swapHandler), mpoolAmount);
        uint256 usdcReceived = swapHandler.swap(
            address(mpoolToken),
            address(usdc),
            mpoolAmount,
            minUsdcOut,
            address(this) // Router receives the USDC
        );

        // Deposit USDC into V3
        usdc.safeIncreaseAllowance(vault, usdcReceived);
        (bool success,) = vault.call(
            abi.encodeWithSignature("fundPremium(uint256,address)", poolId, msg.sender)
        );
        require(success, "Router: fundPremium failed");

        emit PremiumFundedViaMPOOL(poolId, msg.sender, mpoolAmount, usdcReceived);
    }

    /**
     * @notice Join a pool as collateral provider using MPOOLV3 tokens.
     * @dev User approves Router for MPOOLV3 → swap → USDC → joinPool.
     *
     * @param poolId       Pool ID on MutualPoolV3.
     * @param mpoolAmount  MPOOLV3 token amount (18 decimals).
     * @param minUsdcOut   Minimum USDC output after swap.
     */
    function joinPoolWithMPOOL(uint256 poolId, uint256 mpoolAmount, uint256 minUsdcOut)
        external
        nonReentrant
        whenNotPaused
    {
        if (mpoolAmount == 0) revert ZeroAmount();
        if (address(mpoolToken) == address(0)) revert MpoolTokenNotSet();
        if (address(swapHandler) == address(0)) revert SwapHandlerNotSet();

        // Pull MPOOLV3 from user
        mpoolToken.safeTransferFrom(msg.sender, address(this), mpoolAmount);

        // Swap MPOOLV3 → USDC
        mpoolToken.safeIncreaseAllowance(address(swapHandler), mpoolAmount);
        uint256 usdcReceived = swapHandler.swap(
            address(mpoolToken),
            address(usdc),
            mpoolAmount,
            minUsdcOut,
            address(this)
        );

        // Deposit into V3
        usdc.safeIncreaseAllowance(vault, usdcReceived);
        (bool success,) = vault.call(
            abi.encodeWithSignature("joinPool(uint256,uint256,address)", poolId, usdcReceived, msg.sender)
        );
        require(success, "Router: joinPool failed");

        emit JoinedViaMPOOL(poolId, msg.sender, mpoolAmount, usdcReceived);
    }

    // ══════════════════════════════════════════════════════════
    // QUOTE (read-only)
    // ══════════════════════════════════════════════════════════

    /**
     * @notice Preview how much USDC you'd get for a given MPOOLV3 amount.
     * @param mpoolAmount MPOOLV3 input amount (18 decimals).
     * @return usdcOut Expected USDC output (6 decimals).
     */
    function quoteMpoolToUsdc(uint256 mpoolAmount) external view returns (uint256 usdcOut) {
        if (address(swapHandler) == address(0)) revert SwapHandlerNotSet();
        if (address(mpoolToken) == address(0)) revert MpoolTokenNotSet();
        return swapHandler.quote(address(mpoolToken), address(usdc), mpoolAmount);
    }

    // ══════════════════════════════════════════════════════════
    // ADMIN
    // ══════════════════════════════════════════════════════════

    function setMpoolToken(address _token) external onlyOwner {
        require(_token != address(0), "Router: invalid token");
        mpoolToken = IERC20(_token);
        emit MpoolTokenUpdated(_token);
    }

    function setSwapHandler(address _handler) external onlyOwner {
        require(_handler != address(0), "Router: invalid handler");
        swapHandler = ISwapHandler(_handler);
        emit SwapHandlerUpdated(_handler);
    }

    function setDefaultSlippage(uint256 _bps) external onlyOwner {
        if (_bps > 1000) revert SlippageTooHigh(); // Max 10%
        defaultSlippageBps = _bps;
        emit SlippageUpdated(_bps);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @notice Recover tokens accidentally sent to this contract.
     * @dev Cannot recover USDC or MPOOLV3 to prevent rug vectors.
     */
    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(usdc), "Router: use withdraw for USDC");
        if (address(mpoolToken) != address(0)) {
            require(token != address(mpoolToken), "Router: use withdraw for MPOOL");
        }
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Emergency withdraw stuck USDC/MPOOL (only if router is paused).
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(paused, "Router: must be paused");
        IERC20(token).safeTransfer(owner(), amount);
    }
}
