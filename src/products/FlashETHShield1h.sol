// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseFlashShield} from "../shields/BaseFlashShield.sol";

/// @title FlashETHShield1h
/// @notice Flash shield over ETH/USD with a 1-hour window and 4% trigger drop.
contract FlashETHShield1h is BaseFlashShield {
    bytes32 public constant PRODUCT_ID = keccak256("FLASHETH1H-001");
    bytes32 public constant RISK_TYPE = keccak256("VOLATILE");

    constructor() {
        _disableInitializers();
    }

    /// @notice UUPS initializer (replaces the immutable constructor wiring).
    function initialize(address _router, address _priceFeed, address _sequencerFeed) external initializer {
        __BaseFlashShield_init(_router, _priceFeed, _sequencerFeed, msg.sender);
    }

    function _triggerDropBps() internal pure override returns (uint16) {
        return 400; // 4%
    }

    function _window() internal pure override returns (uint32) {
        return 3600; // 1h
    }

    function asset() external pure override returns (bytes32) {
        return bytes32("ETH");
    }
}
