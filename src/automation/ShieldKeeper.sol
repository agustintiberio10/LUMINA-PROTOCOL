// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title AutomationCompatibleInterface
 * @notice Chainlink Automation interface (defined inline to avoid external dependency).
 */
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

interface IShieldSettleable {
    function checkAndSettlePolicy(uint256 policyId) external;
    // [INFO-2 fix] Removed unused `getPolicyStatus(uint256)` declaration: it was never
    // called by the keeper and is unrelated to IShield.getPolicyStatus (different return type).
}

interface IPolicyManagerKeeper {
    function getActivePolicyIds(bytes32 productId, uint256 maxResults) external view returns (uint256[] memory);
    function productShield(bytes32 productId) external view returns (address);
    function getProductCount() external view returns (uint256);
    function productIds(uint256 index) external view returns (bytes32);
}

/**
 * @title ShieldKeeper
 * @author Lumina Protocol
 * @notice Chainlink Automation-compatible keeper that settles expired policies.
 * @dev [V5.1] UUPS upgradeable proxy pattern.
 */
contract ShieldKeeper is Initializable, UUPSUpgradeable, AutomationCompatibleInterface, OwnableUpgradeable {
    // ═══════ CONSTANTS ═══════
    uint256 public constant MAX_POLICIES_PER_UPKEEP = 10;

    // ═══════ STATE ═══════
    IPolicyManagerKeeper public policyManager;
    bool public paused;

    // ═══════ EVENTS ═══════
    event PolicySettled(bytes32 indexed productId, uint256 indexed policyId, address shield);
    event SettlementFailed(bytes32 indexed productId, uint256 indexed policyId, bytes reason);
    event KeeperPaused(address indexed by);
    event KeeperUnpaused(address indexed by);

    // ═══════ ERRORS ═══════
    error KeeperPausedError();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _policyManager) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_policyManager != address(0), "Zero policyManager");
        policyManager = IPolicyManagerKeeper(_policyManager);
    }

    // ═══════ ADMIN ═══════

    function pause() external onlyOwner {
        paused = true;
        emit KeeperPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit KeeperUnpaused(msg.sender);
    }

    // ═══════ CHAINLINK AUTOMATION ═══════

    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (paused) return (false, "");

        if (checkData.length >= 32) {
            bytes32 productId = abi.decode(checkData, (bytes32));
            uint256[] memory ids = policyManager.getActivePolicyIds(productId, MAX_POLICIES_PER_UPKEEP);
            if (ids.length > 0) {
                return (true, abi.encode(productId, ids));
            }
            return (false, "");
        }

        uint256 productCount = policyManager.getProductCount();
        for (uint256 i = 0; i < productCount; i++) {
            bytes32 productId = policyManager.productIds(i);
            uint256[] memory ids = policyManager.getActivePolicyIds(productId, MAX_POLICIES_PER_UPKEEP);
            if (ids.length > 0) {
                return (true, abi.encode(productId, ids));
            }
        }

        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override {
        if (paused) revert KeeperPausedError();

        (bytes32 productId, uint256[] memory policyIds) = abi.decode(performData, (bytes32, uint256[]));

        address shield = policyManager.productShield(productId);
        require(shield != address(0), "Invalid product");

        uint256 limit = policyIds.length > MAX_POLICIES_PER_UPKEEP ? MAX_POLICIES_PER_UPKEEP : policyIds.length;

        for (uint256 i = 0; i < limit; i++) {
            try IShieldSettleable(shield).checkAndSettlePolicy(policyIds[i]) {
                emit PolicySettled(productId, policyIds[i], shield);
            } catch (bytes memory reason) {
                emit SettlementFailed(productId, policyIds[i], reason);
            }
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
