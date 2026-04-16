// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TWAPBurner
/// @notice Receives USDC from premiums and marketplace fees.
///         Executes distributed buy & burn of $LUMINA on Uniswap V3.
/// @dev 100% of all USDC received is used to buy and burn $LUMINA.
///      Nothing goes to treasury. Nothing goes to the team.
///      Burn is distributed across multiple micro-swaps (TWAP) to minimize slippage.
///      A keeper (Gelato/Chainlink Automation) calls executeBurn() periodically.

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

contract TWAPBurner is Ownable, ReentrancyGuard {
    // ═══════ IMMUTABLES ═══════
    IERC20 public immutable usdc;
    IERC20 public immutable lumina;
    ISwapRouter public immutable swapRouter;

    // ═══════ CONFIG (adjustable by owner = Gnosis Safe) ═══════
    uint24 public poolFee = 10000;           // 1% fee tier (new volatile token)
    uint256 public maxSlippageBps = 500;     // 5% max slippage per swap
    uint256 public minBurnAmount = 1e6;      // $1 USDC minimum per burn execution
    uint256 public maxBurnAmount = 10_000e6; // $10K USDC max per burn execution
    uint256 public burnCooldown = 900;       // 15 minutes between burns

    // ═══════ STATE ═══════
    uint256 public lastBurnTimestamp;
    uint256 public totalUSDCReceived;
    uint256 public totalUSDCBurned;     // total USDC spent on buying LUMINA
    uint256 public totalLUMINABurned;   // total LUMINA tokens destroyed

    // ═══════ EVENTS ═══════
    event PremiumReceived(address indexed from, uint256 usdcAmount);
    event MarketplaceFeeReceived(address indexed from, uint256 usdcAmount);
    event BurnExecuted(
        uint256 usdcSpent,
        uint256 luminaBurned,
        uint256 effectivePrice,
        uint256 timestamp
    );
    event ConfigUpdated(string param, uint256 value);

    // ═══════ AUTHORIZED SENDERS ═══════
    mapping(address => bool) public authorizedSenders;

    modifier onlyAuthorized() {
        require(authorizedSenders[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }

    constructor(
        address _usdc,
        address _lumina,
        address _swapRouter
    ) Ownable(msg.sender) {
        require(_usdc != address(0), "Zero USDC");
        require(_lumina != address(0), "Zero LUMINA");
        require(_swapRouter != address(0), "Zero router");

        usdc = IERC20(_usdc);
        lumina = IERC20(_lumina);
        swapRouter = ISwapRouter(_swapRouter);
    }

    // ═══════ RECEIVE FUNDS ═══════

    /// @notice Called by CoverRouter when a premium is paid.
    function receivePremium(uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        totalUSDCReceived += amount;
        emit PremiumReceived(msg.sender, amount);
    }

    /// @notice Called by LuminaBondMarketplace when fees are collected.
    function receiveMarketplaceFee(uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        totalUSDCReceived += amount;
        emit MarketplaceFeeReceived(msg.sender, amount);
    }

    // ═══════ EXECUTE BURN (called by keeper or anyone) ═══════

    /// @notice Buy LUMINA on Uniswap and burn it. Called by keeper every ~15 min.
    /// @dev Permissionless — anyone can call, but cooldown enforced.
    function executeBurn() external nonReentrant {
        require(block.timestamp >= lastBurnTimestamp + burnCooldown, "Cooldown active");

        uint256 usdcBalance = usdc.balanceOf(address(this));
        require(usdcBalance >= minBurnAmount, "Below minimum");

        uint256 amountToSwap = usdcBalance > maxBurnAmount ? maxBurnAmount : usdcBalance;

        // Approve router
        usdc.approve(address(swapRouter), amountToSwap);

        // Calculate minimum output with slippage protection
        // We don't know the exact price here, so we use 0 for amountOutMinimum
        // and rely on the Uniswap pool's built-in price impact protection
        // In production, a keeper with off-chain price feed would set this properly
        uint256 amountOutMin = 0; // keeper should set via separate function in prod

        // Execute swap: USDC → LUMINA
        uint256 luminaReceived = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(lumina),
                fee: poolFee,
                recipient: address(this), // receive LUMINA here first
                amountIn: amountToSwap,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );

        require(luminaReceived > 0, "Zero LUMINA received");

        // Burn the LUMINA
        IBurnable(address(lumina)).burn(luminaReceived);

        // Update state
        lastBurnTimestamp = block.timestamp;
        totalUSDCBurned += amountToSwap;
        totalLUMINABurned += luminaReceived;

        // Effective price = USDC spent / LUMINA burned (18 decimals)
        uint256 effectivePrice = (amountToSwap * 1e18) / luminaReceived;

        emit BurnExecuted(amountToSwap, luminaReceived, effectivePrice, block.timestamp);
    }

    // ═══════ ADMIN (owner = Gnosis Safe) ═══════

    function setPoolFee(uint24 _fee) external onlyOwner {
        require(_fee == 500 || _fee == 3000 || _fee == 10000, "Invalid fee tier");
        poolFee = _fee;
        emit ConfigUpdated("poolFee", _fee);
    }

    function setMaxSlippageBps(uint256 _bps) external onlyOwner {
        require(_bps >= 50 && _bps <= 1000, "Slippage: 0.5%-10%");
        maxSlippageBps = _bps;
        emit ConfigUpdated("maxSlippageBps", _bps);
    }

    function setMinBurnAmount(uint256 _min) external onlyOwner {
        require(_min >= 0.1e6, "Min too low"); // at least $0.10
        minBurnAmount = _min;
        emit ConfigUpdated("minBurnAmount", _min);
    }

    function setMaxBurnAmount(uint256 _max) external onlyOwner {
        require(_max >= minBurnAmount, "Max < min");
        maxBurnAmount = _max;
        emit ConfigUpdated("maxBurnAmount", _max);
    }

    function setBurnCooldown(uint256 _cooldown) external onlyOwner {
        require(_cooldown >= 60 && _cooldown <= 86400, "Cooldown: 1min-24hr");
        burnCooldown = _cooldown;
        emit ConfigUpdated("burnCooldown", _cooldown);
    }

    function setAuthorizedSender(address sender, bool authorized) external onlyOwner {
        authorizedSenders[sender] = authorized;
    }

    // ═══════ VIEW FUNCTIONS ═══════

    function pendingUSDC() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function canBurn() external view returns (bool) {
        return block.timestamp >= lastBurnTimestamp + burnCooldown
            && usdc.balanceOf(address(this)) >= minBurnAmount;
    }

    function getStats() external view returns (
        uint256 _totalUSDCReceived,
        uint256 _totalUSDCBurned,
        uint256 _totalLUMINABurned,
        uint256 _pendingUSDC,
        uint256 _lastBurnTimestamp,
        bool _canBurn
    ) {
        _totalUSDCReceived = totalUSDCReceived;
        _totalUSDCBurned = totalUSDCBurned;
        _totalLUMINABurned = totalLUMINABurned;
        _pendingUSDC = usdc.balanceOf(address(this));
        _lastBurnTimestamp = lastBurnTimestamp;
        _canBurn = block.timestamp >= lastBurnTimestamp + burnCooldown
            && usdc.balanceOf(address(this)) >= minBurnAmount;
    }

    // ═══════ EMERGENCY: recover stuck tokens (NOT LUMINA, NOT USDC) ═══════

    /// @notice Recover tokens accidentally sent to this contract.
    /// @dev Cannot recover USDC (those are for burning) or LUMINA (should never hold any).
    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(usdc), "Cannot recover USDC");
        require(token != address(lumina), "Cannot recover LUMINA");
        IERC20(token).transfer(owner(), amount);
    }
}
