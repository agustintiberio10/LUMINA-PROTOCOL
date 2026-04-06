// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "./BaseVault.sol";

/**
 * @title VolatileShortVault
 * @author Lumina Protocol
 * @notice 37-day cooldown vault for short-duration volatile products.
 *         Backs: BSS 7-30d, IL Index 14-30d (via waterfall)
 *         Cooldown = 30d max policy + 7d safety buffer (actuarial recommendation)
 *         APY range: ~3.3-22.2% (verified from PremiumMath Kink Model + 2.5% Aave)
 */
contract VolatileShortVault is BaseVault {
    function initialize(
        address owner_, address asset_, address router_, address policyManager_,
        address aavePool_, address aToken_
    ) external initializer {
        __BaseVault_init(owner_, asset_, "Lumina Volatile Short", "lvsUSDC", router_, policyManager_, 37 days, aavePool_, aToken_);
    }
}
