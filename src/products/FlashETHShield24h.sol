// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseFlashShield} from "../shields/BaseFlashShield.sol";

/// @title FlashETHShield24h
/// @notice Flash shield over ETH/USD with a 24-hour window and 8.5% trigger drop.
contract FlashETHShield24h is BaseFlashShield {
    bytes32 public constant PRODUCT_ID = keccak256("FLASHETH24-001");
    bytes32 public constant RISK_TYPE = keccak256("VOLATILE");

    constructor(address _router, address _priceFeed, address _sequencerFeed)
        BaseFlashShield(_router, _priceFeed, _sequencerFeed)
    {}

    function _triggerDropBps() internal pure override returns (uint16) {
        return 850; // 8.5%
    }

    function _window() internal pure override returns (uint32) {
        return 86400; // 24h
    }

    function asset() external pure override returns (bytes32) {
        return bytes32("ETH");
    }
}
