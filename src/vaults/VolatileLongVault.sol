// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "./BaseVault.sol";

/**
 * @title VolatileLongVault
 * @author Lumina Protocol
 * @notice 97-day cooldown vault for long-duration volatile products.
 *         Backs: IL Index 60-90d, BSS overflow from VolatileShort (via waterfall)
 *         Cooldown = 90d max policy + 7d safety buffer (actuarial recommendation)
 *         APY range: ~3.3-24.7% (verified from PremiumMath Kink Model + 2.5% Aave)
 */
contract VolatileLongVault is BaseVault {
    function initialize(
        address owner_, address asset_, address router_, address policyManager_,
        address aavePool_, address aToken_
    ) external initializer {
        __BaseVault_init(owner_, asset_, "Lumina Volatile Long", "lvlUSDC", router_, policyManager_, 97 days, aavePool_, aToken_);
    }
}
