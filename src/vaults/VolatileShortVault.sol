// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "./BaseVault.sol";

/**
 * @title VolatileShortVault
 * @author Lumina Protocol
 * @notice 30-day cooldown vault for short-duration volatile products.
 *         Backs: BSS 7-30d, IL Index 14-30d (via waterfall)
 *         APY estimate: ~9-11% at moderate utilization
 */
contract VolatileShortVault is BaseVault {
    function initialize(
        address owner_, address asset_, address router_, address policyManager_
    ) external initializer {
        __BaseVault_init(owner_, asset_, "Lumina Volatile Short", "lvsUSDY", router_, policyManager_, 30 days);
    }
}
