// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "./BaseVault.sol";

/**
 * @title StableShortVault
 * @author Lumina Protocol
 * @notice 97-day cooldown vault for short-duration stable products.
 *         Backs: Depeg Shield 14-90d (via waterfall)
 *         Cooldown = 90d max policy + 7d safety buffer (actuarial recommendation)
 *         APY range: ~2.7-9.0% (verified from PremiumMath Kink Model + 2.5% Aave)
 */
contract StableShortVault is BaseVault {
    function initialize(
        address owner_, address asset_, address router_, address policyManager_,
        address aavePool_, address aToken_
    ) external initializer {
        __BaseVault_init(owner_, asset_, "Lumina Stable Short", "lssUSDC", router_, policyManager_, 97 days, aavePool_, aToken_);
    }
}
