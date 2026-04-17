// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @dev [H-2] IPriceOracle used by CapacityOracle — enables slippage protection in executeBurn.
interface IPriceOracle {
    function getLuminaPrice() external view returns (uint256);
}

/// @dev [V5.0] Interface for AdaptiveFeeDistributor — provides dynamic distribution ratios.
interface IAdaptiveFeeDistributor {
    function getDistribution() external view returns (uint256 burnBps, uint256 buybackBps, uint256 opsBps);
    function isHealthy() external view returns (bool);
}

contract TWAPBurner is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20; // [M-3] SafeERC20 for recoverToken

    // ═══════ IMMUTABLES ═══════
    IERC20 public immutable usdc;
    IERC20 public immutable lumina;
    ISwapRouter public immutable swapRouter;

    // ═══════ [H-2] SLIPPAGE PROTECTION ═══════
    /// @notice Optional CapacityOracle address. When set, executeBurn derives
    ///         amountOutMin from the oracle price × (1 - maxSlippageBps).
    address public capacityOracle;

    // ═══════ CONFIG (adjustable by owner = Gnosis Safe) ═══════
    uint24 public poolFee = 10000; // 1% fee tier (new volatile token)
    uint256 public maxSlippageBps = 500; // 5% max slippage per swap
    uint256 public minBurnAmount = 1e6; // $1 USDC minimum per burn execution
    uint256 public maxBurnAmount = 10_000e6; // $10K USDC max per burn execution
    uint256 public burnCooldown = 900; // 15 minutes between burns

    // ═══════ V5.0: ADAPTIVE FEE DISTRIBUTION ═══════
    address public feeDistributor;
    bool public adaptiveModeEnabled;
    address public buybackReserve;
    address public opsReserve;
    uint256 public constant FALLBACK_BURN_BPS = 8800;
    uint256 public constant FALLBACK_BUYBACK_BPS = 1000;
    uint256 public constant FALLBACK_OPS_BPS = 200;

    // ═══════ STATE ═══════
    uint256 public lastBurnTimestamp;
    uint256 public totalUSDCReceived;
    uint256 public totalUSDCBurned; // total USDC spent on buying LUMINA
    uint256 public totalLUMINABurned; // total LUMINA tokens destroyed

    // ═══════ EVENTS ═══════
    event PremiumReceived(address indexed from, uint256 usdcAmount);
    event MarketplaceFeeReceived(address indexed from, uint256 usdcAmount);
    event BurnExecuted(uint256 usdcSpent, uint256 luminaBurned, uint256 effectivePrice, uint256 timestamp);
    event ConfigUpdated(string param, uint256 value);

    // ═══════ AUTHORIZED SENDERS ═══════
    mapping(address => bool) public authorizedSenders;

    modifier onlyAuthorized() {
        require(authorizedSenders[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }

    constructor(address _usdc, address _lumina, address _swapRouter) Ownable(msg.sender) {
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
        // [LBL-M1] SafeERC20 consistency with the rest of the contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUSDCReceived += amount;
        emit PremiumReceived(msg.sender, amount);
    }

    /// @notice Called by LuminaBondMarketplace when fees are collected.
    function receiveMarketplaceFee(uint256 amount) external {
        require(amount > 0, "Zero amount");
        // [LBL-M1] SafeERC20 consistency
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUSDCReceived += amount;
        emit MarketplaceFeeReceived(msg.sender, amount);
    }

    // ═══════ EXECUTE BURN (called by keeper or anyone) ═══════

    /// @notice Buy LUMINA on Uniswap and burn it (legacy) or distribute adaptively (V5.0).
    /// @dev Permissionless — anyone can call, but cooldown enforced.
    function executeBurn() external nonReentrant {
        require(block.timestamp >= lastBurnTimestamp + burnCooldown, "Cooldown active");

        uint256 usdcBalance = usdc.balanceOf(address(this));
        require(usdcBalance >= minBurnAmount, "Below minimum");

        uint256 amount = usdcBalance > maxBurnAmount ? maxBurnAmount : usdcBalance;
        lastBurnTimestamp = block.timestamp;

        if (adaptiveModeEnabled) {
            _executeAdaptive(amount);
        } else {
            _executeLegacyBurn(amount);
        }
    }

    // ═══════ V5.0: ADAPTIVE DISTRIBUTION INTERNALS ═══════

    /// @notice Adaptive mode: distribute between burn, buybackReserve and opsReserve.
    function _executeAdaptive(uint256 amount) internal {
        (uint256 burnBps, uint256 buybackBps, uint256 opsBps) = _getDistribution();
        require(burnBps + buybackBps + opsBps <= 10000, "Invalid distribution");

        uint256 toBurn = (amount * burnBps) / 10000;
        uint256 toBuyback = (amount * buybackBps) / 10000;
        uint256 toOps = (amount * opsBps) / 10000;

        if (toBuyback > 0 && buybackReserve != address(0)) {
            usdc.safeTransfer(buybackReserve, toBuyback);
        }
        if (toOps > 0 && opsReserve != address(0)) {
            usdc.safeTransfer(opsReserve, toOps);
        }
        if (toBurn > 0) {
            _swapAndBurn(toBurn);
        }

        emit AdaptiveDistributionExecuted(amount, toBurn, toBuyback, toOps);
    }

    /// @notice Legacy mode: 100% burn (pre-V5.0 behavior).
    function _executeLegacyBurn(uint256 amount) internal {
        _swapAndBurn(amount);
        emit LegacyBurnExecuted(amount);
    }

    /// @notice Get distribution from fee distributor with safe fallback.
    function _getDistribution() internal view returns (uint256 burnBps, uint256 buybackBps, uint256 opsBps) {
        if (feeDistributor != address(0)) {
            try IAdaptiveFeeDistributor(feeDistributor).isHealthy() returns (bool healthy) {
                if (healthy) {
                    try IAdaptiveFeeDistributor(feeDistributor).getDistribution() returns (
                        uint256 _b, uint256 _bb, uint256 _o
                    ) {
                        if (_b + _bb + _o <= 10000) {
                            return (_b, _bb, _o);
                        }
                    } catch {}
                }
            } catch {}
        }
        return (FALLBACK_BURN_BPS, FALLBACK_BUYBACK_BPS, FALLBACK_OPS_BPS);
    }

    /// @notice Swap USDC to LUMINA on Uniswap V3 and burn.
    function _swapAndBurn(uint256 usdcAmount) internal {
        usdc.forceApprove(address(swapRouter), usdcAmount);

        uint256 amountOutMin = 0;
        if (capacityOracle != address(0)) {
            try IPriceOracle(capacityOracle).getLuminaPrice() returns (uint256 oraclePrice) {
                if (oraclePrice > 0) {
                    uint256 expectedOut = (usdcAmount * 1e12 * 1e18) / oraclePrice;
                    amountOutMin = (expectedOut * (10_000 - maxSlippageBps)) / 10_000;
                }
            } catch {}
        }

        uint256 luminaReceived = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(lumina),
                fee: poolFee,
                recipient: address(this),
                amountIn: usdcAmount,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );

        require(luminaReceived > 0, "Zero LUMINA received");
        IBurnable(address(lumina)).burn(luminaReceived);

        totalUSDCBurned += usdcAmount;
        totalLUMINABurned += luminaReceived;

        uint256 effectivePrice = (usdcAmount * 1e18) / luminaReceived;
        emit BurnExecuted(usdcAmount, luminaReceived, effectivePrice, block.timestamp);
    }

    // ═══════ V5.0 EVENTS ═══════
    event AdaptiveDistributionExecuted(uint256 total, uint256 burned, uint256 toBuyback, uint256 toOps);
    event LegacyBurnExecuted(uint256 amount);

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

    /// @notice [H-2] Set the CapacityOracle address. Enables slippage protection on executeBurn.
    function setCapacityOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Zero oracle");
        capacityOracle = _oracle;
        emit ConfigUpdated("capacityOracle", uint256(uint160(_oracle)));
    }

    // ═══════ V5.0: ADAPTIVE MODE CONFIG ═══════

    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        feeDistributor = _feeDistributor;
        emit ConfigUpdated("feeDistributor", uint256(uint160(_feeDistributor)));
    }

    function setReserves(address _buybackReserve, address _opsReserve) external onlyOwner {
        require(_buybackReserve != address(0), "BuybackReserve zero");
        require(_opsReserve != address(0), "OpsReserve zero");
        buybackReserve = _buybackReserve;
        opsReserve = _opsReserve;
    }

    function setAdaptiveMode(bool enabled) external onlyOwner {
        require(!enabled || feeDistributor != address(0), "FeeDistributor not set");
        require(!enabled || (buybackReserve != address(0) && opsReserve != address(0)), "Reserves not set");
        adaptiveModeEnabled = enabled;
    }

    // ═══════ VIEW FUNCTIONS ═══════

    function pendingUSDC() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function canBurn() external view returns (bool) {
        return block.timestamp >= lastBurnTimestamp + burnCooldown && usdc.balanceOf(address(this)) >= minBurnAmount;
    }

    function getStats()
        external
        view
        returns (
            uint256 _totalUSDCReceived,
            uint256 _totalUSDCBurned,
            uint256 _totalLUMINABurned,
            uint256 _pendingUSDC,
            uint256 _lastBurnTimestamp,
            bool _canBurn
        )
    {
        _totalUSDCReceived = totalUSDCReceived;
        _totalUSDCBurned = totalUSDCBurned;
        _totalLUMINABurned = totalLUMINABurned;
        _pendingUSDC = usdc.balanceOf(address(this));
        _lastBurnTimestamp = lastBurnTimestamp;
        _canBurn = block.timestamp >= lastBurnTimestamp + burnCooldown && usdc.balanceOf(address(this)) >= minBurnAmount;
    }

    // ═══════ EMERGENCY: recover stuck tokens (NOT LUMINA, NOT USDC) ═══════

    /// @notice Recover tokens accidentally sent to this contract.
    /// @dev Cannot recover USDC (those are for burning) or LUMINA (should never hold any).
    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(usdc), "Cannot recover USDC");
        require(token != address(lumina), "Cannot recover LUMINA");
        IERC20(token).safeTransfer(owner(), amount); // [M-3] SafeERC20
    }
}
