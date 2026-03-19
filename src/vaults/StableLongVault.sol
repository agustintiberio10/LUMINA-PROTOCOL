// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "./BaseVault.sol";

/**
 * @title StableLongVault
 * @author Lumina Protocol
 * @notice 365-day cooldown vault for long-duration stable products.
 *         Backs: Depeg Shield up to 365d, Exploit Shield 90-365d, Depeg overflow from StableShort
 *         This is the ONLY vault that can back annual policies.
 *         Monopoly on long-term premiums → highest APY (~15-22%)
 *         Target: institutional LPs, DAO treasuries, family offices
 */
contract StableLongVault is BaseVault {
    function initialize(
        address owner_, address asset_, address router_, address policyManager_
    ) external initializer {
        __BaseVault_init(owner_, asset_, "Lumina Stable Long", "lslUSDC", router_, policyManager_, 365 days);
    }
}
