// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {
    ERC1155SupplyUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ClaimBond
/// @notice ERC-1155 bond tokens grouped by monthly maturity epoch.
/// @dev Each token represents $1 USD of claim at maturity.
///      Payout is FIXED IN USD — settled in $LUMINA at market price at redemption.
///      Token ID format: YYYYMM (e.g., 202804 = April 2028).
///      Only BondVault can mint and burn. Transferable by anyone (for marketplace).
///      Bonds mature 100% at maturity date — no linear vesting, no partial unlock.
///
///      [V5.1] UUPS upgradeable proxy pattern.
contract ClaimBond is Initializable, UUPSUpgradeable, ERC1155Upgradeable, ERC1155SupplyUpgradeable, OwnableUpgradeable {
    address public bondVault;
    bool private _bondVaultSet;

    mapping(uint256 => uint256) public maturityDate;
    mapping(uint256 => bool) public epochExists;

    // [FIX-#18] HTTPS metadata base + restricted-transfer whitelist.
    string private _baseURI; // slot 3 — was first slot of __gap[50]
    mapping(address => bool) public authorizedOperators; // slot 4 — was second slot of __gap[50]

    event EpochCreated(uint256 indexed epochId, uint256 maturityDate);
    event BondsMinted(uint256 indexed epochId, address indexed to, uint256 usdAmount);
    event BondsBurned(uint256 indexed epochId, address indexed from, uint256 usdAmount);
    event BondVaultSet(address vault);
    event BondsBurnedByHolder(address indexed holder, uint256 indexed epochId, uint256 amount);
    event BaseURIUpdated(string oldBaseURI, string newBaseURI);
    event OperatorAuthorized(address indexed operator, bool authorized);

    modifier onlyBondVault() {
        require(_bondVaultSet, "BondVault not set");
        require(msg.sender == bondVault, "Only BondVault");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __ERC1155_init("");
        __ERC1155Supply_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        // [FIX-#18] Default HTTPS metadata base. Admin can rotate via setBaseURI.
        _baseURI = "https://api.lumina-org.com/metadata/bond/";
    }

    /// @notice [FIX-#18] One-shot reinitializer for proxies upgraded from a
    ///         pre-fix implementation. Seeds `_baseURI` to the canonical default.
    ///         Use `version = 2` for the initial post-fix upgrade.
    function reinitializeURI(uint64 version) external reinitializer(version) {
        _baseURI = "https://api.lumina-org.com/metadata/bond/";
    }

    /// @notice Set BondVault address ONCE. Resolves circular dependency.
    /// @dev [V1/SR2] onlyOwner: prevents deployment-frontrun attacks where a mempool
    ///      observer could hijack the one-shot setter and permanently brick all mint/burn.
    function setBondVault(address _bondVault) external onlyOwner {
        require(!_bondVaultSet, "Already set");
        require(_bondVault != address(0), "Zero address");
        bondVault = _bondVault;
        _bondVaultSet = true;
        emit BondVaultSet(_bondVault);
    }

    /// @notice Mint bond tokens to user when a policy triggers.
    /// @param to Recipient
    /// @param epochId Maturity epoch (YYYYMM)
    /// @param usdAmount Payout in USD (1 token = $1). E.g. $800 payout = 800 tokens.
    function mint(address to, uint256 epochId, uint256 usdAmount) external onlyBondVault {
        require(to != address(0), "Zero address");
        require(usdAmount > 0, "Zero amount");
        require(epochId >= 202600 && epochId <= 210012, "Invalid epoch");

        uint256 month = epochId % 100;
        require(month >= 1 && month <= 12, "Invalid month");

        if (!epochExists[epochId]) {
            uint256 year = epochId / 100;
            maturityDate[epochId] = _timestampFromYearMonth(year, month);
            epochExists[epochId] = true;
            emit EpochCreated(epochId, maturityDate[epochId]);
        }

        _mint(to, epochId, usdAmount, "");
        emit BondsMinted(epochId, to, usdAmount);
    }

    /// @notice Burn bond tokens on redemption. Represents the claimed ticket being voided.
    function burn(address from, uint256 epochId, uint256 usdAmount) external onlyBondVault {
        _burn(from, epochId, usdAmount);
        emit BondsBurned(epochId, from, usdAmount);
    }

    /// @notice [V5.0] Public burn for holders (for BuybackEngine double-burn).
    /// @param account Holder address
    /// @param epochId Epoch ID
    /// @param amount Amount to burn
    function burnByHolder(address account, uint256 epochId, uint256 amount) external {
        require(msg.sender == account || isApprovedForAll(account, msg.sender), "Not holder or approved");
        require(balanceOf(account, epochId) >= amount, "Insufficient balance");
        _burn(account, epochId, amount);
        emit BondsBurnedByHolder(account, epochId, amount);
    }

    /// @notice Face value per token (1 token = $1 USD)
    function getFaceValue(uint256 epochId) external view returns (uint256) {
        require(epochExists[epochId], "Epoch does not exist");
        return 1e18; // 1 token = $1 USD in 18-dec
    }

    /// @notice Total face value of a holder's bonds in an epoch
    function getHolderFaceValue(address holder, uint256 epochId) external view returns (uint256) {
        return balanceOf(holder, epochId) * 1e18;
    }

    function isMatured(uint256 epochId) external view returns (bool) {
        if (!epochExists[epochId]) return false;
        return block.timestamp >= maturityDate[epochId];
    }

    function getEpochInfo(uint256 epochId)
        external
        view
        returns (bool exists, uint256 maturity, uint256 totalSupply_, bool matured)
    {
        exists = epochExists[epochId];
        maturity = maturityDate[epochId];
        totalSupply_ = totalSupply(epochId);
        matured = exists && block.timestamp >= maturityDate[epochId];
    }

    /// @notice [FIX-#18] HTTPS metadata URI: `<baseURI><epoch>.json`.
    ///         Was previously `lumina://claimbond/<epoch>` (non-resolvable).
    function uri(uint256 epochId) public view override returns (string memory) {
        return string(abi.encodePacked(_baseURI, _epochToString(epochId), ".json"));
    }

    /// @notice Collection name for marketplaces / wallets / explorers.
    function name() external pure returns (string memory) {
        return "LUMINA Bonds";
    }

    /// @notice Collection symbol for marketplaces / wallets / explorers.
    function symbol() external pure returns (string memory) {
        return "LBOND";
    }

    /// @notice [FIX-#18] Admin: rotate the metadata base URI. Emits ERC-1155
    ///         `URI(newuri, 0)` so indexers refresh the whole collection.
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        string memory old = _baseURI;
        _baseURI = newBaseURI;
        emit BaseURIUpdated(old, newBaseURI);
        emit URI(uri(0), 0);
    }

    /// @notice [FIX-#18] Admin: whitelist a contract to perform ERC-1155
    ///         transfers between non-zero parties. Marketplace + BuybackEngine
    ///         must be whitelisted post-deploy.
    function setAuthorizedOperator(address operator, bool authorized) external onlyOwner {
        require(operator != address(0), "ClaimBond: zero address");
        authorizedOperators[operator] = authorized;
        emit OperatorAuthorized(operator, authorized);
    }

    // ═══════ INTERNAL HELPERS ═══════

    function _timestampFromYearMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        require(year >= 2026 && year <= 2100, "Year out of range");
        uint256 BASE_TIMESTAMP = 1767225600; // Jan 1 2026 UTC
        uint256 monthsFromBase = (year - 2026) * 12 + (month - 1);
        return BASE_TIMESTAMP + (monthsFromBase * 2629746); // avg seconds per month
    }

    function _epochToString(uint256 epochId) internal pure returns (string memory) {
        bytes memory b = new bytes(6);
        for (uint256 i = 6; i > 0; i--) {
            b[i - 1] = bytes1(uint8(48 + epochId % 10));
            epochId /= 10;
        }
        return string(b);
    }

    /// @notice [FIX-#18] Restricted-transfer override: bonds may move only via
    ///         mint (`from == 0`), burn (`to == 0`), or an authorised operator.
    ///         Direct user-to-user transfers are blocked so the protocol
    ///         captures all secondary-market fees through its own marketplace.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155Upgradeable, ERC1155SupplyUpgradeable)
    {
        if (from != address(0) && to != address(0)) {
            require(
                authorizedOperators[msg.sender] || authorizedOperators[from],
                "ClaimBond: transfers only via authorized operators"
            );
        }
        super._update(from, to, ids, values);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Storage gap for future upgrades — reduced from 50 to 48 by FIX-#18
    // (added _baseURI + authorizedOperators above).
    uint256[48] private __gap;
}
