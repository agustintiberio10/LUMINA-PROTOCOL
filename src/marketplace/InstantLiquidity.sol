// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IExpirable} from "./IExpirable.sol";

// ═══════ Minimal interfaces for NFTs created by other agents ═══════

interface IVaultShareNFT is IERC721 {
    struct Position {
        address vault;
        uint256 shares;
        uint256 depositedAt;
    }

    /// @notice Returns the USD value (6 decimals) of a vault share NFT
    function getValue(uint256 tokenId) external view returns (uint256 usdValue6dec);

    /// @notice Returns the full position data for a token
    function getPosition(uint256 tokenId) external view returns (Position memory);
}

interface IPolicyNFT is IERC721 {
    /// @notice Check if a policy NFT is valid (exists)
    function isValid(uint256 tokenId) external view returns (bool);
}

interface ILuminaPriceOracle {
    /// @notice Convert USD amount (6 decimals) to LUMINA (18 decimals)
    function usdToLumina(uint256 usdAmount6dec) external view returns (uint256);

    /// @notice Get the current LUMINA price in USD (6 decimals)
    function getPrice() external view returns (uint256);
}

interface ILuminaToken is IERC20 {
    function burnByRole(address account, uint256 amount) external;
}

/// @title InstantLiquidity
/// @notice Protocol buyback facility: purchases VaultShare and Policy NFTs at a
///         discount, paying the seller in LUMINA tokens. Holders can request a
///         quote and choose whether to accept.
contract InstantLiquidity is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ═══════ Immutables ═══════

    IERC20 public immutable luminaToken;
    ILuminaPriceOracle public immutable priceOracle;
    IVaultShareNFT public immutable vaultShareNFT;
    IPolicyNFT public immutable policyNFT;

    // ═══════ State ═══════

    mapping(address => uint256) public vaultDiscountBps; // vault address → discount (e.g. 3000 = 30%)

    uint256 public dailyBudgetUsd6dec; // in 6 decimals (USDC format)
    uint256 public dailySpentUsd6dec; // in 6 decimals
    uint256 public lastResetDay; // day number for daily reset

    bool public buyingVaults;

    uint256 public lastPriceUpdate; // timestamp of last admin price update

    uint256 public constant MAX_DISCOUNT_BPS = 5000; // 50% max
    uint256 public constant MIN_SELL_AGE = 300; // 5 minutes — flash loan protection
    uint256 public constant MIN_TIME_BEFORE_EXPIRY = 1800; // 30 minutes
    uint256 public constant MAX_PRICE_AGE = 86400; // 24 hours — oracle staleness limit

    // ═══════ Events ═══════

    event VaultNFTSold(
        address indexed seller, uint256 indexed tokenId, uint256 luminaAmount, uint256 usdValue, uint256 discountBps
    );
    event DiscountUpdated(string nftType, bytes32 indexed key, uint256 discountBps);
    event BudgetUpdated(uint256 newBudgetUsd);
    event PriceUpdated(uint256 timestamp);

    // ═══════ Constructor ═══════

    constructor(address _luminaToken, address _priceOracle, address _vaultShareNFT, address _policyNFT)
        Ownable(msg.sender)
    {
        require(_luminaToken != address(0), "Zero LUMINA address");
        require(_priceOracle != address(0), "Zero oracle address");
        require(_vaultShareNFT != address(0), "Zero VaultShareNFT address");
        require(_policyNFT != address(0), "Zero PolicyNFT address");

        luminaToken = IERC20(_luminaToken);
        priceOracle = ILuminaPriceOracle(_priceOracle);
        vaultShareNFT = IVaultShareNFT(_vaultShareNFT);
        policyNFT = IPolicyNFT(_policyNFT);

        lastResetDay = block.timestamp / 1 days;
        lastPriceUpdate = block.timestamp;
    }

    // ═══════ Admin Functions ═══════

    function setVaultDiscount(address vault, uint256 discountBps) external onlyOwner {
        require(vault != address(0), "Zero vault address");
        require(discountBps <= MAX_DISCOUNT_BPS, "Discount exceeds max");
        vaultDiscountBps[vault] = discountBps;
        emit DiscountUpdated("vault", bytes32(uint256(uint160(vault))), discountBps);
    }

    function setDailyBudget(uint256 amountUsd6dec) external onlyOwner {
        dailyBudgetUsd6dec = amountUsd6dec;
        emit BudgetUpdated(amountUsd6dec);
    }

    function setBuyingVaults(bool enabled) external onlyOwner {
        buyingVaults = enabled;
    }

    /// @notice Admin must call this periodically to confirm oracle price is fresh
    function refreshPriceTimestamp() external onlyOwner {
        uint256 price = priceOracle.getPrice();
        require(price > 0, "Oracle price zero");
        lastPriceUpdate = block.timestamp;
        emit PriceUpdated(block.timestamp);
    }

    function depositLumina(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        luminaToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawLumina(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        luminaToken.safeTransfer(msg.sender, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ═══════ Quote Functions (View) ═══════

    /// @notice Get a quote for selling a VaultShare NFT to the protocol
    /// @param nftTokenId The token ID of the VaultShare NFT
    /// @return luminaAmount Amount of LUMINA the seller would receive (18 dec)
    /// @return usdValue The discounted USD value (6 dec)
    /// @return discountBps The discount applied in basis points
    function getQuoteVault(uint256 nftTokenId)
        external
        view
        returns (uint256 luminaAmount, uint256 usdValue, uint256 discountBps)
    {
        IVaultShareNFT.Position memory position = vaultShareNFT.getPosition(nftTokenId);
        discountBps = vaultDiscountBps[position.vault];
        require(discountBps > 0, "No discount set for vault");

        uint256 fullValue = vaultShareNFT.getValue(nftTokenId);
        usdValue = fullValue * (10_000 - discountBps) / 10_000;
        luminaAmount = priceOracle.usdToLumina(usdValue);
    }

    /// @notice Policy NFT instant liquidity is not yet supported
    function getQuotePolicy(
        uint256 /* nftTokenId */
    )
        external
        pure
        returns (uint256, uint256, uint256)
    {
        revert("Not yet supported");
    }

    // ═══════ Seller Functions ═══════

    /// @notice Sell a VaultShare NFT to the protocol for instant LUMINA
    /// @param nftTokenId The token ID of the VaultShare NFT to sell
    function sellVaultNFT(uint256 nftTokenId) external nonReentrant whenNotPaused {
        require(buyingVaults, "Vault buying disabled");

        // FIX 1: Use getPosition() instead of non-existent getVault()
        IVaultShareNFT.Position memory position = vaultShareNFT.getPosition(nftTokenId);
        uint256 discountBps = vaultDiscountBps[position.vault];
        require(discountBps > 0, "No discount set for vault");

        // Expiry buffer check — reject NFTs that expire within 30 minutes
        try IExpirable(address(vaultShareNFT)).getExpiresAt(nftTokenId) returns (uint256 expiresAt) {
            if (expiresAt > 0) require(expiresAt > block.timestamp + MIN_TIME_BEFORE_EXPIRY, "Expires too soon");
        } catch {}

        // FIX 2: Flash loan protection — position must be at least MIN_SELL_AGE old
        require(block.timestamp - position.depositedAt >= MIN_SELL_AGE, "Position too recent");

        // FIX 3: Oracle staleness check
        uint256 price = priceOracle.getPrice();
        require(price > 0, "Oracle price zero");
        require(block.timestamp - lastPriceUpdate <= MAX_PRICE_AGE, "Oracle price stale");

        uint256 fullValue = vaultShareNFT.getValue(nftTokenId);
        uint256 usdValue = fullValue * (10_000 - discountBps) / 10_000;

        _checkAndResetDaily();
        require(dailySpentUsd6dec + usdValue <= dailyBudgetUsd6dec, "Daily budget exceeded");
        dailySpentUsd6dec += usdValue;

        uint256 luminaAmount = priceOracle.usdToLumina(usdValue);
        require(luminaAmount > 0, "Quote is zero");
        require(luminaToken.balanceOf(address(this)) >= luminaAmount, "Insufficient LUMINA balance");

        // Transfer NFT from seller to this contract
        vaultShareNFT.transferFrom(msg.sender, address(this), nftTokenId);

        // Pay seller in LUMINA
        luminaToken.safeTransfer(msg.sender, luminaAmount);

        emit VaultNFTSold(msg.sender, nftTokenId, luminaAmount, usdValue, discountBps);
    }

    /// @notice Policy NFT instant liquidity is not yet supported
    function sellPolicyNFT(
        uint256 /* nftTokenId */
    )
        external
        pure
    {
        revert("Not yet supported");
    }

    // ═══════ Internal Functions ═══════

    /// @dev Resets daily spending counter if a new UTC day has started
    function _checkAndResetDaily() internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > lastResetDay) {
            dailySpentUsd6dec = 0;
            lastResetDay = currentDay;
        }
    }
}
