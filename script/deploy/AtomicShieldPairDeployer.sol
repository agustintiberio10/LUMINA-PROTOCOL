// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";

/// @title AtomicShieldPairDeployer
/// @notice Red-Team fix F-05 (CVSS 7.9, uninitialized-proxy front-run/takeover).
///         The previous T-30c deploy created each `ERC1967Proxy(impl, "")`
///         uninitialized and then called `initialize(...)` in a SEPARATE
///         transaction, leaving a window in which an adversary could front-run
///         the init and become `owner()` → malicious UUPS upgrade.
///
///         This helper builds the whole shield/adapter pair inside a SINGLE
///         transaction (the call to `deployPair`): adapter impl + proxy, the
///         slim shield, the adapter `initialize`, and the ownership transfer.
///         Because create-proxy and initialize happen in the same call, the
///         proxy is never observable uninitialized across a tx boundary.
///
///         SIZE NOTE: the shield CREATION CODE is passed in as `bytes`
///         (`type(FlashXShield).creationCode`) by the size-exempt deploy Script,
///         so this contract does NOT embed any shield bytecode and stays well
///         under EIP-170 (24,576 bytes). The earlier version that `new`-ed all
///         six shield types inline compiled to ~36 KB and was undeployable.
contract AtomicShieldPairDeployer {
    event PairDeployed(bytes32 indexed productId, address shield, address adapter, address owner);

    /// @param shieldCreationCode `type(FlashXShield).creationCode` (no constructor
    ///        args appended — this helper appends `(adapter, priceFeed, sequencer)`).
    /// @param priceFeed  Chainlink aggregator for the underlying asset
    /// @param sequencer  L2 sequencer uptime feed
    /// @param productId  canonical product id (keccak of the label)
    /// @param finalOwner address that ends up owning the adapter proxy
    function deployPair(
        bytes calldata shieldCreationCode,
        address priceFeed,
        address sequencer,
        bytes32 productId,
        address finalOwner
    ) external returns (address shieldAddr, address adapterAddr) {
        require(finalOwner != address(0), "OWNER_ZERO");
        require(shieldCreationCode.length != 0, "NO_CREATION_CODE");

        // 1. Adapter impl + proxy (uninitialized at this point, but only WITHIN
        //    this transaction — never visible to a front-runner).
        FlashShieldAdapter adapterImpl = new FlashShieldAdapter();
        adapterAddr = address(new ERC1967Proxy(address(adapterImpl), ""));

        // 2. Deploy the slim shield with the adapter proxy as its immutable
        //    `router`, by appending the constructor args to the passed creation
        //    code and CREATE-ing it. No shield bytecode is embedded here.
        bytes memory bc = abi.encodePacked(shieldCreationCode, abi.encode(adapterAddr, priceFeed, sequencer));
        assembly {
            shieldAddr := create(0, add(bc, 0x20), mload(bc))
        }
        require(shieldAddr != address(0), "SHIELD_DEPLOY_FAILED");

        // 3. Initialize the adapter in the SAME tx (atomic) and hand ownership
        //    to the final owner.
        FlashShieldAdapter(adapterAddr).initialize(shieldAddr, productId);
        FlashShieldAdapter(adapterAddr).transferOwnership(finalOwner);

        emit PairDeployed(productId, shieldAddr, adapterAddr, finalOwner);
    }
}
