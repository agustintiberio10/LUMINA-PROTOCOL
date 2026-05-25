// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseFlashShield} from "../shields/BaseFlashShield.sol";

/// @title FlashETHShield48h
/// @notice Flash shield over ETH/USD with a 48-hour window and 14% trigger drop.
contract FlashETHShield48h is BaseFlashShield {
    bytes32 public constant PRODUCT_ID = keccak256("FLASHETH48-001");
    bytes32 public constant RISK_TYPE = keccak256("VOLATILE");

    constructor() {
        _disableInitializers();
    }

    /// @notice UUPS initializer (replaces the immutable constructor wiring).
    function initialize(address _router, address _priceFeed, address _sequencerFeed) external initializer {
        __BaseFlashShield_init(_router, _priceFeed, _sequencerFeed, msg.sender);
    }

    function _triggerDropBps() internal pure override returns (uint16) {
        return 1400; // 14%
    }

    function _window() internal pure override returns (uint32) {
        return 172800; // 48h
    }

    function asset() external pure override returns (bytes32) {
        return bytes32("ETH");
    }
}
