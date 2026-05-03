// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IV51
/// @notice Minimal interfaces for the V5.1 contracts (Sepolia deploy) used
///         by audit-e2e fork tests. Hand-curated to keep the test surface
///         compact and to avoid pulling the full src/ tree into the test
///         compilation graph (which is what tripped up forge build before).

interface IBondVaultV51 {
    function previewRedemption(uint256 usdAmount) external view returns (uint256);
    function redeemBond(uint256 epochId, uint256 usdAmount) external;
    function issueBond(address to, uint256 usdPayout, uint256 priceSnapshot) external;
    function availableCapacityUSD() external view returns (uint256);
    function getStatus()
        external
        view
        returns (uint256 reserveBalance, uint256 reserveValueUSD, uint256 committed, uint256 availableUSD, uint256 currentPrice);
    function priceOracle() external view returns (address);
    function commitReservation(uint256 amount) external;
    function reserveCapacity(uint256 amount) external;
    function burnFromReserves(uint256 amount) external;
    function MIN_REDEEM_PRICE() external view returns (uint256);
    function MAX_REDEEM_PRICE() external view returns (uint256);
    function SOLVENCY_BURN_FLOOR_BPS() external view returns (uint256);
    function BOND_MATURITY_SECONDS() external view returns (uint256);
}

interface IClaimBondV51 {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function getEpochInfo(uint256 epochId)
        external
        view
        returns (bool exists, uint256 maturity, uint256 totalSupply_, bool matured);
    function maturityDate(uint256 epochId) external view returns (uint256);
    function getHolderFaceValue(address holder, uint256 epochId) external view returns (uint256);
    function isMatured(uint256 epochId) external view returns (bool);
    function escapeTransfer(address from, uint256 epochId, uint256 amount) external;
    function marketplaceEscape() external view returns (address);
    function setMarketplaceEscape(address _newEscape) external;
}

interface IPolicyManagerV51 {
    function policies(bytes32 productId, uint256 policyId)
        external
        view
        returns (
            bytes32 productId_,
            address shield,
            address buyer,
            uint256 coverageAmount,
            uint256 payoutAmount,
            uint256 premiumPaid,
            uint256 createdAt,
            uint256 expiresAt,
            bool triggered,
            bool expired
        );
    function policyPriceSnapshot(bytes32 productId, uint256 policyId) external view returns (uint256);
    function productActive(bytes32 productId) external view returns (bool);
    function productShield(bytes32 productId) external view returns (address);
    function deactivateProduct(bytes32 productId) external;
    function reactivateProduct(bytes32 productId) external;
}

interface ICoverRouterV51 {
    function paused() external view returns (bool);
    function globalPauseRegistry() external view returns (address);
    function authorizedRelayers(address relayer) external view returns (bool);
    function purchasePolicy(bytes32 productId, uint256 coverageAmount, bytes32 asset) external returns (uint256);
    function purchasePolicyFor(bytes32 productId, uint256 coverageAmount, bytes32 asset, address buyer)
        external
        returns (uint256);
    function submitTrigger(bytes32 productId, uint256 policyId, bytes calldata oracleProof) external;
    function setRelayer(address relayer, bool authorized) external;
    function setPaused(bool _paused) external;
    function setGlobalPauseRegistry(address _registry) external;
    function quotePremium(bytes32 productId, uint256 coverageAmount) external view returns (uint256, uint256);
    function getProductCount() external view returns (uint256);
    function products(bytes32 productId)
        external
        view
        returns (bytes32, uint256, uint256, uint256, uint32, bool);
}

interface IMarketplaceV51 {
    function list(uint256 epochId, uint256 amount, uint256 priceUSDC) external returns (uint256);
    function executeBuy(uint256 listingId) external;
    function cancel(uint256 listingId) external;
    function emergencyCancel(uint256 listingId) external;
    function getListing(uint256 listingId)
        external
        view
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active);
    function listings(uint256 listingId)
        external
        view
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active, uint256 listedAt);
    function nextListingId() external view returns (uint256);
    function minPricePerUnit() external view returns (uint256);
    function setMinPricePerUnit(uint256) external;
    function MIN_PRICE_PER_UNIT_CAP() external view returns (uint256);
    function DEFAULT_MIN_PRICE_PER_UNIT() external view returns (uint256);
    function calculateFees(uint256 priceUSDC) external view returns (uint256, uint256, uint256);
    function globalPauseRegistry() external view returns (address);
    function setGlobalPauseRegistry(address _registry) external;
}

interface ILuminaTokenV51 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IShieldV51 {
    enum PolicyStatus {
        NONEXISTENT, WAITING, ACTIVE, EXPIRED, SETTLEMENT, PAID_OUT, CANCELLED
    }
    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (
            uint256 policyId_,
            address insuredAgent,
            uint256 coverageAmount,
            uint256 premiumPaid,
            uint256 maxPayout,
            uint256 startTimestamp,
            uint256 waitingEndsAt,
            uint256 expiresAt,
            uint256 cleanupAt,
            PolicyStatus status
        );
    function getPolicyStatus(uint256 policyId) external view returns (PolicyStatus);
    function productId() external view returns (bytes32);
    function waitingPeriod() external view returns (uint32);
    function checkAndSettlePolicy(uint256 policyId) external;
}

interface IGlobalPauseRegistryV51 {
    function isGloballyPaused() external view returns (bool);
    function setGlobalPaused(bool) external;
}

interface IUSDCMockV51 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}
