// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ClaimBond
/// @notice ERC-1155 bond tokens grouped by monthly maturity epoch.
/// @dev Each token represents $1 USD of claim at maturity.
///      Payout is FIXED IN USD — settled in $LUMINA at market price at redemption.
///      Token ID format: YYYYMM (e.g., 202804 = April 2028).
///      Only BondVault can mint and burn. Transferable by anyone (for marketplace).
///      Bonds mature 100% at maturity date — no linear vesting, no partial unlock.
contract ClaimBond is ERC1155, ERC1155Supply, Ownable {
    address public bondVault;
    bool private _bondVaultSet;

    mapping(uint256 => uint256) public maturityDate;
    mapping(uint256 => bool) public epochExists;

    event EpochCreated(uint256 indexed epochId, uint256 maturityDate);
    event BondsMinted(uint256 indexed epochId, address indexed to, uint256 usdAmount);
    event BondsBurned(uint256 indexed epochId, address indexed from, uint256 usdAmount);
    event BondVaultSet(address vault);

    modifier onlyBondVault() {
        require(_bondVaultSet, "BondVault not set");
        require(msg.sender == bondVault, "Only BondVault");
        _;
    }

    constructor() ERC1155("") Ownable(msg.sender) {}

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

    event BondsBurnedByHolder(address indexed holder, uint256 indexed epochId, uint256 amount);

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

    function uri(uint256 epochId) public pure override returns (string memory) {
        return string(abi.encodePacked("lumina://claimbond/", _epochToString(epochId)));
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

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from, to, ids, values);
    }
}
