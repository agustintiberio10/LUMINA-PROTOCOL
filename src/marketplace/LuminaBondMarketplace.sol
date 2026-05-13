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

    function executeBuy(uint256 listingId) external nonReentrant {
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

    function setTwapBurner(address _new) external onlyRole(FEE_MANAGER_ROLE) {
        require(_new != address(0), "Zero");
        twapBurner = _new;
        emit TwapBurnerUpdated(_new);
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

    // Storage gap for future upgrades. [M-3] Reduced from 50 -> 49 because
    // `minPricePerUnit` was appended above; total reserved layout footprint is unchanged.
    uint256[49] private __gap;
}
