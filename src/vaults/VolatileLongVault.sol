// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "./BaseVault.sol";

/**
 * @title VolatileLongVault
 * @author Lumina Protocol
 * @notice 90-day cooldown vault for long-duration volatile products.
 *         Backs: IL Index 60-90d, BSS overflow from VolatileShort (via waterfall)
 *         APY estimate: ~12-14% at moderate utilization
 */
contract VolatileLongVault is BaseVault {
    function initialize(
        address owner_, address asset_, address router_, address policyManager_,
        address aavePool_, address aToken_
    ) external initializer {
        __BaseVault_init(owner_, asset_, "Lumina Volatile Long", "lvlUSDC", router_, policyManager_, 90 days, aavePool_, aToken_);
    }
}
