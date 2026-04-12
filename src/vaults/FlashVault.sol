// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseVault} from "./BaseVault.sol";

/**
 * @title FlashVault
 * @author Lumina Protocol
 * @notice 7-day cooldown vault for flash-duration products.
 *         Cooldown = 604800 seconds (7 days)
 *         UUPS upgradeable, Aave V3 integrated, soulbound ERC-4626 shares.
 */
contract FlashVault is BaseVault {
    function initialize(
        address owner_, address asset_, address router_, address policyManager_,
        address aavePool_, address aToken_
    ) external initializer {
        __BaseVault_init(owner_, asset_, "Lumina FlashVault", "lmFLASH", router_, policyManager_, 604800, aavePool_, aToken_);
    }
}
