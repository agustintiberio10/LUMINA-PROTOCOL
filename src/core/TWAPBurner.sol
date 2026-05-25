// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {IBurnable} from "../interfaces/IBurnable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ChainGuard} from "../utils/ChainGuard.sol";

/// @title TWAPBurner
/// @notice Receives USDC from premiums and marketplace fees.
///         Executes distributed buy & burn of $LUMINA via multi-DEX routing.
/// @dev [V5.1] UUPS upgradeable proxy pattern.

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
    /// @notice [Fix audit #27 INFO-1] Emitted on setAuthorizedSender.
    event AuthorizedSenderUpdated(address indexed sender, bool authorized);
    /// @notice [Fix audit #27 INFO-2] Emitted on setReserves.
    event ReservesUpdated(
        address indexed buybackReserve, address indexed opsReserve, address indexed maintenanceReserve
    );
    /// @notice [Fix audit #27 INFO-3] Emitted when adaptive mode is toggled.
    event AdaptiveModeUpdated(bool enabled);
    /// @notice [Sprint CR-USDC-Reconfig] Emitted when the premium token (USDC) is updated.
    event UsdcUpdated(address indexed oldUsdc, address indexed newUsdc);

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

    /// @notice Receive premium USDC from the router and ACCRUE it toward an
    ///         auto-burn. Burning is NEVER performed synchronously here.
    /// @dev    [F-13 fix] The previous implementation ran a full DEX swap inside
    ///         the buyer's purchase transaction once a threshold was hit. That
    ///         (a) exposed the buyer to swap/MEV failure and unbounded gas, and
    ///         (b) let a buyer time their purchase to front-run/sandwich the
    ///         protocol's own burn. `receivePremium` now ONLY pulls funds and
    ///         bumps counters; the actual burn is executed asynchronously and
    ///         permissionlessly via `executeBurn()` (cooldown-gated, F-24), so
    ///         the burn is decoupled from any single user's transaction.
    ///         [F-22 fix] `tx.origin` is gone entirely — no recipient is derived
    ///         from the transaction origin anywhere in the burn path.
    function receivePremium(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUSDCReceived += amount;
        emit PremiumReceived(msg.sender, amount);

        // [F-13 fix] Accrue only. Counters drive `autoBurnReady()` for keepers;
        // no swap is triggered in the buyer's tx.
        purchaseCounter += 1;
        accumulatedUSDCSinceBurn += amount;
    }

    // [MR-L05 fix] nonReentrant for parity with sibling receivePremium.
    function receiveMarketplaceFee(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUSDCReceived += amount;
        emit MarketplaceFeeReceived(msg.sender, amount);
    }

    // ═══════ EXECUTE BURN ═══════

    /// @notice Permissionless, cooldown-gated buy & burn. Also the async
    ///         settlement point for premium-driven auto-burn accrual.
    /// @dev    [F-13/F-24 fix] Single burn path for both manual and auto-burn.
    ///         Always respects `burnCooldown`. Resets the auto-burn accrual
    ///         counters so threshold accounting stays consistent regardless of
    ///         whether the burn was keeper- or threshold-motivated.
    function executeBurn() external nonReentrant {
        ChainGuard.requireValidChain();
        require(block.timestamp >= lastBurnTimestamp + burnCooldown, "Cooldown active");

        uint256 usdcBalance = usdc.balanceOf(address(this));
        require(usdcBalance >= minBurnAmount, "Below minimum");

        uint256 amount = usdcBalance > maxBurnAmount ? maxBurnAmount : usdcBalance;
        lastBurnTimestamp = block.timestamp;

        // [F-13 fix] Clear premium-driven accrual counters on every burn.
        purchaseCounter = 0;
        accumulatedUSDCSinceBurn = 0;

        if (adaptiveModeEnabled) {
            _executeAdaptive(amount);
        } else {
            _executeLegacyBurn(amount);
        }
    }

    /// @notice [F-13 fix] True when the premium-driven auto-burn thresholds are
    ///         met AND the cooldown has elapsed AND there is enough USDC. Lets
    ///         keepers (or anyone) know `executeBurn()` should be called. This
    ///         replaces the synchronous in-purchase trigger.
    function autoBurnReady() public view returns (bool) {
        if (maxPurchasesBeforeBurn == 0) return false; // dormant
        bool thresholdHit =
            purchaseCounter >= maxPurchasesBeforeBurn || accumulatedUSDCSinceBurn >= maxAccumulatedUSDCBeforeBurn;
        if (!thresholdHit) return false;
        if (block.timestamp < lastBurnTimestamp + burnCooldown) return false;
        return usdc.balanceOf(address(this)) >= minBurnAmount;
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

        // [F-19 fix] Pick the executing router by its quote (best execution),
        // but DERIVE the protective `minOut` exclusively from the INDEPENDENT,
        // deviation-guarded oracle — never from the executing pool's own quote.
        // Sourcing minOut from the pool a sandwicher controls makes the floor
        // move with the manipulation; the oracle is the only trust anchor here.
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

        // [F-19 fix] minOut comes from the oracle price ONLY. If the oracle is
        // unset or unavailable, we REVERT rather than fall back to the
        // manipulable pool quote.
        // [INFO-5 fix] After the MR-H01 CapacityOracle hardening the oracle now
        // enforces freshness + cross-window deviation: it REVERTS on a stale,
        // thin, or diverged feed, so any price it returns here is fresh. We do
        // NOT claim minOut>0 "by construction" — `minOut>0` still requires
        // `oraclePrice > 0`, which is asserted explicitly on the next line.
        require(capacityOracle != address(0), "TWAPBurner: oracle unset");
        uint256 oraclePrice = IPriceOracle(capacityOracle).getLuminaPrice();
        require(oraclePrice > 0, "TWAPBurner: oracle price zero");

        // usdcAmount is 6-dec; *1e12 lifts to 18-dec USD, *1e18 / price(18-dec)
        // yields the expected LUMINA out in 18-dec.
        uint256 expectedOut = (usdcAmount * 1e12 * 1e18) / oraclePrice;
        uint256 minOut = (expectedOut * (10_000 - maxSlippageBps)) / 10_000;

        // [M-02 fix] Defense-in-depth: never swap without a protective floor.
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
        emit AuthorizedSenderUpdated(sender, authorized);
    }

    function setCapacityOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Zero oracle");
        capacityOracle = _oracle;
        emit ConfigUpdated("capacityOracle", uint256(uint160(_oracle)));
    }

    /// @notice [Sprint CR-USDC-Reconfig] Re-point the premium token address.
    /// @dev    Mirrors `CoverRouterV2.setUsdc` — needed so the burner pulls
    ///         the same token the router collects. Auto-burn is gated by
    ///         `maxPurchasesBeforeBurn` (currently 0 on Sepolia), so this
    ///         setter does NOT touch DEX wiring. On mainnet this MUST be
    ///         reverted alongside the router (audit-pack item BL-USDC).
    function setUsdc(address _usdc) external onlyOwner {
        require(_usdc != address(0), "Zero USDC");
        // [MR-M07 fix] The new token MUST be 6-decimals: `_swapAndBurn` hardcodes
        // a `*1e12` conversion (6→18 dec) when deriving minOut, so re-pointing to
        // a token with different decimals would silently corrupt slippage math.
        // Ops MUST drain accrual and sweep the balance BEFORE re-pointing,
        // otherwise stale 6-dec accounting would be attributed to the new token.
        require(accumulatedUSDCSinceBurn == 0, "TWAPBurner: drain accrual first");
        require(usdc.balanceOf(address(this)) == 0, "TWAPBurner: sweep balance first");
        address old = address(usdc);
        usdc = IERC20(_usdc);
        emit UsdcUpdated(old, _usdc);
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
        emit ReservesUpdated(_buybackReserve, _opsReserve, _maintenanceReserve);
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
        emit AdaptiveModeUpdated(enabled);
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

    // ═══════════════════════════════════════════════════════════
    //  V2 — AUTO-BURN ON PURCHASE
    // ═══════════════════════════════════════════════════════════

    /// @notice Trigger an auto-burn after this many premium receipts. 0 = disabled.
    uint256 public maxPurchasesBeforeBurn;
    /// @notice Trigger an auto-burn when this much USDC accumulates since the last burn (6-decimals).
    uint256 public maxAccumulatedUSDCBeforeBurn;
    /// @notice Number of premium receipts since the last successful auto-burn attempt.
    uint256 public purchaseCounter;
    /// @notice USDC accumulated since the last auto-burn attempt (6-decimals).
    uint256 public accumulatedUSDCSinceBurn;

    /// @notice When true, refund part of gas to the buyer that triggered the burn.
    bool public gasRefundEnabled;
    /// @notice Maximum ETH refunded per auto-burn (in wei).
    uint256 public gasRefundCap;
    /// @notice Configured refund source (sentinel only — actual refunds drain `address(this).balance`).
    address public gasRefundTreasury;

    event AutoBurnTriggered(uint256 amount, address indexed router, address indexed gasRecipient);
    event AutoBurnFailed(uint256 amount, bytes reason);
    event GasRefunded(address indexed recipient, uint256 amount);
    event AutoBurnConfigUpdated(uint256 maxPurchases, uint256 maxAccumulatedUSDC);
    event GasRefundConfigUpdated(bool enabled, uint256 cap, address indexed treasury);

    /// @notice One-shot initializer for the V2 upgrade. `reinitializer(2)` ensures it runs exactly once.
    function initializeV2(
        uint256 _maxPurchases,
        uint256 _maxAccumulatedUSDC,
        bool _gasRefundEnabled,
        uint256 _gasRefundCap,
        address _gasRefundTreasury
    ) external reinitializer(2) onlyOwner {
        maxPurchasesBeforeBurn = _maxPurchases;
        maxAccumulatedUSDCBeforeBurn = _maxAccumulatedUSDC;
        gasRefundEnabled = _gasRefundEnabled;
        gasRefundCap = _gasRefundCap;
        gasRefundTreasury = _gasRefundTreasury;

        emit AutoBurnConfigUpdated(_maxPurchases, _maxAccumulatedUSDC);
        emit GasRefundConfigUpdated(_gasRefundEnabled, _gasRefundCap, _gasRefundTreasury);
    }

    /// @notice Configure the premium-driven auto-burn thresholds.
    /// @dev    [F-13(d)] Owner-gated with an `AutoBurnConfigUpdated` event. The
    ///         production owner is the Gnosis Safe (a TimelockController in
    ///         prod), so threshold changes are effectively timelock-gated at the
    ///         ownership layer. Setting `_maxPurchases = 0` disables auto-burn
    ///         entirely (`autoBurnReady()` returns false). These thresholds only
    ///         influence WHEN `autoBurnReady()` flips true for keepers; they
    ///         never trigger a swap inside a user transaction (see F-13).
    function setAutoBurnConfig(uint256 _maxPurchases, uint256 _maxAccumulatedUSDC) external onlyOwner {
        maxPurchasesBeforeBurn = _maxPurchases;
        maxAccumulatedUSDCBeforeBurn = _maxAccumulatedUSDC;
        emit AutoBurnConfigUpdated(_maxPurchases, _maxAccumulatedUSDC);
    }

    function setGasRefundConfig(bool _enabled, uint256 _cap, address _treasury) external onlyOwner {
        gasRefundEnabled = _enabled;
        gasRefundCap = _cap;
        gasRefundTreasury = _treasury;
        emit GasRefundConfigUpdated(_enabled, _cap, _treasury);
    }

    /// @notice Accept ETH for gas-refund pre-funding.
    /// @dev    Retained for storage/ABI continuity. As of the F-13/F-22 fix the
    ///         synchronous in-purchase auto-burn (and its `tx.origin` gas refund)
    ///         was removed, so the `gasRefund*` storage vars are now DORMANT —
    ///         no code path pays a gas refund. They are intentionally NOT removed
    ///         (storage is append-only for the UUPS proxy) and may be repurposed
    ///         by a future keeper-incentive mechanism.
    receive() external payable {}

    // [F-13/F-22 fix] Removed `_autoBurn(address)` and `_executeBurnExternal`.
    // The synchronous, `tx.origin`-based, cooldown-ignoring in-purchase burn is
    // gone; all burns now flow through the permissionless, cooldown-gated
    // `executeBurn()`. Keepers poll `autoBurnReady()` to decide when to call it.

    // Storage gap for future upgrades (was 50; reduced by 7 V2 vars).
    // [F-13/F-22 fix] No storage added/removed by the auto-burn rework — the
    // gap stays at 43 (the 7 V2 vars, incl. the now-dormant gasRefund*, persist).
    uint256[43] private __gap;
}
