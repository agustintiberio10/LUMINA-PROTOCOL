// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    ERC1155HolderUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import {IGlobalPauseRegistry} from "../governance/GlobalPauseRegistry.sol";

interface IMarketClaimBond {
    function balanceOf(address account, uint256 epochId) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function maturityDate(uint256 epochId) external view returns (uint256);
    /// @dev [Audit fix H-12] Escape hatch on ClaimBond — see ClaimBond docs.
    function escapeTransfer(address to, uint256 id, uint256 amount) external;
}

/// @title LuminaBondMarketplace
/// @notice Native marketplace for ClaimBonds ERC-1155 with 3% fees (1.5% buyer + 1.5% seller).
/// @dev [V5.1] UUPS upgradeable proxy pattern.
contract LuminaBondMarketplace is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC1155HolderUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    IMarketClaimBond public claimBond;
    IERC20 public usdc;
    address public twapBurner;

    uint256 public constant SELLER_FEE_BPS = 150; // 1.5%
    uint256 public constant BUYER_FEE_BPS = 150; // 1.5%
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice [Fix M-3] Upper bound for `minPricePerUnit` to prevent admin
    ///         lockout (an adversarial admin could otherwise set the floor
    ///         high enough that no realistic listing passes). USDC has 6
    ///         decimals — 100 USDC = 100e6 = 100x face value of a $1 bond.
    uint256 public constant MIN_PRICE_PER_UNIT_CAP = 100e6;

    /// @notice [Fix M-3] Default seeded into `minPricePerUnit` by
    ///         `initialize()` (fresh deploys) and by `initializeV2()`
    ///         (upgrade path) when the caller passes 0 to indicate
    ///         "use default". Equals 1 USDC = 100% of face value.
    uint256 public constant DEFAULT_MIN_PRICE_PER_UNIT = 1e6;

    struct Listing {
        address seller;
        uint256 epochId;
        uint256 amount;
        uint256 priceUSDC;
        bool active;
        uint256 listedAt;
    }

    mapping(uint256 => Listing) public listings;
    uint256 public nextListingId;

    /// @notice [Fix M-3] Per-unit price floor (raw USDC, 6 decimals).
    ///         `list()` requires `priceUSDC / amount >= minPricePerUnit`.
    ///         Mutable post-deploy via `setMinPricePerUnit` (DEFAULT_ADMIN_ROLE)
    ///         and seeded by `initialize()` / `initializeV2()`.
    /// @dev    [Merge consolidation] M-3 and M-7 each consume 1 slot of
    ///         the original `__gap[50]`. Net `__gap[48]`. UUPS-safe append.
    uint256 public minPricePerUnit;

    /// @notice [Fix M-7] Registry consulted by `list` and `executeBuy`.
    ///         When `address(0)`, global-pause check is skipped. `cancel`
    ///         and `emergencyCancel` are NEVER gated — they are unwind
    ///         paths that must remain available during a pause.
    IGlobalPauseRegistry public globalPauseRegistry;

    event Listed(
        uint256 indexed listingId, address indexed seller, uint256 indexed epochId, uint256 amount, uint256 priceUSDC
    );
    event Cancelled(uint256 indexed listingId, address indexed seller);

    /// @notice [Audit fix H-12] Emitted when a listing is unwound through
    ///         the emergency-cancel path, e.g. while the multisig has
    ///         revoked the marketplace's `authorizedOperator` status.
    ///         Bonds always flow back to the ORIGINAL seller stored on
    ///         the listing — never to the caller.
    event ListingEmergencyCancelled(uint256 indexed listingId, address indexed seller, uint256 timestamp);
    event Bought(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 priceUSDC,
        uint256 sellerFee,
        uint256 buyerFee
    );
    event TwapBurnerUpdated(address indexed newTwapBurner);
    /// @notice [LOW-2 fix] Emitted on successful non-core token rescue (ERC-20 or ERC-1155).
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);
    /// @notice [Fix M-3] Emitted whenever `minPricePerUnit` is changed
    ///         (initialize, initializeV2, or setMinPricePerUnit).
    event MinPricePerUnitUpdated(uint256 oldMin, uint256 newMin);
    /// @notice [Fix M-7] Emitted when the global pause registry is wired or rewired.
    event GlobalPauseRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();

    // ═══════ ERRORS (M-3 min price) ═══════
    /// @notice Thrown by `list()` when `priceUSDC / amount` is below the
    ///         current `minPricePerUnit` floor.
    error PriceBelowMinimum(uint256 pricePerUnit, uint256 minPricePerUnit);
    /// @notice Thrown by setters when the requested floor exceeds
    ///         `MIN_PRICE_PER_UNIT_CAP` (admin-lockout guard).
    error MinPriceCapExceeded(uint256 requested, uint256 cap);
    /// @notice Thrown by setters when the requested floor is zero.
    error MinPriceZeroNotAllowed();

    /// @notice [Fix M-7] Thrown by `list` and `executeBuy` when the global
    ///         pause registry reports `globalPaused == true`. `cancel` and
    ///         `emergencyCancel` never throw this error.
    error GloballyPaused();

    /// @dev [Fix M-7] Reverts if the registry says paused. No-op when
    ///      `globalPauseRegistry == address(0)` (registry not yet wired).
    function _enforceNotGloballyPaused() internal view {
        IGlobalPauseRegistry reg = globalPauseRegistry;
        if (address(reg) != address(0) && reg.isGloballyPaused()) revert GloballyPaused();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _claimBond, address _usdc, address _twapBurner, address _admin) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __ERC1155Holder_init();
        __UUPSUpgradeable_init();

        require(
            _claimBond != address(0) && _usdc != address(0) && _twapBurner != address(0) && _admin != address(0),
            "Zero addr"
        );

        claimBond = IMarketClaimBond(_claimBond);
        usdc = IERC20(_usdc);
        twapBurner = _twapBurner;

        // [Fix M-3] Seed the per-unit price floor for fresh deploys.
        // Existing V1 deployments must call `initializeV2()` post-upgrade
        // to set this slot — without it, every `list()` would revert
        // (pricePerUnit >= 0 always, but the gas saving from skipping the
        // check is not worth the silent-no-op risk).
        minPricePerUnit = DEFAULT_MIN_PRICE_PER_UNIT;
        emit MinPricePerUnitUpdated(0, DEFAULT_MIN_PRICE_PER_UNIT);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
    }

    /// @notice [Fix M-3] Reinitializer for V1 contracts that already
    ///         called `initialize()` and need the new `minPricePerUnit`
    ///         slot seeded post-upgrade. Pass `_initialMinPrice = 0` to
    ///         use `DEFAULT_MIN_PRICE_PER_UNIT` (= 1 USDC).
    /// @dev    Gated on `DEFAULT_ADMIN_ROLE` (not just `reinitializer`)
    ///         so a third party cannot front-run the upgrade and seed an
    ///         adversarial value before the multisig calls it. Atomic
    ///         deploy scripts should bundle `upgradeToAndCall(newImpl,
    ///         abi.encodeCall(initializeV2, (desiredFloor)))` to remove
    ///         the front-run window entirely.
    function initializeV2(uint256 _initialMinPrice) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 floor = _initialMinPrice == 0 ? DEFAULT_MIN_PRICE_PER_UNIT : _initialMinPrice;
        if (floor > MIN_PRICE_PER_UNIT_CAP) revert MinPriceCapExceeded(floor, MIN_PRICE_PER_UNIT_CAP);
        uint256 old = minPricePerUnit;
        minPricePerUnit = floor;
        emit MinPricePerUnitUpdated(old, floor);
    }

    /// @notice [Fix M-3] Mutable per-unit price floor for the marketplace.
    ///         Bounded by `MIN_PRICE_PER_UNIT_CAP` (100 USDC) to prevent
    ///         admin lockout. Existing listings are unaffected — the check
    ///         only runs on new `list()` calls.
    function setMinPricePerUnit(uint256 _newMin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newMin == 0) revert MinPriceZeroNotAllowed();
        if (_newMin > MIN_PRICE_PER_UNIT_CAP) revert MinPriceCapExceeded(_newMin, MIN_PRICE_PER_UNIT_CAP);
        uint256 old = minPricePerUnit;
        minPricePerUnit = _newMin;
        emit MinPricePerUnitUpdated(old, _newMin);
    }

    function list(uint256 epochId, uint256 amount, uint256 priceUSDC)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        // [Fix M-7] Block new listings during a global pause. `cancel`
        // and `emergencyCancel` remain available for sellers to unwind.
        _enforceNotGloballyPaused();
        require(amount > 0, "Amount zero");
        require(priceUSDC > 0, "Price zero");
        require(claimBond.balanceOf(msg.sender, epochId) >= amount, "Insufficient balance");

        // [Fix M-3] Per-unit price floor blocks 1-wei spam attacks and
        // artificial price-floor manipulation. Integer division is
        // deliberately conservative — a listing of `(amount=2, priceUSDC=1.5e6)`
        // gives `pricePerUnit = 750_000`, below the 1 USDC floor, and reverts.
        uint256 pricePerUnit = priceUSDC / amount;
        if (pricePerUnit < minPricePerUnit) revert PriceBelowMinimum(pricePerUnit, minPricePerUnit);

        uint256 maturity = claimBond.maturityDate(epochId);
        require(block.timestamp < maturity, "Bond matured");

        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            epochId: epochId,
            amount: amount,
            priceUSDC: priceUSDC,
            active: true,
            listedAt: block.timestamp
        });

        claimBond.safeTransferFrom(msg.sender, address(this), epochId, amount, "");
        emit Listed(listingId, msg.sender, epochId, amount, priceUSDC);
    }

    function cancel(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active, "Not active");
        require(l.seller == msg.sender, "Not seller");

        l.active = false;
        claimBond.safeTransferFrom(address(this), l.seller, l.epochId, l.amount, "");
        emit Cancelled(listingId, msg.sender);
    }

    /// @notice [Audit fix H-12] Unwinds an active listing and returns the
    ///         escrowed bonds to the ORIGINAL seller, even when the
    ///         multisig has revoked this marketplace's `authorizedOperator`
    ///         status on `ClaimBond`. The function relies on the
    ///         `marketplaceEscape` bypass added to `ClaimBond._update` —
    ///         see ClaimBond docs for the trust model.
    /// @dev    Authorisation:
    ///           - `msg.sender == listing.seller`: a holder can always
    ///              recover their own bonds.
    ///           - `hasRole(DEFAULT_ADMIN_ROLE, msg.sender)`: the multisig
    ///              can recover bonds on behalf of any seller during a
    ///              market-wide emergency.
    ///         Importantly the destination is HARD-CODED to `l.seller`,
    ///         the address recorded at list-time. The caller (whether
    ///         seller or admin) cannot redirect bonds to a third party.
    ///         CEI: the listing is marked inactive BEFORE the external
    ///         transfer, and `nonReentrant` provides defence in depth.
    function emergencyCancel(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active, "Not active");
        require(msg.sender == l.seller || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Only seller or admin");

        l.active = false;
        // [Audit fix H-12] `escapeTransfer` (vs `safeTransferFrom`) keeps
        // working even when the multisig has revoked this marketplace's
        // operator authorization on ClaimBond. The destination is hard-
        // coded to `l.seller` (read from the listing record), so neither
        // the seller nor the admin caller can redirect bonds to a third
        // party through this entry point.
        claimBond.escapeTransfer(l.seller, l.epochId, l.amount);
        emit ListingEmergencyCancelled(listingId, l.seller, block.timestamp);
    }

    function executeBuy(uint256 listingId) external nonReentrant {
        // [Fix M-7] Block buyer match during a global pause. The seller's
        // bond stays in escrow; they can `cancel` to recover it.
        _enforceNotGloballyPaused();
        Listing storage l = listings[listingId];
        require(l.active, "Not active");

        l.active = false;

        uint256 sellerFee = (l.priceUSDC * SELLER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 buyerFee = (l.priceUSDC * BUYER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalBuyerPays = l.priceUSDC + buyerFee;
        uint256 sellerReceives = l.priceUSDC - sellerFee;

        usdc.safeTransferFrom(msg.sender, address(this), totalBuyerPays);
        usdc.safeTransfer(l.seller, sellerReceives);
        usdc.safeTransfer(twapBurner, sellerFee + buyerFee);

        claimBond.safeTransferFrom(address(this), msg.sender, l.epochId, l.amount, "");
        emit Bought(listingId, msg.sender, l.seller, l.priceUSDC, sellerFee, buyerFee);
    }

    /// @notice [Fix M-7] Wire (or re-wire) the global pause registry.
    ///         Passing `address(0)` opts the contract out of the global
    ///         pause. Only `DEFAULT_ADMIN_ROLE` (= multisig) can call.
    function setGlobalPauseRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = address(globalPauseRegistry);
        globalPauseRegistry = IGlobalPauseRegistry(_registry);
        emit GlobalPauseRegistryUpdated(old, _registry);
    }

    function setTwapBurner(address _new) external onlyRole(FEE_MANAGER_ROLE) {
        require(_new != address(0), "Zero");
        twapBurner = _new;
        emit TwapBurnerUpdated(_new);
    }

    function getListing(uint256 listingId)
        external
        view
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
    {
        Listing memory l = listings[listingId];
        return (l.seller, l.epochId, l.amount, l.priceUSDC, l.active);
    }

    function calculateFees(uint256 priceUSDC)
        external
        pure
        returns (uint256 sellerFee, uint256 buyerFee, uint256 total)
    {
        sellerFee =
            (priceUSDC * SELLER_FEE_BPS) / BPS_DENOMINATOR;
        buyerFee = (priceUSDC * BUYER_FEE_BPS) / BPS_DENOMINATOR;
        total = sellerFee + buyerFee;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable, ERC1155HolderUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ═══════ RESCUE (LOW-2 fix, audit #26) ═══════

    /// @notice Recover non-core ERC-20 tokens sent to this contract by mistake.
    /// @dev    USDC and ClaimBond are protected.
    function recoverToken(address token, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (_isCoreToken(token)) revert CoreTokenProtected(token);

        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, amount, to);
    }

    /// @notice Recover non-core ERC-1155 tokens sent to this contract by mistake.
    /// @dev    ClaimBond (core escrow token) is protected.
    function recoverERC1155(address token, uint256 id, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (_isCoreToken(token)) revert CoreTokenProtected(token);

        IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
        emit TokenRecovered(token, amount, to);
    }

    function _isCoreToken(address token) private view returns (bool) {
        return token == address(usdc) || token == address(claimBond);
    }

    // Storage gap for future upgrades.
    // [Merge consolidation] M-3 (`minPricePerUnit`) and M-7 (`globalPauseRegistry`)
    // each consume 1 slot of the original `__gap[50]`. Net `__gap[48]`.
    // UUPS-safe append — existing slots are not reordered.
    uint256[48] private __gap;
}
