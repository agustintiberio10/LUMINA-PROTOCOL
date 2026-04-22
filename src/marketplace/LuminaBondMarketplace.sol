// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
