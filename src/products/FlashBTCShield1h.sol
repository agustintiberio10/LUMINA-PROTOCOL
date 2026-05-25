// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseFlashShield} from "../shields/BaseFlashShield.sol";

/// @title FlashBTCShield1h
/// @notice Flash shield over BTC/USD with a 1-hour window and 2.5% trigger drop.
contract FlashBTCShield1h is BaseFlashShield {
    bytes32 public constant PRODUCT_ID = keccak256("FLASHBTC1H-001");
    bytes32 public constant RISK_TYPE = keccak256("VOLATILE");

    constructor() {
        _disableInitializers();
    }

    /// @notice UUPS initializer (replaces the immutable constructor wiring).
    function initialize(address _router, address _priceFeed, address _sequencerFeed) external initializer {
        __BaseFlashShield_init(_router, _priceFeed, _sequencerFeed, msg.sender);
    }

    function _triggerDropBps() internal pure override returns (uint16) {
        return 250; // 2.5%
    }

    function _window() internal pure override returns (uint32) {
        return 3600; // 1h
    }

    function asset() external pure override returns (bytes32) {
        return bytes32("BTC");
    }
}
