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

interface IMarketClaimBond {
    function balanceOf(address account, uint256 epochId) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function maturityDate(uint256 epochId) external view returns (uint256);
}

/// @title LuminaBondMarketplace
/// @notice Native marketplace for ClaimBonds ERC-1155 with 3% fees (1.5% buyer + 1.5% seller).
/// @dev [V5.1] UUPS upgradeable proxy pattern.
/// @dev [M-3] Anti-spam floor: list() rejects listings whose total `priceUSDC` is
///      below `minPricePerUnit` (default 1e6 = $1 USDC, 6 decimals). The state var name
///      is preserved from the deployed runtime; the on-chain semantic is a TOTAL price
///      floor per listing (not per-unit), which matches the deployed implementation
///      (proxy 0xfaC56692c626718aC8953A3d5fAE67fac2f1Be6E on Base Sepolia where
///      minPricePerUnit() returns 1000000).
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

    /// @notice Anti-spam floor: minimum pricePerUnit allowed in list(). Set to 1e6 (=$1 USDC 6-dec).
    /// @dev    Storage slot appended below all pre-existing state and BEFORE __gap to preserve
    ///         the UUPS layout used by the deployed proxy. __gap was reduced from 50 -> 49.
    uint256 public minPricePerUnit;

    /// @notice [F-14] Pull-payment ledger. Seller USDC proceeds from `executeBuy` are credited
    ///         here instead of being push-transferred, so a USDC-blacklisted (or otherwise
    ///         transfer-reverting) seller can no longer brick a buyer's fill. Sellers pull their
    ///         balance via `withdraw()`.
    /// @dev    Storage slot appended AFTER `minPricePerUnit` and BEFORE __gap to preserve the
    ///         UUPS layout used by the deployed proxy. __gap was reduced from 49 -> 48.
    mapping(address => uint256) public pendingWithdrawals;

    event Listed(
        uint256 indexed listingId, address indexed seller, uint256 indexed epochId, uint256 amount, uint256 priceUSDC
    );
    event Cancelled(uint256 indexed listingId, address indexed seller);
    event Bought(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 priceUSDC,
        uint256 sellerFee,
        uint256 buyerFee
    );
    event TwapBurnerUpdated(address indexed newTwapBurner);
    /// @notice [C-1 fix] Emitted when the settlement/payment USDC token is repointed.
    event UsdcUpdated(address indexed oldUsdc, address indexed newUsdc);
    /// @notice [F-14] Emitted when a seller's proceeds are credited to the pull-payment ledger.
    event WithdrawalCredited(address indexed seller, uint256 amount);
    /// @notice [F-14] Emitted when a seller pulls their accrued proceeds.
    event Withdrawn(address indexed seller, uint256 amount);
    /// @notice [LOW-2 fix] Emitted on successful non-core token rescue (ERC-20 or ERC-1155).
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);
    /// @notice [M-3] Emitted when the anti-spam minimum price floor is updated.
    event MinPricePerUnitUpdated(uint256 oldValue, uint256 newValue);

    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // @custom:coverage-exclude L90, L94-L97 OZ pattern (ADR-017 Sprint Y):
        // `_disableInitializers()` + `__XInit()` lines run via the impl-ctor and
        // proxy delegatecall; forge-coverage `--ir-minimum` does not credit them.
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

        // [M-3] Anti-spam floor: $1 USDC (6 decimals). Matches deployed runtime value.
        minPricePerUnit = 1_000_000;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
    }

    function list(uint256 epochId, uint256 amount, uint256 priceUSDC)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        require(amount > 0, "Amount zero");
        require(priceUSDC > 0, "Price zero");
        // [M-3] Anti-spam floor. Matches deployed runtime (proxy 0xfaC5...Be6E on Base Sepolia)
        // where minPricePerUnit() = 1e6 ($1 USDC). Semantic: total `priceUSDC` for the
        // listing must be >= the configured floor. priceUSDC is the TOTAL price (not per-unit).
        require(priceUSDC >= minPricePerUnit, "below minimum");
        require(claimBond.balanceOf(msg.sender, epochId) >= amount, "Insufficient balance");

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

    /// @notice Fill an active listing: buyer pays USDC + buyer fee, receives the escrowed bonds.
    /// @dev    [F-28] The ERC-1155 `safeTransferFrom` to the buyer at the end of this function can
    ///         invoke `onERC1155Received` on a contract buyer. This is safe because:
    ///           (1) `nonReentrant` blocks re-entry into any guarded function, and
    ///           (2) strict CEI — the listing is marked `!active` and all accounting/effects are
    ///               committed BEFORE the external bond transfer (the only callback vector).
    ///         INVARIANT: no contract may price or settle off un-finalized marketplace listing
    ///         state — by the time the ERC-1155 callback fires, the listing is fully de-activated
    ///         and the seller's proceeds are already booked to `pendingWithdrawals`, so a callback
    ///         observer can never see a half-filled listing.
    /// @dev    [F-14] Pull-payment: the seller's net proceeds are credited to `pendingWithdrawals`
    ///         instead of being push-transferred. A USDC-blacklisted seller can therefore no longer
    ///         force-revert (brick) the buyer's fill; the seller simply cannot `withdraw()` until
    ///         unblacklisted. The protocol fee leg is wrapped so a misbehaving `twapBurner` cannot
    ///         brick fills either — on failure the fee is parked in the burner's withdrawal ledger.
    function executeBuy(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active, "Not active");

        // [F-25] Mirror the maturity guard that `list()` enforces. A bond that has matured must
        // not be tradable on the secondary market (its redemption semantics have changed).
        require(block.timestamp < claimBond.maturityDate(l.epochId), "BOND_MATURED");

        l.active = false;

        uint256 sellerFee = (l.priceUSDC * SELLER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 buyerFee = (l.priceUSDC * BUYER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalBuyerPays = l.priceUSDC + buyerFee;
        uint256 sellerReceives = l.priceUSDC - sellerFee;
        uint256 totalFee = sellerFee + buyerFee;

        // EFFECTS: pull buyer funds in, then book proceeds/fees before any push-out or callback.
        usdc.safeTransferFrom(msg.sender, address(this), totalBuyerPays);

        // [F-14] Credit seller proceeds to the pull-payment ledger (no push-transfer to seller).
        pendingWithdrawals[l.seller] += sellerReceives;
        emit WithdrawalCredited(l.seller, sellerReceives);

        // Protocol fee: attempt a direct push, but never let a misbehaving burner brick the fill.
        // On failure the fee is parked in the burner's own pull-payment balance.
        address burner = twapBurner;
        try usdc.transfer(burner, totalFee) returns (bool ok) {
            if (!ok) {
                pendingWithdrawals[burner] += totalFee;
                emit WithdrawalCredited(burner, totalFee);
            }
        } catch {
            pendingWithdrawals[burner] += totalFee;
            emit WithdrawalCredited(burner, totalFee);
        }

        // INTERACTION (last): deliver bonds to buyer. Only callback vector; state already final.
        claimBond.safeTransferFrom(address(this), msg.sender, l.epochId, l.amount, "");
        emit Bought(listingId, msg.sender, l.seller, l.priceUSDC, sellerFee, buyerFee);
    }

    /// @notice [F-14] Pull accrued USDC proceeds (seller fills, parked protocol fees).
    /// @dev    nonReentrant + checks-effects-interactions: balance is zeroed before transfer.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function setTwapBurner(address _new) external onlyRole(FEE_MANAGER_ROLE) {
        require(_new != address(0), "Zero");
        twapBurner = _new;
        emit TwapBurnerUpdated(_new);
    }

    /// @notice [C-1 fix] Repoint the settlement/payment USDC token. Required after the
    ///         protocol-wide migration from the deprecated Circle Base Sepolia USDC to
    ///         mUSDC: the marketplace was initialized with the old token, leaving
    ///         `executeBuy` un-fillable for any mUSDC-funded buyer. Admin-gated; never
    ///         touches escrowed bonds. New listings/fills settle in the new token; any
    ///         pre-existing `pendingWithdrawals` denominated in the old token are
    ///         unaffected by this pointer change (none exist on this deployment).
    /// @dev    No storage layout change — this is an appended function on the same
    ///         `usdc` slot, applied via UUPS upgrade.
    function setUsdc(address _new) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_new != address(0), "Zero");
        address old = address(usdc);
        usdc = IERC20(_new);
        emit UsdcUpdated(old, _new);
    }

    /// @notice [M-3] Update the anti-spam minimum price floor for new listings.
    /// @dev    Uses FEE_MANAGER_ROLE to match the access pattern of `setTwapBurner`.
    function setMinPricePerUnit(uint256 newFloor) external onlyRole(FEE_MANAGER_ROLE) {
        uint256 old = minPricePerUnit;
        minPricePerUnit = newFloor;
        emit MinPricePerUnitUpdated(old, newFloor);
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

    // Storage gap for future upgrades. [M-3] Reduced from 50 -> 49 (minPricePerUnit appended).
    // [F-14] Reduced from 49 -> 48 (pendingWithdrawals mapping appended). Total reserved layout
    // footprint is unchanged across both appends.
    uint256[48] private __gap;
}
