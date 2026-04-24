// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexRouter} from "../interfaces/IDexRouter.sol";

/// @title TWAPBurner
/// @notice Receives USDC from premiums and marketplace fees.
///         Executes distributed buy & burn of $LUMINA via multi-DEX routing.
/// @dev [V5.1] UUPS upgradeable proxy pattern.

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @dev [H-2] IPriceOracle used by CapacityOracle — enables slippage protection in executeBurn.
interface IPriceOracle {
    function getLuminaPrice() external view returns (uint256);
}

/// @dev [V5.0] Interface for AdaptiveFeeDistributor — provides dynamic distribution ratios (4-bucket).
interface IAdaptiveFeeDistributor {
    function getDistribution()
        external
        view
        returns (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintenanceBps);
    function isHealthy() external view returns (bool);
}

contract TWAPBurner is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20; // [M-3] SafeERC20 for recoverToken

    // ═══════ STORAGE (was immutable) ═══════
    IERC20 public usdc;
    IERC20 public lumina;

    // ═══════ MULTI-DEX ROUTING ═══════
    IDexRouter[] public dexRouters;

    // ═══════ [H-2] SLIPPAGE PROTECTION ═══════
    address public capacityOracle;

    // ═══════ CONFIG (adjustable by owner = Gnosis Safe) ═══════
    uint24 public poolFee;
    uint256 public maxSlippageBps;
    uint256 public minBurnAmount;
    uint256 public maxBurnAmount;
    uint256 public burnCooldown;

    // ═══════ V5.0: ADAPTIVE FEE DISTRIBUTION ═══════
    address public feeDistributor;
    bool public adaptiveModeEnabled;
    address public buybackReserve;
    address public opsReserve;
    address public maintenanceReserve;
    uint256 public constant FALLBACK_BURN_BPS = 8500;
    uint256 public constant FALLBACK_BUYBACK_BPS = 800;
    uint256 public constant FALLBACK_OPS_BPS = 200;
    uint256 public constant FALLBACK_MAINTENANCE_BPS = 500;

    // ═══════ STATE ═══════
    uint256 public lastBurnTimestamp;
    uint256 public totalUSDCReceived;
    uint256 public totalUSDCBurned;
    uint256 public totalLUMINABurned;

    // ═══════ EVENTS ═══════
    event PremiumReceived(address indexed from, uint256 usdcAmount);
    event MarketplaceFeeReceived(address indexed from, uint256 usdcAmount);
    event BurnExecuted(uint256 usdcSpent, uint256 luminaBurned, uint256 effectivePrice, uint256 timestamp);
    event ConfigUpdated(string param, uint256 value);
    event MaintenanceReserveUpdated(address indexed newReserve);
    /// @notice [LOW-1 fix] Emitted when `recoverToken` successfully rescues a non-core ERC-20.
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);

    // ═══════ AUTHORIZED SENDERS ═══════
    mapping(address => bool) public authorizedSenders;

    modifier onlyAuthorized() {
        require(authorizedSenders[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdc, address _lumina, address _initialDexRouter) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_usdc != address(0), "Zero USDC");
        require(_lumina != address(0), "Zero LUMINA");
        require(_initialDexRouter != address(0), "Zero router");

        usdc = IERC20(_usdc);
        lumina = IERC20(_lumina);
        dexRouters.push(IDexRouter(_initialDexRouter));

        poolFee = 10000;
        maxSlippageBps = 500;
        minBurnAmount = 1e6;
        maxBurnAmount = 10_000e6;
        burnCooldown = 900;
    }

    // ═══════ RECEIVE FUNDS ═══════

    function receivePremium(uint256 amount) external {
        require(amount > 0, "Zero amount");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUSDCReceived += amount;
        emit PremiumReceived(msg.sender, amount);
    }

    function receiveMarketplaceFee(uint256 amount) external {
        require(amount > 0, "Zero amount");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUSDCReceived += amount;
        emit MarketplaceFeeReceived(msg.sender, amount);
    }

    // ═══════ EXECUTE BURN ═══════

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

    function _executeAdaptive(uint256 amount) internal {
        (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintBps) = _getDistribution();
        require(burnBps + buybackBps + opsBps + maintBps <= 10000, "Invalid distribution");

        uint256 toBurn = (amount * burnBps) / 10000;
        uint256 toBuyback = (amount * buybackBps) / 10000;
        uint256 toOps = (amount * opsBps) / 10000;
        uint256 toMaint = (amount * maintBps) / 10000;

        if (toBuyback > 0 && buybackReserve != address(0)) {
            usdc.safeTransfer(buybackReserve, toBuyback);
        }
        if (toOps > 0 && opsReserve != address(0)) {
            usdc.safeTransfer(opsReserve, toOps);
        }
        if (toMaint > 0 && maintenanceReserve != address(0)) {
            usdc.safeTransfer(maintenanceReserve, toMaint);
        }
        if (toBurn > 0) {
            _swapAndBurn(toBurn);
        }

        emit AdaptiveDistributionExecuted(amount, toBurn, toBuyback, toOps, toMaint);
    }

    function _executeLegacyBurn(uint256 amount) internal {
        _swapAndBurn(amount);
        emit LegacyBurnExecuted(amount);
    }

    function _getDistribution()
        internal
        view
        returns (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintBps)
    {
        if (feeDistributor != address(0)) {
            try IAdaptiveFeeDistributor(feeDistributor).isHealthy() returns (bool healthy) {
                if (healthy) {
                    try IAdaptiveFeeDistributor(feeDistributor).getDistribution() returns (
                        uint256 _b, uint256 _bb, uint256 _o, uint256 _m
                    ) {
                        if (_b + _bb + _o + _m <= 10000) {
                            return (_b, _bb, _o, _m);
                        }
                    } catch {}
                }
            } catch {}
        }
        return (FALLBACK_BURN_BPS, FALLBACK_BUYBACK_BPS, FALLBACK_OPS_BPS, FALLBACK_MAINTENANCE_BPS);
    }

    function _swapAndBurn(uint256 usdcAmount) internal {
        require(dexRouters.length > 0, "No DEX routers configured");

        IDexRouter bestRouter = dexRouters[0];
        uint256 bestQuote = 0;

        for (uint256 i = 0; i < dexRouters.length; i++) {
            try dexRouters[i].getQuote(address(usdc), address(lumina), usdcAmount) returns (uint256 quote) {
                if (quote > bestQuote) {
                    bestQuote = quote;
                    bestRouter = dexRouters[i];
                }
            } catch {}
        }

        uint256 minOut = 0;
        if (bestQuote > 0) {
            minOut = (bestQuote * (10_000 - maxSlippageBps)) / 10_000;
        }
        if (capacityOracle != address(0)) {
            try IPriceOracle(capacityOracle).getLuminaPrice() returns (uint256 oraclePrice) {
                if (oraclePrice > 0) {
                    uint256 expectedOut = (usdcAmount * 1e12 * 1e18) / oraclePrice;
                    uint256 oracleMin = (expectedOut * (10_000 - maxSlippageBps)) / 10_000;
                    if (oracleMin > minOut) {
                        minOut = oracleMin;
                    }
                }
            } catch {}
        }

        // [M-02 fix] Defense-in-depth: refuse to swap without a protective
        // minOut floor. If quote+oracle both fail we would otherwise accept
        // any 1-wei return, enabling sandwich attacks.
        require(minOut > 0, "TWAPBurner: minOut must be > 0");

        usdc.forceApprove(address(bestRouter), usdcAmount);
        uint256 luminaReceived = bestRouter.swap(address(usdc), address(lumina), usdcAmount, minOut);

        require(luminaReceived > 0, "Swap returned 0");

        IBurnable(address(lumina)).burn(luminaReceived);

        totalUSDCBurned += usdcAmount;
        totalLUMINABurned += luminaReceived;

        uint256 effectivePrice = (usdcAmount * 1e18) / luminaReceived;
        emit BurnExecuted(usdcAmount, luminaReceived, effectivePrice, block.timestamp);
    }

    // ═══════ V5.0 EVENTS ═══════
    event AdaptiveDistributionExecuted(
        uint256 total, uint256 burned, uint256 toBuyback, uint256 toOps, uint256 toMaintenance
    );
    event LegacyBurnExecuted(uint256 amount);

    // ═══════ ADMIN ═══════

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
        require(_min >= 0.1e6, "Min too low");
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

    function setCapacityOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Zero oracle");
        capacityOracle = _oracle;
        emit ConfigUpdated("capacityOracle", uint256(uint160(_oracle)));
    }

    // ═══════ V5.0: MULTI-DEX ROUTER CONFIG ═══════

    function setDexRouters(address[] calldata _routers) external onlyOwner {
        require(_routers.length > 0, "Empty routers");
        delete dexRouters;
        for (uint256 i = 0; i < _routers.length; i++) {
            require(_routers[i] != address(0), "Zero router");
            dexRouters.push(IDexRouter(_routers[i]));
        }
        emit ConfigUpdated("dexRouters", _routers.length);
    }

    function addDexRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero router");
        dexRouters.push(IDexRouter(_router));
        emit ConfigUpdated("dexRouterAdded", dexRouters.length);
    }

    function dexRouterCount() external view returns (uint256) {
        return dexRouters.length;
    }

    // ═══════ V5.0: ADAPTIVE MODE CONFIG ═══════

    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        feeDistributor = _feeDistributor;
        emit ConfigUpdated("feeDistributor", uint256(uint160(_feeDistributor)));
    }

    function setReserves(address _buybackReserve, address _opsReserve, address _maintenanceReserve) external onlyOwner {
        require(_buybackReserve != address(0), "BuybackReserve zero");
        require(_opsReserve != address(0), "OpsReserve zero");
        require(_maintenanceReserve != address(0), "MaintenanceReserve zero");
        buybackReserve = _buybackReserve;
        opsReserve = _opsReserve;
        maintenanceReserve = _maintenanceReserve;
    }

    function setMaintenanceReserve(address _maintenanceReserve) external onlyOwner {
        require(_maintenanceReserve != address(0), "MaintenanceReserve zero");
        maintenanceReserve = _maintenanceReserve;
        emit MaintenanceReserveUpdated(_maintenanceReserve);
    }

    function setAdaptiveMode(bool enabled) external onlyOwner {
        require(!enabled || feeDistributor != address(0), "FeeDistributor not set");
        require(
            !enabled || (buybackReserve != address(0) && opsReserve != address(0) && maintenanceReserve != address(0)),
            "Reserves not set"
        );
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

    // ═══════ EMERGENCY ═══════

    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(usdc), "Cannot recover USDC");
        require(token != address(lumina), "Cannot recover LUMINA");
        IERC20(token).safeTransfer(owner(), amount);
        emit TokenRecovered(token, amount, owner());
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
