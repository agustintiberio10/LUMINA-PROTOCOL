// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";

/// @title AtomicShieldPairDeployer
/// @notice Red-Team fix F-05 (CVSS 7.9, uninitialized-proxy front-run/takeover).
///         The previous T-30c deploy created each `ERC1967Proxy(impl, "")`
///         uninitialized and then called `initialize(...)` in a SEPARATE
///         transaction, leaving a window in which an adversary could front-run
///         the init and become `owner()` → malicious UUPS upgrade.
///
///         This helper performs the whole shield/adapter pair construction —
///         adapter impl, proxy, slim shield, `initialize`, and ownership
///         transfer to the final owner — inside a SINGLE transaction (the call
///         to `deployPair`). The proxy is therefore never observable in an
///         uninitialized state across a transaction boundary, closing the
///         front-run window entirely. The circular shield<->adapter dependency
///         (shield needs the adapter address as `router`; adapter needs the
///         shield address at init) is resolved within that one atomic call.
contract AtomicShieldPairDeployer {
    event PairDeployed(bytes32 indexed productId, address shield, address adapter, address owner);

    /// @param variant      1/24/48 = BTC 1h/24h/48h ; 101/124/148 = ETH 1h/24h/48h
    /// @param priceFeed    Chainlink aggregator for the underlying asset
    /// @param sequencer    L2 sequencer uptime feed
    /// @param productId    canonical product id (keccak of the label)
    /// @param finalOwner   address that ends up owning the adapter proxy
    function deployPair(
        uint256 variant,
        address priceFeed,
        address sequencer,
        bytes32 productId,
        address finalOwner
    ) external returns (address shieldAddr, address adapterAddr) {
        require(finalOwner != address(0), "OWNER_ZERO");

        // 1. Adapter implementation + proxy (still uninitialized at this point,
        //    but only within THIS transaction — never visible to a front-runner).
        FlashShieldAdapter adapterImpl = new FlashShieldAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(adapterImpl), "");
        adapterAddr = address(proxy);

        // 2. Slim shield with the adapter proxy as its immutable `router`.
        if (variant == 1) {
            shieldAddr = address(new FlashBTCShield1h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 24) {
            shieldAddr = address(new FlashBTCShield24h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 48) {
            shieldAddr = address(new FlashBTCShield48h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 101) {
            shieldAddr = address(new FlashETHShield1h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 124) {
            shieldAddr = address(new FlashETHShield24h(adapterAddr, priceFeed, sequencer));
        } else if (variant == 148) {
            shieldAddr = address(new FlashETHShield48h(adapterAddr, priceFeed, sequencer));
        } else {
            revert("Unknown variant");
        }

        // 3. Initialize in the SAME tx (owner becomes this helper transiently).
        FlashShieldAdapter(adapterAddr).initialize(shieldAddr, productId);

        // 4. Hand ownership to the intended final owner, still in the same tx.
        FlashShieldAdapter(adapterAddr).transferOwnership(finalOwner);

        emit PairDeployed(productId, shieldAddr, adapterAddr, finalOwner);
    }
}
