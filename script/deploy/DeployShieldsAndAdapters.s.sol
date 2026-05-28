// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../src/products/FlashETHShield48h.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IPMRegister {
    function registerProduct(bytes32 productId, address shield) external;
    function productShield(bytes32) external view returns (address);
}

/// @notice Atomic factory: deploys the shield proxy + adapter proxy, initializes
///         BOTH and wires the adapter (policyManager + relayer) inside a SINGLE
///         transaction, then transfers ownership of both proxies to `finalOwner`.
///         No proxy is ever observable uninitialized across a tx boundary
///         (red-team F-05). Resolves the shield<->adapter circular dependency
///         (shield needs the adapter address as `router`; adapter needs the
///         shield address at init) within the one atomic call.
contract ShieldAdapterFactory {
    event PairDeployed(bytes32 indexed productId, address shieldProxy, address adapterProxy);

    /// @param shieldImpl  freshly-deployed shield implementation (variant-specific)
    /// @param priceFeed   Chainlink aggregator for the asset
    /// @param sequencer   L2 sequencer uptime feed (0x0 on Base Sepolia)
    /// @param productId   canonical product id (keccak of the label)
    /// @param policyManager PolicyManagerV2 proxy
    /// @param relayer     authorized relayer (settlement)
    /// @param finalOwner  ends up owning both proxies
    function deployPair(
        address shieldImpl,
        address priceFeed,
        address sequencer,
        bytes32 productId,
        address policyManager,
        address relayer,
        address finalOwner
    ) external returns (address shieldProxy, address adapterProxy) {
        // 1. Adapter impl + proxy (uninitialized — but only within THIS tx).
        FlashShieldAdapter adapterImpl = new FlashShieldAdapter();
        adapterProxy = address(new ERC1967Proxy(address(adapterImpl), ""));

        // 2. Shield proxy, initialized atomically with the adapter as `router`.
        //    `initialize(router, priceFeed, sequencer)` — owner becomes this factory.
        bytes memory shieldInit =
            abi.encodeWithSignature("initialize(address,address,address)", adapterProxy, priceFeed, sequencer);
        shieldProxy = address(new ERC1967Proxy(shieldImpl, shieldInit));

        // 3. Initialize the adapter pointing at the shield proxy (owner = factory).
        FlashShieldAdapter(adapterProxy).initialize(shieldProxy, productId);

        // 4. Wire the adapter, still in this tx.
        FlashShieldAdapter(adapterProxy).setPolicyManager(policyManager);
        FlashShieldAdapter(adapterProxy).setRelayer(relayer);

        // 5. Hand ownership of BOTH proxies to the final owner.
        OwnableUpgradeable(shieldProxy).transferOwnership(finalOwner);
        OwnableUpgradeable(adapterProxy).transferOwnership(finalOwner);

        emit PairDeployed(productId, shieldProxy, adapterProxy);
    }
}

/// @title DeployShieldsAndAdapters
/// @notice Sprint Shields-UUPS: deploys 6 NEW UUPS shields (with F-01 multi-block
///         confirmation) + 6 NEW UUPS adapters, and re-points each product in
///         PolicyManagerV2 to the new adapter (same productIds → only addresses
///         change downstream). Old shields/adapters are orphaned (deprecated).
contract DeployShieldsAndAdapters is Script {
    // ── Live Base Sepolia wiring (V5.3) ──
    address constant POLICY_MANAGER = 0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8;
    address constant RELAYER = 0x168dC7105e907294f9d066cee24f30caa5A17E4a;
    address constant BTC_FEED = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address constant ETH_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address constant SEQUENCER = address(0); // Base Sepolia has no sequencer feed

    struct Rec {
        string name;
        bytes32 productId;
        address shield;
        address adapter;
    }

    function run() external returns (Rec[6] memory recs) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address founder = vm.addr(pk);

        vm.startBroadcast(pk);
        ShieldAdapterFactory factory = new ShieldAdapterFactory();

        recs[0] = _pair(
            factory, "FlashBTCShield1h", keccak256("FLASHBTC1H-001"), address(new FlashBTCShield1h()), BTC_FEED, founder
        );
        recs[1] = _pair(
            factory,
            "FlashBTCShield24h",
            keccak256("FLASHBTC24-001"),
            address(new FlashBTCShield24h()),
            BTC_FEED,
            founder
        );
        recs[2] = _pair(
            factory,
            "FlashBTCShield48h",
            keccak256("FLASHBTC48-001"),
            address(new FlashBTCShield48h()),
            BTC_FEED,
            founder
        );
        recs[3] = _pair(
            factory, "FlashETHShield1h", keccak256("FLASHETH1H-001"), address(new FlashETHShield1h()), ETH_FEED, founder
        );
        recs[4] = _pair(
            factory,
            "FlashETHShield24h",
            keccak256("FLASHETH24-001"),
            address(new FlashETHShield24h()),
            ETH_FEED,
            founder
        );
        recs[5] = _pair(
            factory,
            "FlashETHShield48h",
            keccak256("FLASHETH48-001"),
            address(new FlashETHShield48h()),
            ETH_FEED,
            founder
        );

        // Re-point PolicyManager products to the NEW adapters (cutover).
        for (uint256 i = 0; i < 6; i++) {
            IPMRegister(POLICY_MANAGER).registerProduct(recs[i].productId, recs[i].adapter);
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < 6; i++) {
            console.log(recs[i].name);
            console.log("  shield :", recs[i].shield);
            console.log("  adapter:", recs[i].adapter);
        }
    }

    function _pair(
        ShieldAdapterFactory factory,
        string memory name,
        bytes32 productId,
        address shieldImpl,
        address feed,
        address founder
    ) internal returns (Rec memory rec) {
        (address shieldProxy, address adapterProxy) = factory.deployPair(
            shieldImpl, feed, SEQUENCER, productId, POLICY_MANAGER, RELAYER, founder
        );
        rec = Rec({name: name, productId: productId, shield: shieldProxy, adapter: adapterProxy});
    }
}
