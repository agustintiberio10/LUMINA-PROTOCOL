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

interface IBuybackClaimBond {
    function getFaceValue(uint256 epochId) external view returns (uint256);
    function burnByHolder(address account, uint256 epochId, uint256 amount) external;
}

interface IBuybackBondVault {
    function decreaseObligations(uint256 amount) external;
    function burnFromReserves(uint256 amount) external;
}

interface IBuybackSolvencyOracle {
    function getSolvencyRatio() external view returns (uint256);
}

interface IBuybackCapacityOracle {
    function getLuminaPrice() external view returns (uint256);
}

interface IBuybackMarketplace {
    function executeBuy(uint256 listingId) external;
    function getListing(uint256 listingId)
        external
        view
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active);

    // [M-03 fix] Needed so executeOffer approves priceUSDC + buyerFee.
    function BUYER_FEE_BPS() external view returns (uint256);
    function BPS_DENOMINATOR() external view returns (uint256);
}

/// @title BuybackEngine
/// @notice Buys ClaimBonds from marketplace + executes Double Burn.
/// @dev [V5.1] UUPS upgradeable proxy pattern.
contract BuybackEngine is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC1155HolderUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant BUYBACK_OPERATOR_ROLE = keccak256("BUYBACK_OPERATOR_ROLE");

    // ═══════ M-10 COMMIT-REVEAL CONSTANTS ═══════

    /// @notice [Fix M-10] Minimum block delay between `commitBuyback` and
    ///         `revealAndExecute`. ~3 minutes on Base (2s blocks). The
    ///         commitment is opaque to mempool watchers, so MEV bots
    ///         cannot front-run the buyback strategy during this window.
    uint256 public constant MIN_REVEAL_DELAY_BLOCKS = 100;

    /// @notice [Fix M-10] Maximum block age before a commitment expires.
    ///         ~30 minutes on Base. After this window, the operator must
    ///         re-commit (or the multisig may `cancelCommitment` for
    ///         storage hygiene).
    uint256 public constant MAX_REVEAL_WINDOW_BLOCKS = 600;

    IBuybackClaimBond public claimBond;
    IBuybackBondVault public bondVault;
    IBuybackSolvencyOracle public solvencyOracle;
    IBuybackCapacityOracle public capacityOracle;
    IBuybackMarketplace public marketplace;
    IERC20 public usdc;

    uint256 public constant MIN_SOLVENCY_FOR_DOUBLE_BURN = 15000; // 150%

    struct DailyConfig {
        uint256 dailyBudget;
        uint256 maxPricePercent;
        uint256 validUntil;
        uint256 spentToday;
    }

    DailyConfig public dailyConfig;

    /// @notice [Fix M-7] Registry consulted by `revealAndExecute` and
    ///         `setDailyBuyback`. When `address(0)`, global-pause check
    ///         is skipped (legacy/uninitialized state).
    IGlobalPauseRegistry public globalPauseRegistry;

    /// @notice [Fix M-10] Commit-reveal scheme: maps `keccak256(abi.encode(
    ///         listingId, maxPrice, salt))` to the block at which the
    ///         operator committed. Zero means "no commitment". Reveal
    ///         clears the entry (replay-burn).
    mapping(bytes32 => uint256) public commitmentBlock;

    event DailyBuybackConfigured(uint256 budget, uint256 maxPercent, uint256 durationHours);
    event OfferExecuted(uint256 indexed listingId, uint256 epochId, uint256 amount, uint256 priceUSDC);
    event DoubleBurnExecuted(uint256 epochId, uint256 obligationsReduced, uint256 luminaBurned);
    event CircuitBreakerTriggered(uint256 currentSolvency, uint256 threshold);
    /// @notice [LOW-2 fix] Emitted on successful non-core token rescue.
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);
    /// @notice [Fix M-7] Emitted when the global pause registry is wired or rewired.
    event GlobalPauseRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    /// @notice [Fix M-10] Emitted on `commitBuyback`. The commitment payload
    ///         is opaque on-chain — only the operator (who knows the salt)
    ///         can later reveal it.
    event BuybackCommitted(bytes32 indexed commitment, uint256 blockNumber, address indexed operator);
    /// @notice [Fix M-10] Emitted on successful `revealAndExecute`.
    event BuybackRevealed(uint256 indexed listingId, uint256 actualPrice, address indexed operator);
    /// @notice [Fix M-10] Emitted on admin `cancelCommitment` for stuck or
    ///         operationally-cancelled commitments.
    event BuybackCancelled(bytes32 indexed commitment, address indexed admin, string reason);

    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();

    /// @notice [Fix M-7] Thrown by `setDailyBuyback` and `revealAndExecute`
    ///         when the global pause registry reports paused.
    error GloballyPaused();

    /// @dev [Fix M-7] Reverts if the registry says paused. No-op when
    ///      `globalPauseRegistry == address(0)`.
    function _enforceNotGloballyPaused() internal view {
        IGlobalPauseRegistry reg = globalPauseRegistry;
        if (address(reg) != address(0) && reg.isGloballyPaused()) revert GloballyPaused();
    }

    // ═══════ ERRORS (M-10 commit-reveal) ═══════
    /// @notice Thrown when committing the same commitment twice without
    ///         a reveal or cancel in between.
    error CommitmentExists(bytes32 commitment);
    /// @notice Thrown when revealing or cancelling a commitment that was
    ///         never committed (or was already revealed/cancelled).
    error CommitmentNotFound(bytes32 commitment);
    /// @notice Thrown when `revealAndExecute` is called before
    ///         `MIN_REVEAL_DELAY_BLOCKS` blocks have passed since commit.
    error RevealTooEarly(uint256 currentBlock, uint256 readyAtBlock);
    /// @notice Thrown when `revealAndExecute` is called after the
    ///         `MAX_REVEAL_WINDOW_BLOCKS` window has elapsed.
    error RevealTooLate(uint256 currentBlock, uint256 expiredAtBlock);
    /// @notice Thrown when the supplied `(listingId, maxPrice, salt)` does
    ///         not hash to the stored commitment.
    error CommitmentMismatch();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _claimBond,
        address _bondVault,
        address _solvencyOracle,
        address _capacityOracle,
        address _marketplace,
        address _usdc,
        address _multisigOwner
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __ERC1155Holder_init();
        __UUPSUpgradeable_init();

        require(_claimBond != address(0) && _bondVault != address(0) && _solvencyOracle != address(0), "Zero addr core");
        require(
            _capacityOracle != address(0) && _marketplace != address(0) && _usdc != address(0)
                && _multisigOwner != address(0),
            "Zero addr ext"
        );

        claimBond = IBuybackClaimBond(_claimBond);
        bondVault = IBuybackBondVault(_bondVault);
        solvencyOracle = IBuybackSolvencyOracle(_solvencyOracle);
        capacityOracle = IBuybackCapacityOracle(_capacityOracle);
        marketplace = IBuybackMarketplace(_marketplace);
        usdc = IERC20(_usdc);

        _grantRole(DEFAULT_ADMIN_ROLE, _multisigOwner);
        _grantRole(BUYBACK_OPERATOR_ROLE, _multisigOwner);
    }

    function setDailyBuyback(uint256 _budget, uint256 _maxPricePercent, uint256 _durationHours)
        external
        onlyRole(BUYBACK_OPERATOR_ROLE)
    {
        // [Fix M-7] Block scheduling new buyback windows during a global
        // pause. Existing in-flight schedules naturally stop being callable
        // once `executeOffer` rejects.
        _enforceNotGloballyPaused();
        require(_budget > 0, "Budget zero");
        require(_maxPricePercent > 0 && _maxPricePercent <= 95, "Max percent 1-95");
        require(_durationHours > 0 && _durationHours <= 72, "Duration 1-72 hours");

        dailyConfig = DailyConfig({
            dailyBudget: _budget,
            maxPricePercent: _maxPricePercent,
            validUntil: block.timestamp + (_durationHours * 1 hours),
            spentToday: 0
        });

        emit DailyBuybackConfigured(_budget, _maxPricePercent, _durationHours);
    }

    /// @notice [Fix M-10] Phase 1 of the commit-reveal flow. Operator
    ///         publishes an opaque commitment representing their intent
    ///         to buy a specific listing at a chosen max price. The
    ///         actual `(listingId, maxPrice, salt)` is hidden from
    ///         mempool watchers until reveal time.
    /// @param  commitment `keccak256(abi.encode(listingId, maxPrice, salt))`
    /// @dev    The salt SHOULD be a fresh random 256-bit value per
    ///         commitment so a leaked `(listingId, maxPrice)` pair
    ///         cannot be brute-forced.
    function commitBuyback(bytes32 commitment) external onlyRole(BUYBACK_OPERATOR_ROLE) {
        if (commitmentBlock[commitment] != 0) revert CommitmentExists(commitment);
        commitmentBlock[commitment] = block.number;
        emit BuybackCommitted(commitment, block.number, msg.sender);
    }

    /// @notice [Fix M-10] Phase 2 of the commit-reveal flow. Operator
    ///         reveals the pre-image and executes the marketplace buy
    ///         atomically. Only callable between
    ///         `MIN_REVEAL_DELAY_BLOCKS` and `MAX_REVEAL_WINDOW_BLOCKS`
    ///         after the matching commit.
    /// @dev    Edge cases revert gracefully (listing cancelled, listing
    ///         bought by another, listing price > maxPrice). The
    ///         commitment is burned BEFORE the external call (CEI +
    ///         replay-prevention).
    /// @dev    Operations note: for full MEV resistance, the reveal
    ///         tx SHOULD be submitted via a private mempool (Flashbots
    ///         / MEV-Share / a private builder relationship). The
    ///         100-block delay guarantees the strategy is hidden between
    ///         commit and reveal; the reveal itself is a public tx.
    function revealAndExecute(uint256 listingId, uint256 maxPrice, bytes32 salt)
        external
        nonReentrant
        onlyRole(BUYBACK_OPERATOR_ROLE)
    {
        bytes32 commitment = keccak256(abi.encode(listingId, maxPrice, salt));
        uint256 committedAt = commitmentBlock[commitment];
        if (committedAt == 0) revert CommitmentNotFound(commitment);

        uint256 readyAt = committedAt + MIN_REVEAL_DELAY_BLOCKS;
        uint256 expiresAt = committedAt + MAX_REVEAL_WINDOW_BLOCKS;
        if (block.number < readyAt) revert RevealTooEarly(block.number, readyAt);
        if (block.number > expiresAt) revert RevealTooLate(block.number, expiresAt);

        // CEI + replay-burn: clear the commitment BEFORE any external call.
        delete commitmentBlock[commitment];

        _executeBuyback(listingId, maxPrice);
        emit BuybackRevealed(listingId, _readListingPrice(listingId), msg.sender);
    }

    /// @notice [Fix M-10] Admin escape hatch: invalidate a stuck or
    ///         operationally-cancelled commitment so it can be re-issued
    ///         (or simply cleared from storage).
    function cancelCommitment(bytes32 commitment, string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (commitmentBlock[commitment] == 0) revert CommitmentNotFound(commitment);
        delete commitmentBlock[commitment];
        emit BuybackCancelled(commitment, msg.sender, reason);
    }

    /// @dev [Merge consolidation: M-10 + M-7] Body of the legacy
    ///      `executeOffer` — now only callable internally from
    ///      `revealAndExecute`. The public 1-step path was removed (M-10)
    ///      because it leaked the operator's strategy to the mempool.
    ///      M-7's global-pause check is hoisted into this internal
    ///      function so the commit-reveal flow ALSO honors the kill
    ///      switch.
    /// @param maxPriceUSDC Operator-declared upper bound on the
    ///        listing's USDC price. If the on-chain listing now costs
    ///        more (e.g. price was changed by the seller — currently
    ///        impossible but defensive against future Marketplace
    ///        changes), the call reverts gracefully.
    function _executeBuyback(uint256 listingId, uint256 maxPriceUSDC) internal {
        // [Fix M-7] Block buyback execution during a global pause.
        _enforceNotGloballyPaused();
        require(block.timestamp <= dailyConfig.validUntil, "Daily offer expired");

        (, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active) = marketplace.getListing(listingId);
        require(active, "Listing not active");
        require(amount > 0, "Amount zero");
        require(priceUSDC <= maxPriceUSDC, "Listing price exceeds max");

        uint256 faceValueUSD = claimBond.getFaceValue(epochId) * amount;
        uint256 maxAllowedPriceUSDC = (faceValueUSD * dailyConfig.maxPricePercent) / (100 * 1e12);
        require(priceUSDC <= maxAllowedPriceUSDC, "Price exceeds max");

        // [M-03 fix] Marketplace.executeBuy pulls priceUSDC + buyerFee from
        // this engine. Approve the total AND count the total against the
        // daily budget — anything less reverts at the marketplace transfer.
        uint256 buyerFee = (priceUSDC * marketplace.BUYER_FEE_BPS()) / marketplace.BPS_DENOMINATOR();
        uint256 totalRequired = priceUSDC + buyerFee;
        require(dailyConfig.spentToday + totalRequired <= dailyConfig.dailyBudget, "Daily budget exceeded");

        // CEI: update state before external call.
        dailyConfig.spentToday += totalRequired;

        usdc.forceApprove(address(marketplace), totalRequired);
        marketplace.executeBuy(listingId);
        // Defensive reset — should already be zero after the marketplace
        // drained the approval, but keep it explicit.
        usdc.forceApprove(address(marketplace), 0);

        _executeDoubleBurn(epochId, amount, faceValueUSD);
        emit OfferExecuted(listingId, epochId, amount, priceUSDC);
    }

    /// @dev Helper for the `BuybackRevealed` event — read the listing
    ///      price one more time after the buy. Returns 0 if the listing
    ///      has been cleared (which is normal after `executeBuy`).
    function _readListingPrice(uint256 listingId) internal view returns (uint256 priceUSDC) {
        (,,, priceUSDC,) = marketplace.getListing(listingId);
    }

    function _executeDoubleBurn(uint256 epochId, uint256 amount, uint256 faceValueUSD) internal {
        claimBond.burnByHolder(address(this), epochId, amount);
        bondVault.decreaseObligations(faceValueUSD);

        uint256 currentSolvency = solvencyOracle.getSolvencyRatio();
        if (currentSolvency >= MIN_SOLVENCY_FOR_DOUBLE_BURN) {
            uint256 spotPrice = capacityOracle.getLuminaPrice();
            if (spotPrice > 0) {
                uint256 luminaToBurn = (faceValueUSD * 1e18) / spotPrice;
                bondVault.burnFromReserves(luminaToBurn);
                emit DoubleBurnExecuted(epochId, faceValueUSD, luminaToBurn);
                return;
            }
        }

        emit CircuitBreakerTriggered(currentSolvency, MIN_SOLVENCY_FOR_DOUBLE_BURN);
        emit DoubleBurnExecuted(epochId, faceValueUSD, 0);
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

    /// @notice Recover non-core ERC-20 tokens sent here by mistake.
    /// @dev    USDC (budget) and ClaimBond are protected.
    /// @notice [Fix M-7] Wire (or re-wire) the global pause registry.
    ///         Passing `address(0)` opts out of the global pause. Only
    ///         `DEFAULT_ADMIN_ROLE` (= multisig) can call.
    function setGlobalPauseRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = address(globalPauseRegistry);
        globalPauseRegistry = IGlobalPauseRegistry(_registry);
        emit GlobalPauseRegistryUpdated(old, _registry);
    }

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

    /// @notice Recover non-core ERC-1155 tokens sent here by mistake.
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
    // [Merge consolidation] M-7 (`globalPauseRegistry`) and M-10
    // (`commitmentBlock` mapping) each consume 1 slot of the original
    // `__gap[50]`. Net `__gap[48]`. UUPS-safe append.
    uint256[48] private __gap;
}
