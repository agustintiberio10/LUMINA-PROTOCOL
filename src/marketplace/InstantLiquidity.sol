// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ═══════ Minimal interfaces for NFTs created by other agents ═══════

interface IVaultShareNFT is IERC721 {
    /// @notice Returns the USD value (6 decimals) of a vault share NFT
    function getValue(uint256 tokenId) external view returns (uint256 usdValue6dec);

    /// @notice Returns the vault address associated with a token
    function getVault(uint256 tokenId) external view returns (address vault);
}

interface IPolicyNFT is IERC721 {
    /// @notice Returns the premium paid for the policy (6 decimals USD)
    function getPremium(uint256 tokenId) external view returns (uint256 premium6dec);

    /// @notice Returns the product identifier for the policy
    function getProductId(uint256 tokenId) external view returns (bytes32 productId);

    /// @notice Returns the start timestamp of the policy
    function getStartTime(uint256 tokenId) external view returns (uint256 startTime);

    /// @notice Returns the end timestamp of the policy
    function getEndTime(uint256 tokenId) external view returns (uint256 endTime);
}

interface ILuminaPriceOracle {
    /// @notice Convert USD amount (6 decimals) to LUMINA (18 decimals)
    function usdToLumina(uint256 usdAmount6dec) external view returns (uint256);
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
    mapping(bytes32 => uint256) public policyDiscountBps; // productId → discount

    uint256 public dailyBudgetUsd; // in 6 decimals (USDC format)
    uint256 public dailySpentUsd; // in 6 decimals
    uint256 public lastResetDay; // day number for daily reset

    bool public buyingVaults;
    bool public buyingPolicies;

    uint256 public constant MAX_DISCOUNT_BPS = 5000; // 50% max

    // ═══════ Events ═══════

    event VaultNFTSold(
        address indexed seller, uint256 indexed tokenId, uint256 luminaAmount, uint256 usdValue, uint256 discountBps
    );
    event PolicyNFTSold(
        address indexed seller, uint256 indexed tokenId, uint256 luminaAmount, uint256 usdValue, uint256 discountBps
    );
    event DiscountUpdated(string nftType, bytes32 indexed key, uint256 discountBps);
    event BudgetUpdated(uint256 newBudgetUsd);

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
    }

    // ═══════ Admin Functions ═══════

    function setVaultDiscount(address vault, uint256 discountBps) external onlyOwner {
        require(vault != address(0), "Zero vault address");
        require(discountBps <= MAX_DISCOUNT_BPS, "Discount exceeds max");
        vaultDiscountBps[vault] = discountBps;
        emit DiscountUpdated("vault", bytes32(uint256(uint160(vault))), discountBps);
    }

    function setPolicyDiscount(bytes32 productId, uint256 discountBps) external onlyOwner {
        require(discountBps <= MAX_DISCOUNT_BPS, "Discount exceeds max");
        policyDiscountBps[productId] = discountBps;
        emit DiscountUpdated("policy", productId, discountBps);
    }

    function setDailyBudget(uint256 amountUsd6dec) external onlyOwner {
        dailyBudgetUsd = amountUsd6dec;
        emit BudgetUpdated(amountUsd6dec);
    }

    function setBuyingVaults(bool enabled) external onlyOwner {
        buyingVaults = enabled;
    }

    function setBuyingPolicies(bool enabled) external onlyOwner {
        buyingPolicies = enabled;
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
        address vault = vaultShareNFT.getVault(nftTokenId);
        discountBps = vaultDiscountBps[vault];
        require(discountBps > 0, "No discount set for vault");

        uint256 fullValue = vaultShareNFT.getValue(nftTokenId);
        usdValue = fullValue * (10_000 - discountBps) / 10_000;
        luminaAmount = priceOracle.usdToLumina(usdValue);
    }

    /// @notice Get a quote for selling a Policy NFT to the protocol
    /// @param nftTokenId The token ID of the Policy NFT
    /// @return luminaAmount Amount of LUMINA the seller would receive (18 dec)
    /// @return usdValue The discounted USD value (6 dec)
    /// @return discountBps The discount applied in basis points
    function getQuotePolicy(uint256 nftTokenId)
        external
        view
        returns (uint256 luminaAmount, uint256 usdValue, uint256 discountBps)
    {
        bytes32 productId = policyNFT.getProductId(nftTokenId);
        discountBps = policyDiscountBps[productId];
        require(discountBps > 0, "No discount set for product");

        uint256 remainingUsd = _getPolicyRemainingValue(nftTokenId);
        usdValue = remainingUsd * (10_000 - discountBps) / 10_000;
        luminaAmount = priceOracle.usdToLumina(usdValue);
    }

    // ═══════ Seller Functions ═══════

    /// @notice Sell a VaultShare NFT to the protocol for instant LUMINA
    /// @param nftTokenId The token ID of the VaultShare NFT to sell
    function sellVaultNFT(uint256 nftTokenId) external nonReentrant whenNotPaused {
        require(buyingVaults, "Vault buying disabled");

        address vault = vaultShareNFT.getVault(nftTokenId);
        uint256 discountBps = vaultDiscountBps[vault];
        require(discountBps > 0, "No discount set for vault");

        uint256 fullValue = vaultShareNFT.getValue(nftTokenId);
        uint256 usdValue = fullValue * (10_000 - discountBps) / 10_000;

        _checkAndResetDaily();
        require(dailySpentUsd + usdValue <= dailyBudgetUsd, "Daily budget exceeded");
        dailySpentUsd += usdValue;

        uint256 luminaAmount = priceOracle.usdToLumina(usdValue);
        require(luminaAmount > 0, "Quote is zero");
        require(luminaToken.balanceOf(address(this)) >= luminaAmount, "Insufficient LUMINA balance");

        // Transfer NFT from seller to this contract
        vaultShareNFT.transferFrom(msg.sender, address(this), nftTokenId);

        // Pay seller in LUMINA
        luminaToken.safeTransfer(msg.sender, luminaAmount);

        emit VaultNFTSold(msg.sender, nftTokenId, luminaAmount, usdValue, discountBps);
    }

    /// @notice Sell a Policy NFT to the protocol for instant LUMINA
    /// @param nftTokenId The token ID of the Policy NFT to sell
    function sellPolicyNFT(uint256 nftTokenId) external nonReentrant whenNotPaused {
        require(buyingPolicies, "Policy buying disabled");

        bytes32 productId = policyNFT.getProductId(nftTokenId);
        uint256 discountBps = policyDiscountBps[productId];
        require(discountBps > 0, "No discount set for product");

        uint256 remainingUsd = _getPolicyRemainingValue(nftTokenId);
        require(remainingUsd > 0, "Policy has no remaining value");
        uint256 usdValue = remainingUsd * (10_000 - discountBps) / 10_000;

        _checkAndResetDaily();
        require(dailySpentUsd + usdValue <= dailyBudgetUsd, "Daily budget exceeded");
        dailySpentUsd += usdValue;

        uint256 luminaAmount = priceOracle.usdToLumina(usdValue);
        require(luminaAmount > 0, "Quote is zero");
        require(luminaToken.balanceOf(address(this)) >= luminaAmount, "Insufficient LUMINA balance");

        // Transfer NFT from seller to this contract
        policyNFT.transferFrom(msg.sender, address(this), nftTokenId);

        // Pay seller in LUMINA
        luminaToken.safeTransfer(msg.sender, luminaAmount);

        emit PolicyNFTSold(msg.sender, nftTokenId, luminaAmount, usdValue, discountBps);
    }

    // ═══════ Internal Functions ═══════

    /// @dev Resets daily spending counter if a new UTC day has started
    function _checkAndResetDaily() internal {
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > lastResetDay) {
            dailySpentUsd = 0;
            lastResetDay = currentDay;
        }
    }

    /// @dev Calculates remaining value of a policy: premium * timeRemaining / totalDuration
    function _getPolicyRemainingValue(uint256 nftTokenId) internal view returns (uint256) {
        uint256 premium = policyNFT.getPremium(nftTokenId);
        uint256 startTime = policyNFT.getStartTime(nftTokenId);
        uint256 endTime = policyNFT.getEndTime(nftTokenId);

        require(endTime > startTime, "Invalid policy duration");
        if (block.timestamp >= endTime) return 0;

        uint256 totalDuration = endTime - startTime;
        uint256 timeRemaining = endTime - block.timestamp;

        return premium * timeRemaining / totalDuration;
    }
}
