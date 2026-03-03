// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AutoResolver
 * @author Lumina Protocol
 * @notice Chainlink Automation-compatible contract that auto-executes
 *         DisputeResolver proposals after the 24h dispute window closes.
 * @dev Register this contract as a Chainlink Automation upkeep.
 *      checkUpkeep() scans tracked pools for executable proposals.
 *      performUpkeep() calls DisputeResolver.executeResolution().
 */

interface IDisputeResolver {
    function isExecutable(uint256 _poolId) external view returns (bool);
    function executeResolution(uint256 _poolId) external;
    function getProposal(uint256 _poolId) external view returns (
        bool claimApproved,
        uint256 proposedAt,
        uint256 disputeDeadline,
        uint8 status,
        address disputer,
        string memory disputeReason
    );
}

interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

contract AutoResolver is AutomationCompatibleInterface, Ownable {
    IDisputeResolver public immutable disputeResolver;
    uint256 public maxStaleness;
    uint256 public lastPerformTime;

    // Pool tracking
    uint256[] public trackedPools;
    mapping(uint256 => bool) public isTracked;

    event PoolTracked(uint256 indexed poolId);
    event PoolUntracked(uint256 indexed poolId);
    event ResolutionAutoExecuted(uint256 indexed poolId, uint256 timestamp);
    event MaxStalenessUpdated(uint256 newMaxStaleness);

    constructor(address _disputeResolver, uint256 _maxStaleness) Ownable(msg.sender) {
        require(_disputeResolver != address(0), "AutoResolver: invalid disputeResolver");
        require(_maxStaleness > 0, "AutoResolver: invalid maxStaleness");
        disputeResolver = IDisputeResolver(_disputeResolver);
        maxStaleness = _maxStaleness;
        lastPerformTime = block.timestamp;
    }

    // ── Chainlink Automation ──

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            uint256 poolId = trackedPools[i];
            try disputeResolver.isExecutable(poolId) returns (bool executable) {
                if (executable) {
                    return (true, abi.encode(poolId));
                }
            } catch {}
        }
        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override {
        uint256 poolId = abi.decode(performData, (uint256));

        require(disputeResolver.isExecutable(poolId), "AutoResolver: not executable");

        disputeResolver.executeResolution(poolId);
        lastPerformTime = block.timestamp;

        // Remove from tracking after execution
        _untrack(poolId);

        emit ResolutionAutoExecuted(poolId, block.timestamp);
    }

    // ── Pool Management ──

    function trackPool(uint256 _poolId) external onlyOwner {
        require(!isTracked[_poolId], "AutoResolver: already tracked");
        trackedPools.push(_poolId);
        isTracked[_poolId] = true;
        emit PoolTracked(_poolId);
    }

    function trackPools(uint256[] calldata _poolIds) external onlyOwner {
        for (uint256 i = 0; i < _poolIds.length; i++) {
            if (!isTracked[_poolIds[i]]) {
                trackedPools.push(_poolIds[i]);
                isTracked[_poolIds[i]] = true;
                emit PoolTracked(_poolIds[i]);
            }
        }
    }

    function untrackPool(uint256 _poolId) external onlyOwner {
        _untrack(_poolId);
    }

    // ── Admin ──

    function setMaxStaleness(uint256 _maxStaleness) external onlyOwner {
        require(_maxStaleness > 0, "AutoResolver: invalid maxStaleness");
        maxStaleness = _maxStaleness;
        emit MaxStalenessUpdated(_maxStaleness);
    }

    // ── View ──

    function getTrackedPools() external view returns (uint256[] memory) {
        return trackedPools;
    }

    function trackedPoolCount() external view returns (uint256) {
        return trackedPools.length;
    }

    function isStale() external view returns (bool) {
        return block.timestamp > lastPerformTime + maxStaleness;
    }

    // ── Internal ──

    function _untrack(uint256 _poolId) internal {
        if (!isTracked[_poolId]) return;
        isTracked[_poolId] = false;
        for (uint256 i = 0; i < trackedPools.length; i++) {
            if (trackedPools[i] == _poolId) {
                trackedPools[i] = trackedPools[trackedPools.length - 1];
                trackedPools.pop();
                emit PoolUntracked(_poolId);
                break;
            }
        }
    }
}
