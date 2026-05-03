// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title IGlobalPauseRegistry
/// @notice Read-only view consumed by every protocol contract that opts
///         into the global pause. Defined separately so consumers don't
///         need to import the full implementation (avoids dependency
///         cycles with future registry features).
interface IGlobalPauseRegistry {
    function isGloballyPaused() external view returns (bool);
}

/// @title GlobalPauseRegistry
/// @notice [Fix M-7] Single-source-of-truth on/off switch consumed by the
///         non-redemption protocol surface (CoverRouterV2, LuminaBondMarketplace
///         non-emergency paths, BuybackEngine).
///
///         Deliberate non-coverage (per founder decisions C-4 and FIX #15):
///         - `BondVault.redeemBond` is NEVER pausable. Once a user holds a
///           ClaimBond, they always have a path to LUMINA.
///         - `LuminaBondMarketplace.emergencyCancel` is NEVER pausable.
///           A seller stuck during a pause must be able to recover their
///           bond NFT.
///         - `ClaimBond` ERC-1155 transfers are NEVER pausable. Bonds are
///           tradeable peer-to-peer regardless of protocol-wide state.
contract GlobalPauseRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Single boolean state — true means the consuming contracts
    ///         must reject their gated paths.
    bool public globalPaused;

    /// @notice Emitted on every state change. Idempotent toggles still
    ///         emit so off-chain operators can confirm the multisig
    ///         attempt landed even if the state was already at the
    ///         requested value.
    event GlobalPauseToggled(bool indexed paused, address indexed by, uint256 timestamp);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) public initializer {
        require(_owner != address(0), "GlobalPauseRegistry: zero owner");
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        // globalPaused defaults to false — protocol starts unpaused.
    }

    /// @notice Toggle the global pause. Idempotent — calling with the
    ///         current value is allowed and emits the event so off-chain
    ///         monitors can confirm the multisig signed even if the
    ///         state was already correct.
    function setGlobalPaused(bool _paused) external onlyOwner {
        globalPaused = _paused;
        emit GlobalPauseToggled(_paused, msg.sender, block.timestamp);
    }

    /// @notice Read path consumed by every gated contract.
    function isGloballyPaused() external view returns (bool) {
        return globalPaused;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
