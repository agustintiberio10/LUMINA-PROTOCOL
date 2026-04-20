// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
    function getPolicyStatus(uint256 policyId) external view returns (uint8);
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
 *
 * FLOW:
 *   1. Chainlink node calls checkUpkeep() off-chain (view, no gas)
 *   2. If upkeepNeeded == true, node calls performUpkeep() on-chain
 *   3. performUpkeep calls shield.checkAndSettlePolicy(policyId) for each pending policy
 *
 * DESIGN:
 *   - checkUpkeep scans active policies across all registered products
 *   - MAX_POLICIES_PER_UPKEEP limits gas per performUpkeep call
 *   - Off-chain Chainlink node handles scheduling; on-chain is stateless
 *   - Owner can pause/unpause for emergencies
 *
 * @dev NOT upgradeable. Deploy new keeper if logic changes.
 */
contract ShieldKeeper is AutomationCompatibleInterface, Ownable {
    // ═══════ CONSTANTS ═══════

    /// @notice Maximum policies to settle in a single performUpkeep call.
    ///         Prevents gas limit issues on-chain.
    uint256 public constant MAX_POLICIES_PER_UPKEEP = 10;

    // ═══════ STATE ═══════

    /// @notice PolicyManagerV2 reference
    IPolicyManagerKeeper public immutable policyManager;

    /// @notice Emergency pause
    bool public paused;

    // ═══════ EVENTS ═══════

    event PolicySettled(bytes32 indexed productId, uint256 indexed policyId, address shield);
    event SettlementFailed(bytes32 indexed productId, uint256 indexed policyId, bytes reason);
    event KeeperPaused(address indexed by);
    event KeeperUnpaused(address indexed by);

    // ═══════ ERRORS ═══════

    error KeeperPausedError();

    constructor(address _policyManager) Ownable(msg.sender) {
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

    /// @notice Called off-chain by Chainlink node to determine if upkeep is needed.
    /// @param checkData Encoded (bytes32 productId) to scope the check to one product.
    ///        If empty, scans all products.
    /// @return upkeepNeeded True if there are policies to settle
    /// @return performData Encoded array of (bytes32 productId, uint256[] policyIds)
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (paused) return (false, "");

        if (checkData.length >= 32) {
            // Scoped to a single product
            bytes32 productId = abi.decode(checkData, (bytes32));
            uint256[] memory ids = policyManager.getActivePolicyIds(productId, MAX_POLICIES_PER_UPKEEP);
            if (ids.length > 0) {
                return (true, abi.encode(productId, ids));
            }
            return (false, "");
        }

        // Scan all products
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

    /// @notice Called on-chain by Chainlink node to settle policies.
    /// @param performData Encoded (bytes32 productId, uint256[] policyIds)
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
}
